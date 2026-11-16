# TC1 effect contract

Draft 6 • 16 November 2026 • For owner review

**Status.** Written together with its implementation, at the owner's request,
so the text and the behaviour can be reviewed side by side. Both slices are
implemented in the Shen model, in an independent JavaScript implementation and
in the C machine that runs as a Solo5 guest, and checked by the harness: H1,
tail-resumptive handlers, and H2, explicit one-shot resumption. The TC1 gate
is registered (§9); no receipt from the workflow controller exists for it yet,
and nothing here is proved. It supersedes §5 of
[02_TINY_LANGUAGE_CORE.md](../../02_TINY_LANGUAGE_CORE.md) for TC1 and answers
the open questions of the earlier handler task packet (PR #7); §10 lists them.
Draft 4 added §12, remote perform between images: a contract, a Shen model
checked by bounded exploration, and a first implementation. Draft 5 records
the owner's rulings of 15 November 2026 on questions 1, 2 and 10 of §12.10,
specifies a peer's crash between its durable commit and its reply (§12.3,
§12.7), and records that the TC1 gate has two rows for §12 and is registered
(§9, §12.8, §12.11). Draft 6 records the owner's rulings of 16 November 2026
on questions 3, 4, 5, 6 and 8 of §12.10: the outcome `peer_down` is renamed
`not_delivered` and may be reported while the peer is up (§12.4); a restart
of the supervisor is a step of the contract (§12.7); and a key reused with
another argument is refused as `conflict`, inside `reply` (§12.2, §12.3).

Owner decisions of 14 November 2026 are folded in: a clause may continue after
`resume` returns (§7); performs of user effects are not observations (§5);
operation types stay serializable for now (§1); TC1 has its own gate (§9),
registered on 15 November 2026 by the owner's instruction.

TC1 is TC0-A plus what is below. Everything TC0-A specifies (values, checked
I64, evaluation order, calls, closures, data, traps, `emit`) is unchanged.

## 1 Effects and operations

An artifact declares effects. An effect has a name and one or more operations,
each with an argument type A and a result type B.

```text
effect Ask  { ask : I64 -> I64 }
effect Cell { get : Unit -> I64; put : I64 -> Unit }
```

- Effect names are identifiers, unique, and not one of the reserved runtime
  effect names `Emit`, `Task`, `Channel`, `Time`, `Resource`.
- **Restriction, kept for both slices:** A and B are serializable types. No
  closure crosses an operation boundary. Lifting this needs a rule for what a
  closure passed through an operation may capture (§8).

## 2 Expressions

```text
e ::= ... | perform(Effect, operation, e)
        | handle(Effect, [clause]..., body)        clause ::= operation(x) => e | operation(x, k) => e
        | resume(k, e) | discontinue(k)
```

- `perform` and `resume` are strict in their one argument, like a call.
- `handle` supplies exactly one clause per operation of its effect. The body
  and the clauses are not operands: they are not evaluated eagerly.
- A clause of the second form names its resumption `k` (§7).

## 3 Effect sets and typing

Every function and lambda declares a finite effect set. An effect set is a
list of names in unsigned UTF-8 byte order without duplicates, so each set has
one spelling.

