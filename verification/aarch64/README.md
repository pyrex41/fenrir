# Fenrir AArch64 verification lane

> This lane was imported from `claude/keen-ptolemy-w9d7ve`. The recorded runs
> below are historical Linux x86-64 results, not results from ARM64 CI.

This lane compiles closed subsets of existing TC0-A pure-call artifacts to real
AArch64 function bytes, proves the compilation in Rocq, and checks the bytes'
execution under QEMU against the existing independent Fenrir candidate. It is
separate from TC0 qualification and from the Solo5 campaign.

**The proofs end at a handwritten instruction model.** They do not prove
correspondence with Arm's authoritative semantics, the JSON projection, loading,
Linux process execution, Solo5, or the complete Fenrir language. These are
explicit missing theorems, not axioms introduced into the proofs.

Status under the amendment's vocabulary (§9): *implementation refinement proved*
for two closed profiles against that model (three since 15 November: unary, expr, call); the source side is related to the
Shen model by test only (below).

## Run

```sh
sh verification/aarch64/check.sh
```

Run on Linux (`aarch64-linux` or `x86_64-linux`) with Nix flakes enabled.
The script resolves the host's `.#aarch64-verification` and `.#shen-jit` from
the checked-in lockfile. The same check runs on GitHub Actions on an ARM64
runner and an x86-64 runner, both using `qemu-aarch64` for the generated
executables. That is QEMU user-mode evidence even when the host is ARM64.

### Toolchain contract

- `packages.<system>.aarch64-verification`: a single prefix exposing
  `bin/rocq` (`rocq compile`), `bin/rocqchk`, and
  `lib/coq/9.3/user-contrib/Stdlib`. Use `rocqPackages_9_3` from the pinned
  nixpkgs: Rocq 9.3.0 (Búri's pin, amendment §3) and Stdlib V9.2.0.
  Ubuntu 24.04's Coq does not provide this `Stdlib` namespace.
- The same prefix exposes `bin/node` (Node 22), `bin/qemu-aarch64` (QEMU
  user mode 11.1.1, no KVM needed), and GNU binutils 2.46 `as`, `ld`, and
  `objcopy` with either the `aarch64-unknown-linux-gnu-` or
  `aarch64-linux-gnu-` prefix. On x86-64 use AArch64 cross binutils. On ARM64
  the native binutils lack a prefix, so expose explicit AArch64-prefixed
  aliases to the native tools. Do not alias unqualified x86-64 tools.
- `packages.<system>.shen-jit`: the pinned host-native Shen/JIT 0.7 with
  `bin/shen-jit` and `lib/`, including `shen-process.so` for the differential
  harness. If exposing a `devShells.<system>.aarch64-verification`, set
  `ROCQPATH` to the same `user-contrib` directory for direct tool use.
- `FENRIR_AARCH64_TOOLS` and `FENRIR_SHEN_JIT` can supply absolute install
  prefixes matching the layout above instead of building either output.

### Checks

The script fails on a missing tool or failed check. It runs:

1. `node --test tests/aarch64/*.test.mjs`;
2. `node tools/aarch64/check.mjs` — profile `fenrir-aarch64-checked-unary/1` as
   published in PR #8 (only its tool names now go through `toolchain.mjs`);
3. `node tools/aarch64/check-expr.mjs` — profile `fenrir-aarch64-checked-expr/1`;
4. `node tools/aarch64/check-call.mjs` — profile `fenrir-aarch64-checked-call/1`;
5. `sh harness/run-aarch64-differential.sh` — the source semantics of all three
   profiles against the Shen model.

It writes a fresh `build/aarch64/check-*/summary.json` with paths to each
report. CI uploads `build/aarch64/` separately for each host, including logs
on failure. Status is `development-pass`, never a qualification receipt.

Latest recorded run, 15 November 2026, with the call profile
([validation-2026-11-15-call.json](validation-2026-11-15-call.json)), 6 min 21 s
on Linux x86-64 (the earlier record without it is
[validation-2026-11-15.json](validation-2026-11-15.json)):

| Part | Result |
| --- | --- |
| Unit tests | 12 passed, 0 failed |
| Unary profile | Core.v plus 12 exact-image theorems closed under the global context; rocqchk replay passed; 12 GNU-as byte agreements; 564 QEMU comparisons agree with `PureCallMachine`; 3 mutated binaries rejected by proof and by execution |
| Expr profile | 6 modules compiled; `compile_correct` and `compile_correct_typed` closed under the global context; 70 programs (30 hand, 40 generated) each with an exact-image theorem closed under the global context; 70 GNU-as byte agreements; 2,520 QEMU comparisons (70 × 36 inputs: 1,335 Ok I64, 535 Ok Bool, 573 Overflow, 77 DivZero) agree with `PureCallMachine`; 10 single-instruction mutants each rejected by its byte-identity proof and diverging under QEMU; rocqchk replayed all 76 modules |
| Call profile | 7 modules compiled; `call_correct`, `tail_calls_constant_stack`, `tail_program_correct` closed under the global context; 14 programs (12 hand on 36 boundary inputs, plus deep recursion at 60,000 frames and a 200,000-iteration tail loop on 2 inputs each), each with `exact_image_correct` closed, and the 5 tail-only ones also with `exact_image_tail_correct` (constant stack) closed; 14 GNU-as byte agreements; 436 QEMU comparisons (345 Ok I64, 36 Ok Bool, 54 Overflow, 1 DivZero) agree with `PureCallMachine`, the launcher checking `sp` after every call; 8 frame mutants (saved link register, link reload slot, trap-path SP restore, frame-base restore, call target, callee status test, tail frame release, tail target) each rejected by its byte-identity proof and diverging under QEMU (6 crash or fail the SP check, 2 give different results); rocqchk replayed 21 modules |
| Shen differential | 94 programs (12 unary, 70 expr, 12 call) × 40 inputs = 3,760 cases (480 call cases); the Shen model completed every case (2,293 Ok I64, 633 Ok Bool, 748 Overflow, 86 DivZero); Rocq proved `failures = []`; the control file with four falsified expectations (one per profile kind) was refuted at exactly those four cases |

Not run here: physical ARM hardware, Sail/Islaris, Solo5 on AArch64, a second
Shen port, and this repository's GitHub Actions workflow (configured, its
remote result is not part of this record).

