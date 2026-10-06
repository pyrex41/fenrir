# Fenrir tiny core and Gleipnir deterministic machine specification

Version 0.2 • Semantic contract revision • Proposed normative implementation target

**Working names:** Fenrir is the language and overall project. Gleipnir is its deterministic harness and conformance environment. ShenCheck retains its existing name. TC0 is the first core; 0.2 identifies this contract revision.

**Status:** Not yet frozen or executable acceptance authority. This revision resolves semantic choices identified in [review.md](review.md). Machine-readable schemas, complete transition fixtures, and evaluator qualification remain required deliverables. An implementation MUST NOT fill a gap silently and thereby establish authority. Record unresolved cases, review an explicit amendment, and qualify it before promotion. The v0.1 ZIP is historical; v0.1 artifacts/tapes require explicit migration and cannot be labeled exact v0.2 replay.

## 1 Scope, authority and profiles

This document specifies TC0 for [01_FULL_VISION.md](01_FULL_VISION.md). Implementation order and gates are in [03_PHASED_EXECUTION_PLAN.md](03_PHASED_EXECUTION_PLAN.md). TC0 is an internal typed language, not final surface syntax or all of Koka.

Full TC0 supports monomorphic functions, immutable algebraic values, lexical closures, dynamically selected tail-resumptive user effects, structured tasks, bounded channels, cancellation, virtual time, and abstract resources. It excludes unrestricted continuations, shared mutable memory, FFI, real I/O, persistence, floats, user exception handlers, and dynamic code loading.

### Qualification slices

| Slice | Added language features | Required evidence at this slice |
| --- | --- | --- |
| TC0-A | Artifacts, exact arithmetic, pure expressions, calls/closures, emit | Independent model/candidate, strict replay, reducer, evaluation-order/arithmetic mutants |
| TC0-B | User effects and handlers | Context/forwarding/suspension rules and handler mutants |
| TC0-C | Tasks, scopes, channels, cancellation, resources, virtual time | Race/lifetime fixtures, stale-waiter repair, runtime mutants |
| Full TC0 | Complete integration of A–C | Full catalog, exhaustive-small exploration, isolation and verdict qualification |

Slices are closed subsets: unsupported AST tags are rejected, not skipped. B suspension tests requiring timers run when C is available; B alone tests pure clause return/trap behavior. Strict replay starts in A, including singleton scheduler decisions. Full TC0 is not a prerequisite for the first repair demonstration.

### Two distinct scheduling contracts

**TC0-PROFILE:** `TC0-REF-STEP/0.2` is the initial Gleipnir reference profile. Published machine steps are its scheduling/cancellation boundaries and its model-fuel units. Its complete frame/transition catalog is versioned and hashed. Exact tapes bind that identity.

Reference steps are not permanently equated with compiled Fenrir scheduling boundaries. A future compiled profile must independently specify legal task switches, cancellation delivery, atomic operations, time progress, fairness, and abstraction/refinement to observable traces. Coalescing pure steps requires that profile and new evidence; it cannot silently reuse reference-step tapes. This document does not yet authorize a production scheduling contract.

Stable rule IDs label obligations; rule meaning is identified by contract revision as well as ID. Semantic changes require a versioned amendment and distinguishing fixtures.

## 2 Artifacts, canonical encoding and validation

An artifact contains contract/schema version, slice, module name, datatype/effect declarations, named function definitions, entry function, input schema, and source map. Functions and AST nodes have globally unique artifact-local IDs assigned before optimization. Semantic locations are never native addresses. The full canonical artifact, including source map, is SHA-256 hashed; source-map changes therefore change artifact identity. No separate semantic hash is an acceptance identity in v0.2.

Canonical transport uses UTF-8 JSON containing only null, booleans, strings, arrays, and objects. JSON numeric tokens are forbidden. Integers, including IDs, indices, capacities and counters, are decimal strings: no plus sign, leading zero, or negative zero. Unsigned fields additionally reject negative strings. Object keys match `[A-Za-z_][A-Za-z0-9_]*` and sort by unsigned UTF-8 bytes. Duplicate decoded keys are rejected before constructing a map. BOM, invalid UTF-8, unpaired surrogates, and unknown fields are rejected.

Canonical output has no insignificant whitespace. Strings are not Unicode-normalized. Quote and backslash use `\"` and `\\`; every U+0000–U+001F control character uses lowercase `\u00xx`, never short escapes. Slash is not escaped; all other Unicode scalar values are emitted directly as UTF-8. Valid noncanonical JSON spelling/whitespace may be accepted at ingestion and re-encoded; evidence stores canonical bytes and hashes those bytes, never raw input. Semantic decimal strings must already satisfy their grammar.

Bytes use lowercase, even-length hexadecimal strings with no prefix; empty bytes use the empty string. Labels are UTF-8 strings under declared input-size bounds. Source-map indices and all field schemas are closed and versioned. Golden byte vectors MUST include alternate escapes, duplicate decoded keys, BOM, surrogate errors and non-ASCII strings.

