# Fenrir direction amendment: proved core, effect successor, early application proof

Version 0.1 • Proposed architecture amendment • For owner review

**Working names:** unchanged. Fenrir is the language and the project. Gleipnir is its exploration and conformance harness. TC0 is the first core (contract 0.2). This document introduces **TC1** as the working name of TC0's versioned successor.

**Status (12 November 2026, master `4898e7b`):** Proposed. It changes no TC0 0.2 semantics, profile identity, gate, ledger or recorded evidence. Until the owner accepts it, [01_FULL_VISION.md](01_FULL_VISION.md), [02_TINY_LANGUAGE_CORE.md](02_TINY_LANGUAGE_CORE.md) and [03_PHASED_EXECUTION_PLAN.md](03_PHASED_EXECUTION_PLAN.md) govern as written. Where this document says "decision", read "proposed decision". §12 lists what the owner has to settle.

## 1 Summary

Fenrir stays the language we are building, in this repository, under this identity. Recent prototype work done outside it is consolidated here and stops being a separate language project. Four things change:

1. **Rocq gets a defined role.** A small versioned core, formalized in Rocq, defines TC1's semantics and the statements we prove. Shen stays as an independently structured executable reference. The relationship between the two is itself specified and checked.
2. **The effect system is redesigned before the handler plan is extended.** TC0's tail-resumptive, monomorphic, finite-effect-set handlers become one profile of a successor contract with inferred effect rows, explicit one-shot resumptions and resource rules.
3. **The production compiler preserves observations, not interpreter steps.** Reference-machine traces remain a diagnostic tool. Deployment roles are stated per target, and Solo5 no longer sits on the path of every language milestone.
4. **One backend feature is proved early.** A tenant-scoped request that atomically writes business state, a durable job and its retry result, and only then answers, becomes the example that drives language design. A first model-level proof is in [verification/service/](verification/service/).

What does not change:

- TC0-A evidence stays attached to the versions it covers. The recorded G1 PASS is for `1db7471` under its waivers. Nothing here refreshes, widens or retires it.
- Gleipnir's job: counterexamples, schedule exploration, reduction, strict replay, implementation evidence.
- The authority discipline of plan §1 and §3: a candidate cannot change what it is judged against; FAIL, UNKNOWN, BLOCKED and DEFERRED stay distinct; semantic changes go through versioned amendments.
- Checked signed `I64` arithmetic (§5).

## 2 Three layers

The language stays small by putting most of its power in libraries whose contracts and implementations are proved together.

| Layer | Contents | Trust position |
| --- | --- | --- |
| Core language and proof foundation | Immutable values, algebraic data, pattern matching, modules, effects, resource ownership, indexed types, checked proof evidence | Rocq definitions and the checker are authority for TC1 |
| Libraries with contracts | Transactions, durable requests and inboxes, workflows, actors, authorization, typed queries, logic search, codecs, migration | Proved once against stated environment contracts; applications depend on the contract |
| Execution infrastructure | Backends, memory management, scheduling, storage adapters, host integration, profiling | Preservation obligations against the core; adapters are named assumptions until correspondence is established |

Datalog, Prolog-style search, SQL compilation, actors and workflows are libraries over shared types and semantics. They are not core primitives, and they do not enlarge the trusted kernel.

## 3 Semantic authority and the Rocq/Shen relationship

Vision §6 gives authority to reviewed rules and their qualified executable Shen model. That stays true for TC0 0.2. For TC1 the proposed arrangement is:

| Object | Role for TC1 |
| --- | --- |
| Rocq core (`verification/core/`, to be written) | Defines syntax, typing, evaluation, traps and observations. Theorems are stated against it. |
| Shen machine | Independently structured executable reference: exploration, readable model, differential oracle for Gleipnir. |
| JavaScript candidate | Independent development implementation, as today. |
| Compiler and runtime | Systems with explicit preservation obligations against the Rocq core. |
| Gleipnir | Finds disagreements among all of the above and keeps them reproducible. |

**The Rocq/Shen relationship is an obligation, not an assumption.** Two machines with similar constructor names do not thereby describe one language. The relationship is established in this order:

1. **Shared artifact.** Both consume the same canonical artifact bytes. The decoding from artifact JSON to the Rocq AST is a checked projection with its own fixtures. This is the same open obligation the AArch64 lane lists as ARM-02 (JSON/source correspondence); it is done once, for the core, and reused.
2. **Executable Rocq reference.** The Rocq core includes a fuelled definitional interpreter proved equivalent to the relational semantics. It is extracted, or run inside Rocq, and joined to Gleipnir as a third lane.
3. **Differential agreement.** Hand fixtures, the exhaustive-small grammar and generated campaigns must agree across Rocq interpreter, Shen and candidate on results, traps and emitted observations. This is reported as *bounded exploration passed*, never as a proof.
4. **Disagreement.** A disagreement is a defect in one of the three or a gap in the contract. For TC1 the reviewed Rocq text decides after review; it is not edited to match an implementation inside a candidate patch.

