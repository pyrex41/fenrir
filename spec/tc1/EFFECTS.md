# TC1 effect contract

Draft 9 • 16 November 2026 • For owner review

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
Draft 7 records the owner's rulings of the same day on the last two open
questions of §12.10, 7 and 9: a remote operation belongs to a fourth effect
class, `remote`, declared in the source and typed (§1, §3, §8, §12.2); and a
peer with no durable store is allowed only for operations declared read-only,
which have no request key and a weaker guarantee for `reply` (§12.3, §12.4,
§12.6). It raised six questions, 11 to 16 of §12.10.
Draft 8 records the owner's rulings of the same day on four of those six: the
result of a remote perform must be examined, by a must-use rule (§3,
question 11); each read-only perform is its own request (§12.3, question 12);
which member serves a remote effect is stated in the system manifest and
checked at assembly (§12.6, question 14); and a `handle` of a remote effect
is rejected (§3, question 16). Questions 13 and 15 stayed open.
Draft 9 records the owner's direction of the same day on those two, to build
the answers now: a peer is a program of this language, its store is reached
through effects, and the type checker vouches for the read-only marker (§8,
§12.3, §12.12, question 13); and a remote effect's signature is owned by a
declarations file that both programs include, with a digest of the signature
in every image, compared at assembly (§12.6, §12.12, question 15). It raises
eight questions, 17 to 24 of §12.10.

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
remote effect Ledger { add : I64 -> (I64, I64); read-only total : Unit -> I64 }
```

- A declaration has a **class**: *ordinary*, as the first two, or *remote*
  (owner ruling of 16 November 2026, §12.10 question 9; the classes are in
  §8). An operation of a remote effect is carried out by another image
  (§12.2), and is declared with that image's own types A and B. It may be
  marked **read-only** (§12.3).

- Effect names are identifiers, unique, and not one of the reserved runtime
  effect names `Emit`, `Task`, `Channel`, `Time`, `Resource`. In a program
  that serves a remote effect (§12.12) the names `StoreRead` and `StoreWrite`
  are taken too: they are the peer's store, which such a program is given and
  does not declare.
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
| `perform(E, op, a)` with `op : A -> B`, E ordinary | B, given `a : A` | those of `a`, plus E |
| `perform(E, op, (k, a))` with `op : A -> B`, E remote, `op` not read-only | `Remote B`, given `k : I64` and `a : A`; allowed only as the scrutinee of a `match` (must-use, below) | those of the argument, plus E |
| `perform(E, op, a)` with `op : A -> B`, E remote, `op` read-only | `Remote B`, given `a : A`; allowed only as the scrutinee of a `match` | those of `a`, plus E |
| `perform(StoreRead, get, k)`, in a program that serves | I64, given `k : I64` | those of `k`, plus `StoreRead` |
| `perform(StoreWrite, put, (k, v))`, in a program that serves | Unit, given `k : I64` and `v : I64` | those of the argument, plus `StoreWrite` |
| `handle(E, clauses, body)` with `body : T` | T | (body's effects minus E) plus every clause's effects |
| a clause `op(x) => c` | `c : B` with `x : A` in scope | those of `c` |
| call, apply | as in TC0-A | the callee's declared set |

- A clause is checked in the bindings in scope at its `handle` node plus its
  binder.
- The entry function's effect set may contain only `Emit` and remote effects:
  every ordinary effect must be handled inside the program. An unhandled
  ordinary effect in a validated program is an implementation defect, not a
  trap. A remote effect that reaches the entry is discharged by the system the
  image is assembled into (§12). A program that serves a remote effect has no
  entry function; the function of each operation it serves may leave only
  `Emit`, `StoreRead` and `StoreWrite` unhandled, and the function of a
  read-only operation not `StoreWrite` (§12.12).
- **No `handle` names a store effect**, and a program that serves performs no
  remote operation (§12.12).
- **No `handle` names a remote effect.** A program cannot intercept, replace
  or simulate a remote operation: `handle(E, ...)` with E remote is rejected.
  The other choice, a handler that intercepts locally, was not taken: with it
  the meaning of a perform would depend on whether a handler happens to be in
  scope, the outcome type would have to be constructible by programs, and the
  declaration could no longer be read as "this image talks to that member".
  *Owner ruling of 16 November 2026 (§12.10 question 16):* the rejection is
  confirmed. Both the frontend and the validator reject such a `handle`.
- **`Remote B`** is the type of an outcome (§12.2): a closed sum with the three
  constructors `reply(B)`, `not_delivered` and `timed_out`, in that order. A
  program cannot construct a value of it. The one way to take it apart is
  `match`, and a match is exhaustive, so there is an arm for each of the
  three outcomes.
- **Must-use: a remote outcome may not be ignored** (owner ruling of 16
  November 2026, §12.10 question 11). The rule has two parts, and it is the
  strictest form the ruling allows:

  1. A perform of a remote operation is accepted in exactly one position: as
     the scrutinee of a `match`, the perform node itself and not an
     expression that contains or yields it.
  2. The type `Remote B` cannot be written. It is the type of a remote
     perform node and of nothing else: no function argument or result, no
     lambda, no tuple component, no datatype field, no operation type and no
     annotation names it.

  So an outcome exists only between a remote perform and the match that
  takes it apart, and that match has the three arms. What is accepted:

  ```text
  match perform(E, op, arg) { reply(x) => e1; not_delivered => e2; timed_out => e3 }
  ```

  with the arms in any order, anywhere an expression may stand: in a function
  or lambda body, in an arm of another match, as an operand or an argument,
  in a `let`. The arms are free: an arm may ignore `x` or return unit. That
  is a decision written in the program for each outcome, which is what the
  ruling asks; nothing can make an arm do something useful.

  What is rejected, each by both the frontend (at the perform, with its
  position) and the validator: an outcome bound by `let`, even when the next
  thing is its match; one dropped in a sequence or bound and never used; one
  stored in a tuple or a constructor; one returned from a function or a
  lambda; one passed as an argument, to a call, an application, a primitive
  (so `eq` on outcomes is gone), `emit` or another perform; a scrutinee that
  is an `if`, a `let` or a `match` yielding an outcome; and any written
  occurrence of the type, the entry function's argument included, so an
  outcome cannot arrive as the program's input either.

  *What this rejects that a looser rule would accept.* A program cannot name
  an outcome and match it a line later, cannot write a helper that takes an
  outcome (`value_or(outcome, fallback)`), and cannot return an outcome from
  a function that wraps the perform for its caller to decide. All three are
  sound: each outcome is still examined once. They are rejected because
  telling them from a dropped outcome needs a count of uses along every path,
  through calls. What programs do instead: the function that performs also
  matches, and what is shared is what follows the match, written as functions
  of the reply's value (the example of §12.11 does this with `settled`,
  `undelivered` and `unknown`).

  *The typed version, later.* `Remote B` becomes a writable type again, and
  a linear one. Affine, at most one use, is not enough: it would let an
  outcome be dropped. A binding of that type must be consumed exactly once on
  every path, by a `match`, by being passed to a parameter of that type, or
  by being returned; it may not be captured by a closure that can run more
  than once, stored in a serializable value, compared, or left unused when
  its scope ends. That is the discipline §7 already applies to a resumption
  `k` (used exactly once on every path, never a value, out of reach inside a
  lambda), extended across function boundaries, which is the part that needs
  a type system rather than a count. Part 1 above is the special case in
  which the binding has no name and its one use is immediate; a program
  accepted today stays accepted.
- **Where `Remote` lives.**
  In this slice `Remote` is built into the artifact (schema
  `tc1-handler-demo/3`, slice TC1-R1), because datatypes have no parameters.
  With parametric datatypes it becomes an ordinary declared sum,
  `RemoteResult B ::= reply(B) | not_delivered | timed_out`, with the same
  constructors and the same exhaustive match, and nothing else changes; the
  values already carry the name `RemoteResult`.
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
- Four classes of effect are distinguished: **ordinary** effects, handled by
  user handlers as above; **runtime** effects (tasks, channels, time,
  resources, emit), discharged by the runtime and not replaceable by a user
  handler; **durable** effects (transaction, durable job, durable inbox),
  discharged only by a handler that carries a storage contract; and
  **remote** effects, declared by the program, discharged by the system of
  images and its supervisor, and not replaceable by a user handler (owner
  ruling of 16 November 2026, §12.10 question 9). Ordinary and remote effects
  are implemented. Of the durable class one thing is, since draft 9: the
  peer's store, the two effects `StoreRead` and `StoreWrite` of §12.12. They
  fit this class as it is defined here, read as follows. The handler that
  discharges them is not written by the program: it is the peer's runtime,
  around each request. The storage contract it carries is the commit of
  §12.3: a request's writes and its reply record become durable in one step
  or not at all, and a trap commits nothing. So the transaction of this class
  exists as one fixed shape, a request, and not as a construct a program
  opens; a durable job, a durable inbox, and a durable handler written by a
  program do not exist. The runtime class is not implemented beyond `emit`.
  A remote effect
  differs from a runtime effect in three ways: its name and operations are the
  program's, not reserved; its performs can fail, and say so in their type;
  and what discharges it is outside the image.

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
closure; used by an inner clause; and resumed with the wrong type. For the
serving class (schema `tc1-handler-demo/4`,
`tests/tc1/serving-artifact.test.mjs`) they reject: a read-only operation
whose function writes the store, directly, through a call or through a
function value, declared in its effect set or not; an entry; a served
operation without its function or with one of another type; the store
declared or handled; an ordinary effect left unhandled by a served function;
and a remote perform. For the
remote class (schema `tc1-handler-demo/3`, `tests/tc1/remote-artifact.test.mjs`)
they reject: a declaration without its class, or with one under an older
schema; a `handle` of a remote effect; a keyed perform without its key and a
read-only one with a key; an outcome used as the operation's value; a match on
an outcome with an arm missing, doubled or foreign; an ordinary effect left at
the entry beside a remote one; and a constructed outcome. For the must-use
rule of §3 they reject a remote perform that is bound by `let` (and matched
next, or dropped), is the result of an `if` used as the scrutinee, is stored
in a tuple, returned by a function or a lambda, passed to a call, compared,
emitted, or the argument of another perform; and the type `Remote B` written
as a function's argument or result, inside a tuple or function type, in a
datatype field, in an operation's types, or as the type of the input. The
frontend rejects the same programs with a message and a position
(SURFACE.md).

**TC0-A subset.** The JavaScript handler machine gives the same runs as the
TC0-A implementation on all 5,774 TC0-A programs of the existing scopes, and
the extended C machine still agrees with the model on those and on the 8,745
exact-arithmetic programs.

**The TC1 gate** (`harness/tc1-gate.shen`, manifest
`spec/tc1/tc1-requirements.json`) has twenty-two required rows, including a
passing TC0-A gate on the same commit and three rows for remote perform (§12.8,
§12.11, §12.12), and aggregates as the TC0-A gate does. It is **registered**: on 15
November 2026 the owner instructed that the two remote rows be added and the
gate registered, the manifest's status is `owner-accepted`, and the workflow
configuration has the check `tc1-qualification`. That was acceptance by
instruction, not a line-by-line review;
[the registration record](../../campaigns/tc1/TC1_GATE_REGISTRATION.md) says
what was registered, what the gate does not show, and how to revoke it; its
Amendment 1 of 16 November 2026 records the changed scope of the two remote
rows and the manifest's new hash, its Amendment 2 of the same day does so
again for draft 7, its Amendment 3 for draft 8, and its Amendment 4 for
draft 9, which added the third remote row. The
report now says `authority: owner-accepted, registered` and its
`qualification` is its verdict. On a committed tree it gives verdict PASS on
22 of 22 required rows. No run through the workflow controller on a supported
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
8. Later that day, questions 7 and 9 of §12.10, as stated there: the remote
   effect class (§3, §8), and read-only operations as the only ones a peer
   without a durable store may serve (§12.3).

9. Later again, questions 13 and 15 of §12.10, by a direction to build their
   answers: peers written in this language with the store reached through
   effects and read-only checked by the type checker; and a shared
   declarations file, included by both programs, with a signature digest
   checked at assembly (§12.12).

Open:

1. When to lift the serializable restriction, and what a closure passed
   through an operation may capture.
2. The elaboration from inferred effect rows at the surface to the finite
   sets here.
3. Whether a clause that traps before using its resumption should be a
   validation error instead of an implicit abort.
4. Questions 17 to 24 of §12.10, raised by draft 9.

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
supervisor, a restarted caller, and a key reused with another argument; and
later that day on the last two, the class of a remote effect and a peer with
no durable store. All ten are marked in §12.10. Draft 7 raised six more; the
owner ruled on four of them the same day (must-use, the identity of a
read-only perform, the binding in the manifest, no handler for a remote
effect), and then on the other two (peers written in this language, shared
declarations with a digest; draft 9, §12.12), which raised eight more. The
three checks of this section are rows of the TC1 gate (§9).

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

A remote operation is an operation of an effect the program declares remote
(§1; owner ruling of 16 November 2026, §12.10 question 9). The class is the
fourth of §8: no user handler discharges a remote effect, and none can stand
in for it (§3). The declaration gives each operation the peer's own types,
`op : A -> B`, and may mark it read-only (§12.3). The one thing the program
does not say is which member carries the effect out: the system manifest
binds each remote effect of a caller to a member (§12.6; owner ruling of 16
November 2026, §12.10 question 14). The caller writes

```text
perform(E, op, (key, a))        key : I64, a : A        result : Remote B
perform(E, op, a)               op read-only: no key    result : Remote B
Remote B ::= reply(B) | not_delivered | timed_out
```

- A and B are serializable (§1). The perform stands only as the scrutinee of
  a `match` (must-use, §3), so the outcome is examined where it arrives.
- **How the outcome reaches the program, today.** The value of the perform is
  a data value of the name `RemoteResult` with the constructor `reply` and one
  field, or `not_delivered` or `timed_out` with none. The image's runtime
  makes it and gives it to the machine as the value of the perform; the
  machines are unchanged and have no notion of a remote effect. The validator
  types the perform as `Remote B` (§3), requires it to be the scrutinee of a
  match, and so requires the three arms. Until
  draft 7 the program declared that datatype itself and nothing tied it to
  the operation.
- **What the peer says is inside `reply`.** B is the operation's own result,
  and it is where a peer refuses a key reused with another argument (§12.3).
  That refusal is a value of the application, not a fourth outcome of the
  transport (owner ruling, §12.10 question 8). In this slice the values that
  cross are I64, so B is the pair `(status, value)`: `(0, v)` is *ok* with the
  operation's value `v`, and `(1, 0)` is *conflict*. Below, `reply(ok v)` and
  `reply(conflict)` stand for these. Once datatypes cross the boundary the
  pair becomes a sum declared with the effect, `op : A -> Applied B'` with
  `Applied B' ::= ok(B') | conflict`, and nothing else changes. A read-only
  operation has no key and so nothing to conflict on: its B is the value
  itself, here an I64.
