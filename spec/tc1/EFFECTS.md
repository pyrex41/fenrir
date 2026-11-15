# TC1 effect contract

Draft 4 • 15 November 2026 • For owner review

**Status.** Written together with its implementation, at the owner's request,
so the text and the behaviour can be reviewed side by side. Both slices are
implemented in the Shen model, in an independent JavaScript implementation and
in the C machine that runs as a Solo5 guest, and checked by the harness: H1,
tail-resumptive handlers, and H2, explicit one-shot resumption. Nothing in this
document is qualified. It supersedes §5 of
[02_TINY_LANGUAGE_CORE.md](../../02_TINY_LANGUAGE_CORE.md) for TC1 and answers
the open questions of the earlier handler task packet (PR #7); §10 lists them.
Draft 4 adds §12, remote perform between images. That section is a contract
and a Shen model checked by bounded exploration; it has no implementation.

Owner decisions of 14 November 2026 are folded in: a clause may continue after
`resume` returns (§7); performs of user effects are not observations (§5);
operation types stay serializable for now (§1); TC1 has its own gate, proposed
and not yet registered (§9).

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
sh harness/run-tc1-gate.sh                         # the proposed TC1 gate, all of the above and more
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
`spec/tc1/tc1-requirements.json`) has fourteen required rows, including a
passing TC0-A gate on the same commit, and aggregates as the TC0-A gate does.
It is **proposed**: it reports `authority: UNREGISTERED` and
`qualification: UNKNOWN` until the owner registers it. On a committed tree it
gives verdict PASS on 14 of 14 required rows.

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
4. TC1 gets its own gate (§9). It exists and is proposed; registering it is
   an owner decision.

Open:

1. When to lift the serializable restriction, and what a closure passed
   through an operation may capture.
2. The elaboration from inferred effect rows at the surface to the finite
   sets here.
3. Whether a clause that traps before using its resumption should be a
   validation error instead of an implicit abort.

## 12 Remote perform (model only)

**Status.** A contract and an executable Shen model of it
(`models/tc1/remote-system.shen`), explored exhaustively on small systems
(§12.8). No supervisor and no multi-image runtime exist; nothing here has been
run against Erlang/OTP or a Solo5 guest. The owner's decisions of 15 November
2026 are taken as fixed: three outcomes and failure as data; no continuation
crosses an image boundary; a static, declared topology. Where this section had
to choose beyond them, the choice is listed in §12.10.

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

### 12.2 The operation

A remote operation is an operation of an effect that the image's build binds
to a peer. It is a runtime effect (§8): no user handler discharges it, and it
is not replaceable by one. For `op : A -> B` on the peer, the caller writes

```text
perform(E, op, (key, a))        key : I64, a : A        result : RemoteResult B
RemoteResult B ::= reply(B) | peer_down | timed_out
```

- A and B are serializable (§1), so `RemoteResult B` is.
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

- **Caller obligation.** A key stands for one operation and one argument. What
  a peer does with a key reused for a different argument is not specified.
- **Peer obligation: idempotent per request id.** Acting on a request is one
  atomic durable step: either the request id has a reply record, and the peer
  sends that value again and changes nothing; or it applies the request,
  records the reply, and sends it. The record is durable, so this holds across
  the peer's restarts. The obligation covers every way a request can arrive
  twice: a copy duplicated by the supervisor, a retry after `timed_out`, and a
  caller that restarted and performs again.

### 12.4 Outcomes

| Outcome | May be produced | What the caller may conclude |
| --- | --- | --- |
| `reply(v)` | Only by giving the caller a reply message the peer produced by acting on this request id, while the caller is still suspended in the attempt whose tag the message carries | The peer applied the request, once, and `v` is the value in its durable record for the request id. It may have been applied for an earlier attempt |
| `peer_down` | (a) While the peer is down and no copy of any attempt of this request id was ever handed to the peer, in any of its incarnations. The supervisor destroys every copy of the request id it still holds. (b) At once, when the connection is not in the manifest (§12.6) | The peer has not acted on the request id, and will not, until this caller performs it again. Nothing about whether the peer is down afterwards |
| `timed_out` | At any time while the caller waits | Nothing. The peer may have acted, may not have, and may still act later: copies can remain in flight |

