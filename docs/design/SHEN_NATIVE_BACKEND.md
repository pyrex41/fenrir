# The Shen ARM64 backend

The standalone CLI and the prover, HTTP, framed-log and durable-job builders
default to Shen on macOS ARM64 and Solo5 ARM64 SPT. Set
`FENRIR_NATIVE_BACKEND=javascript` for the pre-migration comparison path.
The baseline revision is `94f3b1b4c7b1092645c139df07a92392406bb535`.

## From artifact to executable

The frontend elaborates and validates a source artifact. The standalone build
checks it against the execution profile, then invokes
[emit.shen](../../backends/arm64/emit.shen). Pure scalar programs lower to the
two-word result ABI using [scalar.shen](../../backends/arm64/scalar.shen).
The [managed emitter](../../backends/arm64/managed.shen) handles constructors,
bytes, pattern matching, closures, tasks, handlers and application host calls.
Both paths emit target assembly. Clang or the Solo5 assembler and linker
combine it with the C runtime.

Managed frames keep traced pointers and scalar temporaries in separate arrays.
The compiler links roots for calls that could collect and unlinks them before
tail transfers. Exported functions accept a boxed parameter. Known direct calls
can use x8–x15 when the callee destructures a tuple completely. A self tail call
moves all outgoing fields before clearing iteration roots and rebinding inputs.
Closure field zero contains the entry address. Up to seven fields hold captures.

The [handler pass](../../backends/arm64/handler-context.shen) splits a strict
clause expression into earlier operands, its one-shot use, the answer binder and
the residual expression. Its verifier checks the resumption identity and one
residual reference to each synthetic operand and answer. The generated clause
can defer that residual work until the handled body returns or its scopes have
unwound. The executable Shen source model continues to compute expected events
and outcomes independently.

Node runs the frontend's independent artifact validator. Standalone packaging
also uses it for admission, runtime configuration and the execution-profile
stamp. Application builders use Node to validate artifacts and describe host
exports and the durable worker's Store ABI. The JavaScript image emitter loads
only when selected for comparison.

## Verification

Run the following commands from the checkout. Each evidence directory must
be new. Solo5 execution on macOS needs the ARM64 container image described
in the [native guide](../NATIVE_GUIDE.md).

```sh
python3 tests/native/check-handler-roundtrips.py --all build/shen-roundtrips
python3 tests/native/check-handler-roundtrips.py --native-fixtures build/shen-handlers \
  discontinue-joins-child.fen cancel-during-trap.fen resume-under-perform.fen \
  resume-before-perform.fen resume-conditional-operand.fen resume-conditional-trap.fen
python3 tests/native/check-task-limits.py bin/fenrir build/shen-quotas
python3 tests/native/check-dispatch-replay.py build/shen-replay
LLVM_OBJDUMP=$(xcrun --find llvm-objdump) node tools/aarch64/check-shen-tables.mjs build/shen-tables
```

The last command assembles the uninstrumented Shen functions and compares every
byte with the verification compiler on the 70 expression fixtures and 14 call
fixtures. For matching bytes, the Rocq instance establishes
`image_identity`, `image_decodes_to_compiler` and `exact_image_correct`
under that profile’s premises. Five call fixtures additionally satisfy
`exact_image_tail_correct` for bounded stack use across tail iterations. The expression-profile checks exercise their
single-function prologue. Standalone builds use the call ABI and insert branches
to source-reporting trap stubs. The separate unary verification compiler, JSON
projection, managed emitter, assembler/linker integration, and complete CLI
images have distinct evidence boundaries. The whole-image path is checked by
execution. See the [Rocq lane](../../verification/aarch64/README.md) for the
statement and assumptions of each theorem.

The [package tests](../NATIVE_GUIDE.md) exercise installs outside the checkout.
The application gate checks prover certificates, concurrent HTTP clients, large
framed streams and the durable recovery history. Set `FENRIR_TEST_WITHOUT_JS_EMITTER=1` for the application gate to move
both comparison emitters out of the editable package copy before building.

## Performance comparison

Use the same generated source, validated artifact and host runtime for each
compiler. The prover comparison measures assembly generation independently of
linking and execution. Mac timings include a fresh process. Solo5 timings use
the guest monotonic clock around the repeated kernel. Both lanes check the
work count and alternate backend order.

```sh
git worktree add --detach ../fenrir-js-baseline 94f3b1b4c7b1092645c139df07a92392406bb535
python3 benchmarks/prover/run-fenrir.py macos-arm64 > build/verified-prover.rows
python3 benchmarks/prover/compare-backends.py ../fenrir-js-baseline build/verified-prover.rows build/backend-timings
```