Expressions encode as arrays `[tag,node_id,...operands]`. Named declarations are closed objects. The grammar below determines arity; schema publication cannot widen the language without amendment. Function declarations specify argument type, result type, finite effect set and body; lambdas carry these annotations explicitly. Region binders are implicit lexical binders identified by the scope/resource node in validation; dynamic instances receive distinct runtime IDs.

**TC0-VALIDATE:** Reject malformed syntax, unsupported slice features, unknown names, duplicate IDs, type/effect mismatches, non-exhaustive or duplicate match arms, invalid region escape, invalid capacities, and invalid entry signatures. Entry accepts one declared serializable input and returns a serializable result. Invalid artifacts do not execute. Validator size/work caps yield ValidationLimit, not acceptance. The gate protects against invalid-artifact execution independently of candidate validation.

## 3 Values, signatures and conservative lifetimes

```text
T ::= Unit | Bool | I64 | Bytes | TrapCode
    | Tuple(T...) | D | T -> {effects} T
    | Outcome(T) | SendResult | ReceiveResult(T)
    | Channel(region,T) | Task(region,T) | Resource(region)
```

Tuples have arity 1–8. Datatypes have finite named constructor sets and may be recursive; values are finite constructor trees. A datatype with no finite inhabitant is legal, but no finite input/value can inhabit it. Types are monomorphic. Built-in families instantiate concrete monomorphic types; they do not introduce user polymorphism.

Built-in result families expose the listed constructors to construct/match just like declared datatypes; constructor names are qualified by their concrete type. TrapCode is a closed built-in enum whose constructors are the language trap names below.

Serializable types contain only Unit, Bool, I64, Bytes, TrapCode, serializable tuples/datatypes and compatible built-in results. Functions and handles are neither serializable nor equality-compatible. Recursive serializability/equality checks traverse declaration dependencies with cycle detection; a reachable incompatible field disqualifies the type. Immutable aliases never change (**TC0-VALUE**).

### Built-in signatures

| Operation | Argument(s) → result | Rule |
| --- | --- | --- |
| add, sub, mul, div | I64 × I64 → I64 | Exact range checks; div truncates toward zero |
| neg | I64 → I64 | Exact range check |
| lt, le, gt, ge | I64 × I64 → Bool | Mathematical comparison |
| not | Bool → Bool | Boolean negation |
| bytes_length | Bytes → I64 | Length must fit I64; otherwise Overflow |
| bytes_index | Bytes × I64 → I64 | Zero-based index, octet result 0–255; Bounds on invalid index |
| bytes_concat | Bytes × Bytes → Bytes | Immutable concatenation; nonmodeled allocation exhaustion is infrastructure failure |
| eq | Equality-compatible T × T → Bool | Structural equality at a checked concrete T |
| spawn | (Unit → {E} T) → Task(s,T) | Closure and inherited handlers must meet lifetime obligations |
| await | Task(s,T) → Outcome(T) | Ok(T), Cancelled, Failed(TrapCode) |
| cancel | Task(s,T) → Unit | Request, not join |
| send | Channel(s,T) × T → SendResult | Sent or Closed |
| receive | Channel(s,T) → ReceiveResult(T) | Item(T) or End |
| close | Channel(s,T) → Unit | Idempotent |
| now, sleep | Unit → I64; I64 → Unit | Idle-advance time rules below |
| yield, use, emit | Unit → Unit; Resource(r) → Unit; label × serializable T → Unit | Reserved runtime/observation effects |

Reserved effect names are Task (scope/spawn/await/cancel/yield), Channel (channel/send/receive/close), Time (now/sleep), Resource (resource/use) and Emit (emit). Their requirements remain in declared effect sets and are discharged by the runtime, not user handlers. Pure operations have no effect requirement; traps are not user-handleable effects.

I64 range is −2^63 through 2^63−1. Add/sub/mul/neg trap Overflow outside it; division by zero traps DivZero; minimum-I64 divided by −1 traps Overflow. Sleep of a negative duration traps InvalidDuration. Projection indices are zero-based, statically checked, and invalid indices reject validation. The closed language trap set is Overflow, DivZero, Bounds, InvalidDuration, TaskLimit and ChildFailed. UnhandledEffect, use-after-release and invalid-handle behavior are candidate defects for validated programs, not ordinary traps. Diagnostic payloads are separate from TrapCode and preserve source/task identities.

### Region and capture rules

**TC0-REGION:** Region nesting is a lexical tree. The root and each task own an implicit task scope. `scope` creates a child task-scope region; `resource` creates a resource region covering only its body. A region outlives another if it is the same region or a lexical ancestor. No resource body implicitly creates a task scope or delays release for children in an enclosing scope.

The validator computes a conservative support set for every value: regions referenced by handles in its type, contained values, or closure captures. Function types carry checked capture-support metadata in the validator even though the readable type grammar omits it. Branches union support. A value leaving a binder cannot retain that binder's region, including indirectly through tuples, datatypes or closures. Uncertain support is rejected; v0.2 does not require general lifetime inference or region polymorphism.