## Profiles

### `fenrir-aarch64-checked-unary/1` (PR #8, unchanged)

One pure `I64 → I64` function whose body is the parameter or a chain of `add`
or `sub` by a literal in 0..4095 and `neg`. Each operation is followed by
`b.vc` over an inline overflow return. Its PC is the remaining-instruction
list and registers are signed integers. Theorems in [Core.v](Core.v), whose
only edit is the Rocq 9 import prefix:

| Theorem | Meaning |
|---|---|
| `source_lowering` | Source AST evaluation equals sequential operation evaluation |
| `signed_fits` | Signed normalization preserves in-range integers |
| `flag_correct` | Instruction sign conditions detect exactly mathematical overflow |
| `decode_word` | Every admitted arithmetic encoding decodes back to its operation |
| `compiler_correct` | Every finite admitted operation sequence returns the correct result/trap in the handwritten model, regardless of initial V/status |
| `expression_binary_correct` | Composition from admitted source AST to encoded instructions for all signed-I64 inputs |
| Generated `image_identity` | Exact emitted byte list decodes to the proved instruction sequence |
| Generated `exact_image_correct` | Those exact bytes implement the projected source AST in the model for every signed-I64 input |

### `fenrir-aarch64-checked-expr/1` (new)

One pure function `I64 → I64` or `I64 → Bool` with no other declarations,
whose body uses only: I64 and Bool literals, the parameter and `let`-bound
variables, `let`, `if`, `neg`, `not`, `add`/`sub`/`mul`/`div` between arbitrary
subexpressions, and `lt`/`le`/`gt`/`ge`/`eq` (I64 or Bool operands for `eq`). The
closed TC0 validator runs first; every other well-typed construct (calls,
lambdas, `emit`, data) is rejected, not dropped. An image is admitted only if
every encoded field fits (`encodable`), which bounds code size (±1 MiB branch
range) and stack depth (2,047 slots for variable offsets); no profile program
comes near these.

Code shape: `x9` holds the frame base; the parameter and every `let` value
live in 16-byte stack slots addressed from `sp`; a binary operation evaluates
its left operand, pushes it, evaluates the right operand, pops the left into
`x1`. Each check is inline and returns at once with the trap status: `adds`/
`subs` then `b.vc`; `smulh`, `mul`, `cmp hi, lo, asr #63` then `b.eq`;
`cbnz` for the zero divisor and `cmn`/`b.ne`/`negs xzr`/`b.vc` for MIN / −1
before `sdiv`; `cmp` then `csinc` for comparisons; `cbz`/`b` for `if`. Nothing
is reordered: `(x + 1) - 1` traps at maximum I64, an operand's trap is the
expression's trap, and a branch not taken is never evaluated.

### `fenrir-aarch64-checked-call/1` (new)

A table of first-order functions, each with one I64 or Bool parameter and an
I64 or Bool result (the entry takes an I64). A body is a statement over the
expr profile's call-free expressions: an expression, `let x = e in s`,
`if c then s else s`, `let x = call g a in s`, or `call g a` in tail position.
Calls anywhere else (inside arithmetic, as an argument, as an `if` condition)
are rejected by the projection, not rewritten. Recursion and mutual recursion
are allowed. The convention is pinned as `fenrir-aarch64-call-abi/1` in
[ABI.md](ABI.md): every function saves the return address in its frame, the
caller reloads it after each `bl` and recomputes its frame base, a callee's
trap is returned to the caller in `x1` and passed on, and a tail call releases
the frame and branches.