- **`peer_down` is not "the peer died".** Once a copy has been handed to the
  peer, the supervisor cannot know whether the peer acted before it died. From
  then on the only failure outcome for that request id is `timed_out`, for
  this attempt and every later one. `timed_out` is the indeterminate case that
  [verification/service/README.md](../../verification/service/README.md)
  assumption 4 leaves out.
- **At most one outcome per attempt.** A reply that arrives when the caller is
  no longer suspended in that attempt (after `timed_out`, or in a later
  incarnation) is discarded and is not shown to the program.
- A caller that crashes while waiting gets no outcome: the attempt belonged to
  the image that was lost.

### 12.5 The supervisor

May: deliver messages in any order; delay a message without bound; drop any
message; duplicate any message; report `timed_out` at any time; restart a
member that is down.

May not:

- carry a request along a connection the manifest does not declare;
- create a reply, or change a request or a reply;
- give a reply to an attempt other than the one whose tag it carries;
- report `peer_down` for a request id of which it has handed over a copy;
- after `peer_down`, hand over a copy issued before that report;
- on a member's crash or restart, change another member, that member's
  durable store, or the messages in flight.

Duplicates are allowed so that an implementation which redelivers after a
restart is inside the contract. §12.3 covers them.

### 12.6 The manifest and refusal

The supervisor checks every request against the manifest when it accepts it
from the caller, whatever the image claims about itself. An undeclared
connection carries nothing: no message is put in flight, the supervisor
records a refusal, and the perform returns `peer_down`. A reply travels only
back along the connection of its request.

This is an authority property: which member can cause which other member to
act. It is not confidentiality (§12.9).

### 12.7 Crash and restart

Any member that is up may crash at any time. The crash loses its volatile
state. A restart brings the member up with its durable store as the crash left
it and the volatile state of a fresh image: the program starts from its
beginning, no perform is pending, and the inbox is empty. Messages in flight
stay with the supervisor, which may still deliver or drop them.

So a restarted caller performs its requests again with the same keys, and the
peer answers from its records. A caller that must not start over keeps its
progress in its durable store; that is the durable workflow level of amendment
§14 and is not modelled here.

### 12.8 Events, and what is checked today

The program observes only its outcomes. The supervisor's record has, per
step: issued, refused, handed, acted (applied or replayed, with the value),
outcome, stale-reply, dropped, duplicated, crashed, restarted. As in amendment
§14, one member's events are ordered; events of different members are not.

```sh
sh harness/run-tc1-remote.sh       # explores the model, its mutants, and a negative control
```

`harness/tc1-remote.shen` explores the whole reachable state graph of six
small systems, breadth first, and checks every state and every step. A system
is bounded by its scripts, their retries, and a budget of crash and duplicate
steps; drops, timeouts, restarts and reordering are not bounded.

| System | Crashes, duplicates | States | Transitions | Schedules |
| --- | --- | --- | --- | --- |
| Caller, peer; one request, one retry | 1, 1 | 32,171 | 147,134 | 8,025,082,041,873 |
| The same | 2, 0 | 261,140 | 1,250,008 | 49,484,158,988,752,448 |
| Caller, peer; two requests, one retry on the first | 1, 0 | 221,847 | 1,086,275 | 11,992,843,538,162,608 |
| Caller, two peers; one connection undeclared | 2, 1 | 37,689 | 157,327 | 258,248,093,937 |
| Two callers using the same key, one peer | 1, 1 | 33,065 | 144,944 | 287,911,634,530 |
| Caller is a tc1 handler-machine program with one retry; peer | 1, 1 | 47,605 | 225,864 | 97,146,742,095,094 |

A schedule is a maximal path; the longest has 34 steps. In all 633,517 states
and 3,011,552 transitions, no property below fails.

