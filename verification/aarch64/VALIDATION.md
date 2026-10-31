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
