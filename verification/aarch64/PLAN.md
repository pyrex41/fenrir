# From Fenrir to a reusable ARM proof system

## Target theorem

For exact source P, image B, declared environment E and reviewed observation
mapping alpha, every architectural execution of B under E must map to a trace
allowed by P. Prove progress separately: internal stuttering must not conceal
nontermination, faults, unexpected writes or unauthorized environmental effects.

Fenrir is the first client. Keep source-independent ISA, binary admission and
runtime lemmas reusable for later Shen/Scheme and foreign-binary clients.

## Dependency-ordered work

| Milestone | Deliverable and acceptance | Current state |
|---|---|---|
| ARM-01 | Closed source profile, exact bytes, universal lowering proof, native differential controls, explicit trust ledger | Implemented for `fenrir-aarch64-checked-unary/1` and `fenrir-aarch64-checked-expr/1`; handwritten ISA model only |
| ARM-02 | Independently checked original artifact decoding/projection and correspondence to exact Shen TC0 semantics | Open. Tested only: the Shen differential (harness/aarch64-differential.shen) agrees on 3,280 cases; the projection in `tools/aarch64` is unverified; a proof goes through Búri's KLambda semantics of the model (amendment §3) |
| ARM-03 | Pin Arm/Sail model and execution profile; prove each emitted instruction/flag/control-transfer summary against it | Open; continues Búri's ARM foundation (below), not restarted here |
| ARM-04 | Prove loaded image, instruction addresses, ABI, register framing and fault conditions; compose instruction summaries | Open |
| ARM-05 | Extend source semantics and backend to branches, calls, closures, bytes and immutable algebraic values; prove heap/stack relations | Partly: binary operations with intermediate traps, comparisons and Bool, `if` with byte-offset branches, `let` and variables in stack slots (expr profile). Calls, closures, bytes and data open; next step below |
| ARM-06 | Allocation and resource exhaustion contract, runtime primitives, startup and termination for complete guest image | Open |
| ARM-07 | Actual effect handlers, residual-effect capability derivation, device/host boundary and bypass exclusion | Open; requires a new real-I/O profile beyond TC0 |
| ARM-08 | Handlers, structured tasks, channels, cancellation, cleanup and scheduler refinement | Open |
| ARM-09 | Distributed/environment protocol composition, liveness/fairness and deployment evidence | Open |

Do not count theorem quantities, model-only success, hashes, native tests or
finite exploration as completion of a missing refinement obligation.

## ARM-03: build on Búri's ARM foundation

