# TC1 effect contract

Draft 1 • 14 November 2026 • For owner review

**Status.** Written together with its first implementation, at the owner's
request, so the text and the behaviour can be reviewed side by side. Slice H1
(tail-resumptive handlers) is implemented in the Shen model, in an independent
JavaScript implementation, and checked by the harness. Slice H2 (explicit
one-shot resumption) is specified here and not implemented. Nothing in this
document is qualified. It supersedes §5 of
[02_TINY_LANGUAGE_CORE.md](../../02_TINY_LANGUAGE_CORE.md) for TC1 and answers
the open questions of the earlier handler task packet (PR #7); §10 lists them.

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
- **H1 restriction:** A and B are serializable types. No closure crosses an
  operation boundary yet. Lifting this is tied to the resource rules of §8.

## 2 Expressions

```text
e ::= ... | perform(Effect, operation, e) | handle(Effect, [operation(x) => e]..., body)
```

- `perform` is strict in its one argument, like a call.
- `handle` supplies exactly one clause per operation of its effect. The body
  and the clauses are not operands: they are not evaluated eagerly.

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

A perform is observable. Each one produces, in order with all other events:

| Event | When | Fields |
| --- | --- | --- |
| `Perform` | the handler is selected and the clause is entered | node of the perform, effect, operation, argument value |
| `Resume` | the clause has returned and the segment is restored | node of the perform, result value |

An aborted perform has a `Perform` and no `Resume`. Handler entry and exit
produce no event. This is what a compiler must preserve about effects: the
sequence of these events, interleaved with `emit` events, and the outcome.

## 6 Reference steps

These are properties of the reference machines, for locating a bug exactly.
They are not obligations on compiled code.

| Step | Site | After | Frames |
| --- | --- | --- | --- |
| Dispatch `handle` | the handle node | Eval (the body) | handler frame pushed |
| Dispatch `perform` | the perform node | Eval (its argument) | collect frame pushed |
| Ready `perform` | the perform node | Eval (the clause body) | segment replaced by one clause frame |
| `ClauseReturn` | the perform node | Value | clause frame replaced by the segment |
| `HandleReturn` | the handle node | Value | handler frame popped |
| `UnwindFrame` at a clause frame | the perform node | Unwind | clause frame replaced by the segment, which unwinds next, one frame per step |
| `UnwindFrame` at a handler frame | the handle node | Unwind | handler frame popped |

Depth is the number of active frames. A suspended segment counts as the one
clause frame holding it.

## 7 Slice H2: explicit one-shot resumption (specified, not implemented)

A clause may name its resumption:

```text
handle(E, [op(x, k) => c]..., body)        resume(k, e)        discontinue(k)
```

- `k` is a resumption: the suspended segment as a value. `resume(k, v)`
  restores it with v as the result of the perform, and its value is the value
  of the handled body from that point. `discontinue(k)` abandons it, unwinding
  the segment as an aborted perform does.
- **One-shot.** On every path through the clause, `k` is used exactly once, by
  one `resume` or one `discontinue`. This is checked statically: `k` is an
  affine binding that may not be captured by a closure, stored in data,
  returned, or passed to a function. Zero uses or two uses are validation
  errors.
- An H1 clause `op(x) => c` means `op(x, k) => resume(k, c)` with the resume in
  tail position. An implementation may run it without materializing `k`.
- After `resume(k, v)` returns, the clause may continue; its value is then the
  value of the `handle`. This is what distinguishes H2 from H1.
- **Multi-shot** resumption (using `k` more than once, as backtracking search
  needs) is not part of TC1. It will be admitted only where everything the
  suspended segment holds is duplicable, and is specified with the ownership
  rules.

## 8 What resumptions will have to respect (not implemented)

Recorded now so that H2 and the concurrency slice are designed against it:

- A resumption carries the region support of the segment it suspends and cannot
  outlive those regions.
- A transaction or an exclusive borrow may not be held across a perform whose
  handler can suspend the task.
- Three kinds of effect are distinguished: **ordinary** effects, handled by
  user handlers as above; **runtime** effects (tasks, channels, time,
  resources, emit), discharged by the runtime and not replaceable by a user
  handler; and **durable** effects (transaction, durable job, durable inbox),
  discharged only by a handler that carries a storage contract.

## 9 What H1 is checked against today

`sh harness/run-tc1-handlers.sh`

- **Fixtures** (`fixtures/tc1/handler-hand-cases.mjs`): eleven programs, each
  with expectations written from this text before either machine ran: outcome,
  the order of performed operations, emission order where relevant, and for two
  programs the complete step staging.
- **Agreement:** the Shen model (`models/tc1/handler-machine.shen`) and the
  JavaScript implementation (`runtime/tc1/handler-machine.mjs`) agree step for
  step on all eleven, and both satisfy all 28 expectations.
- **Defects:** four defects injected into the implementation are each detected
  on at least one fixture without crashing: clause return that forgets to
  resume (9 fixtures), resumes twice (9), selection of the outermost handler
  (2), and a clause run in the perform site's bindings (1).
- **TC0-A subset:** the JavaScript handler machine gives the same steps,
  outcome and closure descriptors as the TC0-A implementation on all 5,774
  TC0-A programs of the existing scopes.

Not done for H1: generated or exhaustive handler programs, reduction, strict
replay, catalog coverage, the Solo5 guest, and any soundness proof of the
typing rules in §3. The fixtures, both machines and the harness share one
author lineage.

## 10 Answers to the earlier open questions

| Question (PR #7 packet) | Answer |
| --- | --- |
| Q1 Does `perform` collect its argument? | Yes, like a call (§2, §6) |
| Q2 Are handle and clause bodies tail positions? | Each is its own return destination; a `handle` is not a tail position of its function (§4) |
| Q3 Is the segment unwound per frame on a clause trap? | Yes: one step discards the clause frame and exposes the segment, then one frame per step (§6) |
| Q4 Which environment does a clause see? | The bindings at the `handle` node plus its binder (§3, §4) |
| Q5 Can operation types be arrows? | Not in H1: serializable types only (§1) |
| Q6 Which events are observable? | `Perform` and `Resume` (§5) |
| Q7 What are the site nodes? | The perform node for clause return and clause abort; the handle node for handler entry and exit (§6) |
| Q8 Handler stack or segments in the state? | Handlers are frames in the continuation; a suspended segment is held in one clause frame (§6) |
| Q9 Canonical effect-set order? | Unsigned UTF-8 byte order, duplicates rejected (§3) |

## 11 Decisions for the owner

1. The event set of §5. It fixes what compiled code must preserve.
2. The H1 restriction to serializable operation types (§1).
3. H2's rule that the clause may continue after `resume` returns (§7). The
   alternative, requiring `resume` in tail position, is simpler to implement
   and to prove, and makes H2 no more expressive than H1 plus `discontinue`.
4. Whether TC1 gets its own gate or extends the TC0-A gate. Today the slice is
   one optional row of the TC0-A gate.