- The perform always returns, with exactly one of the three. A failure is a
  value. It is never a trap and never a resumption that does not happen.
- **No continuation crosses the boundary.** The suspended segment stays in the
  caller image. The supervisor's part is that of a tail-resumptive clause
  (§4): it produces one value, and the perform continues with it, in the image
  that performed. The peer receives the key and `a`, nothing else.
- A remote perform is a scheduling point (amendment §14). It is an observation
  (§5), together with its outcome.

### 12.3 Request ids

What follows is for an operation that is not read-only: a *keyed* operation.
Read-only operations are at the end of this section.

The *request id* is (caller, key). The key is chosen by the caller program.
One execution of a perform is an *attempt*; the supervisor gives each attempt
a tag that is never used again. Performing again with the same key is a new
attempt for the same request id; that is what a retry is.

- **Caller obligation.** A key stands for one operation and one argument. A
  caller that reuses a key with a different argument is refused by the peer
  (next).
- **Peer obligation: idempotent per request id, and a key is bound to its
  operation and argument.** Acting on a request has two parts, in this order. First the
  *commit*, one atomic durable step, which does one of three things. If the
  request id has a reply record made with this operation and argument, nothing
  changes. If it has a reply record made with another operation or argument,
  nothing changes. Otherwise
  the request is applied and its reply recorded, together, and the record
  keeps the operation and a digest of the argument. Since draft 9 this
  obligation is kept by the peer's runtime, not by the peer's program:
  applying a request is running the program's function for the operation, and
  the commit is that run's writes to the store together with the reply record
  (§12.12). A function that traps commits nothing and nothing is replied. Then the *reply*: the recorded value, as
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

**Read-only operations** (owner ruling of 16 November 2026, §12.10 question
7). An operation may be declared read-only. That is a promise about the peer:
acting on it changes nothing the peer keeps, durable or not, that any later
action of the peer could depend on.