Búri ([pyrex41/buri](https://github.com/pyrex41/buri)) already has the ARM
groundwork this milestone needs: a pinned Sail Arm model, an Islaris environment
and a first byte-level lemma against the Armv9.4 model (amendment §11). ARM-03
continues that work through a declared adapter instead of reproducing it here:

1. Take Búri's pinned Sail/Islaris dependency set and its byte-level lemma as
   the starting point; record the exact revision used.
2. Extend it to the instruction family the two profiles emit: ADD/ADDS/SUB/SUBS
   (immediate and shifted register, LSL #0 and ASR #63), MADD, SMULH, SDIV,
   CSINC, MOVZ, MOVK, LDR/STR immediate on SP (pre-index, post-index, unsigned
   offset), B, B.cond (EQ, NE, VC), CBZ/CBNZ and RET, for exactly the encodings
   in `Encode.v`.
3. Prove each `Machine.exec` case is a summary of the Sail semantics under a
   stated state relation (`wf` registers ↔ 64-bit vectors, PC offset ↔ address
   plus image base, doubleword map ↔ byte memory). Flags and control transfer
   included; no summary may be assumed.
4. Compose with `compile_correct`, replacing the handwritten-model boundary.
5. Keep architectural preconditions inhabited: retain launch witnesses and
   violating cases (unaligned SP, short stack, wrong return address).

The original research notes: [Islaris](https://github.com/rems-project/islaris),
[Isla](https://github.com/rems-project/isla), the
[Islaris PLDI 2022 paper](https://people.mpi-sws.org/~dg/papers/pldi2022.pdf)
(which found the full Arm model hard to manipulate efficiently in Coq: a
feasibility question that choosing a library does not settle), and
[Zellic/V12's research preview](https://github.com/Zellic/x86-formal-verification-research)
as the first comparison benchmark.

## Next increment in ARM-05: first-order calls

Not started. Target: `call` of a first-order `I64 → I64`/`Bool` function of the
same artifact, then a self tail call. What it needs, in order:

1. Machine: RET becomes a jump to `X[n]` and the run ends when the PC leaves the
   image (an exit address), instead of halting at RET; BL writes X30. Re-prove
   the expr profile on that machine first (its statement does not change).
2. Callee frame: save `x30` and `x9`, restore them on the success and every trap
   path; trap statuses propagate by `cbnz x1` after each `bl`.
3. Source: `eval` with a function table and fuel (the Shen model has no fuel; the
   profile restricts calls to earlier functions so fuel = number of functions
   suffices, and the theorem says so); tail calls need a loop measure and a
   separate termination premise.
4. A per-function specification proved by induction on the call graph, composed
   at each call site; the result ABI gets a version 2 if the frame changes.

## Integration ownership

- **Fenrir/Shen:** executable source semantics, effects, contracts and language
  fixtures. Shen remains a proof producer and reference implementation; independent
  Rocq checking must not assume the Shen host is already correct.
- **Búri:** the KLambda semantics through which the Shen model gets a formal
  meaning (the route for ARM-02), the ARM foundation ARM-03 continues, and
  reusable representation, source/capture correspondence, compiler
  preservation and proof-certificate techniques. Port lemmas through a declared
  adapter rather than treating similarly named semantics as identical.
- **Vor:** business invariants and evidence-indexed judgments. Prove the bridge
  from these judgments to the deployed program's observable trace properties.
- **Thornet:** proof search outside the acceptance boundary; reconstruct every
  accepted logical result in the selected checker. Arithmetic and heap reasoning
  need their own supported proof procedures.
- **Gleipnir/ShenCheck:** fast discrepancy discovery, schedule exploration,
  minimization, strict replay and retained negative controls. No replay receipt
  substitutes for universal compiler/runtime preservation.
- **TLA+:** scheduler/cancellation/channel/environment protocol specifications.
  Generate and check a shared transition interface, validate finite models with
  TLC, and establish general invariants/refinement separately. Do not label a
  finite TLC pass a universal temporal theorem.

## Profiles and resource boundaries

The first production target remains a single-threaded AArch64 Fenrir image with
explicit effects. CPU profile, initial memory, instruction fetch, privilege level,
interrupt behavior and host interactions belong in the theorem statement.
Do not silently inherit Linux userspace assumptions for a Solo5 guest.

Real I/O, persistence and shared-memory weak concurrency are excluded from TC0.
Adding them requires new versioned contracts. An arena allocation experiment must
state sufficient memory or define exhaustion; it cannot silently add a TC0 trap.
Multicore requires the Arm weak-memory model and interference reasoning, beyond
interleavings of a sequential abstract scheduler. Side-channel/noninterference
claims require relational execution and an explicit observation model.

## Verification artifacts and CI

The compile step produces candidate bytes, source projection, exact byte identity
obligation and manifest. The proof gate independently checks these and records
assumptions. CI must fail for missing prerequisites, malformed certificates,
mutated bytes and unsupported instructions. It must distinguish proved, tested,
assumed and unsupported claims. Compile/assembler/QEMU versions are recorded;
a pinned reproducible build alone never establishes semantic correctness.

All tools are pinned by the flake (`.#aarch64-verification`: Rocq 9.3.0 with
stdlib V9.2.0, binutils 2.46, qemu-user 11.1.1, Node 22) and one entry point
runs everything: `sh verification/aarch64/check.sh`. The GitHub workflow runs
that script under Nix; its remote result has not been observed.