**TC0-CAPTURE-SUPPORT:** From A onward, the checked closure descriptor is `{code_id, captures, capture_support}`. Captures are binding-ID/value pairs in increasing binding-ID order; the checked artifact schema assigns stable IDs to lexical bindings as well as code. `capture_support` is a sorted, duplicate-free array of lexical region-binder IDs, represented as canonical unsigned decimal strings. Closure construction unions the support of captured values, including captured closures. Closed named functions have empty captures/support. Higher-order function parameters carry this same checked support component; it is not erased by an ordinary arrow signature. A uses `capture_support: []`, even for closures capturing pure values. C populates the same field rather than introducing a different closure interface.

The validator recomputes support; artifact annotations are claims to check, not authority. As a conservative call-result summary, union the callee's capture support, actual argument support and regions in the declared result type. Propagate that upper bound through returned function values and branch joins; reject escaping results when this bound is unsafe, even if a more precise analysis could accept them. No parametric lifetime inference is required. Runtime descriptors retain a binding from lexical region IDs to live region instances, so recursive scope instances cannot alias merely because they share a binder ID. Support metadata grants no resource-release or task-scope ownership. This descriptor is internal checked machine data, not permission to serialize closures as language values. Its concrete schema and empty-support fixtures are A deliverables.

At spawn into owning task scope s, every region in the closure's support and every copied handler's captured support MUST outlive s. Only serializable values may traverse channels. Resources may be borrowed by children but ownership/release remains with the acquiring task. Task result support cannot contain child-local regions and must be safe in the owning scope.

Rejected:

```text
scope:
    resource("r", r):
        spawn(() => use(r))   # r is shorter-lived than the owning scope
        unit
```

Accepted lifetime pattern:

```text
resource("r", r):
    scope:
        spawn(() => use(r))   # inner scope joins before r is released
        unit                 # do not return the inner Task handle
```

These are explanatory pseudocode, not additional syntax. Handler inheritance follows the same restriction. If static rules cannot establish it, reject rather than invent implicit joins.

## 4 Expressions, frames and evaluation

```text
e ::= unit | bool(b) | int(n) | bytes(hex) | var(x)
    | let(x,e,e) | if(e,e,e) | tuple(e...) | project(e,i)
    | construct(D,C,e...) | match(e,[C(vars) => e]...)
    | lambda(x:T,result:T,effects:E,e) | apply(e,e) | call(function,e)
    | prim(op,e...)
    | handle(effect,[op(x) => e]...,body) | perform(effect,op,e)
    | scope(body) | spawn(e) | await(e) | cancel(e) | yield
    | channel(T,capacity) | send(e,e) | receive(e) | close(e)
    | now | sleep(e) | resource(label,x,body) | use(e) | emit(label,e)
```

Named functions accept one argument (tuples supply multiple arguments) and may be mutually recursive. Let is nonrecursive. Variables and handler clauses capture immutable lexical bindings. Match binds constructor fields; bodies/clauses/branches are not eagerly evaluated operands.

**TC0-EVAL:** Evaluate operands strictly left to right. A trapping operand prevents later operands from running. If/match select exactly one branch. Evaluation never depends on hash iteration order.

**TC0-TAIL:** Tail calls do not increase semantic continuation depth or native stack usage. Calls reuse the current function-return destination in tail position; lexical cleanup frames for genuinely active scopes/resources/handlers remain. Recursively acquiring new lifetimes is not a bounded-stack tail-call claim.

### Reference-step convention

The Shen machine uses explicit control, immutable environment and continuation data, not host recursion for target calls or scheduling. The following staging is normative for `TC0-REF-STEP/0.2`:

| Control/frame family | One selected Run step |
| --- | --- |
| Literal, variable, lambda | Produce Value; do not also return through a frame |
| Strict operand constructor | Push operand-collection frame and enter first operand; a zero-operand operation enters Ready |
| Operand-collection return | Store one value and enter next operand, or set Ready after the last value; do not apply the operation yet |
| Ready pure operation | Apply primitive/build tuple or constructor/project value; produce Value or begin trap unwind |
| Let return | Bind value and enter body |
| If/match return | Select and enter one branch, extending lexical bindings for match |
| Ready call/apply | Enter function body with checked bindings and appropriate return destination; no body instruction runs yet |
| Function-return frame | Restore caller destination and propagate Value |
| Handle entry / normal exit | Install handler and enter body / remove handler and propagate Value |
| Ready perform | Resolve dynamic handler, save suspended segment, and enter clause |
| Clause-return frame | Restore suspended segment with one returned Value |
| Scope entry / body return | Create region and enter body / close scope, save body result, enter Join |
| Ready runtime operation | Invoke and commit or register one operation, including deterministic stabilization |
| Join | If children terminal, exit scope and propagate outcome; otherwise register wait and block |
| Resource entry / normal exit | Acquire and enter body / release once and propagate Value |
| Unwind | Manage one innermost scope, or release one innermost resource, or discard one ordinary frame/handler delimiter |
| Empty continuation | Begin implicit task-scope join, or terminate after that join/cleanup |

