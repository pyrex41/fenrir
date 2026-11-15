# TC1 concurrency contract: structured tasks and bounded channels

Draft 1 • 15 November 2026 • For owner review

**Status.** The first slice of step B4 of
[04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) (§10), written
before its two machines, which were then written from it: a Shen model and an
independent JavaScript implementation. Nothing here is qualified. It takes the
reference semantics of [02_TINY_LANGUAGE_CORE.md](../../02_TINY_LANGUAGE_CORE.md)
§6–§10 (machine state, reference scheduler, structured tasks, scope failure and
joins, cancellation, buffered channels) and the concurrency sketch of the
amendment (§14), and states what slice **C1** keeps, what it changes and what it
defers. Every choice that the sources leave open, or that this text makes
differently from TC0 0.2, is marked *provisional* and listed in §13 for the
owner.

C1 is TC1 (TC0-A plus [EFFECTS.md](EFFECTS.md), slices H1 and H2) plus what is
below. Nothing in EFFECTS.md changes. Its §8 lists what concurrency must respect;
§11 here says how C1 does.

## 1 Scope of slice C1

In C1: `scope`, `spawn`, `await`, `cancel`, `yield`; bounded channels
(`channel`, `send`, `receive`, `close`); cancellation, delivered only at
scheduling points; scope failure (a child's trap latched into its scope, a
cancellation request to its siblings, joins, and the precedence of the primary
outcome, core §8–§9); handlers copied into spawned tasks; deadlock as an
execution outcome; the reference scheduler and the production scheduler, and the
obligation between them (§9).

**Deferred**, and rejected by the validator where they have syntax:

- time: `now`, `sleep`, virtual time and timers (core §7 `TC0-TIME`);
- resources and regions: `resource`, `use`, region support sets
  (`TC0-REGION`, `TC0-CAPTURE-SUPPORT` stay at `capture_support: []`); C1 uses
  the simpler lifetime rule of §3 instead;
- durable effects (transaction, durable job, durable inbox) and actors (the
  second and third levels of amendment §14);
- the `TaskLimit` quota (a configured live-task bound is a harness limit, never a
  trap);
- compiler-inserted budget checks (amendment §14 "Long pure computations"): there
  is no compiler yet; when there is one, an inserted check is a scheduling point
  of §8.

## 2 Expressions and types

```text
e ::= ... | scope(e) | spawn(e) | await(e) | cancel(e) | yield
          | channel(T, capacity) | send(e, e) | receive(e) | close(e)

T ::= ... | Task(T) | Channel(T) | Outcome(T) | SendResult | ReceiveResult(T)
```

Artifact encoding, as everywhere: `["scope",n,body]`, `["spawn",n,e]`,
`["await",n,e]`, `["cancel",n,e]`, `["yield",n]`, `["channel",n,T,capacity]`
(capacity a canonical unsigned decimal string), `["send",n,ch,value]`,
`["receive",n,ch]`, `["close",n,ch]`. Types: `["Task",T]`, `["Channel",T]`,
`["Outcome",T]`, `"SendResult"`, `["ReceiveResult",T]`.

| Expression | Type | Effects |
| --- | --- | --- |
| `scope(b)`, `b : T` | T, which must be serializable | those of b, plus Task |
| `spawn(f)`, `f : Unit -> {E} T` | `Task(T)`, T serializable | those of f, plus E, plus Task |
| `await(t)`, `t : Task(T)` | `Outcome(T)` | those of t, plus Task |
| `cancel(t)`, `t : Task(T)` | Unit | those of t, plus Task |
| `yield` | Unit | Task |
| `channel(T, c)`, T serializable, 1 ≤ c ≤ the configured maximum | `Channel(T)` | Channel |
| `send(ch, v)`, `ch : Channel(T)`, `v : T` | SendResult | those of ch and v, plus Channel |
| `receive(ch)`, `ch : Channel(T)` | `ReceiveResult(T)` | those of ch, plus Channel |
| `close(ch)`, `ch : Channel(T)` | Unit | those of ch, plus Channel |

