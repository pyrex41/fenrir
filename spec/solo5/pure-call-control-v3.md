# Pure-call guest control protocol, version 3 (tasks)

Identity: `fenrir.solo5.pure-call-control/3`. Machine profile: `fenrir.solo5.pure-call-machine/3`.
Tape: `fenrir.solo5.pure-call-control-tape/3`. Status: development, `qualification: UNKNOWN`.

Version 3 is [version 1](pure-call-control-v1.md) plus **structured tasks and bounded
channels**: slice TC1-C1 of [spec/tc1/CONCURRENCY.md](../tc1/CONCURRENCY.md), schema
`tc1-task-demo/1`. The guest holds the task table, scopes, channels and pending awaits
of CONCURRENCY.md §4; the **scheduler choice is an input**, exactly as the Shen model
takes it. Everything below that is not stated is exactly v1 (transport, frame layout,
limits, fail-closed order, comparison discipline, tape layout, strict replay). v3 is
not v2: it has no host requests (durable effects and tasks are not combined by either
contract; CONCURRENCY.md §13), so the type `A` stays unknown to a v3 guest.

Implementations: guest [backends/solo5/pure-call/control.c](../../backends/solo5/pure-call/control.c)
built with `-DFGC_V3` together with [tasks.c](../../backends/solo5/pure-call/tasks.c)
(the task layer over the unchanged handler machine of `machine.c`); without the flag
nothing of v3 is compiled in and the v1 and v2 images are built exactly as before. Host
[harness/solo5-tasks.shen](../../harness/solo5-tasks.shen), which loads the v1 host for
its frame, session, tape and replay code and redefines what v3 changes. Byte vectors:
[pure-call-control-v3.vectors](pure-call-control-v3.vectors). v1 and v2 and their vectors
are unchanged.

## 1 Frame

Unchanged (`FGC1 ` names the layout). A v1 or v2 peer and a v3 peer refuse each other at
Hello or Init (`Identity`).

## 2 Two schedulers

Init names the scheduler for the session, `reference` or `fifo` (CONCURRENCY.md §9):

- **`reference`**: the host chooses every step. A Run names the task that takes it; a
  choice of a task that is not Runnable is a schedule error (`NotRunnable`), never a
  fallback. This is the reference profile `TC1-REF-TASK/draft-1`: any Runnable task at
  every epoch.
- **`fifo`**: the guest chooses, by the FIFO production policy of §9: a queue of
  Runnable tasks, initially [root]; the task that took the last step keeps running until
  that step was a scheduling point or it stopped being Runnable; tasks that became
  Runnable during a step join the back in the order they did so (spawned, woken,
  unblocked by a request); after a scheduling point the stepping task, if still Runnable,
  joins the back behind them; the front is run. Every record names the task the guest
  chose, so the host can replay the choice on the model and check the run is a
  production schedule (`TC1-PROD-TASK/draft-1`) and is the FIFO schedule.

## 3 Messages: what v3 changes

| Type | Dir | Kind | Payload fields (in order) | Answer to |
| --- | --- | --- | --- | --- |
| `I` | H | Init | `artifact_sha256`, `batch_sha256`, `fuel`, `kind`, `mode`, `program`, `protocol`, `scheduler`, `schema` | — |
| `Y` | G | Ready | `artifact_sha256`, `digest`, `epoch`, `execution`, `fuel`, `kind`, `mode`, `program`, `scheduler`, `schema` | Init |
| `R` | H | Run | reference: `kind`, `steps`, `task`; fifo: `kind`, `steps` | — |
| `S` | G | Steps | `digest`, `epoch`, `execution`, `kind`, `steps`, and `wait_graph` when `execution` is `Deadlock` | Run |

- **Run *n* task *t*** (reference). Up to *n* steps (1–64), each a step of task *t*;
  it stops early after a step that leaves *t* not Runnable, at the end of the run, at the
  fuel bound, or when the next record might not fit. *t* is a canonical decimal (at most 9
  digits). If *t* is not Runnable before the first step: Error `NotRunnable`, exit 3.
