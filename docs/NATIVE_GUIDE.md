# Building and testing Fenrir on ARM64

## Build a native ARM64 program

The alpha plan defines the supported targets, four reference applications,
release gates, and commands for reproducing both kernel scorecards.
[Alpha and performance plan](WORK_FILE.md)

On Apple Silicon with Nix, build the development package from the source
checkout with `nix build .#fenrir`. The installed CLI is `./result/bin/fenrir`.
For a working tree with new compiler files awaiting their first commit,
`sh tools/aarch64/package-mac.sh` builds a snapshot and prints its store path.
For a qualification campaign, use
`sh tools/aarch64/package-mac.sh --out-link ./campaign-package ./fenrir-source.tar.gz`.
The new link keeps the package and its toolchain available across Nix garbage
collection. Keep it until the campaign and its verification have finished.
It carries the pinned Shen/JIT 0.12 built from the upstream tag, its compiled process
extension, Node, Python and Clang in its Nix closure. For work in the checkout,
`nix develop` supplies the same Shen/JIT frontend. The Solo5 target also needs
an ARM64 Linux Docker engine and guest toolchain image. With a fresh engine,
`python3 tools/solo5/setup.py --repeats 1` builds and probes a pinned Solo5
source checkout. Select its recorded image ID for subsequent commands:

```sh
export FENRIR_SOLO5_IMAGE=$(python3 -c 'import json; print(json.load(open("build/solo5/setup.json"))["image_id"])')
sh tests/native/check-package.sh "$(pwd)/result/bin/fenrir" "$TMPDIR/fenrir-install-test-$$"
```

To hand a candidate to a second engineer, run
`sh tools/aarch64/package-mac.sh ./fenrir-source.tar.gz` and supply the
archive, its printed SHA-256, and the printed package store path. On a
separate Apple Silicon Mac with Nix, verify the digest and build in a fresh
directory. The extracted sources include the locked flake and the release
exercises. The archive and installed source tree carry the language surface
and typing rules in `spec/tc1`, the native ABI and proof scope in
`verification/aarch64`, native regression programs in `tests/native`, and
the service history controls in `tests/host/histories`.

```sh
shasum -a 256 fenrir-source.tar.gz
mkdir fenrir-candidate
tar -xzf fenrir-source.tar.gz -C fenrir-candidate
cd fenrir-candidate
package=$(nix build --no-link --print-out-paths "path:$PWD#fenrir")
printf '%s\n' "$package"
```

Compare the store path with the supplied one. Prepare the ARM64 Docker
engine and select its Solo5 image as above. Run the two exercises below
from a separate writable directory. Retain the package and image IDs, Mac
model and macOS version, the CLI trap/replay receipts, and
`app-check/summary.json` with the engineer's observations.

An installed package also carries both qualification scripts. From a writable
directory outside the checkout, set `package` to the absolute Nix store path
printed by the build. With the ARM64 Docker engine and toolchain image ready,
run the following commands. The packaged `fenrir-toolchain` supplies Erlang/OTP
for the supervisor and Elixir for the BEAM reference worker.

```sh
src="$package/libexec/fenrir"
"$package/bin/fenrir-toolchain" sh "$src/tests/native/check-package.sh" "$package/bin/fenrir" "$PWD/cli-check"
"$package/bin/fenrir-toolchain" sh "$src/tests/native/check-package-apps.sh" "$package" "$PWD/app-check"
```

For a fresh engine, copy `$src` to a writable directory, give the copy owner
write access, and run the Solo5 setup command above from that copy.

The exercise creates a program with a local library, builds it for both
targets, records a normal result and an overflow, checks the source location
in the library, and replays the trap against each image. A second program yields,
emits its task ID, then traps in the library. A concurrent program sends a
computed value through a bounded channel and awaits its worker. The exercise
records and replays the dispatch sequence, edits the imported library, and
verifies that the rebuilt program produces the new value on each target.
It then replays the original executable against its original receipt. The
application exercise renames the HTTP status route to `/health` in the
writable Fenrir source, rebuilds both servers, and checks the new response
and the 404 from the old route over TCP.

