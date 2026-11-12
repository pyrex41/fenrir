# Fenrir direction amendment: Shen authority with checked proofs, effect successor, Solo5 first

Version 0.3 • Architecture amendment with owner decisions recorded and confirmed

**Working names:** unchanged. Fenrir is the language and the project. Gleipnir is its exploration and conformance harness. TC0 is the first core (contract 0.2). **TC1** is the name of its versioned successor.

**Status (12 November 2026, master `4898e7b`):** The owner ruled on the ten decisions of version 0.1 on 12 November 2026; §12 records each ruling and this version is rewritten to match. It changes no TC0 0.2 semantics, profile identity, gate, ledger or recorded evidence. Where it conflicts with [01_FULL_VISION.md](01_FULL_VISION.md) or [03_PHASED_EXECUTION_PLAN.md](03_PHASED_EXECUTION_PLAN.md) on direction and ordering, this document is the newer statement; [02_TINY_LANGUAGE_CORE.md](02_TINY_LANGUAGE_CORE.md) remains the TC0 0.2 contract.

## 1 Summary

Fenrir stays the language we are building, in this repository, under this identity. Four things change:

1. **Shen stays the semantic authority, and proving gets a defined place.** Derivations are searched for and certificates are checked in Shen. Rocq is used where a rule set or a universal theorem needs a proof that Shen alone cannot give, and it is reached through Búri rather than through a second, hand-maintained Rocq definition of Fenrir (§3).
2. **The effect system is redesigned before the handler plan is extended.** TC0's tail-resumptive, monomorphic handlers become one profile of a successor contract with inferred effect rows, explicit one-shot resumptions and resource rules (§4).
3. **The compiler preserves observations, not interpreter steps, and Solo5 is the first target.** A concurrency model is sketched now so the observation boundary is not sequential-only (§6, §7, §14).
4. **One backend feature is built through the whole stack**: a tenant-scoped request that atomically writes business state, a durable job and its retry result, and only then answers. It runs on BEAM with SQLite (§8).

There is no disposable prototype stage. Each step in §10 builds the real component.

What does not change:

- TC0-A evidence stays attached to the versions it covers. The recorded G1 PASS is for `1db7471` under its waivers.
- Gleipnir's job: counterexamples, schedule exploration, reduction, strict replay, implementation evidence.
- The authority discipline of plan §1 and §3: a candidate cannot change what it is judged against; FAIL, UNKNOWN, BLOCKED and DEFERRED stay distinct; semantic changes go through versioned amendments.
- Checked signed `I64` arithmetic (§5).

## 2 Three layers

The language stays small by putting most of its power in libraries whose contracts and implementations are proved together.

| Layer | Contents | Trust position |
| --- | --- | --- |
| Core language and proof foundation | Immutable values, algebraic data, pattern matching, modules, effects, resource ownership, indexed types, checked proof evidence | The reviewed rules and their Shen model are authority; typing and contract rule sets are proved sound once |
| Libraries with contracts | Transactions, durable requests and inboxes, workflows, actors, authorization, typed queries, logic search, codecs, migration | Proved once against stated environment contracts; applications depend on the contract |
| Execution infrastructure | Backends, memory management, scheduling, storage adapters, host integration, profiling | Preservation obligations against the core; adapters are named assumptions until correspondence is established |

Datalog, Prolog-style search, SQL compilation, actors and workflows are libraries over shared types and semantics. They are not core primitives, and they do not enlarge the trusted kernel.

## 3 Semantic authority and where proofs are checked

**Ruling: stay with Shen if theorems can actually be proved there.** Vision §6 already gives authority to reviewed rules and their qualified executable Shen model. That stays true for TC1. The question was whether Shen can also be the prover.

**What Shen gives by itself.** [verification/shen-proving/](verification/shen-proving/) runs the experiment with the pinned shen-scheme. Shen's type checker finds a derivation of 2 + 1 = 3 under two addition rules and rejects 1 + 1 = 1. After one unsound rule is declared it accepts 1 + 1 = 1 with no warning, and it accepts a function of type `A --> B` that only calls itself. So Shen is a programmable proof search over whatever rules are declared. It does not check that rules are sound, typed functions are not proofs because they may diverge, and a statement about all inputs needs an induction principle that someone must supply as a rule.