| Property | Statement |
| --- | --- |
| single-outcome | No attempt has two outcomes |
| resolved-at-termination | When no step is enabled, every attempt has exactly one outcome, except those whose caller crashed while waiting, which have none |
| reply-implies-acted | An observed `reply(v)` has `v` in the peer's durable record for that request id |
| peer-down-not-handed | Other than as a refusal, `peer_down` is reported only while the peer is down, for a request id never handed to it and absent from its record |
| peer-down-sealed | From `peer_down` until the caller issues the request id again: no copy in flight, none handed over, no record |
| applied-at-most-once | No request id is applied twice; acting on a recorded request id leaves the durable store unchanged |
| declared-edges-only | Everything in a member's inbox or record came along a declared connection |
| crash-isolation | A crash or restart changes no other member, not the member's durable store, and nothing in flight |

Eight defects, each a switch on the model, are each caught on the property
they are aimed at. The schedule shown is a shortest one.

| Defect | Caught by | Shortest schedule |
| --- | --- | --- |
| `peer_down` reported after hand-over | peer-down-not-handed | issue, hand over, crash peer, peer-down |
| Supervisor answers for a dead peer | reply-implies-acted | crash peer, issue, forged reply |
| Peer applies a recorded request id again | applied-at-most-once | issue, duplicate, hand over, act, hand over, act |
| Supervisor carries an undeclared connection | declared-edges-only | issue, timeout, issue to the undeclared peer, hand over |
| Caller takes a reply after `timed_out` | single-outcome | issue, hand over, act, timeout, deliver reply |
| A crash resets the callers waiting on it | crash-isolation | issue, crash peer |
| `peer_down` destroys only its own attempt's copies | peer-down-sealed | issue, timeout, crash peer, issue, peer-down |
| The timeout never fires | resolved-at-termination | issue, hand over, crash peer, restart peer |

A defective run that raises an error would be reported as crashed and not as
caught; none does. Eight hand-written schedules, with expectations taken from
this text, pass. As a negative control, the same checker run with the
non-idempotent peer in place of the model reports failure and exits with
status 1; the runner requires that.

The model's members are abstract: a caller is a script of requests, a peer
adds one to a counter and replies with it. One system uses a real tc1 program
as the caller (`models/tc1/remote-tc1-caller.shen`): the handler machine runs
to a perform of a bound effect that no frame handles, keeps its frames, and is
given the outcome as the value of that perform.

This is in no gate.

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
- **A supervisor that fails.** The supervisor's record of what it handed over
  is assumed never lost, and its messages are assumed uncorrupted.
- **A peer that breaks its obligation.** Idempotence is assumed of peers, not
  enforced on them; the non-idempotent defect shows what then fails.
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

1. **Refusal.** An undeclared connection returns `peer_down` here, because the
   guarantee is the same and the outcomes stay three. Alternatives: reject the
   program at build time and fault the image if it tries; or a fourth outcome.
2. **Who chooses the key.** Here the program does, as part of the argument, so
   that a retry and a restarted caller name the same request. The alternative,
   ids assigned by the supervisor, cannot survive the caller's restart.
3. **May the supervisor duplicate?** Allowed here, to be safe. If the OTP
   supervisor never redelivers, the clause can go; retries still need §12.3.
4. **`peer_down` only while the peer is down.** The supervisor could also
   report it for a request it dropped before hand-over while the peer is up.
   That would be sound, but the name would mislead. Not allowed here.
5. **Supervisor state.** `peer_down` relies on the supervisor remembering every
   hand-over. If that record can be lost, everything issued before the loss
   has to count as handed over.
6. **A restarted caller starts from the beginning** (§12.7). Confirm that this
   is the actor level's meaning of "the supervisor restarts computation".
7. **A peer with no durable store** can be idempotent only within one
   incarnation. Allowed, and with what guarantee for `reply`?
8. **A key reused with a different argument:** refuse, as the service example
   does with `Conflict`, or unspecified?
9. **Naming and class.** Is a remote operation a runtime effect with a reserved
   name, or a fourth class beside ordinary, runtime and durable (§8)?