**Machine.** The expr machine (`Machine.step`) ends at `RET`; it is kept, with
its theorems, for the earlier profiles. `CallCompile.step_c` is the same
machine except that `RET` jumps to `X[n]`, and a run ends when the PC reaches
the entry link address (outside the image). Because both agree on every step
that is not a `RET` (`sim_step`), the expression fragment theorem
`Compile.comp_correct` is reused unchanged through a simulation lemma rather
than re-proved; only `RET` and `BL` steps are reasoned about anew. This was the
smaller of the two options: re-proving the expr profile on the new machine
would have repeated its whole fragment proof.

**Source.** `CallCompile.sexec`/`fcall`/`ceval` transcribe the model: the
argument is evaluated first (`tc0.pc.collect`, Tail false), then
`tc0.pc.enter` runs the named function's body in the environment `[[Id Arg]]`
with no captures; an unwinding trap passes every frame, so a callee's trap is
the caller's; and a call in tail position (the body is entered by
`[evaluate Body true]`, `let` bodies and `if` branches keep `Tail`) enters the
callee with no `return` frame — the first clause of `tc0.pc.enter`. The
semantics is indexed by fuel (calls allowed) and also returns the stack slots
the evaluation needs.

**Termination and stack hypotheses, exactly.** `call_correct` assumes
`fcall fuel prog main (VInt x) = Some (r, n)` for some fuel — the source
terminates with result `r` — and `lo ≤ sp − 16·n`. `n` is the number of
16-byte slots used below the entry `sp`: within one activation, 2 (parameter,
saved link register) plus `let` slots plus expression temporaries
(`d + depth e` at each point); across a non-tail call, the slots in use at the
call site plus the callee's `n`; across a tail call, the callee's `n` alone.
Stack overflow is outside the theorem; nontermination too.

## What is proved

[Expr.v](Expr.v) (source), [Machine.v](Machine.v) (instruction model),
[Flags.v](Flags.v), [Encode.v](Encode.v), [Compile.v](Compile.v):

| Theorem | Statement in words |
| --- | --- |
| `Expr.type_safety` | If `typeof G e = Some t` and the environment's values have the types `G`, then `eval env e` is `Some r` and `r` is a trap or a value of type `t` (I64 values inside the I64 range) |
| `Flags.addsub_fst/N/Z/V` | The AddWithCarry transcription's result is the signed normalization of `x ± y`; N, Z and V are its sign, zero test and "not in I64" |
| `Flags.cmp_conditions` | After `SUBS` of two in-range values, ConditionHolds for GE, LT, GT, LE, EQ, NE is exactly `y ≤ x`, `x < y`, `y < x`, `x ≤ y`, `x = y`, `x ≠ y` |
| `Flags.mul_check` | For in-range `a`, `b`: EQ after `CMP SMULH(a,b), MUL(a,b) ASR 63` holds exactly when `a·b` is in I64 |
| `Flags.quot_overflow` | For in-range `a` and non-zero in-range `b`, the truncated quotient is in I64 exactly unless `a = MIN ∧ b = −1` |
| `Flags.load_imm_value` | MOVZ then three MOVK of the four 16-bit halves of an in-range `n` leave `n` |
| `Encode.decode_encode` | For every instruction whose fields fit, `decode (encode i) = Some i` |
| `Encode.image_decodes` | For every list of such instructions, its little-endian byte image decodes back to the list |
| `Compile.compile_correct` | For every source `e`, input `x` and machine state `s` with in-range registers, PC 0, `x0 = x`, 16-byte-aligned `sp` and 16·(1 + depth e) bytes of stack below it: if `eval_main e x = Some r` then there is a final state `f` such that for every fuel ≥ the code length the interpreter returns `f` (it reaches `ret` within that many steps); `f`'s PC is the entry `x30`, `sp` is restored, every register other than x0–x3 and x9 and all memory at or above the entry `sp` are unchanged, and `x1 = 0 ∧ x0 = repr v` when `r = Ok v`, `x1 = trap_code t` when `r` is trap `t` |
| `Compile.compile_correct_typed` | The same for every `e` with `typeof [TInt] e = Some t` and every in-range `x`, with `eval_main e x` shown to exist and have type `t` |
| `CallCompile.sim_steps` | Every execution of the expr machine without a RET step is an execution of the call machine |
| `CallCompile.call_correct` | For every function table `prog` whose image fits (`4·length ≤ 2^63−1`), every entry `main`, input `x`, machine state `s` with in-range registers, PC at `main`'s first instruction, `x0 = x`, 16-byte-aligned `sp`, `x30 = exit` outside the image: if `fcall fuel prog main (VInt x) = Some (r, n)` and `lo ≤ sp − 16·n`, then for every fuel ≥ some k the run returns a state `f` with PC = `exit`, `x30 = exit`, `sp` restored, all registers but x0–x3, x9, x30 and all memory at or above the entry `sp` unchanged, and `x1`/`x0` encoding `r` |
| `CallCompile.tail_calls_constant_stack` | If no body contains a non-tail call, every `fcall fuel prog g v = Some (r, n)` has `n ≤ table_need prog`, for every fuel, i.e. for any number of iterations |
| `CallCompile.tail_program_correct` | For such a table, `call_correct` holds with the constant hypothesis `lo ≤ sp − 16·table_need prog` instead of `n` |
| Generated `image_identity` | The exact emitted bytes equal `image_of (compile_fn source)` (kernel `vm_compute`) |
| Generated `exact_image_correct` | Any code the exact bytes decode to satisfies `compile_correct_typed` for `source` |

