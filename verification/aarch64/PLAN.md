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
| ARM-05 | Extend source semantics and backend to branches, calls, closures, bytes and immutable algebraic values; prove heap/stack relations | Partly: binary operations with intermediate traps, comparisons and Bool, `if` with byte-offset branches, `let` and variables in stack slots (expr profile); first-order calls, recursion and tail calls in constant stack (call profile). Closures, bytes, tuples and data open; next steps below |
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

## ARM-05: calls (done) and what follows

Done as `fenrir-aarch64-checked-call/1` (README, ABI.md `fenrir-aarch64-call-abi/1`).
Decisions: the expr machine is kept and the call machine simulates it on
non-RET steps, so the expression proof is reused; the source semantics is
fuel-indexed and the theorem is relative to termination; the stack bound is the
semantics' own `need`, and tail-only tables get a constant bound
(`tail_calls_constant_stack`). Profile restrictions: one parameter; calls only
as a `let` initializer or in tail position; no stack-overflow detection.

Next, in order:

1. Several parameters (pass in x0..x7 or on the stack; extends the frame
   layout and `fenrir-aarch64-call-abi` to version 2).
2. Calls inside expressions without the A-normal-form restriction (needs the
   expression compiler itself to know about calls and the caller-saved
   temporaries on the stack).
3. Stack-overflow detection (a limit check in the prologue and a new trap, which
   is a contract change: TC0 has no stack trap) or a proof obligation on the
   loader that enough stack exists.
4. Closures and immutable data: a heap model, allocation and its exhaustion
   contract (ARM-06), and the representation relation for tuples and datatypes.

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

### Native task-runtime checks for ARM-08

On Apple Silicon, run `python3 tests/native/check-scheduler.py NEW_OUTPUT_DIRECTORY`
with the Solo5 ARM64 SPT toolchain image installed. The runner builds and
executes each C fixture on Darwin and in an SPT guest. It retains compiler and
launcher commands, exit statuses, source and binary hashes, and the container
image ID. Fixtures cover the context switch, collection with suspended
stacks, handler isolation and inheritance, FIFO yield, completion waits,
and cancellation of a waiter. The cancel-owned-scopes fixture cancels a parent
blocked in a nested join and checks that both children terminate before the
parent. Compiled lexical scopes reserve their own scheduler frame, join on
success, and abort on a body trap. Run the four tests/native/task-scope*.fen
fixtures through bin/fenrir test on each target for source-level checks.
The root task also joins its implicit scope. The implicit-join-roots runtime
fixture forces collection while the parent holds its return value and checks
child failure and body-trap precedence. The root-task-result.fen source
fixture exercises the generated result-type flag with an allocated byte string.
Compiled spawn, await and cancel now use the FIFO scheduler. The native CLI
reserves 16 concurrent child stacks of 256 KiB and space for 32 inherited
handler frames per child. Completed handles keep the outcome in the managed
heap and release the stack for reuse. Exceeding the slot or handler bound
at spawn reports TaskLimit. Differential runs cover repeated await,
cancellation, captured values, copied handlers, child failure, and reusing
a completed child's stack while an older handle remains reachable.
Compiled channel creation, send, receive, and close share the FIFO scheduler.
The native profile supports capacities 1 through 8 and 64 simultaneously
reachable channels. Managed buffers retain queued objects. The runtime
collects discarded handles before reporting exhaustion of its channel pool.
When every remaining task is blocked, the CLI prints the wait graph in task
ID order and exits with status 1. The native record and replay commands
reproduce this observable outcome on both targets.
Run `python3 tests/native/check-dispatch-replay.py NEW_DIRECTORY` to
compare FIFO and a forced reverse order on both targets. The fixture checks
both observable event orders, replays both receipts, and rejects unavailable,
short, and trailing choices. Scheduler refinement remains open.