- **No key, no record.** A read-only operation is performed without a request
  key, and the peer keeps no reply record for it. Each perform is its own
  request: where the rules of §12.4 and §12.5 speak of a request id, for a
  read-only perform that is the one attempt. A retry is a new perform and a
  new request. *Owner ruling of 16 November 2026 (§12.10 question 12):*
  confirmed. The alternative, one identity per caller and operation, was not
  taken.
- **Duplicates and retries are evaluated again.** A copy duplicated by the
  supervisor, a late copy, and a retry are each acted on by evaluating the
  operation on the peer's state at that moment. Two of them may give
  different values. Nothing is replayed, because nothing was recorded, and
  nothing needs to be: evaluating again changes nothing.
- **There is no commit**, so no crash between a commit and a reply (§12.7). A
  peer killed while acting on a read-only request has done nothing.
- **A peer with no durable store** is allowed, and serves read-only operations
  only. Every operation that is not read-only requires a store, because its
  idempotence across the peer's restarts is the reply record (above). A system
  in which a peer without a store serves a keyed operation is refused when it
  is assembled (§12.6). What a storeless peer reads is what its image has: its
  constants and whatever it has computed since it started, none of which
  survives a crash.
- **What is weaker** is the guarantee of `reply`, stated in §12.4. In short:
  some incarnation of the peer computed the value from its state at some time
  between the issue of the perform and the reply. It may be out of date when
  the program sees it, and a retry may return another.
- **Who vouches for the marker** (owner ruling of 16 November 2026, §12.10
  question 13). The type checker does, on the peer's program. The function
  that implements a read-only operation may not have `StoreWrite` in its
  effect set (§12.12): not by a perform of its own, not through a function it
  calls, not through a function value it applies. The frontend rejects such a
  program with a position, the validator rejects such an artifact, and no
  image is built from it. What the check does not cover is the peer's
  runtime, which is C: a runtime that writes while it serves a read is a
  defect, kept as a switch and caught on the histories run (§12.8, §12.11).
  The marker in the caller's program and the one in the peer's are the same
  marker because both programs include one declaration and the images'
  digests are compared (§12.6).

### 12.4 Outcomes

| Outcome | May be produced | What the caller may conclude |
| --- | --- | --- |
| `reply(v)`, keyed operation | Only by giving the caller a reply message the peer produced by acting on this request id, while the caller is still suspended in the attempt whose tag the message carries | The peer has a durable record for the request id. `ok v`: the peer applied the request, once, with this argument, and `v` is the value in the record; it may have been applied for an earlier attempt. `conflict`: the record was made with another argument, and this attempt applied nothing |
| `reply(v)`, read-only operation | Only by giving the caller a reply message a peer produced by evaluating the operation for a copy of this attempt's request, while the caller is still suspended in that attempt | Some incarnation of the peer evaluated the operation, at some time after this attempt was issued and before the reply was given to the caller, and `v` is the result on that incarnation's state at that time. No record of it exists. Not that `v` is the state now; not which incarnation; not that another perform, even an earlier one, would have given the same |
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
- **A read-only perform** has the same three outcomes. Its request id is the
  attempt itself (§12.3), so `not_delivered` says that this perform's request
  was never handed over and never will be, and says nothing about any other
  read; `timed_out` again says nothing. Neither matters for the peer's state,
  which a read does not change: the two differ only in what the supervisor
  knows. The guarantee of its `reply` is weaker than the keyed one in exactly
  this: there is no record, so the value is tied to a moment and not to the
  request. For a peer whose answer only grows, as the ledger's total does
  while amounts are not negative, "between
  issue and reply" bounds the value from both sides, and §12.8 checks that
  bound; for any other peer it says only that the value was once the state.

### 12.5 The supervisor

A request id *counts as handed over* when the supervisor has handed a copy of
any attempt of it to the peer, or when it was issued before the supervisor's
latest restart. It never stops counting. A read-only perform is its own
request id (§12.3): the supervisor keeps it in the same records, under a name
made from the attempt's number, and applies the same rules to it.

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

**What an image carries is derived** (owner ruling of 16 November 2026,
§12.10 question 9). The connections of a caller image are not written by
hand. They are the members its program's remote effects are bound to: one
connection for every remote effect the program declares, taken from the
declarations and the manifest's binding of each remote effect to a member
(below). The image also
carries each remote operation it may perform with the member it goes to and
whether it is keyed or read-only. A peer image carries the operations it
serves, each keyed or read-only, whether it has a durable store, and whether
its program mentions `StoreWrite` at all; since draft 9 these come from the
peer's own program, not from a caller's declarations (§12.10 question 15).
Every image also carries a **digest of the signature** of each remote effect
it uses or serves (below).

**One signature, and a digest of it** (owner ruling of 16 November 2026,
§12.10 question 15). The signature of a remote effect is owned by a
declarations file that the caller's program and the peer's program both
include (§12.12). Each build computes, from its own program's artifact, a
digest of the effect's signature and puts it in the image. The digest is
SHA-256, in lowercase hexadecimal, of the canonical encoding
(`tools/tc0/canonical.mjs`) of

```json
{"effect": "Ledger",
 "operations": [{"argument_type": "I64", "name": "add", "read_only": false, "result_type": ["Tuple", "I64", "I64"]},
                {"argument_type": "Unit", "name": "total", "read_only": true, "result_type": "I64"}],
 "schema": "fenrir.remote-signature/1"}
```

with the operations in unsigned UTF-8 byte order of their names (a signature
is a set of operations: the order of declaration is not part of it) and the
types as the artifact writes them. It covers the effect's name and each
operation's name, types and read-only marker. A declared datatype appears in
a type by its name only: its constructors are not in the digest, and none
crosses the wire yet. Two programs that include the same file have the same
digest; two that declare the effect apart have the same digest only if they
declare the same thing.

**The system manifest, and the binding** (owner ruling of 16 November 2026,
§12.10 question 14). One file describes a system: its members, its declared
connections, and which member serves each remote effect of each caller.
Until draft 7 the last of these was a constant of the build script. Now the
build reads it from the manifest and holds none, and the supervisor's check
at assembly uses the same manifest.

```json
{"schema": "fenrir.system-manifest/2",
 "members": [{"name": "caller", "kind": "caller", "program": "examples/remote/ledger-caller.fen"},
             {"name": "peer", "kind": "peer", "program": "examples/remote/ledger-peer.fen", "store": true}],
 "connections": [["caller", "peer"]],
 "bindings": [["caller", "Ledger", "peer"]]}
```

- `members`: each has a name, unique in the system, a kind, and its program,
  a source file. A peer also says whether it has a durable store (schema /2,
  draft 9; schema /1 had no program for a peer). The manifest the supervisor
  is given is this one with each member's image file in place of the program
  (`"image"`); the build writes it.
- `connections`: `[caller, member]`, the authority of this section: the
  caller may send requests to that member. Both names are members.
- `bindings`: `[caller, Effect, member]`: the operations of the remote effect
  `Effect` that the program of `caller` performs are carried out by
  `member`. At most one binding for a caller and an effect.

A binding does not imply a connection, and a connection does not imply a
binding. The binding says who serves; the connection says that the caller is
allowed to reach that member. Both must be there. A manifest that is not of
this shape, a binding for a member that is not a caller, two bindings of one
effect for one caller, a binding for an effect the caller's program does not
use, and a caller image that was built for another member than the manifest
now binds its effect to, are errors of the manifest: nothing is built or
started, and no refusal is reported.

**Assembly refuses seven things**, and starts no member if it finds one. The
first three are about the binding and are told apart in the report:

1. `unbound`: a caller's program uses a remote effect, and the manifest binds
   it to no member;
2. `unknown-member`: the manifest binds the effect to a name that is no
   member of the system;
3. the effect is bound to a member, and the manifest declares no connection
   from the caller to it (the start-time check of the ruling on question 1,
   above);
4. `no-store`: a peer image with no durable store serves an operation which
   is not read-only (§12.3; owner ruling, §12.10 question 7);
5. `no-store`, of `StoreWrite`: a peer image with no durable store whose
   program mentions the store's write effect at all, in any function's or
   function type's effect set (draft 9: the rule of the fourth, checked from
   the peer's program too);
6. `unserved`: a caller uses an operation that the member its effect is bound
   to does not serve, or serves in the other mode: a caller that sends no key
   for an operation the peer applies would defeat the peer's idempotence. A
   member that is not a peer serves nothing;