- `Outcome(T)` has constructors `Ok(T)`, `Cancelled`, `Failed(TrapCode)`;
  `SendResult` has `Sent`, `Closed`; `ReceiveResult(T)` has `Item(T)`, `End`.
  They are matched like declared datatypes (core §3); the value spelling is
  `["data","Outcome","Ok",v]` and so on. Each is serializable when its T is. A
  program cannot construct them in C1: `construct` would need the type argument,
  which the expression does not carry (*provisional*; only the runtime makes
  them).
- `Task(T)` and `Channel(T)` are handles: not serializable and not
  equality-compatible.
- Operands are evaluated strictly left to right (TC0-EVAL): `send` evaluates the
  channel, then the value. The type T and the capacity of `channel` are metadata,
  not operands.
- **Runtime effects in effect sets.** `Task` and `Channel` are the reserved
  runtime effects of core §3, and appear in declared effect sets like any other,
  in the same canonical order. They cannot be declared by an artifact or handled
  by a user handler (EFFECTS.md §1). An entry function may declare `Emit`, `Task`
  and `Channel` and nothing else: every user effect is handled inside the
  program.
- **Exclusion rule, noted and not built.** When transactions or exclusive
  borrows exist, the body of `atomic` will have an effect row that excludes
  `Task`, `Channel` and `Time` (amendment §14, EFFECTS.md §8). C1 has neither,
  so there is nothing to check yet.

## 3 Lifetimes in C1 (*provisional*)

TC0 checks lifetimes with region support sets. C1 defers regions and uses one
conservative rule instead:

> A value that leaves a scope or a task is serializable: the result of a `scope`,
> the result type of a spawned function, a channel's element type, an `emit`
> payload, an operation's argument and result types (already so in EFFECTS.md §1).

Handles and closures are not serializable, so neither can outlive the scope it
was made in. Every handle a task can reach therefore belongs to a scope that is
still open, and the innermost open scope, where `spawn` puts a child, is nested
inside all of them. This is what TC0's "captures must outlive the owning scope"
asks, without computing support. It rejects programs TC0 would accept (a scope
returning a closure that captures nothing), never the reverse.

## 4 Machine state

```text
State   = { tasks, scopes, channels, awaits, next_task, next_scope, next_channel }
Task    = { id, status, control, env, frames, cancel, owning_scope, implicit_scope }
Scope   = { id, owner, phase, reason, children, failed, failures, join_waiting }
Channel = { id, capacity, queue, closed, senders, receivers }
```

- `status` is Runnable, Blocked or Terminal(outcome). A task outcome is
  `Ok(v)`, `Trap(code)` or `Cancelled`. TC0's Unwinding status is a Runnable task
  whose control is Unwind.
