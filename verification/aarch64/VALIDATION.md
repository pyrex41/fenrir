# Recorded development validation — 2026-11-15, with the call profile

Base: `claude/keen-ptolemy-w9d7ve` at `3674ec1` plus the call-profile commits.
Entry point `sh verification/aarch64/check.sh`, 6 min 21 s, same tools as the
record below. Full record: [validation-2026-11-15-call.json](validation-2026-11-15-call.json).

- Unary and expr profiles: unchanged results (12 + 70 exact-image theorems,
  564 + 2,520 QEMU comparisons, 3 + 10 rejected mutants), now with `BL` in
  the instruction type and decoder; every earlier proof re-checks.
- `fenrir-aarch64-checked-call/1`: `call_correct`, `tail_calls_constant_stack`,
  `tail_program_correct` closed under the global context; 14 programs, each
  with `exact_image_correct` closed, 5 tail-only ones also with
  `exact_image_tail_correct`; 14 GNU-as byte agreements; 436 QEMU comparisons
  agree with `PureCallMachine` (including 60,000-deep recursion and a
  200,000-iteration tail loop); 8 frame mutants rejected by proof and by
  execution; rocqchk replayed 21 modules.
- Shen differential: 94 programs × 40 inputs = 3,760 cases (480 call cases);
  `failures = []` proved; a 4-case falsified control refuted exactly.
- `node --test tests/tc0/*.test.mjs tests/tc1/*.test.mjs tests/aarch64/*.test.mjs`:
  228 passed, 0 failed, 0 skipped.

Not run: physical ARM hardware, Sail, Islaris, Solo5 on AArch64, the GitHub workflow.

# Recorded development validation — 2026-11-15

Base: this branch after merging PR #8 (`codex/aarch64-checked-core` at
`0114607`) into `claude/keen-ptolemy-w9d7ve` (`ddb2b21`). Entry point
`sh verification/aarch64/check.sh`; full record with source hashes and per-image
receipts: [validation-2026-11-15.json](validation-2026-11-15.json). Tools, all
from the flake: Rocq 9.3.0 (stdlib V9.2.0), rocqchk 9.3.0, GNU binutils 2.46
(aarch64-unknown-linux-gnu), qemu-aarch64 11.1.1, Node 22, Shen/JIT 0.7
(`/nix/store/kxlj7mdmijpm307qx4w7a9cwpmcmslyz-shen-jit-0.7`). Linux x86-64,
3 min 40 s.

Reproduction of PR #8's own check on these tools (`tools/aarch64/check.mjs`;
only tool-name resolution changed):

- Core.v compiles on Rocq 9.3.0; the dependency audit of
  `expression_binary_correct` and of all twelve `exact_image_correct` instances
  reports closure under the global context;
- rocqchk replayed Core and the twelve instance modules;
- twelve GNU-assembled instruction sequences agree byte for byte;
- 564 QEMU comparisons agree with `PureCallMachine`;
- the three altered binaries (immediate, branch condition, success status) are
  rejected by their exact-image proofs and each diverges under QEMU.

New profile `fenrir-aarch64-checked-expr/1` (`tools/aarch64/check-expr.mjs`):

- `compile_correct`, `compile_correct_typed`: closed under the global context;
- 70 programs (30 hand, 40 generated), each with an exact-image theorem closed
  under the global context; 70 GNU-as byte agreements;
- 2,520 QEMU comparisons (36 inputs each) agree with `PureCallMachine`:
  1,335 Ok I64, 535 Ok Bool, 573 Overflow, 77 DivZero; SP checked unchanged by
  the launcher after every call;
- 10 single-instruction mutants (trap code, overflow branch, operand order,
  stack slot, branch polarity, DivZero guard, MUL overflow test, MIN / -1
  guard, compare condition, stack release): each fails at its
  `image_identity` proof and diverges under QEMU;
- rocqchk replayed 76 modules.

Shen differential (`harness/run-aarch64-differential.sh`): 82 programs × 40
inputs = 3,280 cases; the model completed all of them; Rocq proved that the
lane's `eval_expr`/`eval_main` agree on every case and refuted the control file
at exactly its three falsified cases. Status development-pass, qualification
UNKNOWN.

Also: `node --test tests/aarch64/*.test.mjs` 9 passed; `node --test
tests/tc0/*.test.mjs tests/tc1/*.test.mjs` 199 passed, 0 failed, 0 skipped.

Not run: physical ARM hardware, Sail, Islaris, Solo5 on AArch64, TLC, a second
Shen port, the GitHub workflow.

# Recorded development validation — 2026-10-31

Base repository: `4898e7bd3d98a8e8f267b44e2b72261ea2652806`.
Exact checked source hashes and binary receipts: [validation.json](validation.json).
This record applies to those hashes, not automatically to future source changes.

- Universal compiler/source/overflow proofs: checked with Coq 8.18.0.
- Twelve exact-byte theorem instances: checked; dependency audit reports closure
  under the global context, with no custom axioms.
- Coqchk: replayed the core and all twelve instance modules successfully.
- GNU assembler: all twelve independently assembled instruction sequences agree
  byte-for-byte with the compiler output.
- QEMU: 564 input/program comparisons agree with `PureCallMachine`.
- Three altered binaries (arithmetic immediate, branch condition, success status):
  rejected by exact-image proofs; each also diverges in QEMU comparisons.
- TC0/native-lowering/AArch64 Node tests: 143 passed, zero failed, one skipped.
  The skipped sandbox probe requires an unavailable network namespace. No
  sandbox-isolation claim is established by this run.
- Existing workflow tests: 42 passed, zero failed, zero skipped.
- `git diff --check`: passed.

This check did not run the Shen oracle, Nix builds, physical ARM hardware, Solo5,
TLC, Sail or Islaris. GitHub Actions is configured but its remote result is not
part of this local record. See README and PLAN for the proof's exact boundary.