**What that means for the three kinds of claim.**

| Claim | Example | Where it is established |
| --- | --- | --- |
| Ground and bounded | This program yields this trace; these 5,695 programs agree | Executed in Shen and Gleipnir. No proof assistant |
| Derivable under a rule set | This handler touches only tenant *t*'s data; this resumption is used once | Shen's sequent checker, under Fenrir's typing rules. Sound only if the rule set is |
| Universal | The rule set is sound; compiled code preserves observations for every input; the protocol invariant holds over every interleaving | Needs induction and a checker that cannot be extended by accident |

**The arrangement.** Búri ([pyrex41/buri](https://github.com/pyrex41/buri)) is not a language prototype. It proves, in Rocq, that Shen implementations run Shen programs as Shen's semantics says, with Shen/JIT as its lead track. It already contains the pieces the third row needs: a Rocq semantics for all of KLambda, and a contract calculus over it (`BURI/KL-CONTRACT-1`) whose rules are each proved sound, with a certificate grammar checked by a Rocq checker and by an executable Shen checker.

So Fenrir does not get its own Rocq core:

- Fenrir's semantics is the Shen model. A Shen program is a KLambda program, and Búri gives KLambda a formal meaning. There is one definition, and no hand-maintained Rocq transcription whose agreement with Shen would itself need proving.
- Fenrir's typing rules are Shen sequent rules. Each rule set is proved sound once, as a universal claim.
- Universal claims about Fenrir are stated as contracts on the Shen model in Búri's calculus. Certificates are produced by search in Shen and accepted by Búri's Shen checker. Rocq's part is the one-time soundness proof of that checker's rules, which lives in Búri.
- Rocq is used directly in this repository only where a claim is not about the Shen model at all: machine-code encodings (the AArch64 lane) and abstract protocol models (the service model). These are scoped lanes, not Fenrir's definition.

**Limits, stated now.** Búri's own ledger says no Shen implementation is verified yet and the contract calculus is in progress with one worked example. Reasoning about a Fenrir program through contracts on the interpreter that runs it has not been tried and its cost is unknown. The first test is small: one TC0-A property, for example that checked `add` never returns a value outside I64, certified through Búri's checker against `models/tc0/pure-call-machine.shen`. Until that works, universal claims about Fenrir are reported as open, and rule-set claims as "derivable under rule set R, soundness not yet proved".

**Proof assistant version.** Use a current Rocq release where Rocq is needed. Búri pins Rocq 9.3.0 for its current lane; this repository follows Búri's pin rather than choosing separately. The two Rocq files here were checked with Coq 8.18 and are to be moved when they are next touched.

### Programmable typing, fixed checking

Today's validator ([tools/tc0/pure-call-artifact.mjs](tools/tc0/pure-call-artifact.mjs)) is a direct monomorphic checker. Shen's sequent machinery is not Fenrir's type system yet. Making it so is new work, with one rule that fixes its place:

> The surface elaborator and the logic engine produce explicit typed core terms or derivations. A small fixed checker accepts or rejects them. Extensions make proofs easier to find; they cannot change what counts as a proof.

- A module may add typing rules, search strategies and domain-specific elaboration. Whatever it concludes must be justified to the checker.
- A new logical principle is either proved admissible or appears in the claim as a named assumption. The experiment above is the reason: Shen accepts an unsound rule silently.
- Search exhaustion, timeout and budget overrun mean *unknown*. Unknown is never a permission, in typing or in authorization.
- A general recursive program is not proof evidence. Programs may diverge; derivations are checked data.

## 4 Effects: the successor contract

TC0 §5 specifies handlers with no user-visible resumption: a clause returns normally and the suspended segment resumes once with that value. Functions declare finite effect sets. The implemented validator accepts only the built-in `Emit` effect and rejects user effect declarations. Almost no general handler machinery exists to disrupt, so this is the time to choose.

The owner accepted these (ruling 3: one-shot by default is exactly right). They are written down as the TC1 effect contract before B-slice machine work:

| Question | Decision |
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

**Decision (accepted): TC1 keeps checked signed `I64`.** Overflow, division by zero and the other language traps stay observable, including intermediate ones.

Explicitly wrapping machine-word types (`W32`, `W64`, names provisional) are added later as distinct types with their own operations. Nothing converts between checked and wrapping arithmetic implicitly. Mathematical integers, money or decimal quantities, bytes, text, durations and instants are separate standard-library types, so a business proof never silently inherits machine-word behaviour.

This fixes what may be reused from work done under wrapping `Word32` arithmetic:

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
- the concurrency observations the production scheduling contract permits (sketched in §14).

It may remove anything else: frames, steps, closures, allocations, handler captures. Each removal is justified by the preservation proof for that pass, or it is not done.

The target theorem is the one stated in the AArch64 lane's plan: for source P, image B, declared environment E and observation mapping α, every execution of B under E maps to a trace allowed by P, with progress proved separately. Passes are free to be straightforward: direct native code, specialization, stack allocation, inferred regions, later ownership-based reuse.

**Memory.** Begin with a small tracing collector for the native and Wasm heap, and keep ownership, liveness and reuse information in the IR. Inferred local allocation, checked allocation contracts (for example a `no_heap_alloc` requirement on a latency-sensitive function) and Perceus-style lowering are evaluated afterwards on real workloads. No language decision depends on one collector.

## 7 Targets

**Ruling: Solo5 comes first.** Version 0.1 proposed native process first; that was rejected.

| Target | Role | State |
| --- | --- | --- |
| Solo5 | First execution target. Fenrir programs run as Solo5 guests | Running in development: see below |
| BEAM/OTP | Supervision and orchestration host around Solo5 guests; owner of the storage adapter (§8) | Not started |
| Native process | Development adapter only | JS candidate |
| Wasm | Later: portable components, sandboxed tenant or policy logic | Not started |

**Solo5 state (12 November 2026).** Solo5 v0.9.3 at the pinned commit `38e0c348` builds from source on Linux x86-64 with the distribution compiler, without Docker and without the retained images whose loss blocked the native epoch. Two development checks run Fenrir programs as guests of the stock `spt` tender and compare every reference step with the Shen model and the JS candidate:

| Check | Guest machine | Programs | Steps | Result |
| --- | --- | --- | --- | --- |
| [tools/solo5/freerun.mjs](tools/solo5/freerun.mjs) | Existing arithmetic machine | 81 | 1,051 | Guest, Shen and JS agree |
| [tools/solo5/freerun-pure-call.mjs](tools/solo5/freerun-pure-call.mjs) | New pure-call machine ([backends/solo5/pure-call/](backends/solo5/pure-call/)): calls, tail calls, closures, tuples, datatypes, match, bytes, `eq`, checked I64, emit | 5,774: 23 hand cases, 56 generated, and every program of the 5-node exhaustive grammar | 86,286 | Guest, Shen and JS agree |

The guest's injected defects are detected by the same comparison: reversed operand order on 4,019 programs and wrapping overflow on 238, the same counts the JS candidate's mutants give in the existing exhaustive check. This is *bounded exploration passed*, development grade: one author lineage wrote the guest machine and the JS candidate was visible while writing it.

What "Solo5 up" still needs, in order:

1. The host control channel, so the host selects steps instead of observing a free run, and with it strict replay. This is the patched tender of the earlier native host and reopens that dependency epoch with rebuilt, recorded identities.
2. `hvt` under KVM. The development container used here has no `/dev/kvm`; `spt` is a seccomp-sandboxed process, not a virtual machine.
3. AArch64, where the proved code lane (PR #8) and the earlier measured profile live.
4. Entry inputs other than unit, bool and int, and IDs above 2^64, which the guest lowering refuses today.
5. Registration of these checks with the workflow controller, and a pinned build of Solo5 in the flake.

Supervision restarts computation; it does not make state or messages durable. Durability comes from a persistence and acknowledgment protocol with a contract (§8).

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

**Ruling: BEAM and SQLite.** The deployment shape, confirmed by the owner (BEAM cannot run inside a Solo5 guest):

- An OTP supervisor owns the Solo5 tender processes. Each Fenrir image is a supervised worker with a typed request/response protocol over the guest's control channel.
- SQLite lives on the host side, behind the storage adapter that discharges Fenrir's durable effects. A durable operation crosses the Solo5 boundary as a protocol request; the guest holds no database.
- The OTP code and the SQLite adapter are host infrastructure with a stated contract. They are named assumptions, tested by crash and history campaigns, not part of what Fenrir's proofs cover.

SQLite fits the model unusually well. It has one writer at a time, so transactions on a store are serial, which is the storage assumption the model makes. The remaining adapter obligations are concrete: `BEGIN IMMEDIATE` so a transaction never upgrades a read lock mid-flight, a journal mode and `synchronous` setting under which a reported commit survives power loss, and an outcome for "busy" that is not mistaken for a rollback.

**Stages.** Each stage keeps the same contract.

| Stage | Deliverable | State |
| --- | --- | --- |
| A0 | Abstract protocol model with the properties above proved, plus a negative control | **Done at model level:** [verification/service/AcceptedJob.v](verification/service/AcceptedJob.v) |
| A1 | The contract as an executable Shen model, which becomes its authoritative statement; Gleipnir explores schedules, crashes and duplicate deliveries against it, with the volatile-mailbox design as a mutant that must be caught | Next |
| A2 | The handler written as a Fenrir program against `atomic`, `once`, `jobs.stage` library interfaces | Needs TC1 effects and the frontend |
| A3 | SQLite adapter under an OTP supervisor, Fenrir worker in Solo5, black-box crash and history tests against the contract | After A2 |
| A4 | A versioned upgrade that preserves pending work | Later |

A0 assumes its storage contract: a transaction is a pure function on one tenant's store, installed atomically, and a crash loses only volatile state. A3 is where that meets SQLite, including the case A0 does not model: a commit whose acknowledgment is lost, which the API must report as indeterminate rather than as a rollback.

## 9 Evidence vocabulary

Gate verdicts (PASS, FAIL, UNKNOWN, BLOCKED, DEFERRED) are unchanged. Claims additionally say which of four things they establish, and one never stands in for another:

| Status | Establishes |
| --- | --- |
| Model property proved | All modelled executions satisfy the property under the stated assumptions |
| Implementation refinement proved | The implementation's behaviour is related to that model |
| Bounded exploration passed | No violation within the explored programs, schedules and bounds |
| Observed history accepted | This recorded execution is consistent with the specification |

Current standing under this vocabulary: TC0-A is *bounded exploration passed* (at `1db7471`, under waivers). The Solo5 free-run comparisons are *bounded exploration passed* against Shen and the JS candidate, development grade. The AArch64 lane is *implementation refinement proved* for a closed unary checked-I64 add/subtract/negate profile against a handwritten instruction model, and is still a draft PR. The service example is *model property proved*. Nothing in the repository is yet a refinement proof against real hardware semantics or a real database.

## 10 Build order

**Ruling: no staged prototypes; build it.** Version 0.1's sequence, with a disposable surface slice, was rejected. Each item below is the real component, built in the repository, checked by the harness that exists. Gates G1–G10 keep their content.

| Step | Build | Done when |
| --- | --- | --- |
| B0 | Merge the open branches in the order given in [campaigns/RECONCILIATION_2026-11.md](campaigns/RECONCILIATION_2026-11.md) | PRs #5, #6, #8 merged; #7 rewritten against §4 |
| B1 | **Solo5 lane** (§7): Shen in the comparison (done), pure-call machine as guest (done, free-running), control channel (open) | A `/2` program with closures and data runs in Solo5 under host-selected steps and agrees with Shen |
| B2 | **TC1 effects** (§4): contract text, then handlers in the Shen model and the candidate with fixtures and mutants; tail-resumptive first, explicit one-shot resumption second | A handler program with agreeing traces; `double-resume` and `forgotten-resume` mutants caught |
| B3 | **Frontend**, written in Shen: reader, elaboration to checked core artifacts, effect-row inference, typing rules as sequent rules | A program a person can write, read, run and check, executing in Solo5 |
| B4 | **Tasks and channels** under the production scheduling contract (§14) | The commuting obligation checked on the exhaustive-small scope |
| B5 | **Service example** A1 → A3 (§8) on BEAM, SQLite and a Solo5 worker | Crash and duplicate-delivery campaigns accepted against the contract |
| B6 | **Proved native code** growing from the AArch64 lane: branches, calls, closures, data | Proved code for a program that is not only arithmetic |

B1 and B2 do not depend on each other. B3 needs B2's contract text, not its implementation. The first universal-claim test of §3 (one TC0-A property through Búri's checker) runs alongside B1.

Advanced machinery (Datalog, a λProlog-style elaboration engine, query compilation, arenas, Perceus-style reuse, interaction nets, tracing compilation) enters when a program in B3–B5 needs it.

The G1 refresh on a supported runner (plan §18 item 1) is still owed. TC0-B and TC0-C as slices of contract 0.2 are superseded by B2 and B4; the requirements they carry (fixtures, mutants, reduction, strict replay per slice) transfer unchanged.

## 11 Búri, Vör and earlier Rocq work

- **Búri** proves Shen implementations correct in Rocq and supplies the KLambda semantics and contract calculus that §3 relies on. It stays its own repository: it has a different subject (Shen, not Fenrir) and other clients.
- **Vör** is named by Búri as the consumer of its language-level guarantees for business contracts. How Vör's contracts relate to the service contract in §8 is not examined here.
- Results proved under wrapping `Word32` arithmetic apply to Fenrir's later wrapping types only (§5).
- Fenrir's object language already has immutable lexical captures ([models/tc0/pure-call-machine.shen](models/tc0/pure-call-machine.shen)). Hosting the reference model in Shen does not give Fenrir programs Shen's global environment.
- Búri's ARM work (Sail model, Islaris environment, a first byte-level lemma against the Armv9.4 model) is the natural route for the AArch64 lane's open ISA-correspondence obligation.

## 12 Owner rulings (12 November 2026)

| # | Question in version 0.1 | Ruling | Where applied |
| --- | --- | --- | --- |
| 1 | Rocq as semantic authority for TC1 | **Changed.** Stay with Shen if theorems can actually be proved there | §3: Shen is authority and checks certificates; Rocq sits behind Búri for rule soundness |
| 2 | Name TC1; supersede TC0-B/C | Accepted | §4, §10 |
| 3 | One-shot resumption by default | Accepted | §4 |
| 4 | Checked `I64`; wrapping words later | Accepted | §5 |
| 5 | Observation list as the preservation boundary | Accepted, and sketch the concurrency model now | §6, §14 |
| 6 | Native process first | **Rejected.** Get Solo5 up | §7 |
| 7 | PostgreSQL as first adapter | **Changed.** BEAM and SQLite | §8 |
| 8 | Staged sequence with a disposable surface slice | **Rejected.** Build it | §10 |
| 9 | Proof assistant version | Current Rocq release, where Rocq is needed | §3: follow Búri's pin |
| 10 | Consolidate here | Agreed. Búri is on GitHub and is about proving Shen/JIT in Rocq | §11 |

Three points in version 0.2 were this document's reading of a ruling. The owner confirmed all three on 12 November 2026:

1. Ruling 1 as "Shen authority, Búri-backed checking", given what the experiment shows Shen does not do alone (§3).
2. Ruling 7 as "OTP supervises Solo5 guests and owns SQLite on the host side" (§8).
3. Ruling 8 as "the frontend is written in Shen and is not disposable" (§10, B3).

## 13 Not decided here

- Surface syntax.
- The elapsed-time profile (plan §11), and the open points listed at the end of §14.
- Realistic finalizers and cancellation shielding.
- Actor protocol typing, hot upgrade and migration contracts beyond A4's version-pinned default.
- Confidentiality as a proved property.
- Any JIT, interaction-net or custom storage-engine work.

## 14 Concurrency model (sketch)

This is a sketch for review, not a contract. It keeps TC0's structured tasks, scopes, bounded channels, cancellation and virtual time (core §6–§10) as the reference semantics and says what the production contract is and why it refines them.

**Three levels, never merged.**

| Level | Lives in | Communication | Failure |
| --- | --- | --- | --- |
| Task | One image, inside a scope | Bounded channels, await | Scope failure and cancellation, as TC0 specifies |
| Actor | One image per actor, supervised by OTP | Bounded mailbox; serializable values only; a send can report overload | Volatile. A crash loses the mailbox and in-flight messages; the supervisor restarts computation |
| Durable workflow | Persisted state | Durable inbox | At-least-once delivery with durable deduplication, so each logical transition takes effect once (the model's `duplicate_delivery_absorbed`) |

**One image is single-threaded.** A Solo5 guest has one virtual CPU. Tasks in an image interleave; they never run in parallel and share no mutable memory. Parallelism is several images. Shared-memory weak-memory behaviour is therefore outside the language, and stays outside until a multi-core image profile is written.

**Scheduling points.** The reference profile may switch tasks at every machine step. The production profile switches only at a *scheduling point*: an operation of the runtime or durable effect classes (`await`, `send`, `receive`, `sleep`, `yield`, `spawn` completion, a durable operation), or a compiler-inserted check (below). Between two scheduling points a task's steps are atomic with respect to every other task.

**Why that is a refinement.** A pure step reads and writes only its own task's immutable state, so it commutes with every step of every other task. Any reference interleaving can therefore be rearranged, without changing any observation, into one that switches only at scheduling points. Production schedules are a subset of reference schedules with the same set of observable behaviours. The obligation is:

> For every program and every reference schedule there is a production schedule with the same observations, and every production schedule is a reference schedule.

The second half holds by construction. The first is the commuting argument; it is a universal claim (§3) and is first checked by Gleipnir on the exhaustive-small concurrent scope by comparing the observation sets of the two schedulers.

**Observations are a partial order.** Preserved: each task's own effect order; the order of operations on one channel, one resource, one durable store; and spawn, await and cancel edges. Not preserved, and not specified: the relative order of causally unrelated events in different tasks, and any wall-clock order across images.

**Cancellation** is delivered only at a scheduling point. Unwinding follows TC0: nested scopes join first, resources release innermost first, exactly once, and no user code runs during abort cleanup.

**Invariants at suspension.** An actor or task invariant must hold at every scheduling point, because that is where other tasks can observe or interleave. A transaction or exclusive borrow may not be held across a scheduling point other than its own operations: the body of `atomic` has an effect row that excludes task, channel and time effects. This is a typing rule, checked like any other.

**Long pure computations.** To bound cancellation latency and starvation, the compiler inserts a budget check on loop back-edges and calls. An inserted check is a scheduling point. It is safe for the same commuting reason and changes no observation.

**Fairness.** Gleipnir's reference scheduler chooses arbitrarily, to explore. The production scheduler runs runnable tasks first-in first-out, which gives weak fairness: a task that stays runnable is eventually run. Every progress claim names that assumption.

**Time.** Unchanged from plan §11: virtual idle-advance time under Gleipnir, and elapsed time as an effect handler in production.

**Open points.**

- Whether `spawn` itself is a scheduling point or only the child's first step.
- Mailbox overflow policy for actors: reject, block with a deadline, or drop with a reported outcome.
- Whether a durable operation's reply can be delivered to a task that was cancelled while waiting, and what the task observes.
- A multi-core image profile, if one is ever wanted.