7. `signature`: the member a caller's effect is bound to serves that effect,
   and its digest of the effect's signature is not the caller's: the two
   images were built from different declarations (owner ruling, §12.10
   question 15). This is told apart from `unserved`: a peer built from a
   declaration with one operation more serves everything the caller performs
   and is refused all the same.

The build makes the same check, on the same manifest, before it compiles
anything, so a system that would be refused is not built.

Only the third has a run-time backstop: a request along a connection the
manifest lacks is refused whatever else is true. The others rest on the
manifest and on what the images declare, which the build derives; an image
that lies about itself is outside the contract (§12.9). In particular the
digest is what a build wrote into an image, not something the supervisor
recomputes from a program.

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

**A crash inside the commit** (draft 9). The commit is one atomic durable
step: a request's writes and its reply record are in the store together or
not at all. A peer killed before that step is complete has committed nothing,
whatever it had already written to its device, and its successor finds the
store as it was before the request; a retry is then the request's first
application. In the model that is the step `crash`: there is no state in
which a part of a commit exists. §12.12 says what the implementation's
commit rests on, and §12.11 places the kill there.

In the model the crash after the commit is one step, `crash-after-commit`, enabled wherever acting
would apply a request and a crash is possible. It is one step and not a
separate commit and reply because nothing of the peer can happen between its
commit and its reply except the crash, and every other member's steps commute
with that gap. It adds no reachable state: the state after it is the state
after acting, losing the reply, and crashing. What it adds is a way to get
there in which no reply ever existed, which is what an implementation does
when the kill lands there. Where acting would only replay, a crash before the
reply changes nothing durable and is the ordinary crash. The same holds where
the request is read-only: nothing is committed, so there is no such place.

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
step: issued, refused, handed, acted (applied, replayed, conflict, read or
trapped, with the value), outcome, stale-reply, dropped, duplicated, crashed, restarted,
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

`harness/tc1-remote.shen` explores the whole reachable state graph of ten
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
| Caller, peer; a keyed request, then a read-only one | 1, 1, 0 | 140,837 | 671,912 | 8,545,748,518,405 |
| Caller, peer with no durable store; one read-only request, one retry | 1, 1, 0 | 54,186 | 246,562 | 8,345,522,833,044 |

A schedule is a maximal path; the longest has 34 steps. In all 1,029,806
states and 4,850,067 transitions, no property below fails. Since draft 9 the
peers of these systems are programs (§12.12): the ledger peer of
`examples/remote/ledger-peer.fen` in the first nine, and in the tenth the
storeless peer of `examples/remote/rates-peer.fen`. A request names its
operation, the store is the program's cells, and what acting does is one run
of the program's function. Every number in the table is what it was with the
abstract counter of draft 8: these scripts cannot tell the ledger from a
counter, the total after k additions of 5 standing where k stood. The first eight
systems are those of draft 6, and their numbers are as they were: 834,783
states and 3,931,593 transitions. (The first six are those of draft 5, which
had 633,517 states and 3,013,418 transitions; they have had 681,127 and
3,211,727 since draft 6, the difference being `not_delivered` with the peer
up.) Of the transitions, 42,331 report `not_delivered` other than as a
refusal, 32,783 are supervisor restarts, 22,603 are conflicts, 2,293 are the
crash between commit and reply (§12.7), and 84,651 are acts on a read-only
request. The ninth system with one retry of its read was too large to explore
whole within the checker's limit of 1,500,000 states; the retry of a read is
explored in the tenth, where the peer's state never changes, and with a
changing state only by hand schedules.

| Property | Statement |
| --- | --- |
| single-outcome | No attempt has two outcomes |
| resolved-at-termination | When no step is enabled, every attempt has exactly one outcome, except those whose caller crashed while waiting, which have none |
| reply-implies-acted | An observed `reply(v)` is `ok` or `conflict`, and the peer's durable store has a record for that request id; if it is `ok v`, the record's value is `v`. Judged against the store, not against a record of who saw the peer act |
| not-delivered-not-handed | Other than as a refusal, `not_delivered` is reported only for a request id of which no copy was ever handed to the peer, which was not issued before the supervisor's latest restart, and which is absent from the peer's record. Judged from the history, not from the supervisor's own record of hand-overs |
| not-delivered-sealed | From `not_delivered` until the caller issues the request id again: no copy in flight, none handed over, no record |
| applied-at-most-once | No request id is applied twice; acting on a recorded request id leaves the durable store unchanged; a crash after a commit leaves the store with exactly that one application and its record, made with the request's argument, more than before |
| key-bound-to-argument | An observed `ok` belongs to a record made with that attempt's operation and argument, and an observed `conflict` to a record made with another. A peer says `conflict` only where such a record exists, and then leaves the store unchanged; it replays only a record made with the same operation and argument |
| declared-edges-only | Everything in a member's inbox or record came along a declared connection |
| crash-isolation | A crash or restart changes no other member, not the member's durable store, and nothing in flight. A crash after a commit changes no other member and nothing in flight: no reply is emitted. A restart of the supervisor changes no member and puts nothing in flight |
| read-only-changes-nothing | Acting on a read-only request leaves the peer's durable store exactly as it was, every cell and every record; and a peer says `read` of a read-only request and of no other (or `trapped`, when its function trapped) |
| read-reply-from-state | An observed `reply(v)` of a read-only perform is a value the peer's state had between the issue of that attempt and the reply: `v` is not less than what the operation would have answered on the peer's store when the attempt was issued, and not more than what it would answer when the reply is given. This uses that the answer never decreases (a total of amounts that are not negative, a constant); it is the reading of §12.4 for these peers, not a general one |
| commit-atomic | The business state and the reply records were committed together, every time. Read for the ledger peer, whose program gives the store a meaning the checker can state without running it: cell 0, the total, is the sum of the arguments of the reply records, and cell 1 is their number, in every state; and a request whose function trapped changes nothing |
| reads-see-own-writes | What an applied request replies was computed with its own writes in view. Read for the ledger peer, whose `add` writes the total and replies with what it reads back: the value replied is the total before plus the argument |

The first nine properties are those of draft 6 and hold in the two
systems that have read-only requests as in the others: a read-only delivery
adds no application and no record, so the guarantees of keyed operations are
judged on the same store as before. The last two came with draft 9. They are
about what the peer's runtime owes the peer's program, and they are stated
for one program, the ledger, in terms of what that program means: a checker
that knew nothing of the program could only compare the model with itself.
The property applied-at-most-once still says, of a crash after a commit, that
the store afterwards is the store before plus the writes of exactly one run
of the operation's function and its record.

Seventeen defects, each a switch on the model, are each caught on the property
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
| The runtime writes while it serves a read-only request: it adds one to cell 0 | read-only-changes-nothing | issue key 1, not-delivered, issue the read, hand over, act: the store's total is 1 and nothing was applied |
| A read-only operation ignores the state: it answers 0 | read-reply-from-state | issue key 1, hand over, act (applied), deliver reply, issue the read, hand over, act, deliver reply: 0, when the total has been 5 since before the read was issued |
| The commit leaves out the reply record | commit-atomic | issue, hand over, act: the total is 5 and no record says why |
| The commit leaves out the program's writes | commit-atomic | issue, hand over, act: a record of 5, and a total of 0 |
| A crash of a peer about to commit leaves the first of the request's writes | commit-atomic | issue, hand over, crash peer: the total is 5, with no record |
| A read does not see its own request's writes | reads-see-own-writes | issue, hand over, act: the reply is `ok 0`, the total before the addition |

The ninth was added with the crash between commit and reply: it is the order
of the two parts of acting, which §12.3 fixes. In that defect the caller
holds a reply for which the store has no record, at once, and for good if the
peer then crashes. The tenth and eleventh came with draft 6, the next two with
draft 7, and the last four with draft 9: the runtime's half of a peer, which
the program cannot be blamed for.