Dispatch of let/if/match enters their first expression with the corresponding frame. Tuple/construct/prim/apply/send collect expression operands in grammar order; declaration names, labels, types and indices are metadata, not evaluated operands. Call collects its argument. Scope, handle and resource use their entry rules rather than ordinary operand collection. Yield/now/channel enter Ready on dispatch. Positive sleep wakes with a committed Unit value, not by re-executing sleep.

Blocked-operation commits install a pending return value and mark the task Runnable; the task consumes that value on its next Run without re-invoking the operation. Cancellation may intervene before consumption. Spawn/cancel/close/channel creation and observations commit in Ready steps, not operand-return steps. A task termination step includes scope-failure latching and waiter wakeups but does not execute another task's continuation.

Cancellation delivery preempts normal control at a Run boundary; that step begins unwind without also releasing a resource. Each Run and AdvanceTime costs one reference step. Bookkeeping inside a transition is not separately scheduled. The executable catalog MUST enumerate concrete frame shapes, all AST dispatch rules, tail positions, trap routing and event sequences with one-step fixtures. Missing cases block freeze rather than becoming implementation discretion.

## 5 User effects and handler contexts

**TC0-EFFECT:** Handler selection is dynamic in the current task, innermost active matching handler first. Closures capture lexical variables, not definition-site handler selection. Calling a closure under H2 uses H2 even if defined under H1.

Each effect declares operations A → B. A handler supplies exactly one clause per operation, checked at the declared argument/result types. When Ready perform executes, save the computation segment through the selected handler, including all intervening inner handlers and cleanup frames. The clause runs in its definition's lexical variable environment plus its operation argument, under only the selected handler's outer dynamic handler stack. The selected handler and every intervening inner handler are inactive during the clause. Their intervening scope/resource frames remain suspended and live, but are not the clause's active lexical ownership context. Clause-created scopes/resources attach to the selected handler's outer active context; its spawns use that context's innermost task scope and the usual capture checks. Thus performing the same effect forwards outward; an inner different-effect handler is unavailable in the clause.

There is no user-visible resume continuation. On normal clause return, restore the saved segment and supply one B value at the suspended operation. The original handler remains active in the resumed body; body result passes through unchanged. Clause sleep/blocking suspends the clause task normally.

A clause trap/cancellation aborts rather than resumes the saved segment. Cleanup follows actual acquisition/ownership order: finish clause-local nested scopes/resources first, then the suspended segment's scopes/resources, then outer frames. Suspended resources remain live and owned until resume or abort cleanup; moving handler frames does not release them. User code never runs during abort cleanup.

**TC0-EFFECT-CHECK:** Functions/lambdas declare finite effect sets. Calls require their declared effects. Perform adds its effect. Handle checks the body with that effect available and checks clauses under the outer available context; its outward requirement is `(body effects minus handled effect) union clause effects`. Spawn requires the closure's effects to be discharged by the spawning task's copied active handler context or propagated outward at that site. Reserved scheduler/channel/time/resource/emit effects cannot be replaced by user handlers. Entry must close all user effects. UnhandledEffect in a validated run is a candidate defect.

Spawn copies active handler definitions, lexical captures and outer ordering, not the parent's continuation or resource ownership. Child handler frames are independent and persist after parent handler exit. Region support checks include all copied captures. Inactive suspended handlers are not copied when a clause spawns.

**TC0-HANDLER-OWNERSHIP:** Copying a handler rebinds its ownership anchor to the child's implicit task scope; it never copies a parent task-scope ID or cleanup authority. Clause execution for an inherited handler uses the child's task-local ownership context. Newly acquired resources belong to the child; clause-created scopes and unscoped spawns attach to that child-local anchor, or to scopes entered by the clause itself. Selecting a handler's outer effect context does not select the parent's ownership context. Captured ancestor handles retain only their explicitly allowed use/await/cancel capabilities; they do not grant authority to enter, close, spawn into, or unwind the parent's task scopes or release its resources. This B/C rule is tested when C exists and does not block A.

## 6 Machine state and identities

```text
State = {
  tasks, scopes, channels, resources, registrations, timers,
  virtual_time, next_ids, observations, scheduler_epoch,
  remaining_reference_steps, artifact_hash, slice, profile
}
Task = {
  id, owning_scope, control, environment, continuation,
  handlers, suspended_segments, owned_resources, owned_scopes,
  status, cancel_requested, pending_operation, result
}
Scope = {
  id, owner_task, phase, children, body_outcome,
  failed_children, join_registration
}
```

Statuses are Runnable, Blocked(reason), Unwinding(reason), Terminal(outcome). Outcomes are Ok(value), Cancelled, Trap(code). Scope phases are BodyOpen, Joining and Exited. Failure is a separate monotonic latch, not a replacement for the body outcome.

