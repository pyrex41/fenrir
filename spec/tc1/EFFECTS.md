# TC1 effect contract

Draft 2 • 14 November 2026 • For owner review (§6 aligned with the model and catalog, 15 November 2026)

**Status.** Written together with its implementation, at the owner's request,
so the text and the behaviour can be reviewed side by side. Both slices are
implemented in the Shen model, in an independent JavaScript implementation and
in the C machine that runs as a Solo5 guest, and checked by the harness: H1,
tail-resumptive handlers, and H2, explicit one-shot resumption. Nothing in this
document is qualified. It supersedes §5 of
[02_TINY_LANGUAGE_CORE.md](../../02_TINY_LANGUAGE_CORE.md) for TC1 and answers
the open questions of the earlier handler task packet (PR #7); §10 lists them.

Owner decisions of 14 November 2026 are folded in: a clause may continue after
`resume` returns (§7); performs of user effects are not observations (§5);
operation types stay serializable for now (§1); the slices are one optional
row each of the TC0-A gate until TC1 has its own (§9).

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
| `AbandonFrame` | the frame's node | Abandon | one frame discarded per step; a clause frame is instead replaced by the segment it holds, which is abandoned next (as for `UnwindFrame` below) |
| `DiscontinueReturn` | the discontinue node | Value (unit) | discontinue-return frame popped |
| `HandleReturn` | the handle node | Value | handler frame popped |
| `UnwindFrame` at a clause frame | the perform node | Unwind | clause frame replaced by the segment, which unwinds next, one frame per step |

Depth is the number of active frames. A suspended segment held by a clause
frame counts as that one frame; a segment held in a resumption counts as none.

A clause `op(x,k)` that traps before using `k` drops the segment without
steps. With no resources in TC1 this cannot be observed. When resources exist,
the segment's releases must happen at that point.

**Draft-text alignment, 15 November 2026.** The table above was written before
the machines. The Shen model (`models/tc1/handler-machine.shen`, the authority
here) takes the steps below as well, and
[handler-catalog.json](handler-catalog.json) lists these and the rows above as
29 transitions (a row naming two cases counts as two, and `AbandonFrame` is one
transition per kind of frame). The text is changed to say what the model does;
no behaviour is changed or decided by this edit.

| Step | Site | After | Frames |
| --- | --- | --- | --- |
| Dispatch `discontinue` | that node | Ready | none: it has no operand |
| `CollectReturn` of `perform` or `resume` | that node | Ready | collect frame popped, the argument stored |
| `UnwindFrame` at a handler frame | the handle node | Unwind | one handler frame discarded |
| `UnwindFrame` at a collect or clause-exit frame of a `perform` | the perform node | Unwind | one frame discarded |
| `UnwindFrame` at a collect or resume-return frame of a `resume` | the resume node | Unwind | one frame discarded |
| `AbandonFrame` at a frame other than a clause frame: `let`, `if`, `match`, a strict form's collect frame, a call or apply frame, a handler frame, a `perform` frame, a `resume` frame | the frame's node | Abandon | one frame discarded; the catalog has one transition per kind |

Also, `Dispatch handle` enters the body in tail position (§4), and `Ready
resume` and `Ready discontinue` push the segment of s >= 1 frames, so their
depth change is a bound, not a constant: the catalog records it per
transition. Where two kinds of frame can sit at one node (a collect frame and
a clause-exit frame, say) the step record does not say which one a step
discards; the catalog keeps them as one transition. Whether the record should
say is open (§11).

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

Recorded now so that the concurrency slice is designed against it. The first
concurrency slice, C1 (tasks and bounded channels), is specified in
[CONCURRENCY.md](CONCURRENCY.md); its §11 says how C1 meets each point below.

- A resumption carries the region support of the segment it suspends and cannot
  outlive those regions.
- A transaction or an exclusive borrow may not be held across a perform whose
  handler can suspend the task.
- Three kinds of effect are distinguished: **ordinary** effects, handled by
  user handlers as above; **runtime** effects (tasks, channels, time,
  resources, emit), discharged by the runtime and not replaceable by a user
  handler; and **durable** effects (transaction, durable job, durable inbox),
  discharged only by a handler that carries a storage contract. Slice D1,
  [DURABLE.md](DURABLE.md), specifies and implements durable effects: the host is
  that handler, a host request is an observation, and the transaction is one commit
  of data.

## 9 What is checked today

```sh
sh harness/run-tc1-handlers.sh          # model against the JavaScript implementation
sh harness/run-solo5-pure-call.sh tc1   # model against the Solo5 guest
sh harness/run-tc1-exhaustive.sh        # grammar H, every program up to 7 nodes
sh harness/run-tc1-generated.sh         # generated family G, 2,048 programs
sh harness/run-tc1-reduction.sh DEFECT  # discover, reduce and replay one defect
sh harness/run-tc1-strict-replay.sh     # tapes for the fixtures and retained failures
sh harness/run-tc1-gate.sh              # the proposed TC1 gate, all of the above
```

- **Fixtures** (`fixtures/tc1/handler-hand-cases.mjs`): twenty programs, eleven
  for H1 and nine for H2, each with expectations written from this text before
  any machine ran: outcome, the order of performed operations, emission order
  where relevant, and for three programs the complete step staging.
- **Model and implementation:** the Shen model
  (`models/tc1/handler-machine.shen`) and the JavaScript implementation
  (`runtime/tc1/handler-machine.mjs`) agree step for step on all twenty, over
  625 steps, and both satisfy all 51 expectations.
- **Model and Solo5 guest:** the C machine (`backends/solo5/pure-call`),
  running as a Solo5 guest, agrees step for step with the model on the same
  twenty programs.
- **Defects:** six defects injected into the JavaScript implementation are each
  detected on at least one fixture: forgotten resume (9 fixtures), double
  resume (9), outermost-handler selection (2), clause run in the perform site's
  bindings (1), `resume` yielding its argument instead of the body's result
  (2), and a resumed segment without its handler (5, plus one run that crashes,
  which is not counted).
- **Validation:** unit tests reject, for the stated reason, a resumption used
  zero times, twice, or on one path only; read as a value; captured by a
  closure; used by an inner clause; and resumed with the wrong type.
- **Typing rules:** §3 and §7 are written as named inference rules in
  [TYPING.md](TYPING.md), with the one-shot rule as a usage-counting judgment.
  `sh typing/run.sh` finds a derivation, with Shen's sequent machinery, for
  every valid program of the repository (the twenty fixtures, the 12,693
  programs of the exhaustive handler grammar, and the TC0-A families) and has
  the small fixed checker `typing/checker.shen` accept it; both validators
  reject every invalid and ill-typed mutant. The claim is "derivable under rule
  set R, soundness not yet proved". It found one place where the JavaScript
  validator departed from this text, since fixed: it rejected a datatype field
  of a function type that names a declared effect (TYPING.md §11).
- **TC0-A subset:** the JavaScript handler machine gives the same steps,
  outcome and closure descriptors as the TC0-A implementation on all 5,774
  TC0-A programs of the existing scopes, and the extended C machine still
  agrees with the model on those and on the 8,745 exact-arithmetic programs.

- **Exhaustive-small:** every program of grammar H
  (`tools/tc1/handler-enumerate.mjs`, one-operation effects with I64 types, no
  closures) with at most 7 nodes, 12,693 programs over 263,222 steps (11,192
  Ok, 1,501 DivZero), agrees with the model step for step; each of the six
  defects is killed on some of them.
- **Generated family:** the 2,048 programs of family G
  (`tools/tc1/handler-generate.mjs`: seeded, finite, not exhaustive) go beyond
  H with multi-operation effects and Unit operation types, closures, `Opt`
  matches and explicit clauses that do work after `resume`. Model and
  implementation agree on all of them, over 80,611 steps (1,655 Ok, 393
  DivZero). Read from the model's traces, the family exercises: two operations
  of one effect in one run (84 programs), a perform inside two or more handle
  bodies (296), a handler installed after another was removed (332),
  same-effect forwarding out of a clause (72), a closure made under one handler
  performing under another (7), a clause continuing after `resume` returns
  (136), `discontinue` (50), a trap in a clause (85) and in a handled body
  (170), and emissions before and after a perform (159). Every defect is
  killed: forgotten resume on 559 programs, double resume 572, outermost
  handler 304, clause environment 119, resume yielding its argument 21,
  resumed segment without its handler 393 (crashes, between 0 and 111 per
  defect, are counted apart and never as kills).
- **Discovery, reduction and replay:** for four defects a campaign
  (`harness/tc1-reduction.shen`) finds the first generated program showing the
  defect's class of discrepancy, reduces it by typed, handler-aware proposals
  (`tools/tc1/handler-reduce.mjs`: handle-to-body, perform-to-argument,
  resume-to-argument, clause-to-binder and others, each revalidated), accepting
  one only when fresh model and implementation runs show the same class, and
  replays both failures strictly. Forgotten resume: program 6, 61 to 4 nodes in
  54 attempts, class clause-return-drops-segment, diverging at epochs 77 and 6.
  Double resume: the same program and sizes, clause-return-duplicates-segment.
  Outermost handler: program 6, 61 to 23 nodes in 153 attempts,
  selected-other-handler, epochs 75 and 44. Resumed segment without its
  handler: program 5, 56 to 12 nodes in 50 attempts, resume-drops-handler,
  epochs 34 and 11. The original and minimized cases are retained in
  `fixtures/tc1/handler-retained-failures.json`. The other two defects show
  their first difference only through later values; no class is defined for
  them yet.
- **Strict replay** (`harness/tc1-strict-replay.shen`): a tape of the
  implementation recorded against the model's trace replays exactly and is
  admitted for all twenty fixtures; for the eight retained failures the
  defect-free tape is admitted and the defective one diverges at the retained
  epoch. Tapes bind the program, the reference, the implementation with its
  defect switches and the transition catalog.
- **Catalog coverage:** `spec/tc1/handler-catalog.json`
  (`tc1-handler-catalog/1`) turns the table of §6 into 29 transitions, with the
  depth change each allows. It adds what the table leaves out: dispatch of
  `discontinue` (Ready at once), the argument collection of `perform` and
  `resume`, unwinding through handler and clause-exit frames, and
  AbandonFrame per kind of frame. The hand, exhaustive and generated traces
  exercise all 29, and no handler step falls outside the catalog or
  contradicts its depth change.

TC1 has its own proposed gate (`harness/tc1-gate.shen`, manifest
`spec/tc1/tc1-requirements.json`), with a row for each check above; it is not
owner-accepted, so it reports authority UNREGISTERED and qualification UNKNOWN.

Not done: exhaustive exploration beyond grammar H, reduction campaigns for the
two value-only defects, any soundness proof of the typing rules in §3 or of the
one-shot check in §7 (the rules are now stated, in TYPING.md, and checked as
derivations; that they are sound is not proved). The fixtures, all three machines, the generators and the
harness share one author lineage.

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
4. The slices are optional rows of the TC0-A gate until TC1 has its own (§9).

Open:

1. When to lift the serializable restriction, and what a closure passed
   through an operation may capture.
2. The elaboration from inferred effect rows at the surface to the finite
   sets here.
3. Whether a clause that traps before using its resumption should be a
   validation error instead of an implicit abort.
4. Whether abandoning a clause frame should expose the segment it holds, as
   the model does and §6 now says (by analogy with unwinding), or discard it as
   one frame; and whether step records should distinguish the frames that
   share a node (§6). Reference-machine detail only; neither changes an
   observation.
5. When resources exist: the order and timing of the releases of a segment
   dropped by a clause that traps before using `k` (§6).