| Expression | Type | Effects |
| --- | --- | --- |
| `perform(E, op, a)` with `op : A -> B` | B, given `a : A` | those of `a`, plus E |
| `handle(E, clauses, body)` with `body : T` | T | (body's effects minus E) plus every clause's effects |
| a clause `op(x) => c` | `c : B` with `x : A` in scope | those of `c` |
| call, apply | as in TC0-A | the callee's declared set |

- A clause is checked in the bindings in scope at its `handle` node plus its
  binder.
- The entry function's effect set may contain only `Emit`: every user effect
  must be handled inside the program. An unhandled effect in a validated
  program is an implementation defect, not a trap.
- The surface language will infer effect rows and allow row polymorphism. The
  core keeps explicit finite sets; the elaboration between them is a separate
  contract, not written yet.

## 4 Semantics of handlers (H1: tail-resumptive)

**Selection is dynamic.** `perform(E, op, v)` selects the innermost *active*
handler for E in the current continuation. A closure captures bindings, not
handlers: a closure made under one handler and applied under another uses the
handler active where it is applied.

**The suspended segment.** When a perform selects a handler, the part of the
continuation from the perform site out to and including that handler is
suspended. The clause then runs:

- in the bindings of the handler's `handle` node, plus its binder bound to v
  (not the bindings of the perform site);
- with only the handlers *outside* the selected one active. The selected
  handler and any handlers between it and the perform site are inactive. So a
  perform of the same effect inside a clause goes to the next handler out.

**Clause return resumes, once.** When the clause returns a value, the suspended
segment is restored and that value is the result of the perform. The handler
is active again in the resumed body. There is no way in H1 for a clause to
resume twice, or not at all, except by trapping.

**Clause trap aborts.** A trap in a clause does not resume. The clause's own
frames are discarded first, then the suspended segment's, then the frames
outside, in that order. No user code runs during the unwinding.

**Handler exit.** When the body of a `handle` returns, the handler is removed
and the body's value is the value of the `handle`, unchanged. A handler is not
active after its body has returned.

**Tail positions.** The body of a `handle` and the body of a clause each have
their own return destination (the handler, and the point of resumption). A call
in the tail position of either needs no return frame of its own. A `handle` is
therefore not a tail position of the function containing it.

## 5 Observations

**A perform of a user effect is not an observation.** Neither is a resume, a
discontinue, or entering or leaving a handler. An effect that is handled inside
the program has no footprint outside it. What a program can be observed to do
is unchanged from TC0-A: its outcome, and its `emit` events in order (later,
its runtime and durable operations).

This is deliberate. It leaves a compiler free to inline a handler, to compile a
perform to a direct call, or to remove a handler whose clauses are pure,
provided outcome and emissions are preserved. A handler that should be visible
emits in its clause.

The reference machines still show every perform, resume and discontinue in
their step records (§6). That is for locating a bug, not something compiled
code must reproduce.

## 6 Reference steps

These are properties of the reference machines. They are not obligations on
compiled code.

| Step | Site | After | Frames |
| --- | --- | --- | --- |
| Dispatch `handle` | the handle node | Eval (the body) | handler frame pushed |
| Dispatch `perform`, `resume` | that node | Eval (its argument) | collect frame pushed |
| Ready `perform`, clause `op(x)` | the perform node | Eval (the clause body) | segment replaced by one clause frame |
| Ready `perform`, clause `op(x,k)` | the perform node | Eval (the clause body) | segment removed into `k`; one clause-exit frame pushed |
| `ClauseReturn` | the perform node | Value | clause frame replaced by the segment |
| `ClauseExitReturn` | the perform node | Value | clause-exit frame popped; the value is the handle's |
| Ready `resume` | the resume node | Value (at the perform site) | resume-return frame pushed unless in tail position, then the segment |
| `ResumeReturn` | the resume node | Value | resume-return frame popped; the value is the resume's |
| Ready `discontinue` | the discontinue node | Abandon | discontinue-return frame pushed, then the segment |
| `AbandonFrame` | the frame's node | Abandon | one frame discarded per step |
| `DiscontinueReturn` | the discontinue node | Value (unit) | discontinue-return frame popped |
| `HandleReturn` | the handle node | Value | handler frame popped |
| `UnwindFrame` at a clause frame | the perform node | Unwind | clause frame replaced by the segment, which unwinds next, one frame per step |

Depth is the number of active frames. A suspended segment held by a clause
frame counts as that one frame; a segment held in a resumption counts as none.

A clause `op(x,k)` that traps before using `k` drops the segment without
steps. With no resources in TC1 this cannot be observed. When resources exist,
the segment's releases must happen at that point.

## 7 Slice H2: explicit one-shot resumption

A clause may name its resumption:

```text
handle(E, [op(x, k) => c]..., body)        resume(k, e)        discontinue(k)
```

- `k` stands for the suspended segment. `resume(k, v)` restores it with v as
  the result of the perform. The handler is active again in the resumed body.
- **The clause may continue after `resume` returns.** The value of
  `resume(k, v)` is the value the handled body finally produces, and the value
  of the clause is the value of the whole `handle`. So `c` has the type of the
  `handle`, `e` has the operation's result type B, and `resume(k, e)` has the
  type of the `handle`.
- `discontinue(k)` abandons the segment, discarding it as an aborted perform
  does, and has type Unit. The clause then continues, and its value is the
  value of the `handle`.
- **One-shot.** On every path through the clause, `k` is used exactly once, by
  one `resume` or one `discontinue`. This is checked at validation:
  - both branches of an `if`, and every arm of a `match`, must use each
    resumption in scope the same number of times;
  - `k` is not a value: it cannot be read as a variable, stored, returned or
    passed;
  - a closure cannot mention `k`;
  - a clause of an inner handler cannot use the `k` of an outer clause, since
    the inner clause may run any number of times.
  A path that traps before using `k` is allowed: the perform is then aborted.
- A tail-resumptive clause `op(x) => c` behaves as `op(x, k) => resume(k, c)`
  with the resume in tail position. A resume in tail position pushes no frame.
- **Multi-shot** resumption (using `k` more than once, as backtracking search
  needs) is not part of TC1. It will be admitted only where everything the
  suspended segment holds is duplicable, and is specified with the ownership
  rules.

## 8 What resumptions will have to respect (not implemented)

Recorded now so that the concurrency slice is designed against it:

- A resumption carries the region support of the segment it suspends and cannot
  outlive those regions.
- A transaction or an exclusive borrow may not be held across a perform whose
  handler can suspend the task.
- Three kinds of effect are distinguished: **ordinary** effects, handled by
  user handlers as above; **runtime** effects (tasks, channels, time,
  resources, emit), discharged by the runtime and not replaceable by a user
  handler; and **durable** effects (transaction, durable job, durable inbox),
  discharged only by a handler that carries a storage contract.

## 9 What is checked today

```sh
sh harness/run-tc1-handlers.sh                     # hand fixtures: model against the JavaScript implementation
sh harness/run-tc1-exhaustive.sh                   # every program of grammar H: the same comparison
sh harness/run-solo5-pure-call.sh tc1              # hand fixtures: model against the Solo5 guest
sh harness/run-solo5-pure-call.sh tc1-exhaustive   # grammar H: model against the Solo5 guest
sh harness/run-tc1-gate.sh                         # the TC1 gate, all of the above and more
```

**Hand fixtures** (`fixtures/tc1/handler-hand-cases.mjs`). Twenty programs,
eleven for H1 and nine for H2, each with expectations written from this text
before any machine ran: outcome, the order of performed operations, emission
order where relevant, and for three programs the complete step staging. The
Shen model and the JavaScript implementation agree step for step on all twenty
(625 steps) and both satisfy all 51 expectations; the Solo5 guest agrees with
the model on the same programs.

**Exhaustive family** (`tools/tc1/handler-enumerate.mjs`, grammar H in its
header). Every program of a bounded grammar of handler programs up to 7 nodes:
12,693 programs, 2,826 of them with explicit resumptions. Counts for sizes 1 to
5 are derived by hand in the test; sizes 6 and 7 come from two independent
counting recurrences. The grammar has two one-operation effects, both clause
forms, nested handlers, forwarding, tail and non-tail resume, discontinue, an
emitting form, and division by zero as its trap.

- Model against JavaScript implementation: 12,693 of 12,693 agree on every
  step and the outcome, over 263,222 steps (11,192 Ok, 1,501 DivZero).
- Model against Solo5 guest: the same programs, none differing.
- No disagreement between the three machines was found.

**Defects.** Six defects injected into the JavaScript implementation are each
detected, on the exhaustive family, on this many programs: forgotten resume
2,885; double resume 2,836; outermost-handler selection 421; clause run in the
perform site's bindings 237; `resume` yielding its argument 16; a resumed
segment without its handler 425. A defective run that crashes or runs out of
steps (149 runs in all) is counted separately and never as a detection.

**Step coverage.** All fifteen handler step kinds of §6 are exercised, by the
hand traces alone and by the exhaustive traces alone.

**Validation.** Unit tests reject, for the stated reason, a resumption used
zero times, twice, or on one path only; read as a value; captured by a
closure; used by an inner clause; and resumed with the wrong type.

**TC0-A subset.** The JavaScript handler machine gives the same runs as the
TC0-A implementation on all 5,774 TC0-A programs of the existing scopes, and
the extended C machine still agrees with the model on those and on the 8,745
exact-arithmetic programs.

**The TC1 gate** (`harness/tc1-gate.shen`, manifest
`spec/tc1/tc1-requirements.json`) has twenty-one required rows, including a
passing TC0-A gate on the same commit and two rows for remote perform (§12.8,
§12.11), and aggregates as the TC0-A gate does. It is **registered**: on 15
November 2026 the owner instructed that the two remote rows be added and the
gate registered, the manifest's status is `owner-accepted`, and the workflow
configuration has the check `tc1-qualification`. That was acceptance by
instruction, not a line-by-line review;
[the registration record](../../campaigns/tc1/TC1_GATE_REGISTRATION.md) says
what was registered, what the gate does not show, and how to revoke it; its
Amendment 1 of 16 November 2026 records the changed scope of the two remote
rows and the manifest's new hash. The
report now says `authority: owner-accepted, registered` and its
`qualification` is its verdict. On a committed tree it gives verdict PASS on
21 of 21 required rows. No run through the workflow controller on a supported
runner has been made, so there is no qualification receipt.

Not done: programs above 7 nodes; in the exhaustive family, effects with
several operations, non-I64 operation types, closures, and resume and
discontinue on different paths of one clause (the hand fixtures cover those);
a randomly generated family; reduction of a failing handler program; strict
replay; and any soundness proof of the typing rules in §3 or of the one-shot
check in §7. The fixtures, the grammar, all three machines and the harness
share one author lineage.

## 10 Answers to the earlier open questions

| Question (PR #7 packet) | Answer |
| --- | --- |
| Q1 Does `perform` collect its argument? | Yes, like a call (§2, §6) |
| Q2 Are handle and clause bodies tail positions? | Each is its own return destination; a `handle` is not a tail position of its function (§4) |
| Q3 Is the segment unwound per frame on a clause trap? | Yes: one step discards the clause frame and exposes the segment, then one frame per step (§6) |
| Q4 Which environment does a clause see? | The bindings at the `handle` node plus its binder (§3, §4) |
| Q5 Can operation types be arrows? | Not in H1: serializable types only (§1) |
| Q6 Which events are observable? | None for user effects; performs appear only in step records (§5) |
| Q7 What are the site nodes? | The perform node for clause return and clause abort; the handle node for handler entry and exit (§6) |
| Q8 Handler stack or segments in the state? | Handlers are frames in the continuation; a suspended segment is held in one clause frame (§6) |
| Q9 Canonical effect-set order? | Unsigned UTF-8 byte order, duplicates rejected (§3) |

## 11 Decisions

Settled by the owner on 14 November 2026:

1. A clause may continue after `resume` returns (§7).
2. Performs of user effects are not observations (§5).
3. Operation types stay serializable for now (§1).
4. TC1 gets its own gate (§9).

Settled by the owner on 15 November 2026, by instruction in conversation and
not by line review:

5. Questions 1, 2 and 10 of §12.10, as stated there.
6. The two checks of remote perform are rows of the TC1 gate, and the gate is
   registered (§9).

Settled by the owner on 16 November 2026, in the same way:

7. Questions 3, 4, 5, 6 and 8 of §12.10, as stated there.

Open:

1. When to lift the serializable restriction, and what a closure passed
   through an operation may capture.
2. The elaboration from inferred effect rows at the surface to the finite
   sets here.
3. Whether a clause that traps before using its resumption should be a
   validation error instead of an implicit abort.

## 12 Remote perform (model, and a first implementation)

**Status.** A contract and an executable Shen model of it
(`models/tc1/remote-system.shen`), explored exhaustively on small systems
(§12.8). A first implementation exists, an Erlang/OTP supervisor and two Solo5
images on the `spt` tender; recorded runs of it have been replayed through the
model (§12.11). That is observed histories accepted, not a proof, and there is
no `hvt` run. Paragraphs marked *Clarification (implementation)* were added
because the implementation forced the question. The owner's decisions of 15 November
2026 are taken as fixed: three outcomes and failure as data; no continuation
crosses an image boundary; a static, declared topology. Later the same day
the owner ruled on three of the choices this section had made beyond them:
refusal of undeclared connections, who chooses the key, and a peer killed
between its commit and its reply. On 16 November 2026 the owner ruled on five
more: duplicates, the outcome now called `not_delivered`, a restart of the
supervisor, a restarted caller, and a key reused with another argument. All
are marked in §12.10; questions 7 and 9 there are still open. Both checks of
this section are rows of the TC1 gate (§9).

### 12.1 Systems

A *system* is a fixed set of *members*, one image each (amendment §14), a
*supervisor* that carries every message between them, and a *manifest*: a set
of directed connections (caller, peer). Members are never created or removed.
A member is *up* or *down*, and has

- a *volatile* state: its program's position, the remote perform it is
  suspended in (at most one: an image is single-threaded), and the requests
  handed to it and not yet acted on;
- a *durable* store, held on the host side (amendment §8), which survives a
  crash.

The supervisor has state of its own: the messages in flight, and a record of
which request ids it has handed over. It can restart and lose both (§12.7).

### 12.2 The operation

A remote operation is an operation of an effect that the image's build binds
to a peer. It is a runtime effect (§8): no user handler discharges it, and it
is not replaceable by one. For `op : A -> B` on the peer, the caller writes

```text
perform(E, op, (key, a))        key : I64, a : A        result : RemoteResult B
RemoteResult B ::= reply(B) | not_delivered | timed_out
```

- A and B are serializable (§1), so `RemoteResult B` is.
- **What the peer says is inside `reply`.** B is the operation's own result,
  and it is where a peer refuses a key reused with another argument (§12.3).
  That refusal is a value of the application, not a fourth outcome of the
  transport (owner ruling, §12.10 question 8). In this slice the values that
  cross are I64, so B is the pair `(status, value)`: `(0, v)` is *ok* with the
  operation's value `v`, and `(1, 0)` is *conflict*. Below, `reply(ok v)` and
  `reply(conflict)` stand for these. Once datatypes cross the boundary the
  pair becomes a sum declared with the effect, `op : A -> Applied B'` with
  `Applied B' ::= ok(B') | conflict`, and nothing else changes.
- The perform always returns, with exactly one of the three. A failure is a
  value. It is never a trap and never a resumption that does not happen.
- **No continuation crosses the boundary.** The suspended segment stays in the
  caller image. The supervisor's part is that of a tail-resumptive clause
  (§4): it produces one value, and the perform continues with it, in the image
  that performed. The peer receives the key and `a`, nothing else.
- A remote perform is a scheduling point (amendment §14). It is an observation
  (§5), together with its outcome.

### 12.3 Request ids

The *request id* is (caller, key). The key is chosen by the caller program.
One execution of a perform is an *attempt*; the supervisor gives each attempt
a tag that is never used again. Performing again with the same key is a new
attempt for the same request id; that is what a retry is.

- **Caller obligation.** A key stands for one operation and one argument. A
  caller that reuses a key with a different argument is refused by the peer
  (next).
- **Peer obligation: idempotent per request id, and a key is bound to its
  argument.** Acting on a request has two parts, in this order. First the
  *commit*, one atomic durable step, which does one of three things. If the
  request id has a reply record made with this argument, nothing changes. If
  it has a reply record made with another argument, nothing changes. Otherwise
  the request is applied and its reply recorded, together, and the record
  keeps a digest of the argument. Then the *reply*: the recorded value, as
  `ok`, in the first and the third case, and `conflict` in the second. The
  record is durable, so this holds across the peer's restarts. The obligation
  covers every way a request can arrive twice: a copy duplicated by the
  supervisor, a retry after `timed_out`, and a caller that restarted and
  performs again.
- **Conflict** (owner ruling of 16 November 2026, §12.10 question 8). A
  `conflict` says: this request id has a record, made with another argument,
  and nothing was applied for this attempt. It is the `Conflict` of
  [verification/service/README.md](../../verification/service/README.md), and
  like it leaves the store unchanged. Two arguments are the same when their
  digests are equal. Here an argument is an I64 and the record keeps the
  argument itself, which is its own digest; a larger argument would need a
  collision-resistant one. A record never changes, so a `conflict` stays true.
  Which of two arguments a key ends up bound to is decided by the order in
  which the peer acts, not the order in which the caller performed: the
  supervisor may hand over a late copy of the first request after the second
  has been applied, and it is then the first that conflicts.
- **Commit before reply.** A peer never sends an `ok` for which it has no
  durable record, and never a `conflict` without the record that justifies
  it. A crash can fall between the two parts (§12.7): the request is then
  applied and recorded, and no reply for it exists. Whether a request id has
  been applied, and with what argument, is what the peer's durable store says,
  and nothing else: not what the supervisor saw, and not its record of events
  (owner ruling, §12.10 question 10).

### 12.4 Outcomes

| Outcome | May be produced | What the caller may conclude |
| --- | --- | --- |
| `reply(v)` | Only by giving the caller a reply message the peer produced by acting on this request id, while the caller is still suspended in the attempt whose tag the message carries | The peer has a durable record for the request id. `ok v`: the peer applied the request, once, with this argument, and `v` is the value in the record; it may have been applied for an earlier attempt. `conflict`: the record was made with another argument, and this attempt applied nothing |
| `not_delivered` | (a) For a request id that does not *count as handed over* (§12.5): no copy of any attempt of it was ever handed to the peer, in any of its incarnations, and it was not issued before the supervisor's latest restart (§12.7). The peer may be up or down. The supervisor first destroys every copy of the request id it still holds. (b) At once, when the connection is not in the manifest (§12.6) | No copy of any attempt of this request id was ever handed to the peer, and none will be until this caller performs it again. So the peer has not acted on it. Nothing about whether the peer is up or down |
| `timed_out` | At any time while the caller waits | Nothing. The peer may have acted, may not have, and may still act later: copies can remain in flight |

- **`not_delivered` is about the hand-over, not about the peer** (owner ruling
  of 16 November 2026, §12.10 question 4). Until draft 5 the outcome was
  called `peer_down` and could be reported only while the peer was down. The
  guarantee was never about the peer's state, and the supervisor may now give
  it also for a request it has dropped, or drops in order to say so, before
  any hand-over, while the peer is up.
- **After a hand-over, only `timed_out`.** Once a copy has been handed to the
  peer, the supervisor cannot know whether the peer acted before it died. From
  then on the only failure outcome for that request id is `timed_out`, for
  this attempt and every later one. The same holds for every request id
  issued before a restart of the supervisor, which no longer knows what it
  handed over (§12.7). `timed_out` is the indeterminate case that
  [verification/service/README.md](../../verification/service/README.md)
  assumption 4 leaves out.
- **At most one outcome per attempt.** A reply that arrives when the caller is
  no longer suspended in that attempt (after `timed_out`, or in a later
  incarnation) is discarded and is not shown to the program.
- A caller that crashes while waiting gets no outcome: the attempt belonged to
  the image that was lost.

### 12.5 The supervisor

A request id *counts as handed over* when the supervisor has handed a copy of
any attempt of it to the peer, or when it was issued before the supervisor's
latest restart. It never stops counting.

May: deliver messages in any order; delay a message without bound; drop any
message; duplicate any message; report `timed_out` at any time; report
`not_delivered` for a request id that does not count as handed over; restart
a member that is down; restart itself (§12.7).

May not:

- carry a request along a connection the manifest does not declare;
- create a reply, or change a request or a reply;
- give a reply to an attempt other than the one whose tag it carries;
- report `not_delivered` for a request id that counts as handed over;
- after `not_delivered`, hand over a copy issued before that report;
- on a member's crash or restart, change another member, that member's
  durable store, or the messages in flight;
- on its own restart, change a member in any way, or put a message in flight.

Duplicates stay allowed (owner ruling of 16 November 2026, §12.10 question
3), so that an implementation which redelivers after a restart is inside the
contract. §12.3 covers them.

### 12.6 The manifest and refusal

The supervisor checks every request against the manifest when it accepts it
from the caller, whatever the image claims about itself. An undeclared
connection carries nothing: no message is put in flight, the supervisor
records a refusal, and the perform returns `not_delivered`. A reply travels only
back along the connection of its request.

This is an authority property: which member can cause which other member to
act. It is not confidentiality (§12.9).

*Clarification (implementation); owner ruling of 15 November 2026 (§12.10
question 1).* The first check is when the system is assembled. Each image carries the connections its program was
built with, and if one of them is not in the manifest the supervisor starts no
member at all. The refusal above stays as the backstop behind it,
because it does not depend on what an image says about itself. A system that
passed the start-time check never takes a `refuse` step unless an image
performs on a connection it did not declare.

### 12.7 Crash and restart

Any member that is up may crash at any time. The crash loses its volatile
state. A restart brings the member up with its durable store as the crash left
it and the volatile state of a fresh image: the program starts from its
beginning, no perform is pending, and the inbox is empty. Messages in flight
stay with the supervisor, which may still deliver or drop them.

**A crash between a peer's commit and its reply** (owner ruling of 15 November
2026, §12.10 question 10). The peer has committed the oldest request in its
inbox and crashes before any reply is emitted. Afterwards the durable store
has the application and its reply record; no reply for it is in flight; the
image, with the rest of its inbox, is lost as in any crash; and nobody outside
the peer has seen the action. The request had been handed over, so `not_delivered`
is not possible for it: the caller can only get `timed_out`. When a copy of
the same request id reaches the peer again, in this incarnation's successor or
any later one, the peer finds the record and sends the recorded value: the
request is applied once, and the retry's `reply(v)` carries the value that was
committed before the crash.

In the model this is one step, `crash-after-commit`, enabled wherever acting
would apply a request and a crash is possible. It is one step and not a
separate commit and reply because nothing of the peer can happen between its
commit and its reply except the crash, and every other member's steps commute
with that gap. It adds no reachable state: the state after it is the state
after acting, losing the reply, and crashing. What it adds is a way to get
there in which no reply ever existed, which is what an implementation does
when the kill lands there. Where acting would only replay, a crash before the
reply changes nothing durable and is the ordinary crash.

**A restarted caller starts from the beginning** (confirmed by the owner on
16 November 2026, §12.10 question 6). It keeps its durable store and nothing
else. So it performs its requests again with the same keys, and the peer
answers from its records. Resuming from a checkpoint is not the actor level's
meaning of a restart: it belongs to the durable workflow level of amendment
§14 and is not modelled here.

**A restart of the supervisor** (owner ruling of 16 November 2026, §12.10
question 5). The supervisor may restart at any time, and then:

- *Lost.* Every message in flight, requests and replies alike, and the
  supervisor's record of which request ids it handed over.
- *Kept.* Every member as it is: up or down, its durable store, and its
  volatile state, which is its program's position, the perform it is suspended
  in, and the requests in its inbox. The images do not notice. Also kept: the
  manifest, the numbering of attempts (a tag is not reused after a restart
  either), and the set of request ids the supervisor has ever accepted. An
  implementation has to hold those where its restart does not lose them.
- *From then on.* Every request id issued before the restart counts as handed
  over (§12.5), in the attempt that is pending and in every later attempt with
  the same key. Only `timed_out` or `reply` is possible for it;
  `not_delivered` is never reported for it. A request id first issued after
  the restart is treated as before.

A pending perform stays pending. If a copy of its request was already in the
peer's inbox, the peer still acts on it and the reply is carried to the
caller. If not, nothing is left to arrive, and the perform ends in
`timed_out`. The supervisor does not redeliver what it lost; it would be
allowed to (§12.5), and this model does not.

The set of accepted request ids has to survive because without it a restarted
supervisor could not tell a key first used after its restart from one used,
and perhaps applied, before it, and could then never report `not_delivered`
again without risking that it is false.

In the model this is the step `supervisor-restart`, bounded by a budget like
crashes and duplicates. A restart in the middle of another step is not
modelled (§12.9).

### 12.8 Events, and what is checked today

The program observes only its outcomes. The supervisor's record has, per
step: issued, refused, handed, acted (applied, replayed or conflict, with the
value), outcome, stale-reply, dropped, duplicated, crashed, restarted,
supervisor-restarted. As in amendment
§14, one member's events are ordered; events of different members are not.

The record is what the supervisor could observe, and it is not the authority
on what a peer did (owner ruling, §12.10 question 10). It learns of an action
from the reply. A peer that crashed after its commit and before its reply is
recorded as crashed-after-commit when the supervisor placed the crash there or
found the commit in the peer's store afterwards; the store is on the host
side. A later `replayed` is justified by the store, whatever the record says.

```sh
sh harness/run-tc1-remote.sh       # explores the model, its mutants, and a negative control
```

`harness/tc1-remote.shen` explores the whole reachable state graph of eight
small systems, breadth first, and checks every state and every step. A system
is bounded by its scripts, their retries, and a budget of crash, duplicate and
supervisor-restart steps; drops, timeouts, `not_delivered`, member restarts
and reordering are not bounded.

| System | Crashes, duplicates, supervisor restarts | States | Transitions | Schedules |
| --- | --- | --- | --- | --- |
| Caller, peer; one request, one retry | 1, 1, 0 | 32,783 | 149,398 | 8,025,085,292,837 |
| The same | 2, 0, 0 | 268,932 | 1,280,992 | 49,484,181,860,038,150 |
| Caller, peer; two requests, one retry on the first | 1, 0, 0 | 252,193 | 1,219,081 | 12,007,579,938,882,645 |
| Caller, two peers; one connection undeclared | 2, 1, 0 | 41,849 | 170,980 | 258,303,024,668 |
| Two callers using the same key, one peer | 1, 1, 0 | 36,839 | 162,012 | 291,132,317,230 |
| Caller is a tc1 handler-machine program with one retry; peer | 1, 1, 0 | 48,531 | 229,264 | 97,146,773,747,921 |
| Caller, peer; one request, one retry; the supervisor may restart | 1, 1, 1 | 87,427 | 419,263 | 30,144,991,211,636 |
| Caller, peer; one key performed with one argument, then with another | 1, 1, 0 | 66,229 | 300,603 | 8,067,873,152,396 |

A schedule is a maximal path; the longest has 34 steps. In all 834,783 states
and 3,931,593 transitions, no property below fails. The first six systems are
those of draft 5, which had 633,517 states and 3,013,418 transitions; they now
have 681,127 and 3,211,727, the difference being `not_delivered` with the peer
up. Of the transitions, 20,120 report `not_delivered` other than as a refusal,
32,783 are supervisor restarts, 22,603 are conflicts, and 2,218 are the crash
between commit and reply (§12.7).

| Property | Statement |
| --- | --- |
| single-outcome | No attempt has two outcomes |
| resolved-at-termination | When no step is enabled, every attempt has exactly one outcome, except those whose caller crashed while waiting, which have none |
| reply-implies-acted | An observed `reply(v)` is `ok` or `conflict`, and the peer's durable store has a record for that request id; if it is `ok v`, the record's value is `v`. Judged against the store, not against a record of who saw the peer act |
| not-delivered-not-handed | Other than as a refusal, `not_delivered` is reported only for a request id of which no copy was ever handed to the peer, which was not issued before the supervisor's latest restart, and which is absent from the peer's record. Judged from the history, not from the supervisor's own record of hand-overs |
| not-delivered-sealed | From `not_delivered` until the caller issues the request id again: no copy in flight, none handed over, no record |
| applied-at-most-once | No request id is applied twice; acting on a recorded request id leaves the durable store unchanged; a crash after a commit leaves the store with exactly that one application and its record, made with the request's argument, more than before |
| key-bound-to-argument | An observed `ok` belongs to a record made with that attempt's argument, and an observed `conflict` to a record made with another. A peer says `conflict` only where such a record exists, and then leaves the store unchanged; it replays only a record made with the same argument |
| declared-edges-only | Everything in a member's inbox or record came along a declared connection |
| crash-isolation | A crash or restart changes no other member, not the member's durable store, and nothing in flight. A crash after a commit changes no other member and nothing in flight: no reply is emitted. A restart of the supervisor changes no member and puts nothing in flight |

Eleven defects, each a switch on the model, are each caught on the property
they are aimed at. The schedule shown is a shortest one.

| Defect | Caught by | Shortest schedule |
| --- | --- | --- |
| `not_delivered` reported after hand-over | not-delivered-not-handed | issue, hand over, not-delivered: the request is in the peer's inbox |
| Supervisor answers for a dead peer | reply-implies-acted | crash peer, issue, forged reply |
| Peer applies a recorded request id again | applied-at-most-once | issue, duplicate, hand over, act, hand over, act |
| Supervisor carries an undeclared connection | declared-edges-only | issue, timeout, issue to the undeclared peer, hand over |
| Caller takes a reply after `timed_out` | single-outcome | issue, hand over, act, timeout, deliver reply |
| A crash resets the callers waiting on it | crash-isolation | issue, crash peer |
| `not_delivered` destroys only its own attempt's copies | not-delivered-sealed | issue, timeout, issue, not-delivered: the first attempt's copy is still in flight |
| The timeout never fires | resolved-at-termination | issue, hand over, crash peer, restart peer |
| Peer replies first and commits afterwards | reply-implies-acted | issue, hand over, act (reply sent, nothing committed), deliver reply |
| A restarted supervisor takes nothing as handed over | not-delivered-not-handed | issue, supervisor restart, not-delivered. With a hand-over and an act before the restart, the same step tells the caller the peer has not acted when it has; §12.11 runs that one |
| Peer replays a record whatever the argument | key-bound-to-argument | issue key 1 with 5, timeout, issue key 1 with 6, hand over the second, act (applied with 6), hand over the first, act: replayed, though its argument is 5 |

The ninth was added with the crash between commit and reply: it is the order
of the two parts of acting, which §12.3 fixes. In that defect the caller
holds a reply for which the store has no record, at once, and for good if the
peer then crashes. The last two came with draft 6.

A defective run that raises an error would be reported as crashed and not as
caught; none does. Fourteen hand-written schedules, with expectations taken from
this text, pass. One is the crash between commit and reply, the timeout, the
restart, and the retry answered from the record with one application. Five
came with draft 6: `not_delivered` with the peer up and nothing handed over;
a supervisor restart after a hand-over, with no `not_delivered` afterwards
whether the peer is up or down, no member changed, and the request in the
peer's inbox still answered; a supervisor restart before any hand-over, with
the old key never `not_delivered` again and a new key still able to be; a key
reused with another argument refused as `conflict` with the store unchanged;
and the same reuse applied when the first perform was `not_delivered`. As a negative control, the same checker run with the
non-idempotent peer in place of the model reports failure and exits with
status 1; the runner requires that.

The model's members are abstract: a caller is a script of requests, a peer
adds one to a counter and replies with it, or with `conflict`. One system uses a real tc1 program
as the caller (`models/tc1/remote-tc1-caller.shen`): the handler machine runs
to a perform of a bound effect that no frame handles, keeps its frames, and is
given the outcome as the value of that perform.

This check is the row `remote-model` of the TC1 gate (§9). Its evidence class
is model-level bounded exploration: no implementation is run.

*Clarification (implementation).* Three things the list of events leaves open,
which the implementation had to settle:

- **Hand-over.** A request counts as handed over from the moment the
  supervisor starts to put it where the peer image can read it. The record is
  made before the write, not after it.
- **An outcome is reported before it is observed.** The supervisor's `outcome`
  event is its report. The program sees the value when its image next runs. A
  caller that crashes in between is in the same position as one that crashed
  just after observing it: its image is lost either way. What an image does
  between two scheduling points (its emissions) becomes visible outside before
  the supervisor's next step for that image, and a crash can cut it anywhere.
- **A finished caller.** A member whose program has ended is still up in the
  sense of §12.1; its image no longer runs. A crash of it only makes a restart
  possible.

### 12.9 Not covered

- **Liveness.** Nothing says a request is ever handed over, a reply ever
  delivered, or a member ever restarted. Every perform returns only because
  `timed_out` is always possible.
- **Confidentiality.** The manifest limits who can make whom act. It does not
  limit what a member can learn.
- **Dynamic topology.** No member is spawned; no connection is added.
- **Continuation or closure transfer.** Only serializable values cross.
- **Order.** Between different peers, and between two requests to one peer:
  the supervisor may reorder.
- **A supervisor that fails in any way but the restart of §12.7.** What that
  restart keeps (the attempt numbering and the set of accepted request ids)
  is assumed never lost; its messages are assumed uncorrupted; and a restart
  in the middle of a step is not modelled.
- **A peer that breaks its obligation.** Idempotence and the refusal of a
  reused key are assumed of peers, not enforced on them; the non-idempotent
  defect and the replaying defect show what then fails.
- **Digests.** A peer that compared real digests could take two different
  arguments for the same one. Here the argument is its own digest.
- **External effects of a peer's action.** Applied once means one durable
  application; an email sent by it needs its own receiver-side contract.
- **Time.** A timeout has no clock here; it may fire at once.
- **Several tasks in one image** performing concurrently, bounded mailboxes
  and overload.
- **Peers written in tc1,** typing of remote effects (§3 still says the entry
  function's set may contain only `Emit`), and the surface syntax for a key.
- Systems larger than those listed; any proof. The contract, the model, the
  defects and the checker share one author lineage, and the checker reads
  history variables that the model's own steps maintain.

### 12.10 Open questions for the owner

Questions 1, 2 and 10 have owner rulings of 15 November 2026, and questions 3,
4, 5, 6 and 8 of 16 November 2026. All were given by instruction in
conversation, not by line review of this text. Questions 7 and 9 are open.

1. **Refusal.** An undeclared connection returns `not_delivered` here, because the
   guarantee is the same and the outcomes stay three. Alternatives: reject the
   program at build time and fault the image if it tries; or a fourth outcome.
   **Owner ruling, 15 November 2026:** rejected when the system is assembled
   from the manifest, with the run-time refusal kept as a backstop (§12.6).
2. **Who chooses the key.** Here the program does, as part of the argument, so
   that a retry and a restarted caller name the same request. The alternative,
   ids assigned by the supervisor, cannot survive the caller's restart.
   **Owner ruling, 15 November 2026:** the program chooses (§12.3).
3. **May the supervisor duplicate?** Allowed here, to be safe. If the OTP
   supervisor never redelivers, the clause can go; retries still need §12.3.
   **Owner ruling, 16 November 2026:** the supervisor may duplicate messages.
   The clause stays (§12.5).
4. **The outcome for a request that was never handed over.** Until draft 5 it
   was `peer_down` and could be reported only while the peer was down. The
   supervisor could also report it for a request it dropped before hand-over
   while the peer is up; that would be sound, but the name would mislead.
   **Owner ruling, 16 November 2026:** the outcome is renamed `not_delivered`,
   and it is allowed in that case too. Its guarantee is what the name says: no
   copy of any attempt of the request id was ever handed to the peer, and none
   will be until the caller issues it again. The sealing rule stays (§12.4,
   §12.5).
5. **Supervisor state.** `not_delivered` relies on the supervisor remembering
   every hand-over. If that record can be lost, everything issued before the
   loss has to count as handed over.
   **Owner ruling, 16 November 2026:** so it does. On a restart of the
   supervisor every request issued before the restart counts as handed over:
   only `timed_out` or `reply` is possible for it, and `not_delivered` is
   never reported for it. Done as the step `supervisor-restart` (§12.7). What
   the ruling left to this text, and how it was decided: the messages in
   flight are lost, all of them; a pending perform stays pending and ends in a
   reply or `timed_out`; members are untouched; and the attempt numbering and
   the set of accepted request ids survive, the second because the rule cannot
   be kept without it.
6. **A restarted caller starts from the beginning** (§12.7). Confirm that this
   is the actor level's meaning of "the supervisor restarts computation".
   **Owner ruling, 16 November 2026:** confirmed. A restarted caller starts its
   program from the beginning and keeps its durable store. Checkpointed
   resumption belongs to durable workflows (amendment §14), not to actors.
7. **A peer with no durable store** can be idempotent only within one
   incarnation. Allowed, and with what guarantee for `reply`?
8. **A key reused with a different argument:** refuse, as the service example
   does with `Conflict`, or unspecified?
   **Owner ruling, 16 November 2026:** refused, and reported inside `reply` as
   a value of the application, not as a fourth outcome of the transport,
   matching the service model's `Conflict`. The peer records a digest of the
   argument with the reply record (§12.2, §12.3). What the ruling left to this
   text: the encoding, which is the pair `(status, value)` while only I64
   crosses the boundary, and a sum `ok(v) | conflict` later (§12.2).
9. **Naming and class.** Is a remote operation a runtime effect with a reserved
   name, or a fourth class beside ordinary, runtime and durable (§8)?
10. **The supervisor's record of `acted`** (raised by the implementation). In
    the model a peer's action, its record and the sending of the reply are one
    step. In an implementation the durable commit comes first and the reply
    after it, and the supervisor learns of the action from the reply. A peer
    killed in between has acted and the supervisor's record does not say so.
    The outcomes are unaffected, since after hand-over nothing but `reply` and
    `timed_out` is possible; but the record of §12.8 was then incomplete, and
    a replay of it through the model failed at the later `replayed`.
    **Owner ruling, 15 November 2026:** the model accepts a replay when the
    durable store shows the request was applied. The store is the durable
    truth; the supervisor's log is not. Done as follows: acting is commit and
    then reply (§12.3); the crash between them is a step of the model (§12.7);
    the properties are judged against the store (§12.8); the implementation
    can place the kill there and can find out afterwards that it happened
    (§12.11).

### 12.11 First implementation

```sh
sh harness/run-tc1-remote-run.sh    # the real system under schedules, judged by the model
```

The smallest system, for real: an Erlang/OTP supervisor
([supervisor/](../../supervisor/README.md); Erlang/OTP is assumed for this
step, on a recommendation that is not yet an owner ruling), a caller image and
a peer image, each a Solo5 guest run as an OS process under the `spt` tender.
The caller is a TC1 program on the C machine of `backends/solo5/pure-call`,
unchanged: it performs `Ledger.add` with key 7 and argument 5, once more with
the same key and argument after `timed_out`, then with key 8, then with key 7
again and argument 6, a reuse of the key that the peer refuses if key 7 was
applied with 5. The build binds `Ledger` to the peer, the
outcome becomes the value of the perform, and the frames stay in the image.
The validator admits the program only through an option, because the typing of
remote effects is open (§12.9). The peer is the model's counter with its
durable store in a file; each record keeps the argument it was made with.
Messages go through block-device files used as mailboxes, which need no
privileges, not through the network device; an argument is an I64 and a reply
is a status and an I64 (§12.2). The wire format is version 2: version 1 had no
status, no `conflict` and no argument in a store record. The code of the
outcome now called `not_delivered` is the one `peer_down` had. The
supervisor's README has the wire format, what is trusted, and what is not
shown.

`harness/tc1-remote-run.shen` runs the system and judges each recorded run:
(a) every recorded step is enabled in the model at that point, and the set of
steps the supervisor considered enabled is the model's; (b) the properties of
§12.8 hold in every state and on every step of the replay; (c) the consoles of
the images show what the model says they observe (the caller's outcomes,
requests and TC1 events per incarnation, the peer's actions and the store it
found at each start), the peer's store file at the end is the model's
durable store, record by record with the argument each was made with, and the
run had one relay process more than the supervisor restarts in its log. The
model's caller is the same program, read from the build.

| Schedules | Number | Result |
| --- | --- | --- |
| Written by hand from this section | 19 | Accepted; the recorded steps are the schedule's and the outcomes the expected ones |
| Seeded (1 crash, 1 duplicate, 1 supervisor restart, until no step is enabled) | 40, 791 steps | Accepted. All forty take the supervisor restart, 28 end a perform in `conflict`, 7 report `not_delivered`, 3 take the crash between commit and reply |
| Free-running: one undisturbed, two with the peer killed from outside, one with a request the supervisor is told to lose | 4 | Accepted |

The hand schedules cover: plain reply; request dropped, timeout, retry applied;
reply dropped, timeout, retry replayed; peer killed before hand-over,
`not_delivered`; a request dropped before hand-over with the peer up,
`not_delivered`, the remaining copy destroyed; peer killed after hand-over,
`timed_out`, restart, retry (applied if it had not acted, replayed from the
surviving store if it had); peer killed between its commit and its reply,
`timed_out`, restart, the retry given the committed value, applied once; no
`not_delivered` offered after a hand-over; a duplicate applied once; a reply
after `timed_out` discarded; a caller restarted from its beginning; key 7
applied with one argument and then performed with another, `conflict`, the
store unchanged, and a late copy of the first request still replayed; four
schedules with a supervisor restart (below); an undeclared connection refused
at start, and at run time with the start-time check off. In every schedule
that applies key 7 with argument 5, the program's last perform is the reuse of
key 7 and ends in `reply(conflict)`. Every step kind of the model occurs. Each
scheduled run was made twice with equal recordings.

*The supervisor's restart, for real.* The step machine and the two things the
contract says are lost, the record of hand-overs and the messages in flight,
are one Erlang process, the relay. The step `supervisor-restart` kills that
process (`exit(Pid, kill)`) once the step is in its log, and its OTP supervisor
starts another. The member processes, which hold the tender processes and the
mailbox files, are not touched: both images keep running, a caller stays
suspended in its perform, and a request stays in the peer's inbox. What the
contract says is kept, the relay has left, after every step, with a journal
process: what it knows of each member, the pending attempts, the attempt
numbering, the set of accepted request ids, and for the harness the event log
and the budgets. The record of hand-overs and the messages in flight are never
put there. The new relay takes every accepted request id as handed over. The
journal is memory of another process in the same Erlang VM, not durable
storage: this is a restart of the relay, not of the VM or the host. The four
hand schedules: after a hand-over and an act, `not_delivered` is not offered;
a reply in flight is lost, the caller is timed out and its retry is replayed;
a request in the peer's inbox at the restart is acted on and its reply is the
outcome of the pending perform; and a request issued and never handed over
counts as handed over afterwards, in that attempt and its retry, while key 8,
first issued after the restart, is still reported `not_delivered`. The step is
taken only in the scheduled modes, between steps. A relay that dies in any
other way ends the run in an error.

*`not_delivered` with the peer up, for real.* In the scheduled modes the step
is offered for every pending request that does not count as handed over. In
the free-running mode the supervisor hands a request over at once, so it
reports `not_delivered` only where it did not: one free-running run tells it
to lose the caller's first request, which it drops, and when the caller has
waited its timeout the supervisor reports `not_delivered`, not `timed_out`.

*The crash between commit and reply, for real.* The supervisor grants the
peer image the request with a mark in the inbox header (`hold`, wire format in
the supervisor's README) that makes the image stop, without exiting, after
its commit and before its reply. The supervisor waits until the peer's store
file shows the record and then kills the tender process with `kill -9`, as for
any crash. The step is offered where acting would apply, which the supervisor
reads from the store file, not from its log. In the free-running mode the
supervisor places no kills. A peer that dies inside an act is found dead with
no reply; the supervisor compares the store with what it read before the
grant and records `crash-after-commit` if the record appeared, `crash` if
not. One free-running run kills the peer there from outside the step machine;
the supervisor finds it, restarts the peer, and the retry is answered from the
record. Before draft 5 that run ended in an error.

| Defect, as a switch on the real system | Caught by | Schedule |
| --- | --- | --- |
| Supervisor reports `not_delivered` after hand-over | (a): the step is not the model's | issue, hand over, not-delivered |
| Peer image applies a recorded request id again | (a): the model has only `replayed` there | issue, duplicate, hand over, hand over, act, act |
| Supervisor hands over a reply after `timed_out` | (a): the model has only `discard-reply` there | issue, hand over, act, timeout, deliver reply |
| Supervisor carries an undeclared connection (start-time check off) | (a): the model has only `refuse` there | issue, hand over, act, deliver reply |
| Peer image replies first and commits afterwards | (c): the peer's store file has no application where the model has one | issue, hand over, crash between commit and reply, deliver reply |
| Restarted supervisor takes nothing as handed over | (a): the model has only `timeout` there | issue, hand over, act, supervisor restart, not-delivered: the caller is told the peer has not acted, and it has applied the request |
| Peer image replays a record whatever the argument | (a): the model has only `conflict` there | key 7 with argument 5 and key 8, each issued, handed over, acted on and replied to; then key 7 with argument 6 issued, handed over, act: replayed |

In the fifth, the kill finds a reply and no commit. The supervisor records what
it saw, an act by the reply and then the crash, and the caller is given the
reply. (a) and (b) accept that log: by the log the peer acted. Only the store
says otherwise, which is the point of the ruling on question 10.

Each of these recordings, replayed through the corresponding model mutant, is
accepted and violates the property that mutant is aimed at in §12.8. A run
that ends in an error would count as crashed, not caught; none does. As a
negative control the checker is run with the non-idempotent peer image in
place of the peer: it reports failure and exits with status 1, and the runner
requires that.

This check is the row `remote-run` of the TC1 gate (§9). Its evidence class is
observed histories on `spt` accepted by the model.

Limits. One two-member system and a few dozen histories of it: (a) to (c) say
those histories are ones the model allows, nothing more. The supervisor's log
is its own account. In the scheduled modes a crash is taken between steps,
with the images at rest, or at the one place inside a step described above,
with the image's cooperation; a kill at any other instant inside a step (in
the middle of the store's two writes, or between the reply's two) is not
placed and not exercised. The supervisor's restart is taken between steps
only, never in the free-running mode, and what survives it is in the memory of
another Erlang process: a relay killed inside a step, and the loss of the
whole VM, are not covered. Six defects are caught by (a), the fifth by (c)
alone. Three free-running runs depend on the wall clock. No `hvt` run and no
proof.