A defective run that raises an error would be reported as crashed and not as
caught; none does. Twenty-three hand-written schedules, with expectations taken from
this text, pass. One is the crash between commit and reply, the timeout, the
restart, and the retry answered from the record with one application. Five
came with draft 6: `not_delivered` with the peer up and nothing handed over;
a supervisor restart after a hand-over, with no `not_delivered` afterwards
whether the peer is up or down, no member changed, and the request in the
peer's inbox still answered; a supervisor restart before any hand-over, with
the old key never `not_delivered` again and a new key still able to be; a key
reused with another argument refused as `conflict` with the store unchanged;
and the same reuse applied when the first perform was `not_delivered`. Five
more came with draft 7: a read-only request and its duplicate, each
evaluated, the reply the bare value, the store and the count of applications
untouched, and no crash between commit and reply offered; a read handed to a
peer that is then killed, timed out, and its retry, a new request, answered
by the restarted peer from the store it found; `not_delivered` for a read
never handed over, after an earlier read that was; a peer with no durable
store serving a read before and after it is killed; and the refusal at
assembly of a storeless peer that is sent a keyed request, and of an
undeclared connection (`remote.assembly-refusals`: the model has no step for
either system). Four came with draft 9: where acting would commit, the crash
steps offered are exactly the crash that leaves the store as it was and the
crash that leaves every write of the request and its record, and after the
first the retry is applied once; a function that traps (the ledger's total
overflowing) commits nothing, sends no reply, and is offered no crash between
commit and reply; a key performed again with another operation and the same
argument is a `conflict`, a function that traps after it has written leaves
none of its writes, and a read-only function reads the store under a handler
frame (the pots peer of `tests/remote/peers/pots.fen`); and a peer with no
durable store serves two read-only operations, the request naming the one
meant. As a negative control, the same checker run with the
non-idempotent peer in place of the model reports failure and exits with
status 1; the runner requires that.

A caller of the model is abstract, a script of requests, except in one system,
which uses a real tc1 program
as the caller (`models/tc1/remote-tc1-caller.shen`): the handler machine runs
to a perform of a bound effect that no frame handles, keeps its frames, and is
given the outcome as the value of that perform. A peer is a program in every
system (`models/tc1/remote-tc1-peer.shen`, §12.12): the check elaborates the
peers' source files with the frontend, has the validator admit the artifacts,
and runs the functions on the model's handler machine. A peer with no durable
store answers read-only requests only.

This check is the row `remote-model` of the TC1 gate (§9). Its evidence class
is model-level bounded exploration: no image and no supervisor is run.

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
- **A peer's runtime that breaks its obligation.** Idempotence, the refusal
  of a reused key and the atomic commit are the peer's runtime's, which is
  hand-written C and is checked on histories, not proved; the defect switches
  show what fails when it breaks one. That a read-only operation's program
  writes nothing is checked on the program (§12.12); that the runtime writes
  nothing while serving one is not.
- **Atomicity below a block.** The commit is atomic if one 512-byte block
  write is atomic and a write that returned survives the death of the image
  (§12.12). A torn block, a lost write, and the loss of the host are not
  modelled, not injected and not defended against.
- **A peer's program that does not finish, and one that traps.** A request
  whose function does not end within the step bound is an error of the model
  and a fault of the image. A trap is specified (nothing committed, no
  reply) and exercised in the model and in the three-way check, not on the
  real system.
- **An image that misdeclares itself.** Four of the five assembly checks
  (§12.6) rest on what the images say, which the build derives; nothing ties
  an image file to the build that made it, or to the manifest it was built
  from, beyond the member names in its line.
- **Soundness of the must-use rule of §3.** It is two syntactic conditions,
  checked by the frontend and the validator on tests. Nothing proves that no
  outcome escapes them, and nothing says an arm does anything useful.
- **Freshness of a read.** A read-only reply may be arbitrarily old when the
  program uses it, and nothing orders the replies of two reads.
- **Digests.** A peer that compared real digests could take two different
  arguments for the same one. Here the argument is its own digest.
- **External effects of a peer's action.** Applied once means one durable
  application; an email sent by it needs its own receiver-side contract.
- **Time.** A timeout has no clock here; it may fire at once.
- **Several tasks in one image** performing concurrently, bounded mailboxes
  and overload.
- **A peer that calls onward.** A program that serves performs no remote
  operation (§12.12). **Who is asking.** An implementation sees the request's
  key and argument, not the caller. Remote operation types beyond what the
  wire carries (§12.11). **The store's growth:** its log is never compacted
  and reply records are kept for ever.
- **Soundness of the typing of §3 for remote effects.** It is checked by the
  validator and the frontend on tests, not proved.
- Systems larger than those listed; any proof. The contract, the model, the
  defects and the checker share one author lineage, and the checker reads
  history variables that the model's own steps maintain.

### 12.10 Open questions for the owner

Questions 1, 2 and 10 have owner rulings of 15 November 2026, and questions 3,
4, 5, 6 and 8, later the same day 7 and 9, and later again 11, 12, 14 and 16,
of 16 November 2026, and last of all 13 and 15. All were given by instruction
in conversation, not by line review of this text. None of the first sixteen
is open. Questions 17 to 24 came with draft 9 and are open.

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
   **Owner ruling, 16 November 2026:** allowed only for operations declared
   read-only; any operation that changes state requires a store. Done as
   follows: an operation of a remote effect may be marked read-only in its
   declaration (§1); it has no request key and no reply record, and
   duplicates and retries are evaluated again (§12.3); its `reply` says that
   some incarnation of the peer computed the value from its state at some
   time between issue and reply, and no more (§12.4); a peer image without a
   store that serves an operation which is not read-only is refused at
   assembly (§12.6). What the ruling left to this text: that a read-only
   perform is its own request for the supervisor's rules (question 12); that
   read-only is a promise about the peer which nothing checks on the peer
   (question 13); and the reading of "between issue and reply" that the
   model checks, which is exact only for a state that never decreases.
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
   **Owner ruling, 16 November 2026:** a fourth class, `remote`, declared in
   the source. Done as follows: effect declarations carry their class, in a
   new artifact schema, `tc1-handler-demo/3`, for programs that declare a
   remote effect (§1); the validator's option that admitted an unhandled
   effect is gone, and the entry function may leave exactly the remote
   effects unhandled (§3); a perform of a remote operation has the type
   `Remote B`, which only an exhaustive match takes apart (§3, §12.2); an
   image's connections are derived from its program's declarations and the
   build's binding of effect to member (§12.6); and the caller image of
   §12.11 is built from a source file. What the ruling left to this text: a
   `handle` of a remote effect is rejected, not given a local meaning
   (question 16); the outcome type is built in until datatypes take
   parameters (§3); the declaration states the peer's types, and the key is
   the first component of the caller's argument (§12.2); and the surface
   spelling (SURFACE.md).
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

Raised by draft 7:

11. **An outcome that is never examined.** The type `Remote B` forces the
    three arms on a program that wants the operation's value. It does not
    stop a program from dropping an outcome, or passing it on unmatched.
    Should the result of a remote perform have to be matched (or explicitly
    discarded)? That needs a must-use rule the language does not have.
    **Owner ruling, 16 November 2026:** a remote outcome may not be ignored.
    The result of a remote perform must be scrutinised by a `match`; it may
    not be discarded, stored, returned or passed on. The ruling asked for the
    simplest sound rule. Done as follows (§3): a remote perform is accepted
    only as the scrutinee of a match, and the type `Remote B` cannot be
    written, so no outcome is ever bound, held or moved; the frontend rejects
    a wrong program at the perform, and the validator rejects a hand-made
    artifact that tries the same. What the ruling left to this text: that a
    `let` between the perform and its match is rejected too, though the
    ruling would allow it; that the type becomes unwritable, which draft 7
    allowed; that an arm may do nothing; and what the linear version looks
    like (§3). The example program needed no change.
12. **The identity of a read-only perform.** Here each perform is its own
    request, so `not_delivered` is decided per perform. The alternative, one
    identity per caller and operation, is also sound and makes
    `not_delivered` almost never available after the first read. Confirm.
    **Owner ruling, 16 November 2026:** confirmed. Each read-only perform is
    its own request (§12.3). Nothing changed in the model or the
    implementation.
13. **Who vouches for read-only.** The marker is in the caller's program. The
    peer's image says the same only because the build copies it there. When
    a peer is written in this language, read-only should be checked on the
    peer: a handler that performs no durable effect. Until then it is a
    promise, and a peer that breaks it is caught only on the histories run.
    **Owner ruling, 16 November 2026:** the peer is written in Fenrir, its
    store is reached through effects, and the type checker vouches for the
    read-only marker. Accepted with it: the store is a small map from key to
    integer for now, on the block device as before (SQLite later). Done as
    §12.12 says: two store effects of the durable class, provided by the
    peer's runtime; a `serve` form with one implementation for each
    operation; the rule that the implementation of a read-only operation has
    no `StoreWrite` in its effect set, in the frontend and in the validator;
    the peer image running that program on the C machine once for each
    request, in a transaction; the model's peer being that program; and the
    hand-written counter gone. What the ruling left to this text: the
    effects' names and that an absent cell reads 0 (question 17); that an
    implementation sees the key and the argument and not the caller
    (question 18); that only the runtime says `conflict` (question 19); what
    a trap of the program does (question 20); that a peer without a store may
    still read (question 22); how the commit is made atomic and what that
    assumes (question 23); and that a peer does not call onward (question 24).