- `cancel` is None, Requested or Delivered (§6).
- `control` and `frames` are those of the handler machine of EFFECTS.md, per
  task, plus the controls Start, Wait, Pending(v) and Join, and one new frame,
  the **scope frame**. Every task's frame list ends with the scope frame of its
  **implicit scope** (core §6: "each child begins with its own implicit task
  scope"); an explicit `scope` pushes another. Depth (§10) counts it.
- A scope has `phase` Open or Joining (an exited scope is gone from the frames
  and stays in the table only as history), a `reason` set when it closes —
  Normal(v), Trap(code), Cancelled or Abandon — the IDs of its children in
  spawn order, the failure latch `failed` with the trap codes of failed children
  in task-ID order (`failures`), and whether its owner is blocked on its join.
- A channel holds its queue (oldest first), whether it is closed, and its
  waiting senders (each with its value) and receivers, in registration order.
  Invariant after every step: if any sender waits, the queue is full; if any
  receiver waits, the queue is empty.
- `awaits` holds pending awaits, each (waiter, target), in registration order.
- IDs are canonical unsigned decimal strings in three separate spaces, tasks,
  scopes and channels, each allocated by one counter for the whole machine.
  The root task and its implicit scope are `0`. Registration IDs of TC0 are not
  kept: registration order is what decides service, and it is held as list
  order.

**Initial state.** One task, the root, `0`, Runnable, with the control and
environment of the entry function as in TC1 and the single frame of its implicit
scope `0`. `next_task = 1`, `next_scope = 1`, `next_channel = 0`.

## 5 Operations

Each operation below is the *Ready* step of its expression (core §4 staging),
except `scope` which acts on Dispatch. Each is a **scheduling point** (§8). A
task with a pending cancellation does not perform it: the step delivers the
cancellation instead (§6).

**`scope(b)`** (Dispatch). Allocate scope ID s, owned by this task, Open; push its
scope frame; enter b (b's return destination is the scope frame, so b is in tail
position). Event `ScopeEnter`.

**`spawn(f)`**. The owning scope is the innermost scope frame in the task's
*active* frames (not those of a suspended segment, EFFECTS.md §4). If that scope's
failure latch is set, trap `ChildFailed` (core §8) and allocate nothing.
Otherwise allocate task ID c and scope ID k (c's implicit scope), add c to the
owning scope's children, and create c Runnable with control Start(f) and frames
(copied handlers, then c's implicit scope frame). Event `Spawn`. Value: the
handle of c. The child does not run in this step.

- **Handlers are copied into the child** (*provisional*, core §5 "Spawn copies
  active handler definitions", amendment §4 "retained from TC0"): the handler
  frames among the spawning task's active frames, in the same order, each with
  its clauses and the bindings of its handle node. Nothing else is copied: not
  the continuation, not scope frames, not suspended segments. The copies are the
  child's own; the parent leaving its handler does not affect them. A clause of a
  copied handler runs in the child, and a `spawn` or `scope` in it attaches to
  the child's frames, so to the child's implicit scope unless the clause entered
  a scope itself (TC0-HANDLER-OWNERSHIP). Since `spawn`'s effects include f's
  (§2), every user effect f performs has a handler at the spawn site, and so a
  copy in the child.

**Start(f)** (the child's first step, machine site `TaskStart`). Apply f to unit
with the child's frames as the continuation (f's body in tail position). It is a
scheduling point, so a task cancelled before it first runs never runs user code.

**`await(t)`**. If t is Terminal, the value is its outcome as `Outcome`:
`Ok(v)`, `Cancelled`, `Failed(code)`; event `Await` then `Awaited`. Otherwise
register (this task, t) at the end of `awaits`, block; events `Await`,
`AwaitWait`. Awaiting is repeatable and consumes nothing (core §8). A task that
awaits itself, or an await cycle, blocks (it may deadlock, §7).

**`cancel(t)`**. A cancellation request (§6) for t. Value unit. Event
`CancelRequest` with `new_request`.

**`yield`**. Value unit. Event `Yield`. It does nothing but be a scheduling
point.

**`channel(T, c)`**. Allocate channel ID h with capacity c, empty, open. Event
`Channel`. Value: the handle.

**`send(ch, v)`**. Event `Send`. If ch is closed: value `Closed`, event
`SendClosed`. If the queue is not full: append v, stabilize ch (below), value
`Sent`; events `Sent`, then the stabilization's. Otherwise register this task
with v at the end of ch's senders and block; event `SendWait`.

**`receive(ch)`**. Event `Receive`. If the queue is not empty: remove the
oldest value v, stabilize ch, value `Item(v)`; events `Received`, then the
stabilization's. If it is empty and ch is closed: value `End`, event `End`.
Otherwise register at the end of ch's receivers and block; event `ReceiveWait`.

**`close(ch)`**. Value unit. Event `Close` with `first`. On the first close only:
mark ch closed; commit `Closed` to every waiting sender in registration order
(their values are not enqueued; event `SendClosed` for each); then serve
waiting receivers from the queue in registration order; then commit `End` to
every receiver still waiting (event `End` for each). By the invariant of §4 at
most one of these groups is nonempty. Values already queued stay receivable.

**Stabilization of a channel** (TC0-CHANNEL). Repeat until neither applies:
while a receiver waits and the queue is not empty, remove the oldest value and
commit `Item(v)` to the earliest receiver (event `Received`); then, while ch is
open, a sender waits and the queue is not full, append the earliest sender's
value and commit `Sent` to it (event `Sent`). Committing to a waiter removes its
registration, sets its control to Pending(value) and makes it Runnable. The
woken task does not run in this step.

**Wake** (a step of a task that was blocked and is Runnable again, site: the
node of its operation, rule `Wake`). From Pending(v): the value v. From Wait
(its registration was removed by a cancellation request, §6): deliver the
cancellation. It is a scheduling point, so a pending cancellation is delivered
here even when the operation had committed: the committed operation is not
undone (a received message stays consumed, core §9).

## 6 Cancellation

**Requests.** A request for task t, from `cancel(t)` or from a scope (§7):

- If t is Terminal, or its `cancel` is not None, nothing changes
  (`new_request: false`).
- Otherwise t's `cancel` becomes Requested (`new_request: true`). If t is
  Blocked on a channel or an await, its registration is removed (event
  `SendRemoved`, `ReceiveRemoved` or `AwaitRemoved`; a channel then
  stabilizes, which with the invariant of §4 changes nothing) and t becomes
  Runnable with control Wait. If t is Blocked on a join, it becomes Runnable
  with control Join.

Requests are idempotent: repeated requests never repeat delivery or cleanup.
Each request produces its `CancelRequest` event (task: the requester; the
operation's for `cancel`, the scope owner's for a scope abort or a delivery at a
Join, the failed child's for a scope failure), followed directly by the removal
event when it removes a registration.

**Delivery** (*provisional*: this replaces TC0-CANCEL's "on the target's next
Run"). A Requested cancellation is delivered only at a scheduling-point step
taken in normal control: TaskStart, the Dispatch of `scope`, the Ready step of
every operation of §5, Wake, and a Join of a scope whose reason is Normal. The
step does nothing else: `cancel` becomes Delivered, event `CancelEffective`, and
the control becomes Unwind(Cancelled) — except at a Join, where the scope's
reason becomes Cancelled, its nonterminal children are requested cancelled in
task-ID order, and the control stays Join (core §8: "cancellation delivered
while joining a normal body changes its outcome to Cancelled"). It is never
delivered at a pure step, at `emit`, at a perform or resume, or while the task
is unwinding or abandoning. A task unwinding from a trap keeps its trap: a
request then stays Requested and is never delivered.

This is what makes the production scheduler a refinement (§9): if cancellation
were delivered at any step, a pure step would read another task's write.

**Unwinding** runs no user code. It discards one frame per step as in
EFFECTS.md §6, except at an open scope frame, where it closes the scope (§7).

## 7 Scopes, joins and failure

At a scope frame — the scope of an explicit `scope` or a task's implicit scope:

| Step | Taken when | What it does | Scheduling point |
| --- | --- | --- | --- |
| `ScopeClose` | Value v reaches an Open scope frame | phase Joining, reason Normal(v); control Join | no |
| `ScopeAbort` | Unwind(r) or Abandon reaches an Open scope frame | phase Joining, reason Trap(r), Cancelled or Abandon; request cancellation of every nonterminal child, in task-ID order; control Join | yes |
| `Join` | control Join | delivery if due (§6); else if every child is Terminal: pop the frame, event `ScopeExit`, and continue with the scope's outcome (below); else register the join and block | yes |

**Scope outcome** (core §8, primary-outcome precedence):

| Reason | Failure latch | Exit continues with | `ScopeExit` outcome |
| --- | --- | --- | --- |
| Normal(v) | clear | Value v | `Ok(v)` |
| Normal(v) | set | Unwind(ChildFailed) | `Trap(ChildFailed)` |
| Trap(c) | either | Unwind(c) | `Trap(c)` |
| Cancelled | either | Unwind(Cancelled) | `Cancelled` |
| Abandon | either | Abandon | `Abandoned` |

So a body trap takes precedence over child failures, and a body cancellation
over child failures. A child cancelled explicitly does not fail a normal scope.
Trap codes of every failed child are kept in `failures` in task-ID order,
whatever the outcome. A discontinued segment that holds a scope closes it as
Abandon: its children are cancelled and joined before the segment is gone, and
the clause continues (EFFECTS.md §7; *provisional*).

**Termination** (machine site `Terminate`, a scheduling point). When the
implicit scope has exited and the control is Value v, Unwind(Cancelled) or
Unwind(c) with no frames left, the task becomes Terminal with outcome `Ok(v)`,
`Cancelled` or `Trap(c)`. In the same step, in this order:

1. event `Termination`;
2. if the outcome is a trap, latch it into the owning scope (set `failed`, add
   the code; event `ScopeFailure`) and request cancellation of every other
   nonterminal child of that scope in task-ID order (TC0-SCOPE). The parent body
   is neither cancelled nor trapped; it continues;
3. commit the outcome to every pending await of this task, in registration
   order (event `Awaited` for each, task the waiter);
4. if the owning scope's owner is blocked on its join and every child of it is
   now Terminal, make the owner Runnable (control Join).

The latch happens in the child's terminal step, after the child's own scopes
have joined, never when the child begins to unwind (core §8,
`TC0-C-FAILURE-AFTER-DESCENDANT-JOIN`). The root's outcome is its Termination
outcome; root has no handle and cannot be cancelled.

## 8 Scheduling points

A step is a **scheduling point** exactly when it reads or writes state other than
its own task's control, environment and frames: TaskStart, the Dispatch of
`scope`, the Ready step of every operation of §5 (including `spawn`, `channel`,
`yield` and `cancel`), Wake, `ScopeAbort`, `Join` and `Terminate`. Every other
step is **pure**: the steps of EFFECTS.md, `emit`, and `ScopeClose`.

A pure step reads and writes only its own task's local state. It does not read
another task's cancellation request, a channel, a scope's latch or an ID
counter. That is the whole basis of §9.

## 9 The two schedulers and the obligation

A **schedule** is the list of choices of a run: at each epoch, the ID of the task
that takes the next step. It is an explicit input of both machines, so a run is
deterministic given (program, schedule). A choice that the scheduler in force
does not enable is a schedule error (ReplayDiverged), never a fallback.

**Reference scheduler** (`TC1-REF-TASK/draft-1`, TC0-SCHEDULE). Enabled
decisions at every epoch: Run(t) for every Runnable task, in ID order. It may
switch at every step. The canonical policy picks the lowest ID; exploration may
pick any. No fairness.

**Production scheduler** (`TC1-PROD-TASK/draft-1`). It may switch only after a
scheduling point. With c the task that took the last step: if that step was a
scheduling point, or c is no longer Runnable, or no step has been taken, every
Runnable task is enabled; otherwise only Run(c) is. A production schedule is a
schedule every choice of which this enables. **FIFO** is the production policy:
a queue of Runnable tasks, initially [root]; tasks that become Runnable during a
step join the back in the order they did so (spawned, woken, unblocked by a
request); after a scheduling point, if c is still Runnable it joins the back;
then the front is run. FIFO gives weak fairness: a task that stays Runnable is
eventually run.

**Observation** of a run (amendment §14: a partial order):

- the execution footer: `Completed` with the root's outcome, `Deadlock` with
  its wait graph (§10), or `BudgetExhausted`;
- for every task, the sequence of events whose `task` is that task, in order;
  a `Spawn` event also opens the sequence of its child;
- for every channel, the sequence of events that name it, in order.

Two runs have the same observation exactly when these are equal. This is the
partial order generated by each task's order and each channel's order: an event
belongs to its task and to the channel it names, and a run's partial order is
determined by its projections onto those (a standard property of traces over a
distributed alphabet). Spawn, await and cancel edges are determined by event
content (a `Spawn` names its child, an `Awaited` its target, whose `Termination`
it follows; the first request, `new_request: true`, precedes `CancelEffective`),
so they need no further sequence. Not observed: the relative order of events of
different tasks that no task or channel orders.

**The obligation** (amendment §14):

> For every program and every reference schedule there is a production schedule
> with the same observation, and every production schedule is a reference
> schedule.

The second half holds by construction: production enables a subset of what
reference enables at every epoch. The first half is the commuting argument: a
pure step of one task commutes with every step of every other task (§8), so any
reference schedule can be rearranged, moving each pure step later to just before
its task's next scheduling point, into a production schedule with the same
observation. It is checked on the exhaustive-small scope of §12 by comparing, for
each program, the set of observations of all reference schedules with the set of
all production schedules.

## 10 Reference steps and records

Steps are those of EFFECTS.md §6 for each task, plus:

| Step | Site | After | Scheduling point |
| --- | --- | --- | --- |
| TaskStart | machine `TaskStart` | Eval (or Unwind on delivery) | yes |
| Dispatch `scope` | the scope node, `Dispatch` | Eval (or Unwind) | yes |
| Dispatch `spawn`, `await`, `cancel`, `send`, `receive`, `close` | that node, `Dispatch` | Eval (its first operand) | no |
| Dispatch `yield`, `channel` | that node, `Dispatch` | Ready | no |
| Ready of an operation of §5 | that node, `Ready` | Value, Wait (blocked) or Unwind | yes |
| Wake | the operation's node, `Wake` | Value or Unwind | yes |
| `ScopeClose`, `ScopeAbort`, `Join` | the scope node, or machine `TaskScope` for an implicit scope | Join; after Join: Value, Unwind, Abandon, or Join (blocked or delivered) | §7 |
| Terminate | machine `Terminate` | Terminal | yes |

A **step record** is `{epoch, task, site, after, depth, events, point,
runnable}`: the step's task, its site, the task's control kind after it, the
number of the task's frames after it (counting scope frames, the implicit one
included, and counting a suspended segment as EFFECTS.md §6 does), its events in
order, whether it was a scheduling point, and the IDs of all Runnable tasks
after it, in ID order. Both machines publish these; the harness compares them.

**Events.** Every event has `kind` and `task`. Fields beyond those:

| Kind | Fields | Emitted by |
| --- | --- | --- |
| `Emit` | label, value | `emit` (as TC0-A, without Invoke/Commit) |
| `ScopeEnter` / `ScopeExit` | scope; ScopeExit also outcome | §7 |
| `Spawn` | child, scope (the owning scope), child_scope | §5 |
| `Await`, `AwaitWait`, `AwaitRemoved` | target | §5, §6 |
| `Awaited` | target, outcome (an Outcome value) | §5, §7 |
| `CancelRequest` | target, new_request | §5, §6, §7; task is the requester |
| `CancelEffective` | — | §6 |
| `Yield` | — | §5 |
| `Channel` | channel, capacity | §5 |
| `Send` | channel, value | §5 |
| `Sent`, `SendClosed`, `SendWait`, `SendRemoved` | channel | §5, §6; task is the sender |
| `Receive`, `End`, `ReceiveWait`, `ReceiveRemoved` | channel | §5, §6; task is the receiver |
| `Received` | channel, value | §5; task is the receiver |
| `Close` | channel, first | §5 |
| `ScopeFailure` | scope, code | §7; task is the failed child |
| `Termination` | outcome (`["Ok",v]`, `["Trap",code]`, `["Cancelled"]`) | §7 |

Events of a step appear in the order §5–§7 give. A commit to a waiting task is
its event (its `task` is the waiter), though another task's step produces it.

**Execution footer.** `Completed(outcome)` when the root is Terminal.
`Deadlock` when the root is not Terminal and no task is Runnable; the wait graph
lists every nonterminal task in ID order with what it waits for:
`{receive: channel}`, `{send: channel}`, `{await: task}` or `{join: scope}`. A
deadlock is an outcome of a run, admissible, not a failure of the machine.
`BudgetExhausted` when the step bound is reached first; it is never a pass.

## 11 What EFFECTS.md §8 asked for

- *Region support of a resumption.* There are no regions in C1 (§3). A
  resumption never crosses a task (it is not a value), so a suspended segment
  stays in its task; a segment discarded by `discontinue` closes the scopes it
  holds as Abandon and joins their children first (§7).
- *No transaction or borrow across a suspending perform.* Neither exists in C1;
  the exclusion rule is in §2.
- *Three classes of effect.* `Task` and `Channel` are runtime effects: in effect
  sets, discharged by the runtime, not handleable. Durable effects are deferred.

## 12 What is checked

**Typing.** §2–§3 are stated as rules in [TYPING.md](TYPING.md) §6.2 (T-Scope,
T-Spawn, T-Await, T-Cancel, T-Yield, T-Channel, T-Send, T-Receive, T-Close,
P-Result, and the C1 constructor tables). `sh typing/run.sh` finds both
validators accept the 18 hand fixtures and all 3,600 programs of grammar G, with
a derivation the fixed checker accepts for each, and agree on every program
`tests/tc1/task-artifact.test.mjs` validates, on 3,141 single-point mutants and
on 32 boundary probes whose verdicts were written from this text first. The
claim is "derivable under rule set R, soundness not yet proved".


```sh
sh harness/run-tc1-tasks.sh             # hand fixtures, model against the JavaScript implementation
sh harness/run-tc1-task-explore.sh      # exhaustive-small: the obligation of section 9
```

- **Hand fixtures** (`fixtures/tc1/task-hand-cases.mjs`): eighteen programs,
  expectations written from this text before either machine ran, each under 8
  or 9 recorded schedules (151 runs, 54 of them production). Model and
  implementation agree step for step on all; 619 expectations hold; nine
  injected defects are each killed. One expectation was wrong (it assumed task
  IDs independent of the schedule); the machines were right.
- **Exhaustive-small** (grammar G of `tools/tc1/task-enumerate.mjs`, 3,600
  programs): every reference and every production schedule explored; the
  obligation of §9 holds on all 3,600 programs (equal observation sets,
  production included in reference), with no bound hit. Two broken variants
  fail it: no switch after `send` (493 programs) and cancellation delivered at
  any step (373 programs). The implementation agrees with the model on one
  witness schedule per reference observation class (15,808).

The full numbers are in [harness/README.md](../../harness/README.md). Evidence
grade: development, bounded exploration; no gate verdict. The obligation is
checked on G only; it is not proved.

## 13 For the owner to confirm

Provisional choices this draft makes:

1. **`spawn` is a scheduling point, and so is the child's first step**
   (amendment §14, first open point). Spawn allocates an ID from a counter shared
   by all tasks, and IDs are observed, so it must be; the child's first step reads
   its cancellation request, so it must be too. Consequence: a task cancelled
   before it first runs runs no user code.
2. **Cancellation is delivered only at scheduling points** (§6), not at the
   target's next step as in TC0-CANCEL. Needed for the refinement of §9; a
   reference profile delivering at every step does not commute (the
   exhaustive check demonstrates it with a deliberately broken variant).
3. **`emit` is not a scheduling point**, although `Emit` is a runtime effect
   (amendment §4 table). It touches only its own task's sequence, so it commutes;
   making it one would only add production schedules.
4. **ID spaces are global counters**, as in core §6. Two tasks that spawn or
   create channels independently are therefore ordered by the IDs they get. A
   hierarchical ID (parent ID plus a per-parent index) would remove that order,
   and would let `spawn` stop being a scheduling point.
5. **Handlers are copied into a spawned task** (§5), following core §5. The
   alternative, not inheriting, would make spawn's closure handle its own user
   effects; it is simpler to compile but breaks "a handler installed in the
   parent answers a perform in the child".
6. **The lifetime rule of §3** replaces region support sets until regions exist.
7. **Observations** (§9): task sequences and channel sequences; scope failure
   order among children is not a sequence of its own, and await and cancel
   edges are carried by event content. Registration IDs are not observed.
8. **A discontinued segment holding a scope** closes it as Abandon (§7): its
   children are cancelled and joined, child failures recorded but not raised.
9. **Deadlock** is an admissible execution outcome with a wait graph, not a trap
   and not a machine failure.
10. **Join is a scheduling point and `ScopeClose` is not** (§7); the TC0 staging
    of a normal scope exit (close, then join) is kept as two steps.

**Durable effects with tasks: questions for the owner.** Neither this contract nor
[DURABLE.md](DURABLE.md) defines a program that has both: a D1 artifact has no task
forms (DURABLE.md §11, §13 item 13), a C1 artifact no durable effects (§1), and the
frontend rejects a program that declares a durable effect and uses tasks. What the
two contracts do say: a durable operation is a scheduling point (amendment §14), a
host request is an observation and the replies are inputs (DURABLE.md §6), D1 has at
most one outstanding request because the whole machine stops in `HostWait`
(DURABLE.md §4, v2 §6), and cancellation is delivered only at a scheduling point
(§6 here). A combined slice has to answer the following; each comes with the smallest
program (surface syntax, `(effect Store durable (put I64 --> I64))` declared) whose
observations differ between the answers. No combined schema is built until they are
answered.

- **D×C 1. What does `HostWait` stop: the requesting task, or the image?**
  ```
  (let t (spawn (lambda (_ : Unit) (perform Store put 1)))
    (do (emit "root" 0) (match (await t) ((Ok v) -> v) (Cancelled -> 0) ((Failed c) -> 0))))
  ```
  If only the task blocks (it is Blocked, other tasks Runnable), some schedule
  emits `root` after t's `HostRequest` and before its `HostReply`; if the image
  stops (D1's rule), no schedule does. The first makes the reply a wake-up like a
  channel commit (§5 Wake) and the host's timing a scheduling input.
- **D×C 2. Can a reply reach a task that was cancelled while waiting** (amendment
  §14 open point)**, and what does it observe?**
  ```
  (let t (spawn (lambda (_ : Unit) (do (perform Store put 1) (emit "after" 0) 1)))
    (do yield (cancel t) (match (await t) ((Ok v) -> v) (Cancelled -> 2) ((Failed c) -> 3))))
  ```
  under a schedule that runs t to its request first. (a) As a committed channel
  receive: the request stays outstanding, the reply is taken, and the cancellation
  is delivered at the Wake step that follows: no `after`, outcome 2, the host saw a
  request whose reply nobody used. (b) The request is withdrawn: the host must be
  told (a new guest→host frame, and the amendment's "cancelling a durable obligation
  is itself a durable transition"), outcome 2, and a reply that arrives later is a
  protocol violation. (c) Cancellation waits for the reply: t is not Runnable until
  the host answers, so the cancel is delivered at the reply's Wake, as in (a), but
  root's `await` cannot complete without the host. (a) and (c) differ only when the
  host never replies (D×C 5).
- **D×C 3. Several outstanding requests: which reply comes first?**
  ```
  (let a (spawn (lambda (_ : Unit) (perform Store put 1)))
       b (spawn (lambda (_ : Unit) (perform Store put 2)))
    (do (emit "first" (match (await a) ((Ok v) -> v) (Cancelled -> 0) ((Failed c) -> 0))) 0))
  ```
  With both requests outstanding, the order of the two replies is either the
  host's choice (an input like the schedule, recorded on the tape) or fixed by
  request `seq`. The amendment preserves "the order of operations on one durable
  store"; whether that is request order or reply order decides whether the host may
  answer b before a. DURABLE.md §6's "each reply right after its request" cannot
  hold for both.
- **D×C 4. Whose request is it?** DURABLE.md §7 fixes `"task":"0"` in `HostRequest`
  and `HostReply`; with tasks the event must name the requesting task, and the
  observation (§9 here) must say whether a host request belongs to its task's
  sequence, to a per-store sequence, or both. Same program as D×C 3.
- **D×C 5. Deadlock against "awaiting the host".**
  ```
  (let t (spawn (lambda (_ : Unit) (perform Store put 1)))
    (match (await t) ((Ok v) -> v) (Cancelled -> 0) ((Failed c) -> 0)))
  ```
  Once t has made its request, no task is Runnable. §10 calls that `Deadlock`;
  DURABLE.md §7 calls a stopped machine with a pending request `AwaitingHost`. A
  combined footer needs a rule (proposed: `AwaitingHost` whenever a request is
  outstanding, `Deadlock` only when none is).
- **D×C 6. Scope failure while a sibling waits on the host.**
  ```
  (scope (let a (spawn (lambda (_ : Unit) (perform Store put 1)))
              b (spawn (lambda (_ : Unit) (/ 1 0)))
           0))
  ```
  b's trap requests a's cancellation (§7) while a is in `HostWait`; the scope's join
  then waits for a. Under D×C 2 (a) or (c) the scope cannot exit before the host
  replies; under (b) it can, with a withdrawn request.
- **D×C 7. A durable handler copied into a child.** Handlers are copied into a
  spawned task (§5), so a `(handle Store ...)` that reinterprets the durable effect
  in the parent also answers the child's perform, which is then not a host request.
  Is that intended for durable reinterpretation handlers, which may carry a storage
  contract? (Same answer as item 5 above, unless the owner wants durable handlers
  excluded.)

The `atomic` exclusion rule needs nothing new: D1's `atomic` body already has an
empty effect set (DURABLE.md §8), which excludes `Task` and `Channel`.

## 14 Not decided here

- Time, resources, durable effects and actors (§1).
- The actor mailbox overflow policy and whether a durable reply can reach a
  cancelled task (amendment §14, second and third open points): there are no
  actors or durable effects in C1. The durable questions are written out, with a
  distinguishing program each, at the end of §13 (D×C 1–7).
- A multi-core image profile.
- Fairness beyond FIFO's weak fairness; any progress property.