The Mac package includes editable sources for the prover, HTTP service,
durable worker, framed-log processor and their comparison implementations.
To work in a new directory, copy the application sources and use the
packaged toolchain to run the build scripts. From the checkout with the
Nix package at `./result`:

```sh
package=$(cd result && pwd -P)
cp -R "$package/libexec/fenrir" fenrir-apps
chmod -R u+w fenrir-apps
cd fenrir-apps
"$package/bin/fenrir-toolchain" python3 benchmarks/prover/run-fenrir.py macos-arm64 --formula '> z z' --budget 3
"$package/bin/fenrir-toolchain" sh benchmarks/framed-log/build-mac.sh ./stream
"$package/bin/fenrir-toolchain" python3 benchmarks/framed-log/check.py ./stream
"$package/bin/fenrir-toolchain" sh benchmarks/framed-log/build-spt.sh ./stream.spt
"$package/bin/fenrir-toolchain" python3 benchmarks/framed-log/check-spt.py ./stream.spt
```

To run your own prover corpus with that installed package, give each goal a
unique ASCII name, expected outcome, node budget and prefix formula. This
example exercises a proof, a countermodel and fuel exhaustion on both targets.

```sh
cat > goals.txt <<'EOF'
identity proof 3 > z z
open model 2 a
limited exhausted 1 > z z
EOF
for target in macos-arm64 solo5-arm64-spt; do
  "$package/bin/fenrir-toolchain" python3 benchmarks/prover/run-fenrir.py "$target" --corpus goals.txt
done
```

Each invocation prints the following verified rows.

```text
identity proof 3 ssx
open model 2 0
limited exhausted 1 -
```

Each application directory under `benchmarks` documents its workload and
reference runtimes. From the checkout, run
`sh tests/native/check-package-apps.sh ./result NEW_DIRECTORY` to build all
four applications from the installed sources. This exercise checks prover
certificates and countermodels, HTTP responses under concurrent clients,
streaming validation, supervised worker recovery, and replay of the retained service-model counterexamples in the packaged `spec/service` directory. It retains the model
verdicts and package identity in `NEW_DIRECTORY/summary.json`. The Mac
recovery exercise also needs Erlang/OTP with the `json` module and the
`erlc` and `escript` executables on PATH.
The Solo5 builds use the ARM64 Docker engine configured
above. Cross-language comparisons also require the indicated reference compilers.

To compare the complete frontend round-trip corpus against Shen on both
native targets, run the following command from the checkout. The output
directory must be new. Each case retains the source digest, build transcript,
native image digest, oracle observations, exit status, and native output.

```sh
"$package/bin/fenrir-toolchain" python3 tests/native/check-handler-roundtrips.py --all build/native-roundtrips
```

Scalar CLI images
add source-reporting branches on arithmetic trap paths. The existing Rocq
exact-image results apply to the function tables produced by the verification
compiler. The instrumented CLI images have execution-test coverage.

The installed CLI and the four preview application builders use the Shen ARM64
backend by default. Set `FENRIR_NATIVE_BACKEND=javascript` when building to
select the comparison compiler. Node runs the independent artifact validator
and prepares standalone profile metadata. Some application builders also use
Node for host bindings and build orchestration. Both compilers link against
the same native C runtime.