IDs are increasing unsigned integers in separately named task/scope/channel/resource/registration spaces; root task and root scope IDs are zero. Child creation also records parent task and spawn node. Candidate IDs must map bijectively to model IDs. Configured ID-space exhaustion is a harness limit, never an invented language trap.

Root starts with canonical input, virtual time zero and an implicit root scope. Each child begins with its own implicit task scope nested within its owning region. Identical initial state plus decisions yields identical normalized observations.

## 7 Reference scheduler and time

**TC0-SCHEDULE:** Enabled decisions contain Run(id) for every Runnable or Unwinding task, in numeric ID order. Run advances exactly one published reference step. The canonical policy selects the lowest ID; exploration may select any enabled decision. Pure computation is preemptible in this reference profile only. No fairness is implied.

**TC0-TIME:** `TC0-IDLE-TIME/0.2` supplies nonnegative I64 nanoseconds. Now reads it. Sleep(d) checks d ≥ 0 and time+d overflow; Sleep(0) commits Unit as a yield without a timer. Positive sleep registers a deadline and blocks. When no task is Runnable or Unwinding and live timers exist, the sole enabled decision is AdvanceTime(minimum deadline). It sets time and commits all due sleeps in numeric task-ID order. Cancellation removes the timer. Without runnable tasks or timers and before root termination, report Deadlock with a canonical wait graph.

Host elapsed time never advances virtual time. Fair scheduling does not repair idle-only timer starvation: a perpetually runnable task can prevent time advance even under fair task selection. Production elapsed-time deadlines and simulations of them require a separate profile and evidence. A wall-clock watchdog is HarnessTimeout, not a language timer.

## 8 Structured tasks, scope failure and joins

Scope creates a nested task-scope region. Spawn owns its child in the caller's innermost active task scope; the child starts Runnable after the transition and does not run within it. A child uses its own implicit task scope for its later spawns unless it enters an explicit nested scope.

TaskLimit applies only when explicitly selected as a modeled profile quota. It counts all nonterminal tasks, including root and unwinding tasks. The check occurs before allocation. Terminal tasks no longer charge the quota even if their handles remain accessible. Spawning into a Joining/Exited scope is an illegal machine transition; spawning into a failure-latched BodyOpen scope traps ChildFailed before allocation.

Await may be repeated and may have multiple waiters. Any task with a region-valid handle may await/cancel it, including a sibling; parent-only access is not required. Awaiting a terminal child returns its stored Outcome without consuming it. Pending awaits register/wake in registration-ID order. Await cycles are permitted to deadlock, not silently broken. Observation of Failed does not acknowledge or suppress scope failure.

**TC0-SCOPE:** A child Trap is latched into its owning scope atomically in the child's terminal transition, after that child's own cleanup/join. In the same transition, request cancellation of every other nonterminal child in task-ID order. No parent Run is needed to initiate sibling cancellation. The parent body is neither cancelled nor asynchronously trapped; it may continue pure computation, emit, or await. A future spawn into that failed scope traps as above.

Failure is not propagated to the owning scope when the child first starts trap unwind. In `TC0-C-FAILURE-AFTER-DESCENDANT-JOIN`, A and B share an owning scope, and A has live descendants: A traps, requests descendant cancellation, and joins/cleans up while the fixture's schedule runs B and records its emission. B receives no cancellation from A's owning scope during that interval. Only after A becomes terminal does its owning scope latch failure and request B's cancellation. Descendant cleanup can therefore delay sibling-failure propagation; no bound on that delay is implied.

On normal body return, close the scope and enter Joining with its saved value. On body trap/cancellation, close it, save the original reason, request child cancellation in ID order, and enter unwind join. Requests are idempotent. Exit requires every owned child terminal. If body returned normally and any child trapped, exit with ChildFailed; otherwise return the body value. Explicitly cancelled children alone do not fail a normal scope.

Body Trap takes precedence over child failures. Body Cancelled takes precedence over child failures when no body Trap has already begun unwind. Cancellation delivered while joining a normal body changes its outcome to Cancelled and requests child cancellation. Once a trap/cancellation unwind reason is latched, later cancellation does not replace it. Retain all child trap diagnostics in task-ID order regardless of primary outcome.

A last-child termination wakes a blocked owner Join; scope exit itself occurs on the owner's Run, not on the child transition. No child outlives its scope. Resource safety follows the conservative region rules, not delayed release of resources acquired inside an enclosing task scope. Root terminal outcome is accepted only after implicit root-scope join and cleanup; no subsequent semantic operation is accepted.

## 9 Cancellation

Cancel requests cancellation and returns Unit without joining. Terminal targets are unchanged. The cancel-request event is emitted for each explicit invocation with a `new_request` boolean; repeated requests never duplicate cleanup or effective-cancellation events.