14. **Where the binding of a remote effect to a member lives.** Today it is a
    constant of the build script. It could be in the manifest, in the source,
    or on the build's command line. The manifest would then be the one
    description of who talks to whom.
    **Owner ruling, 16 November 2026:** in the system manifest, the file that
    lists the members and the declared connections. The build reads it from
    there, the supervisor's assembly check uses the same manifest, and an
    effect with no binding, bound to a name that is no member, or bound to a
    member with no declared connection from the caller is refused at
    assembly, each with its own message. Done as §12.6 says. What the ruling
    left to this text: the format; that a binding is per caller,
    `[caller, Effect, member]`; that a binding and a connection are both
    required and neither implies the other; and that a caller image built for
    another member than the manifest binds is an error of the manifest, not a
    refusal.
15. **Operations a peer serves.** They are derived from the caller's
    declarations, because there is one caller and no peer program. With two
    callers that declare the same effect differently, something has to own
    the effect's signature: a shared declaration both programs import, which
    needs modules.
    **Owner ruling, 16 November 2026:** a shared declarations file included
    by both programs, and a signature digest check at assembly. Accepted with
    it: include, not import; the file is spliced in textually and may contain
    only declarations; real modules are a later decision. Done as §12.6 and
    §12.12 say: `(include "file")`; a digest of each remote effect's
    signature in every image, computed by each build from its own program;
    the refusal `signature` at assembly; and the operations a peer serves
    derived from the peer's program. What the ruling left to this text: how
    the file is named and that an included file may include (question 21);
    and what the digest covers and how it is encoded (question 21).
16. **No handler for a remote effect.** Rejected here (§3). Allowing one that
    intercepts locally would let a caller program be run alone against a
    stub, at the price given in §3. Confirm the rejection, or say that
    testing against a stub should be a property of the build (bind the effect
    to a stub member) rather than of the program.
    **Owner ruling, 16 November 2026:** confirmed: `handle` of a remote effect
    is rejected. Nothing changed in the implementation; the frontend and the
    validator each have a test that rejects one. With the binding in the
    manifest (question 14), running a caller against a stub is a matter of
    binding its effect to a stub member there.

Raised by draft 9:

17. **A cell that was never written reads 0.** So a program cannot tell an
    absent cell from one that holds 0. That keeps `get` total and its type
    an I64. The alternatives need a type the language can state at an
    operation: an optional value, or a second operation that asks whether a
    cell exists. Confirm, or say which.
18. **What an implementation is told about a request.** Here the key and the
    argument, and nothing about who asks; the reply record is per (caller,
    key), but the program cannot see the caller. A tenant-scoped service
    (amendment §8) needs the caller's identity, or a tenant, in the request
    and in what the store's cells are keyed by. Should the runtime scope the
    store by caller, or hand the caller to the program?
19. **Only the runtime says `conflict`.** While the reply of a keyed
    operation is the pair (status, value), an implementation must return
    status 0; any other status is treated as a trap. With sums across the
    boundary the implementation would return the value alone and the runtime
    wrap it. Confirm the interim rule, or let a program define statuses of
    its own beside 0 and 1.
20. **A trap of a peer's program.** Here it commits nothing and sends no
    reply: the caller times out, and a retry runs the program again. The
    caller cannot tell a peer that always traps on this request from one
    that is slow. Alternatives: a reply that says the operation failed, as a
    value of the application; or a record of the failure under the key, so
    that a retry is answered without running anything.
21. **Include, and the digest.** The file is named relative to the including
    file's directory, without `..`, and may include other declaration files;
    nothing says where a file shared by two repositories lives. The digest
    is over the canonical encoding of §12.6, ignores the order of
    declaration, and does not cover the definition of a datatype a type
    names. Confirm the three choices; the last has to change before a
    datatype crosses the wire.
22. **A peer with no store may read.** The ruling's rule is that such a
    peer's program does not mention the write effect. `StoreRead` is left
    allowed, and reads an empty store: every cell is 0. Forbidding both would
    be simpler to state and loses nothing today.
23. **What "atomic" rests on, and the store's growth.** The commit is atomic
    if one 512-byte block write is atomic and a completed write is not lost
    when the image dies; the store is an append-only log that is never
    compacted, and reply records are never dropped. Is that the contract
    wanted of the host-side store until SQLite replaces it, and how long must
    a reply record be kept?
24. **A peer that calls onward.** Rejected here: a program that serves
    performs no remote operation. Allowing it needs a rule for a read-only
    operation (it may perform read-only operations only), and a rule for the
    transaction, which §8 says may not be held across a perform that can
    suspend the task.

### 12.11 First implementation

```sh
sh harness/run-tc1-remote-run.sh    # the real system under schedules, judged by the model
```

The smallest system, for real: an Erlang/OTP supervisor
([supervisor/](../../supervisor/README.md); Erlang/OTP is assumed for this
step, on a recommendation that is not yet an owner ruling), a caller image and
a peer image, each a Solo5 guest run as an OS process under the `spt` tender.
Both images run a program of this language on the C machine of
`backends/solo5/pure-call`, and both programs are source files that the build
elaborates with the frontend ([SURFACE.md](SURFACE.md)).

*The caller.*
[examples/remote/ledger-caller.fen](../../examples/remote/ledger-caller.fen),
an artifact of schema `tc1-handler-demo/3`. It performs `Ledger.add` with key 7
and argument 5, once more with the same key and argument after `timed_out`,
then with key 8, then with key 7 again and argument 6, a reuse of the key that
the peer refuses if key 7 was applied with 5; and then `Ledger.total`, once
more after `timed_out`. Every one of those performs is the scrutinee of a
match (must-use, §3). With draft 9 its three lines that declared `Ledger`
became three lines that include the shared declaration, and its artifact is
the same bytes as before. When the machine is Ready at a remote perform, the
image sends the request, waits for the one outcome, and gives it to the
machine as the value of the perform; the frames stay in the image.

*The peer* (draft 9, §12.12).
[examples/remote/ledger-peer.fen](../../examples/remote/ledger-peer.fen), an
artifact of schema `tc1-handler-demo/4`: it serves `Ledger`. `add` puts the
amount on a stored total (cell 0), counts the addition (cell 1), notes the
request key (cell 2), and replies status 0 with the total it reads back;
`total` reads cell 0. The peer image is that program and a runtime in C:
transport, the store, and the transaction around each request. The
hand-written counter of drafts 4 to 8 is gone; nothing in the C says what an
operation does. So the values differ from draft 8's: the first application of
5 replies 5 where the counter replied 1, the second 10.

*The system* is described by its manifest,
[examples/remote/ledger-system.json](../../examples/remote/ledger-system.json)
(§12.6), which names both programs, says that the peer has a durable store,
and binds `Ledger` of the caller to the peer. The build derives what each
image says of itself from that image's own program: the caller's connections
and operations, the operations the peer serves, whether the peer's program
writes, and a digest of `Ledger`'s signature on both sides, which are equal
because both programs include
[examples/remote/ledger.decl.fen](../../examples/remote/ledger.decl.fen).

*A second system*,
[examples/remote/rates-system.json](../../examples/remote/rates-system.json),
is the one draft 8 lacked: a caller that only reads
([rates-caller.fen](../../examples/remote/rates-caller.fen)) and a peer with
no durable store ([rates-peer.fen](../../examples/remote/rates-peer.fen)),
which serves two read-only operations from constants and arithmetic. Its peer
image has no store device, its program mentions no store effect, and the
system is assembled and runs.

*The wire.* Messages go through block-device files used as mailboxes, which
need no privileges, not through the network device. The wire format is
version 4. A request now names its operation, `Effect.operation`, so a peer
serves any number of operations of each mode; version 3 sent only the mode,
and a peer served one of each. The types are still what one system needed: a
keyed operation takes an I64 and replies a status and an I64 (§12.2); a
read-only one takes unit and replies an I64; the build rejects a program
whose remote operations are otherwise. A reply to the supervisor may say
`trapped`, which the supervisor does not pass on. The peer's store is a log
of two kinds of record, cells and reply records, and a reply record keeps the
operation with the argument (§12.12). The supervisor's README has the format,
what is trusted, and what is not shown.