The installed Shen emitter reproduced the exact bytes of 70 expression and 14
call function tables covered by the Rocq checks. The release suite separately
compared source-model observations with native execution and exercised the
four application builds with the JavaScript emitters removed. The release
record identifies the tested package and the commands to repeat these checks.
[Proof scope](design/SHEN_NATIVE_BACKEND.md#verification) · [Installed checks and measurements](../verification/backend-migration/README.md)

### Choose an execution profile

The public CLI builds standalone programs with the `fenrir-native-standalone/1`
profile. Both targets take one I64 input and return a serializable value.
`fenrir profile` prints the versioned JSON descriptor with the supported targets,
artifact schemas, adapter conditions and compiler limits. A source closure or
compiler-generated handler closure can capture up to seven bindings. Native
frontend validation accepts up to 2,000 expression nodes.

| What you want to check or run | Command from the checkout |
|---|---|
| Validate syntax, types and effects, including programs that need a host | `bin/fenrir check SOURCE` |
| Validate and lower every function to assembly for a standalone target, without invoking a linker or Docker | `bin/fenrir check --target TARGET SOURCE` |
| Evaluate the admitted artifact in Shen at input 0 with the standalone task and inherited-handler limits | `bin/fenrir model --profile fenrir-native-standalone/1 SOURCE` |
| Build or run that same standalone program | `bin/fenrir build --target TARGET SOURCE -o IMAGE` or `bin/fenrir run --target TARGET SOURCE I64` |
| Run the accepted-job worker with its durable host | `sh host/service/check-supervised-recovery.sh fenrir-native-spt` on the configured development Mac |
| Run the ledger caller and peer using their system manifest | `sh supervisor/run.sh` in a Linux repository checkout with Solo5 and Erlang |

A durable operation handled entirely by the program can execute standalone.
A remote declaration can also appear when no function performs a remote
operation. The public target check identifies sources that need either adapter
before linking. For task programs, the model command also takes a schedule after
the source path, such as `fifo` or a JSON file of task IDs as decimal strings.
The default is FIFO. Both the Shen model and the native runtime check the
spawn limits of 16 live children and 32 inherited handlers per child. The
standalone compiler also fixes the native managed heap at 1,024 object slots
and the stack for each scheduled task, including the root, at 262,144 bytes.
Heap exhaustion and machine-stack consumption require a native run to observe.
The native runtime covers checked arithmetic, tuples,
constructors, pattern matching, closures, handlers and structured tasks.

From the checkout on Apple Silicon:

```sh
bin/fenrir profile
bin/fenrir check --target macos-arm64 examples/recursive-sum.fen
bin/fenrir test --target solo5-arm64-spt examples/closures.fen examples/bytes.fen
bin/fenrir run --target macos-arm64 examples/list-sum.fen
bin/fenrir run --target solo5-arm64-spt examples/recursive-sum.fen 10
bin/fenrir build --target macos-arm64 examples/recursive-sum.fen -o ./sum
./sum 10
bin/fenrir record macos-arm64 ./sum 10 sum-run.json
bin/fenrir replay ./sum sum-run.json
bin/fenrir build --target solo5-arm64-spt examples/recursive-sum.fen -o ./sum.spt
```

Native replay checks the caller-supplied image digest, input, exit status, and
combined console bytes, including emitted values and trap locations. Version 2
receipts also check the launcher digest, OS, architecture, and kernel release.
For Solo5 they identify the container image on Mac or the tender digest on
ARM64 Linux. New standalone images also embed the target, profile ID, and SHA-256 of the exact JSON printed by `fenrir profile`. Observation receipts (version 3) and schedule receipts (version 2) bind this identity to the executable. Replay checks the embedded identity before launch. Earlier images and receipts retain their original checks.

For a compiled task program, record the native dispatch sequence with
`bin/fenrir record-schedule TARGET IMAGE I64 RECEIPT`. The default records
FIFO execution. Append a file containing a JSON array of unsigned task IDs
to execute an explicit order. Run `bin/fenrir replay IMAGE RECEIPT` to
dispatch those same tasks and compare the outcome and console bytes.
The command supports up to 240 dispatches and 960 characters of
comma-separated IDs. An incomplete schedule, an unavailable task, or
choices remaining after termination cause recording to fail. Gleipnir
provides the separate model-level schedule harness.

Both images take a decimal I64 argument. The example prints 55 for input 10.
Run the guest on Linux ARM64 with `solo5-spt ./sum.spt 10`. The frontend uses
the Shen/JIT installation described in `harness/jit.sh`. Darwin linking uses
Apple Clang. For guest linking on macOS the CLI uses Docker and the ARM64
development image `fenrir-track1-solo5:38e0c348be23-arm64`;
`FENRIR_SOLO5_IMAGE` selects another compatible image with tools under
`/opt/solo5-install`. On ARM64 Linux it uses the installed Solo5 tools on
PATH or under `$FENRIR_SOLO5/bin`.