**TC0-CANCEL:** On the target's next Run, pending cancellation begins unwind before normal evaluation. If Blocked, the request atomically removes its channel/timer/await registration and marks it Unwinding so it can take that Run. Registered operations have exactly one disposition: Committed or Removed. A Removed operation cannot commit later. A Committed operation is never undone by cancellation, including message consumption before the receiver consumes its return value.

An Unwinding task does not run user code and retains its original unwind reason. Cancellation of a task already unwinding from Trap does not turn the trap into Cancelled. Scope-generated requests use the same primitive; ordering is specified above.

Unwind proceeds one reference step at a time and waits for owned child scopes before releasing enclosing resources. If an unwind join must wait, it registers and becomes Blocked until child termination wakes it to continue Unwinding; it must not stay runnable and spin. Removing a normal Join registration on cancellation does not abandon its children: unwind re-enters that scope's join after issuing child cancellation. Budget exhaustion during unwind is incomplete evidence, never successful cleanup. A caller requiring completion uses await; a send after await returns Cancelled cannot be consumed by a stale registration.

## 10 Buffered channels

Channel(T,c) creates an open FIFO queue in the current task scope; T is serializable and 1 ≤ c ≤ the configured maximum. Zero-capacity channels are excluded. Queue changes are atomic Ready transitions.

Send evaluates channel then payload. Closed returns Closed. Free space appends payload and commits Sent; full queues register a sender carrying the evaluated value. Receive consumes the oldest queued value and commits Item, or returns End for an empty closed queue, or registers a receiver. Registrations have globally monotonic IDs.

**TC0-CHANNEL:** Stabilize each channel transition without task interleaving: serve the earliest registered receiver while queued data exists; then admit the earliest sender while open and space exists; repeat until no rule applies. Each admission appends one value and commits Sent; each consumption commits Item. Commit events follow stabilization order. Awakened tasks do not execute in the transition.

Close returns Unit. First close marks closed, commits Closed to all waiting senders in registration order without enqueuing their payloads, serves buffered values to waiting receivers in registration order, then commits End to remaining receivers when empty. Repeated close emits its invocation/Unit commit but no new channel-close state event or duplicate waiter commits. Buffered values remain readable. Cancellation removal stabilizes the affected channel under the same rule, with no Removed registration eligible for service.

FIFO and waiter ordering are language rules, not network assumptions.

## 11 Resources, events and observation boundaries

Resource entry acquires a live abstract resource and binds its handle. Normal resource exit releases it; trap/cancellation unwind releases it after nested task scopes have joined. Release is nonblocking/nonthrowing, reserved, exactly once, innermost first. Acquisition failure injection and arbitrary user finalizers are excluded.

**TC0-RESOURCE:** Use validates accessibility/liveness, emits resource-use and returns Unit. Use-after-release, double release and escape are forbidden for validated programs. A resource does not implicitly join children spawned into a longer-lived surrounding scope; validation rejects that pattern.

Emit accepts a serializable value and returns Unit. Events include operation invocation/registration/commit/removal, task spawn/cancel-request/cancel-effective/termination, scope entry/failure/exit, resource acquire/use/release, channel close, application emit and time advance. The schema assigns canonical task/node/operation identities, payloads and event order. Invocation precedes that operation's state effect and commit; stabilization commits follow the initiating state change; child termination precedes its scope-failure latch and resulting cancellation requests. Frame fixtures specify the remaining concrete sequences before qualification.

The normalized semantic trace contains only schema-defined model events and their order. Host timestamps, native addresses, run-directory names and transport/debug metadata are kept in separate diagnostic streams, not semantic fields. Normalization cannot delete semantic outcomes or reorder events.

Candidate events are evidence inputs checked against the oracle, not verdict authority. The adapter independently observes framing, decoded artifacts/outputs, process or guest exit, and termination handshake; effects are mediated where available. Claims are limited to those observations. An early terminal event contradicting model state is rejected. A completely fabricated admissible trace alone cannot reveal hidden native computation or certify the absence of private tasks/resources.

## 12 Candidate adaptation and isolation

The reference profile's atomicity unit is its published step, including channel stabilization. Initial candidates use explicit state machines with equivalent safe points. Conservative generated native code may implement this profile; later production/optimized scheduling needs a separately qualified contract.

The host chooses decisions. Requests bind run, sequence, task, node, operation ordinal and payload. Reject duplicate/out-of-order/malformed/oversized requests. Host framing sequence is validated independently of candidate-supplied contents. No ambient guest device or external input is authorized unless specified in the profile.

**TC0-BOUNDARY:** Candidate builds and runs use isolated writable directories and read-only oracle, goldens and gate inputs, with no evaluator credentials, explicit network/device access policy, and source/binary/protected-input verification. Test attempted protected writes and forbidden access. State sandbox limitations and stop affected claims if enforcement is absent. Path permissions in an agent task packet are not execution isolation.

## 13 Strict replay from the first slice