`harness/tc1-remote-run.shen` runs the systems and judges each recorded run:
(a) every recorded step is enabled in the model at that point, and the set of
steps the supervisor considered enabled is the model's; (b) the properties of
§12.8 hold in every state and on every step of the replay; (c) the consoles of
the images show what the model says they observe (the caller's outcomes,
requests and TC1 events per incarnation, the peer's actions and the store it
found at each start, cell by cell), the peer's store file at the end is the
model's durable store, every cell and every record with the operation and
argument it was made with, and the run had one relay process more than the
supervisor restarts in its log. The model's caller and the model's peer are
the two programs, read from the build's artifacts.

| Schedules | Number | Result |
| --- | --- | --- |
| Written by hand from this section | 31, two of them of the rates system | Accepted; the recorded steps are the schedule's and the outcomes the expected ones |
| Seeded (1 crash, 1 duplicate, 1 supervisor restart, until no step is enabled) | 50, 1,147 steps: 40 of the ledger system, 989 steps, and 10 of the rates system, 158 steps | Accepted. All fifty take the supervisor restart, 41 act on a read-only request, 28 end a perform in `conflict`, 20 report `not_delivered`, 3 take the crash between commit and reply |
| Free-running: one undisturbed, two with the peer killed from outside, one with a request the supervisor is told to lose, and one of the rates system | 5 | Accepted |

The forty seeded schedules of the ledger system have, in all, the 989 steps
they had in draft 8: the same seeds meet the same choices, with the new
values in the replies.

The hand schedules cover: plain reply; request dropped, timeout, retry applied;
reply dropped, timeout, retry replayed; peer killed before hand-over,
`not_delivered`; a request dropped before hand-over with the peer up,
`not_delivered`, the remaining copy destroyed; peer killed after hand-over,
`timed_out`, restart, retry (applied if it had not acted, replayed from the
surviving store if it had); peer killed between its commit and its reply,
`timed_out`, restart, the retry given the committed value, applied once; two
with the peer killed inside its commit (below); no
`not_delivered` offered after a hand-over; a duplicate applied once; a reply
after `timed_out` discarded; a caller restarted from its beginning; key 7
applied with one argument and then performed with another, `conflict`, the
store unchanged, and a late copy of the first request still replayed; four
schedules with a supervisor restart (below); an undeclared connection refused
at start, and at run time with the start-time check off; five about read-only
operations and a storeless peer image refused at assembly (below); two
refusals about a binding, the manifest given with no binding for
`Ledger` (`unbound`) and with `Ledger` bound to a name that is no member
(`unknown-member`); one refusal of a differing signature (below); and the two
of the rates system (below). Every other run is given the bindings the
build read from the manifest. In every schedule that applies key 7 with argument 5,
the program's third keyed perform is the reuse of key 7 and ends in
`reply(conflict)`, and every schedule that runs the program to its end ends
with the read. Every step kind of the model but `act ... trapped` occurs: the
two programs never trap on these arguments. Each scheduled run was
made twice with equal recordings.

*A kill inside the commit, for real* (draft 9). The model has no step of its
own for it: a commit is durable whole or not at all, so a peer killed inside
one has committed nothing, which is the step `crash`. The supervisor takes
that step in a particular way when a schedule asks for it. It grants the peer
the request with a mark in the inbox header that makes the image stop,
without exiting, inside its commit: when every record of the commit is
written to the store device and the header that would count them is not. The
supervisor waits until the store file shows the request's reply record
beyond the header's count, kills the tender process with `kill -9`, and
records `crash`, having read from the store that the request has no counted
record. Its report lists the records it saw written and uncounted, and the
check requires that list. Two hand schedules: the peer killed inside the
commit of its first request, with three cells and the reply record of key 7
written and none counted, after which the restarted peer finds an empty
store and the retry is the key's first application; and the peer killed
inside the commit of key 8 after key 7 was committed, after which the store
has key 7 whole and nothing of key 8, key 7 performed with another argument
is still a `conflict`, and the total read is 5. The kill is placed at that
one point; a kill between two record writes of a commit would find fewer
records and no different store, and is not placed.

*Read-only, assembly, and a storeless peer, for real.* Four schedules of the
ledger system: the read handed to the peer, the peer killed before it acts,
`timed_out`, the peer restarted, and the retry, a new request, answered 10
by the new incarnation from the store it found; two copies of one read handed
over, each evaluated, the second reply stale, the store as it was; a read
never handed over reported `not_delivered` with the peer up, after three
keyed requests of the same caller that were handed over; and a read issued
when the total is 5, a late copy of key 8 applied before the peer acts on the
read, and the reply 10, which is the weaker guarantee of §12.4 seen from
outside. Two refusals at assembly, each of an image the build makes beside the
real peer for the purpose, with nothing started: the ledger peer built
without a store device, refused both because it serves `Ledger.add` and
because its program writes (`no-store`, twice); and a peer built from
[a program that declares `Ledger` itself](../../tests/remote/ledger-peer-other-signature.fen),
with one read-only operation more than the shared file has, which serves
everything the caller performs and is refused because its digest of the
signature is not the caller's (`signature`). And two accepted runs of the
rates system, whose peer has no store: both read-only operations served, the
request naming the one meant; and the peer killed with a read in its inbox,
restarted, the retry answered, and a duplicated read evaluated twice. No
store file exists in those runs.

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
record.

| Defect, as a switch on the real system | Caught by | Schedule |
| --- | --- | --- |
| Supervisor reports `not_delivered` after hand-over | (a): the step is not the model's | issue, hand over, not-delivered |
| Peer runtime applies a recorded request id again | (a): the model has only `replayed` there | issue, duplicate, hand over, hand over, act, act |
| Supervisor hands over a reply after `timed_out` | (a): the model has only `discard-reply` there | issue, hand over, act, timeout, deliver reply |
| Supervisor carries an undeclared connection (start-time check off) | (a): the model has only `refuse` there | issue, hand over, act, deliver reply |
| Peer runtime replies first and commits afterwards | (c): the peer's store file is empty where the model has three cells and a record | issue, hand over, crash between commit and reply, deliver reply |
| Restarted supervisor takes nothing as handed over | (a): the model has only `timeout` there | issue, hand over, act, supervisor restart, not-delivered: the caller is told the peer has not acted, and it has applied the request |
| Peer runtime replays a record whatever the argument | (a): the model has only `conflict` there | key 7 with argument 5 and key 8, each issued, handed over, acted on and replied to; then key 7 with argument 6 issued, handed over, act: replayed |
| Peer runtime adds one to the total and commits it before it serves a read-only request | (a): the reply the supervisor carries is 11, and the model has only the reply 10 there | the three keyed performs, each issued, handed over, acted on and replied to; then the read issued, handed over, acted on, deliver reply |
| Peer runtime commits a request's writes without its reply record | (a): the second copy is applied again, and the model has only `replayed` there | issue, duplicate, hand over, hand over, act, act |
| Peer runtime commits a request's reply record without its writes | (a): the next addition replies 5, and the model has only the reply 10 there | keys 7 and 8, each issued, handed over, acted on and replied to |
| Peer runtime counts each record of a commit as it writes it; killed inside the commit | (c): the restarted image finds the three cells of key 7 and no record, where the model's store is empty | issue, hand over, kill inside the commit, restart |
| Peer runtime answers a read of the store without the request's own writes | (a): the reply is `ok 0`, and the model has only `ok 5` there | issue, hand over, act, deliver reply |

In the fifth, the kill finds a reply and no commit. The supervisor records what
it saw, an act by the reply and then the crash, and the caller is given the
reply. (a) and (b) accept that log: by the log the peer acted. Only the store
says otherwise, which is the point of the ruling on question 10.

In the eighth, the act itself is a step of the model: the supervisor cannot see
that the image wrote. The value gives it away one step later. This is the
defect draft 8 called "a read-only operation writes". A peer's program cannot
have it any more, being rejected before an image exists (§12.12); the runtime
can, and the switch shows that the check on histories still sees it.

The last four came with draft 9 and are the runtime's half of §12.3: the two
halves of a commit each left out, a commit that is not atomic, and a
transaction whose reads do not see its writes.

Each of these recordings, replayed through the corresponding model mutant, is
accepted and violates the property that mutant is aimed at in §12.8. A run
that ends in an error would count as crashed, not caught; none does. As a
negative control the checker is run with the non-idempotent peer runtime in
place of the peer: it reports failure and exits with status 1, and the runner
requires that.

This check is the row `remote-run` of the TC1 gate (§9). Its evidence class is
observed histories on `spt` accepted by the model.