`Print Assumptions` for `compile_correct`, `compile_correct_typed`,
`call_correct`, `tail_calls_constant_stack`, `tail_program_correct` and every
generated `exact_image_correct`/`exact_image_tail_correct`: *Closed under the
global context*. No `Admitted`, no
axioms. The trap behaviour and left-to-right order are part of `eval`, hence
of every statement.

### What "implementation refinement proved" covers here

- **A handwritten instruction model.** `Machine.v` transcribes the Arm ARM
  pseudocode for the instructions used (AddWithCarry, ConditionHolds,
  ShiftReg, MADD, SMULH, SDIV, CSINC, MOVZ, MOVK, LDR/STR immediate with the SP
  alignment check, B, B.cond, CBZ/CBNZ, RET). The flag and condition facts are
  proved from the transcription, not defined as the answers. Nothing relates
  the transcription to Arm's machine-readable specification.
- **Registers as bounded mathematical integers.** X0–X30 and SP hold the
  SInt of their 64 bits, an integer in [−2^63, 2^63); `wf` is that range
  invariant and every instruction preserves it (`step_wf`). UInt is recovered
  modulo 2^64. PC is a byte offset from the image start (aligned fetch of the
  image's words), not an address. Memory is a map from addresses to
  doublewords: no bytes, no overlapping accesses, permissions, faults or other
  agents.
- **No ISA correspondence, no loader, no ABI beyond [ABI.md](ABI.md).** In the
  expr machine RET ends the modelled execution; in the call machine the run
  ends at the external link address. The external caller, the image's
  placement and stack overflow are not modelled.

## Source semantics and the Shen model

The lane's source semantics is **local to the lane**: `Core.eval_expr`, `CallCompile.ceval` and
`Expr.eval_main` are Rocq definitions written by hand, each rule citing the
function of [models/tc0/pure-call-machine.shen](../../models/tc0/pure-call-machine.shen)
or [models/tc0/i64.shen](../../models/tc0/i64.shen) it transcribes. There is no
proof that they agree with the Shen model; the amendment (§3) puts that route
through Búri's KLambda semantics. What exists is a test:
[harness/aarch64-differential.shen](../../harness/aarch64-differential.shen)
runs the model on every program the lane proves and runs, over the I64 boundary
inputs, and Rocq checks the lane's definitions against the model's outcomes
(3,760 cases agree, 480 of them call-profile cases; table above). Outside those cases agreement is unknown.

## Trust and evidence boundaries

1. **Projection (open, ARM-02).** `tools/aarch64/compile.mjs` and `expr.mjs`
   turn artifact JSON into the Rocq AST. This is unverified. The differential
   test exercises it (it uses the same projection), but proves nothing about it.
2. **ISA (open, ARM-03).** The decoder and interpreter are handwritten. GNU
   assembly agreement and QEMU runs test them. ARM-03 builds on Búri's ARM
   foundation (Sail model, Islaris environment, a first byte-level lemma against
   the Armv9.4 model; [PLAN.md](PLAN.md)).
3. **Execution (open, ARM-04).** Loading, executable permissions, instruction
   fetch from addresses, return-address validity, exceptions, caches, other
   cores, hardware faults. The QEMU launcher and its Linux syscalls are tested
   infrastructure outside every theorem.
4. **Checking.** Rocq's kernel and its build remain trusted; `rocqchk` replays
   the compiled objects but is not an independent kernel. Generated instances
   use kernel-checked `vm_compute`.
5. **Scope.** Neither TC0-A qualification status nor the Solo5 epochs change.
   No oracle, golden, controller or gate is edited. Proved code reaches a Solo5
   guest only once the Solo5 lane builds for AArch64 (amendment §7 item 5).

See [PLAN.md](PLAN.md) for the route to a reusable, authoritative ARM backend
and [VALIDATION.md](VALIDATION.md) for the recorded runs.