A header binds contract/slice, artifact/input hashes, oracle/catalog, monitor/gate version, environment/time/scheduling profile, candidate compiler/runtime, backend, initial state and all bounds. Exact replay uses exact identities, not moving branch names. Different candidates can be checked against a fixed scenario, but that is not exact replay of the original candidate.

Each choice has schema, run ID, index, scheduler epoch, decision kind, canonical enabled-domain hash, selected decision and selected-transition site. Scheduler epoch identifies the decision point independently of any selected task. Run site contains task/node/control-rule/occurrence; machine-owned joins/unwind/termination use explicit machine-site tags rather than invented AST nodes. AdvanceTime site contains deadline and a time-transition occurrence, not a task/node.

Record every decision, including singleton Run and AdvanceTime. Epoch increments after every accepted decision. Transition occurrence counters increment only for the corresponding executed site/rule. The enabled domain is a canonical array of tagged decisions in numeric task order (or the sole AdvanceTime), hashed with SHA-256. The transport/event schemas must define these records before the slice gate.

**TC0-REPLAY:** Validate header compatibility, epoch/site/kind/domain and membership at each decision. Missing choice, extra suffix, changed domain/site, or out-of-order choice is ReplayDiverged; no seed fallback. Check trace checkpoints and the final boundary as well as the tape.

A recording footer states Completed(root outcome), Deadlock(wait graph), BudgetExhausted(boundary state/checkpoint), or Divergence(first mismatch, epoch, expected/observed checkpoints). A deterministic semantic failure can replay Exact when the same first divergence and prefix recur; its conformance remains Diverged and never becomes PASS. Do not require a divergent candidate to reach model root termination to retain a replayable failure. A deterministic budget-boundary recording may replay Exact but remains BudgetExhausted and cannot satisfy a completion gate. Truncated evidence or nondeterministic watchdog/crash endings cannot establish exact terminal replay; classify replay Incomplete unless a separately validated backend captures that boundary. CandidateCrash and HarnessTimeout remain independent execution outcomes.

Cross-version migration is a new claim, never exact original replay. Discovery seeds supplement retained decisions, not replace them.

## 14 Bounds, exploration and gate verdicts

Initial smoke settings: at most 4 live tasks including root, 2 channels of capacity ≤2, 2 live resources per task, 32 bytes per Bytes value, 200 AST nodes, 200 reference steps, and input integers −2 through 2. These are campaign settings, not universal limits or a tractability guarantee. The manifest also bounds serialized aggregate values, validation work, search nodes, model states, trace bytes and wall time. Unless explicitly modeled, crossing an exploration cap truncates the claim; it does not fabricate a language trap.

Check terminal/deadlock state before testing whether another step fits the fuel budget, so termination on the last permitted step is Completed. A runnable next transition with zero remaining fuel is BudgetExhausted. Physical OOM, native stack failure and truncated transport are not language traps.

**TC0-EXPLORE:** Search identity is `(machine state, property-monitor state, remaining bounds)`. Include pending registrations, timers, continuations/suspended segments, IDs, obligations, relevant history/trigger/coverage summaries and fairness monitors. Different obligations cannot merge merely because machine states match. Excluding/quotienting a field needs a reviewed equivalence argument. Evidence histories and search-state hashes are distinct; hash collision handling compares canonical states before merging. Search reduction needs validation against unreduced small campaigns.

```text
conformance: Admitted | Diverged | Unknown
property: SatisfiedWithinScope | Violated | Unknown | NotReached
execution: Completed | Deadlock | StoppedAtDivergence | CandidateCrash | HarnessTimeout | HarnessError | BudgetExhausted
replay: NotRequested | Exact | Diverged | Incompatible | Incomplete
exploration: Sampled | ExhaustiveWithinBounds | Truncated
```

Properties are per property ID, not one undifferentiated boolean. Report scope, triggers, coverage and cap hits. Permitted deadlock may be Admitted; a progress property can still be Violated. Agreement on a trap is conformance for that run, not application success. Invariants established only over prefixes retain that scope. Missing required reachability coverage cannot pass. ExhaustiveWithinBounds means every reachable alternative in a finite declared scope was explored without truncation/pruning gaps; completing one bounded run is not exhaustive exploration.

**TC0-GATE:** Aggregate independently of per-run results using a versioned requirement manifest. PASS requires every required row to meet its declared outcome, coverage, exploration and replay scope with fresh source-bound evidence. Unexpected violations/divergences in required candidate/property rows yield FAIL; missing evidence/caps yield UNKNOWN; unavailable required infrastructure yields BLOCKED. Mutant-test rows may require an independently expected divergence and reproducer; satisfying that row demonstrates evaluator detection, never conformance of the mutant. Report all reasons rather than hiding unknowns behind a failure. DEFERRED is only an explicitly optional row and never satisfies a required gate. Crash/watchdog/invalid-protocol tests may pass an evaluator robustness row only when the independently expected classification is observed; they never count as a semantically completing candidate run.

## 15 Required distinguishing fixtures

Fixtures have stable IDs, rule references and hand-derived traces. Required additions include:

| Case | Required distinction |
| --- | --- |
| Left operand traps, right emits | No right emission; Ready step separate from operand return |
| I64 boundary arithmetic | Independently derived Overflow/DivZero/results, including values around 2^53 |
| Tail recursion / alias retention | Bounded stack for true tail calls; immutable aliases unchanged |
| TC0-A-CLOSURE-EMPTY-SUPPORT | Pure captures survive closure creation/call with checked capture_support []; higher-order calls preserve the descriptor |
| Closure defined under H1, called under H2 | Dynamic H2 selected |
| Outer E across inner F | F inactive in E clause, restored on resume |
| Clause sleeps/traps/cancels | Single resume or abort; both cleanup segments handled |
| TC0-BC-INHERITED-HANDLER-OWNERSHIP | Inherited clause in child C creates resource and task D owned by C's local context; C joins D/releases its resource before terminal; parent scope gains no D and parent resources are not released by C |
| Child traps while body computes | Failure latched and siblings requested cancelled at child termination; body continues |
| TC0-C-FAILURE-AFTER-DESCENDANT-JOIN | A trap → descendant cancellation/join and scheduled B emission → A cleanup/terminal → owning-scope failure latch → B cancellation request; no earlier sibling request |
| Parent awaits Failed | Does not suppress scope ChildFailed |
| Body trap versus child trap/cancel | Body reason precedence; all child diagnostics retained |
| Resource capture across outer scope | Rejected; explicit inner scope accepted |
| Copied handler resource capture | Same conservative lifetime requirement |
| Cancel blocked receiver then await then send | No stale consumption |
| Receive commit before cancel/result consumption | Message stays consumed |
| Close/cancel and multiple waiters | Deterministic dispositions and stabilization order |
| Equal deadlines / perpetually runnable task | Due sleepers wake together; idle-time starvation not hidden by fairness |
| Repeat await/close/cancel | No consumed task outcome or duplicate release/commit |
| Budget during cleanup / last-step termination | Incomplete cleanup versus valid completion |
| Singleton/AdvanceTime replay | Correct epoch and machine-site validation |
| JSON alternate escapes/decoded duplicate keys | Unique output bytes; duplicates rejected |
| Same machine, different obligations | Distinct exploration states |
| Fake early terminal / forbidden evaluator write | Model contradiction / enforced isolation rejection |

Add generated valid and invalid programs, exhaustive small domains and fresh regressions after hand fixtures pass. B fixtures depending on C must remain explicitly deferred until C, not credited early.

## 16 Mutant catalog by component

Mandatory non-equivalent mutants: reversed operands, bad overflow, skipped handler, double resume, lost/duplicated message, stale cancelled waiter, omitted child join, missing/double release, host-time read, ignored replay-domain mismatch, early terminal contradiction and unknown-to-pass promotion.

Evaluator/protocol mutants start in A using scripted peers; pure candidate mutants start in A; handler mutants in B; runtime/time mutants in C; compiler/backend mutants when those components exist. Mutation of the semantic kernel is a separately isolated evaluator test, never a candidate patch that changes authority. Full qualification requires the complete applicable catalog and an equivalent accepted control.

A kill requires the expected discrepancy classification and retained reproducer. A harness crash alone is not a semantic kill. Fabrication tests exercise observable contradictions, not a claim to detect every perfectly fabricated trace. Survivors block the relevant implemented-feature gate.

## 17 Shen implementation and independent checks

Use explicit constructors, ordered maps, explicit integer representation and data continuations. The transition kernel does not read wall time, entropy, files, sockets or host thread identity. Host wrappers serialize and transport; they do not decide legal abstract outcomes.

Before relying on a Shen port, demonstrate exact I64 values/intermediates and unsigned IDs against independently established integer results. Include multiplication wider than I64, min/max, minimum negation/division, sign truncation and values around 2^53. Use exact integer support or an explicit exact arithmetic implementation; decimal transport and agreement between ports are insufficient evidence.

Two-port fixture agreement supports only the demonstrated portability claim, not semantic truth. Preserve an independently structured encoding/arithmetic evaluator. Shen types assist state construction; Prolog search order is not semantic authority or a completeness proof.

## 18 Freeze criteria and migration

Qualify A, then B, then C with model, evaluator, independent candidate, strict replay, minimization and applicable mutants in each slice. Full TC0 freeze requires closed artifact/event/tape schemas, concrete transition/frame catalog, effect/region checker, independent review, all hand fixtures, monitor/gate encoder, applicable mutant coverage, exhaustive-small evidence and no unresolved semantic ambiguity.

Reference-profile changes version the catalog and tapes even if abstract outcomes are unchanged. A production scheduling/time profile requires its own reviewed contract and refinement evidence; full TC0 freeze does not imply production qualification. No optimization may change the oracle in its own candidate patch.

Future language additions require new rules, generators, replay compatibility and independent evaluator tests. This revision chooses semantics but does not assert that those choices or any acceptance gate have already been implemented or proven.