Limits. Two two-member systems and a few dozen histories of them: (a) to (c) say
those histories are ones the model allows, nothing more. The supervisor's log
is its own account. In the scheduled modes a crash is taken between steps,
with the images at rest, or at one of two places inside a step, with the
image's cooperation: after the commit and before the reply, and inside the
commit when every record is written and none counted. A kill at any other
instant (between two record writes of a commit, between the reply's two
writes) is not placed and not exercised. The supervisor's restart is taken between steps
only, never in the free-running mode, and what survives it is in the memory of
another Erlang process: a relay killed inside a step, and the loss of the
whole VM, are not covered. Ten defects are caught by (a), two by (c)
alone. Four free-running runs depend on the wall clock. The peer's runtime is
hand-written C and is checked only on these histories; no peer program traps
in them. The supervisor's handling of a manifest's errors (a duplicate
binding, a binding for an unused effect, an image built for another member)
was tried by hand runs only; no schedule of this check and no unit test runs
it. The build's own check of a manifest has unit tests. The frontend that
elaborates the programs is development code with its own tests (`sh frontend/test.sh`), which are not a row of the gate.
No `hvt` run and no proof.

### 12.12 Peers written in the language

Draft 9, by the owner's direction of 16 November 2026 on questions 13 and 15
of §12.10. What follows is specified and implemented together; what it leaves
open is questions 17 to 24.

**The store.** A peer's durable store (§12.1) is a finite map from I64 to
I64. A peer's program reaches it through two effects of the durable class
(§8), which it is given and does not declare:

```text
effect StoreRead  { get : I64 -> I64 }
effect StoreWrite { put : (I64, I64) -> Unit }      (key, value)
```

- `get` of a cell that was never written is 0. The operation is total, and
  a program cannot tell an absent cell from one that holds 0 (question 17).
- The two are provided by the peer's runtime. No `handle` names either, and
  they exist only in a program that serves. The machines have no notion of a
  store: when a machine is Ready at a perform of one of them that no frame
  handles, its host gives the perform its value and the machine takes no
  step for it, exactly as a caller's host does for a remote perform (§12.2).
  All three machines are used so (below).

**Serving.** A program *serves* a remote effect by giving one implementation
for each of its operations (SURFACE.md has the spelling):

```text
serve Ledger { add(key, a) => e1 ; total(u) => e2 }
```

- The implementation of an operation `op : A -> B` that is not read-only is a
  function `(I64, A) -> B`: it is given the request key, then the argument,
  as the caller performed them. That of a read-only operation is `A -> B`.
  It is not told who the caller is (question 18).
- A program that serves has no entry function. It is run once for each
  request, at the function of the operation requested, on the request's
  input. Nothing of one run survives into the next except the store.
- An implementation may leave unhandled only `Emit`, `StoreRead` and
  `StoreWrite`; every ordinary effect is handled inside it, as at an entry.
- **A peer does not call onward.** A perform of a remote operation in a
  program that serves is rejected (question 24).
- In the artifact (schema `tc1-handler-demo/4`, slice TC1-P1) each
  implementation is a function named `Effect.operation`, which no program can
  call, and `serves` lists them; there is no `entry` and no `input_schema`.

**Read-only is checked** (owner ruling, §12.10 question 13). The function of
an operation declared read-only may not have `StoreWrite` in its effect set.
Effect sets are closed under calls and applications (§3), so this covers a
write made by a function it calls and by a function value it applies. Both
the frontend and the validator reject a program that breaks it, the frontend
at the perform, call or application the write comes from. With no remote
perform allowed, that is the whole rule; when a peer may call onward it has a
second half, that a read-only implementation performs only read-only remote
operations. **A peer without a durable store** has a program that does not
mention `StoreWrite` at all, in any function's or function type's effect set:
the build checks that on the artifact, the image says it, and the supervisor
refuses at assembly otherwise (§12.6). Such a program may read; it reads an
empty store (question 22).

**The transaction.** The peer's runtime serves one request at a time (an image
is single-threaded), and each request is a transaction:

1. *Keyed, and the request id has a reply record.* Nothing is run. The reply
   is the recorded value if the record was made with this operation and
   argument, and `conflict` if not (§12.3).
2. *Keyed, no record.* The function is run on (key, argument). Its writes
   are kept aside, in the order of the cells; a read sees the value this
   request last wrote to the cell, else the store's, else 0. If it returns
   (0, v), **the commit**: the request's writes, the final value of each cell
   it wrote, and the reply record (caller, key, operation, argument, v)
   become durable in one atomic step. Then the reply `ok v` is sent.
3. *Read-only.* The function is run on the store as it is. There is nothing
   to commit, and the reply is its value.
4. *A trap* of the function, at any point, or a keyed result whose status is
   not 0: nothing is committed, not even what was written before the trap,
   and no reply is sent. The supervisor is told, the caller is not, and the
   caller's perform ends in `timed_out` (questions 19 and 20).

**What "atomic" rests on.** The store is a block device of 512-byte blocks: a
header block and a log of record blocks. The header counts the log's records.
A commit writes its records, one for each cell written and one reply record,
to the blocks after the last counted one, and then writes the header once,
with the new count. A record the header does not count does not exist: it is
not read when the store is opened, and the next commit writes over it. So a
kill before the header write leaves the store exactly as it was, and a kill
after it leaves all of the request. This is atomic at the granularity of a
record under two assumptions about the device, neither of which is tested:
that one 512-byte block write is atomic, so the header is never seen half
written; and that a write that has returned is not lost when the image dies.
A commit of n writes is n + 2 block writes, and the last is the commit. The
log is never compacted (question 23). SQLite, on the host side, replaces this
later (amendment §8).

**Shared declarations** (owner ruling, §12.10 question 15). `(include "file")`
at the top level of a program stands for the declarations of that file,
spliced in at that place. It is textual inclusion, not a module: there is no
namespace and no interface, and a name declared twice is an error wherever
the two declarations are written. The file is named relative to the directory
of the file the include is written in, with `/` between components, no
absolute path and no `.` or `..` component. An included file may contain
only declarations, of datatypes, effects and remote effects, and includes of
its own; a function or a `serve` there, a file that cannot be read, and a
file that includes itself directly or through others are rejected, each with
the file, line and column of the form at fault. The caller and the peer of
§12.11 include one file, and the digest of §12.6 is what makes that matter
at assembly: nothing else stops two programs from declaring an effect apart.

**The three machines.** The store effects have the same treatment in the Shen
model (`models/tc1/remote-tc1-peer.shen`), the JavaScript machine
(`runtime/tc1/peer-request.mjs`) and the C machine
(`backends/solo5/remote/serve.c`, the code the peer image uses). The system
model's peer is the first of them (§12.8).

```sh
sh harness/run-tc1-peer-requests.sh   # one request, three machines
```

`harness/tc1-peer-requests.shen` takes cases, each a peer program, one of
its operations, a request input and a store, and requires the three machines
to agree on the whole run: every machine step, every store perform with its
value, in order, how the run ended, and the writes it would commit. The
programs are the two peers of §12.11 and a third,
[tests/remote/peers/pots.fen](../../tests/remote/peers/pots.fen), with two
operations that change state, a trap after writes, a cell written twice in
one request, and a store read under a handler frame.

| Cases | Number | Result |
| --- | --- | --- |
| Written by hand, with the outcome and the writes expected from the programs' text | 22 | The model gives the expected outcome and writes of all 22; the three machines agree |
| Generated from one fixed seed: a program, an operation, a key and argument from boundary and small values, a store of up to four cells | 400 | The three machines agree on all 400 |

In all 422 cases: 22,500 machine steps and 1,138 store performs; 394 runs end
Ok, 11 in `Overflow` and 17 in `DivZero`; 137 leave writes. The defect of a
read that does not see its own request's writes, as a switch of the
JavaScript and of the C store code, is detected on 123 cases each. This check
is the row `remote-peer` of the TC1 gate (§9). Its evidence class is
agreement of three implementations on listed cases. It has no commit, no
reply record, no replay and no conflict: those are the runtime's, and are
checked on the real system (§12.11) and, as a model, in §12.8.

**Not done.** A peer that calls onward. Tenant scoping, and any identity of
the caller in a request. A reply for a program that failed. A store other
than I64 to I64, compaction, and retention of reply records. A torn block or
a lost write. A proof of the read-only rule, of the atomicity of the commit,
or of anything else here. The peer's runtime, the three store plugs, the
programs, the cases and this text share one author lineage.