The trusted base for TC1 claims is then: the Rocq kernel and its toolchain, the artifact projection until it is verified, and the statements themselves. Shen and the JS candidate leave the trusted base for anything stated as a theorem and remain essential for finding the theorems that are false.

**TC1 is not TC0 with a proof attached.** TC0-A's rules, fixtures and regression cases are the starting material. Each one is either carried into TC1 with a fixture showing the same observation, or listed as a deliberate change.

### Programmable typing, fixed checking

Today's validator ([tools/tc0/pure-call-artifact.mjs](tools/tc0/pure-call-artifact.mjs)) is a direct monomorphic checker. Shen's sequent machinery is not Fenrir's type system yet, so this is new work with one rule that fixes its place:

> The surface elaborator and the logic engine produce explicit typed core terms or derivations. A small fixed checker accepts or rejects them. Extensions make proofs easier to find; they cannot change what counts as a proof.

- A module may add typing rules, search strategies and domain-specific elaboration. Whatever it concludes must be justified to the checker.
- A new logical principle is either proved admissible or appears in the claim as a named assumption.
- Search exhaustion, timeout and budget overrun mean *unknown*. Unknown is never a permission, in typing or in authorization.
- A general recursive program is not proof evidence. Programs may diverge; derivations are checked data.

## 4 Effects: the successor contract

TC0 §5 specifies handlers with no user-visible resumption: a clause returns normally and the suspended segment resumes once with that value. Functions declare finite effect sets. The implemented validator accepts only the built-in `Emit` effect and rejects user effect declarations. Almost no general handler machinery exists to disrupt, so this is the time to choose.

These are settled together in a TC1 effect contract, written and reviewed before any B-slice machine work:

