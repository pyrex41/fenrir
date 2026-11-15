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
| ARM-01 | Closed source profile, exact bytes, universal lowering proof, native differential controls, explicit trust ledger | Implemented for unary checked I64; handwritten ISA model only |
| ARM-02 | Independently checked original artifact decoding/projection and correspondence to exact Shen TC0 semantics | Open |
| ARM-03 | Pin Arm/Sail model and execution profile; prove each emitted instruction/flag/control-transfer summary against it | Open; research blocker for architectural verification |
| ARM-04 | Prove loaded image, instruction addresses, ABI, register framing and fault conditions; compose instruction summaries | Open |
| ARM-05 | Extend source semantics and backend to branches, calls, closures, bytes and immutable algebraic values; prove heap/stack relations | Open |
| ARM-06 | Allocation and resource exhaustion contract, runtime primitives, startup and termination for complete guest image | Open |
| ARM-07 | Actual effect handlers, residual-effect capability derivation, device/host boundary and bypass exclusion | Open; requires a new real-I/O profile beyond TC0 |
| ARM-08 | Handlers, structured tasks, channels, cancellation, cleanup and scheduler refinement | Open |
| ARM-09 | Distributed/environment protocol composition, liveness/fairness and deployment evidence | Open |

Do not count theorem quantities, model-only success, hashes, native tests or
finite exploration as completion of a missing refinement obligation.

## ARM-03 research experiment

Start from [Islaris](https://github.com/rems-project/islaris) and
[Isla](https://github.com/rems-project/isla), using a pinned Arm model snapshot.
The initial required instruction family is deliberately tiny: ADDS/SUBS immediate,
SUBS shifted-register for NEGS, B.cond VC, MOVZ and RET. No arithmetic summary may
be replaced with a convenient assumption and still count as discharged.

1. Reproduce an existing Arm proof with the upstream pinned dependency set.
2. Identify every trusted transformation from architectural model to proof.
3. Produce an instruction-summary certificate for these exact encodings.
4. Recheck summaries against the selected authoritative semantics in Rocq, or
   retain a conspicuous unresolved translator assumption. The original Islaris
   work found the full Arm model difficult to manipulate efficiently in Coq;
   this is an actual feasibility question, not solved by selecting that library.
5. Compose summaries with ARM-01, replacing its handwritten semantics boundary.
6. Validate architectural-state preconditions are inhabited; retain launch/call
   witnesses and deliberate violating cases. Avoid a theorem true only because
   no real execution satisfies its premises.

Reference: [Islaris PLDI 2022 paper](https://people.mpi-sws.org/~dg/papers/pldi2022.pdf).
The first comparison benchmark is [Zellic/V12's research preview](https://github.com/Zellic/x86-formal-verification-research),
whose process assumptions and startup/liveness scope must be compared explicitly.

## Integration ownership

- **Fenrir/Shen:** executable source semantics, effects, contracts and language
  fixtures. Shen remains a proof producer and reference implementation; independent
  Rocq checking must not assume the Shen host is already correct.
- **Buri:** reusable representation, source/capture correspondence, compiler
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