- **Run *n*** (fifo). Up to *n* steps, each of the task the guest's FIFO policy chooses.
- A Run whose form does not match the session's scheduler is `BadState`.
- **Step record**: the record of CONCURRENCY.md §10 in one spelling, keys sorted:
  `{"after","depth","epoch","events","point","runnable","site","task"}`; `point` is
  JSON `true`/`false`; `runnable` an array of decimal task IDs in ID order; `site`
  `{"node":N,"rule":R}` or `{"machine":M,"rule":R}` with `M` one of `TaskStart`,
  `TaskScope`, `Terminate`. Each event is an object with keys sorted, its fields those of
  §10's table, IDs and capacities as decimal strings, booleans as JSON booleans, values
  in the artifact's value encoding, task outcomes `["Ok",v]`, `["Trap",code]`,
  `["Cancelled"]` (and `["Abandoned"]` in a `ScopeExit`), `Awaited`'s outcome an
  `Outcome` value. Only the C1 events appear; a step of the handler machine contributes
  its `Emit` event alone (no `Invoke`, `Commit`).
- `execution` values: `Running`, `Completed` (the root is Terminal), `Deadlock` (the root
  is not Terminal and no task is Runnable), `BudgetExhausted` (epoch = fuel otherwise).
  Precedence in that order. A Run when the execution is not `Running` is `NotRunning`.
- `wait_graph`: every nonterminal task in ID order, `{"await":X,"task":T}`,
  `{"receive":C,"task":T}`, `{"send":C,"task":T}` or `{"join":S,"task":T}` (§10).
- **Digest**: FNV-1a 64 over a structural walk of the whole task machine: epoch, the
  three ID counters, every task (status, cancellation, wait, owning scope, outcome, and
  its local machine as v1 walks one), every scope (owner, phase, reason, children,
  latch, failures, join waiting), every channel (capacity, queue, closed, senders with
  values, receivers), the pending awaits, and in `fifo` the scheduler queue, the current
  task and whether it may switch.

## 4 Modes

`mode` is `normal` or an injected guest defect, for the harness to detect; never a
default:

| Mode | Defect |
| --- | --- |
| `fifo-reversed` | the FIFO policy runs the back of its queue instead of the front |
| `cancel-off-point` | a pending cancellation is delivered at a pure step of normal control (not a scheduling point) |
| `lost-wakeup` | a terminating task does not commit its outcome to the tasks awaiting it |
| `capacity-off-by-one` | a channel holds one value more than its capacity |

## 5 Fail-closed rules: what v3 adds

Guest, after v1's checks: an Init that does not match the v3 template, or a Run that
matches neither Run template → `BadPayload`; `scheduler` other than `reference` or
`fifo`, or a `mode` not in §4 → `Identity`; a Run form that does not match the scheduler
→ `BadState`; a reference Run naming a task that is not Runnable (including an
unallocated ID) → `NotRunnable`. The guest's own limits (tasks, scopes, channels, events
per step) → `GuestLimit`. Each sends one Error frame and exits 3 (2 for `GuestLimit`).
Type `A` (v2 Reply) is `UnknownType`.

Host: a Steps response may report `Deadlock` (and must then carry `wait_graph`, and only
then); a record whose `task` differs from the task the host named (reference) is a
divergence; anything else is v1.

## 6 Comparison discipline (host)

One step per Run for hand fixtures, consecutive steps of one task grouped into one Run
for the exhaustive sample. Reference: for each choice of the recorded schedule the host
sends Run with that task, and compares the record with the model's step of that task.
FIFO: the host sends Run 1 and steps the model with the task the record names (a task the
model does not have Runnable is a divergence); at the end the guest's choices must equal
the FIFO schedule the batch declares and must be a production schedule by the model's
own records (CONCURRENCY.md §9). The execution footer (`Completed` with the root's
outcome in the Termination event, or `Deadlock` with `wait_graph`) must equal the
model's.

## 7 Tape and strict replay

As v1, tape schema `fenrir.solo5.pure-call-control-tape/3`, and the header carries
`scheduler` (keys sorted: after `protocol`). The recorded Run frames name every task the
host chose, so **the tape binds the schedule**: strict replay re-sends them byte for
byte. A FIFO tape binds the guest's choices through the recorded records. The structure
check is v1's, with a Run only while `Running` (a `Deadlock` or `Completed` response ends
the run).

## 8 What v3 does not cover

Everything v1 §6 lists; host requests (v2) in a task program; more than 16 tasks, 64
scopes or 16 channels per run, a capacity above 8, more than 96 events in one step
(`GuestLimit`); a multi-core profile; the **free-running guest**, which has no scheduler
input: task programs are refused by the lowering for the free-run image
(`UnsupportedGuestProgram`), so `guest.c` never sees one.