| Question | Proposed decision |
| --- | --- |
| Effect types at the surface | Inferred, row-polymorphic effect rows (Koka-style). |
| Effect types in the core | Explicit. The core may stay simpler than the surface: effect-row instantiation is elaborated away, and the elaboration is a checked contract with fixtures (plan §10's lowering contract, moved earlier). |
| Resumption | Explicit and **one-shot by default**: a clause receives a resumption it must resume or discontinue exactly once. TC0's rule is the special case "resume once, in tail position", kept as a named profile so its implementation can skip the capture. |
| Multi-shot | Admitted only where everything the captured segment holds is duplicable: no transaction, lock, borrow, region handle or acknowledgment obligation. Needed for logic search; deferred until that library needs it, and designed with ownership. |
| Handler selection and nesting | Retained from TC0: dynamic, innermost matching handler first; the clause runs under the selected handler's outer context; same-effect performs forward outward. |
| Captured resources | A resumption carries the region support of the segment it suspends, by the existing TC0-CAPTURE-SUPPORT rule. It is affine and cannot outlive those regions. |
| Cancellation and cleanup | Discontinuing a resumption unwinds the suspended segment in acquisition order. TC0's rule that no user code runs during abort cleanup is the starting point; realistic finalizers are a later, separate decision. |
| Effect classes | Three, distinguished in the contract: **ordinary** effects (user handlers, pure reinterpretation), **runtime** effects (tasks, channels, time, resources, emit: discharged by the runtime, as TC0's reserved effects are), and **durable** effects (transaction, durable job, durable inbox: discharged only by a handler that carries a storage contract). |
| Capabilities | A tenant or storage capability is a value with an indexed type. Residual effects remain the image's capability manifest (vision §7). |

Three lifetimes follow from the classes and must stay visibly different:

- a **task** belongs to its scope and is cancelled with it;
- an **actor** belongs to its supervision tree and is volatile unless it says otherwise;
- a **durable obligation** belongs to persisted state, and cancelling it is itself a durable transition.

A client disconnect cancels request-local work. It does not erase an accepted job.

The P2 task packet (PR #7) asks its questions Q1–Q9 against 0.2. Under this amendment they are answered once, in the TC1 effect contract. Its tail-resumptive increment B1 remains a valid first slice of TC1 (§10).

## 5 Arithmetic

**Decision: TC1 keeps checked signed `I64`.** Overflow, division by zero and the other language traps stay observable, including intermediate ones.

Explicitly wrapping machine-word types (`W32`, `W64`, names provisional) are added later as distinct types with their own operations. Nothing converts between checked and wrapping arithmetic implicitly. Mathematical integers, money or decimal quantities, bytes, text, durations and instants are separate standard-library types, so a business proof never silently inherits machine-word behaviour.

This fixes what may be ported from the external prototype, which used wrapping `Word32`:

```text
(x + 1) - 1  →  x        valid for wrapping words
                         INVALID for checked I64: at maximum I64 the left side traps Overflow
```

An optimizer theorem proved for wrapping arithmetic applies to the wrapping types only. For `I64` it has to be re-proved with its trap side condition or dropped. The AArch64 lane (PR #8) already preserves intermediate overflow and stays as written.

## 6 What the compiler must preserve

The reference machine publishes every step so that a semantic bug can be located exactly. That is a property of the reference profile `TC0-REF-STEP/0.2`. It was never the production contract (core §1, vision §4), and this amendment keeps that separation and makes the production side explicit.

A conforming compilation preserves, for every admitted program and environment:

- the result value, or the trap and its code, including traps of intermediate computations;
- the order and content of observable effects (operations performed, `emit`, durable operations);
- resource behaviour: acquisition and release, exactly once, in the specified order;
- the concurrency observations the production scheduling contract permits (to be written; plan §11).

It may remove anything else: frames, steps, closures, allocations, handler captures. Each removal is justified by the preservation proof for that pass, or it is not done.

The target theorem is the one stated in the AArch64 lane's plan: for source P, image B, declared environment E and observation mapping α, every execution of B under E maps to a trace allowed by P, with progress proved separately. Passes are free to be straightforward: direct native code, specialization, stack allocation, inferred regions, later ownership-based reuse.

**Memory.** Begin with a small tracing collector for the native and Wasm heap, and keep ownership, liveness and reuse information in the IR. Inferred local allocation, checked allocation contracts (for example a `no_heap_alloc` requirement on a latency-sensitive function) and Perceus-style lowering are evaluated afterwards on real workloads. No language decision depends on one collector.

## 7 Targets

| Target | Intended role | State |
| --- | --- | --- |
| Native process | First practical development and deployment target | JS candidate only; AArch64 proof lane in draft (PR #8) |
| Solo5 | Restricted image and deployment profile | Arithmetic spike; native host epoch open |
| Wasm | Portable components, sandboxed tenant or policy logic | Not started |
| OTP/BEAM | Possible supervision and orchestration host | Not started |

These are roles, not four implemented backends. The Solo5 work is kept and continues under its own epoch. A Solo5 blocker does not stall semantic, proof or surface work (already the policy in plan §2). Supervision restarts computation; it does not make state or messages durable. Durability comes from a persistence and acknowledgment protocol with a contract (§8).

## 8 The first application example

> A tenant-scoped request atomically writes business state, records a durable job, records its retry result, and then returns acceptance.

It must establish, as separate statements:

| Property | Statement | Kind |
| --- | --- | --- |
| Authority | A handler acting under tenant *t*'s capability changes only *t*'s state | Frame property |
| Atomicity | Business state, job record and request-deduplication state commit together | State invariant |
| Response discipline | An acceptance response requires evidence of that commit | Trace/state invariant |
| Retry safety | Repeating a request or a delivery does not repeat the logical mutation; a reused key with a different payload is refused | Functional property |
| Recovery | Crash and retry preserve the invariants and the outstanding obligations | Invariant over crash steps |
| Progress | Accepted work completes or reaches a visible terminal outcome | Conditional on explicit scheduling and availability assumptions |

Confidentiality (other tenants' data cannot influence what *t* observes) is a relational property and stronger than the frame property. It is not claimed until it is stated and proved as such. Concurrency of transactions needs an explicit isolation contract; atomicity alone does not protect a business invariant from two interleaved read-then-write requests.

**Stages.** Each stage keeps the same independently stated contract.

| Stage | Deliverable | State |
| --- | --- | --- |
| A0 | Abstract model in Rocq with the properties above proved, plus a negative control | **Done at model level:** [verification/service/AcceptedJob.v](verification/service/AcceptedJob.v) |
| A1 | The same contract as an executable Shen model; Gleipnir explores schedules, crashes and duplicate deliveries against it | Next |
| A2 | The handler written as an ordinary Fenrir program against `atomic`, `once`, `jobs.stage` library interfaces; refinement to the A0 model | Needs TC1 effects and the first surface slice |
| A3 | A real storage adapter (PostgreSQL first) and black-box container history tests against the contract | Later |
| A4 | A versioned upgrade that preserves pending work | Later |

A0 deliberately assumes its storage contract: a transaction is a pure function on one tenant's store, installed atomically, and a crash loses only volatile state. A3 is where that assumption meets a real database, including the case A0 does not model: a commit whose acknowledgment is lost, which the API must report as indeterminate rather than as a rollback.

## 9 Evidence vocabulary

Gate verdicts (PASS, FAIL, UNKNOWN, BLOCKED, DEFERRED) are unchanged. Claims additionally say which of four things they establish, and one never stands in for another:

| Status | Establishes |
| --- | --- |
| Model property proved | All modelled executions satisfy the property under the stated assumptions |
| Implementation refinement proved | The implementation's behaviour is related to that model |
| Bounded exploration passed | No violation within the explored programs, schedules and bounds |
| Observed history accepted | This recorded execution is consistent with the specification |

Current standing under this vocabulary: TC0-A is *bounded exploration passed* (at `1db7471`, under waivers). The AArch64 lane is *implementation refinement proved* for a closed unary checked-I64 add/subtract/negate profile against a handwritten instruction model, and is still a draft PR. The service example is *model property proved*. Nothing in the repository is yet a refinement proof against real hardware semantics or a real database.

## 10 Revised sequence

On acceptance this replaces the ordering in plan §18 items 2–6 and the dependency edges that put the surface language at P6 and persistence at P8. Gates G1–G10 keep their content; what moves is when work starts.

| Step | Work | Unit of progress |
| --- | --- | --- |
| D0 | Reconcile open branches (PRs #5–#8) against this direction: [campaigns/RECONCILIATION_2026-11.md](campaigns/RECONCILIATION_2026-11.md) | Merged or explicitly re-scoped PRs |
| D1 | Owner review of this amendment (§12) | Accepted decisions |
| D2 | **TC1 pure core in Rocq**: the TC0-A fragment (values, let, if, tuples, datatypes, match, closures, calls, checked I64, bytes, emit), definitional interpreter, artifact projection, differential lane against Shen and candidate. Rebase the AArch64 lane's source language on it. | A TC0-A fixture evaluated by three machines, one of them a Rocq definition |
| D3 | **TC1 effect contract** (§4), then its first slice through model, candidate, Rocq and fixtures: tail-resumptive handlers, then explicit one-shot resumption | A handler program with agreeing traces and a proved type-and-effect soundness statement for the slice |
| D4 | **First surface slice** developed with D2/D3, not after P5: a small frontend elaborating to checked core terms, with the elaboration contract | A program a person can write, read, run and check |
| D5 | **Service example A1 → A2** (§8) | The request handler as Fenrir source, refined to the proved model |
| D6 | Native compilation with preservation (§6) growing from the AArch64 lane: branches, calls, closures, data | Proved native code for a program that is not only arithmetic |
| D7 | Concurrency, supervision, real adapters, history tests (A3, A4) | Container tests against the same contract |

Advanced machinery (Datalog, a λProlog-style elaboration engine, query compilation, arenas, Perceus-style reuse, interaction nets, tracing compilation) enters when a concrete program in D4–D7 needs it and shows the need.

The G1 refresh on a supported runner (plan §18 item 1) is still owed and is independent of D1–D5. TC0-B and TC0-C as slices of contract 0.2 are superseded by the TC1 slices in D3 and D7 if this amendment is accepted; the requirements they carry (fixtures, mutants, reduction, strict replay per slice) transfer unchanged.

## 11 Consolidating the external prototype

The separate prototype was not available in this repository or session, so this section states rules rather than an inventory.

- It stops being a separate language. Useful parts (lexical resolution, compiler structure, proof techniques, frontend experiments) are ported into Fenrir as TC1 work.
- Porting goes through a declared adapter: each imported definition or lemma states which TC1 definition it is about. Similarly named semantics are not assumed identical.
- Its arithmetic is wrapping `Word32`; §5 governs what carries over.
- Fenrir's object language already has immutable lexical captures ([models/tc0/pure-call-machine.shen](models/tc0/pure-call-machine.shen)), so "Shen without the global environment" describes the existing core. Hosting the reference model in Shen does not give Fenrir programs Shen's global environment.

A separate repository becomes reasonable when there is a real ownership or release boundary, for example Gleipnir infrastructure reused by other languages. There is no such reason now.

## 12 Decisions for the owner

1. Accept Rocq as semantic authority for TC1, with Shen as independent executable reference (§3).
2. Accept the name TC1 and that TC0-B/TC0-C are superseded as 0.2 slices rather than implemented as specified (§4, §10).
3. One-shot resumption as the default, multi-shot only over duplicable captures (§4).
4. Checked `I64` retained; wrapping words as later distinct types (§5).
5. The observation list in §6 as the compiler's preservation boundary.
6. Target roles in §7, and that native process comes first.
7. The service example and its staging as the driver (§8), and whether PostgreSQL is the first real adapter.
8. The revised sequence (§10), in particular starting the surface slice at D4.
9. Proof assistant version: the AArch64 lane and the service model are checked with Coq 8.18. Pin it in the flake, or move both to a current Rocq release first.
10. Where the external prototype lives and who ports which parts (§11).

## 13 Not decided here

- Surface syntax.
- The production scheduling contract and elapsed-time profile (plan §11).
- Realistic finalizers and cancellation shielding.
- Actor protocol typing, hot upgrade and migration contracts beyond A4's version-pinned default.
- Confidentiality as a proved property.
- Any JIT, interaction-net or custom storage-engine work.
