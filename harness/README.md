# Harness in Shen

The owner's direction (12 November 2026): the machinery around the Shen model
should itself be Shen, not Python or JavaScript. This directory is where it
moves to, piece by piece. Host: Shen/JIT 0.7, using its own JSON, buffer and
subprocess libraries.

## What runs today

```sh
sh harness/run-solo5-pure-call.sh          # Solo5 guest against the model, full scope, ~5 s
sh harness/run-solo5-pure-call.sh exact    # exact arithmetic: C guest against the model, ~4 s
sh harness/run-model-vs-candidate.sh       # JavaScript implementation against the model, ~11 s
```

[common.shen](common.shen) holds what the programs share: turning a program
(decoded JSON) into a model state as data, running the model, putting its
observations in JSON shape, and comparing JSON values regardless of key order.
Nothing is printed and re-read between the harness and the model: they are one
Shen process.

**[solo5-pure-call.shen](solo5-pure-call.shen)** runs the model on each program,
launches the Solo5 tender on the guest image, parses the guest's frames
strictly, compares every step, then reruns the guest with each injected defect
and requires that the comparison detects it.

| Batch | Programs | Steps | Result |
| --- | --- | --- | --- |
| Hand, generated and 5-node exhaustive | 5,774 | 86,286 | No difference; defects detected on 4,019 and 238 programs |
| Exact arithmetic (`exact`) | 8,745 | 78,639 | No difference; 975 Overflow, 33 DivZero; defects detected on 8,712 and 975 |

The exact-arithmetic batch is every binary I64 operation over a 33-value
boundary set squared, and negation over the set, each as a whole program. No
expected results are attached. The two sides are independent by construction:
the guest uses the C compiler's checked 64-bit arithmetic, the model uses
decimal digit lists. This replaces Python's exact integers as the independent
side of the arithmetic ledger, as the owner agreed.

**[model-vs-candidate.shen](model-vs-candidate.shen)** launches `node` on the
existing batch runner for the JavaScript implementation and its three mutants,
runs the model here, and compares. At the 5-node bound: 5,695 of 5,695 programs
agree (81,063 steps; 4,350 Ok, 595 DivZero, 517 Bounds, 233 Overflow), with
reverse-operands killed on 3,940, arm-by-position on 975 and wrap-overflow on
233, and no mutant crash. Those are the counts the Python checker
the former Python checker reported for the same scope.

The same comparisons took about 100 s and 82 s through the Python route, most
of it printing Shen terms and parsing them back.

## The proposed gate

```sh
sh harness/run-hand-cases.sh
sh harness/run-gate.sh
```

**[hand-cases.shen](hand-cases.shen)** checks the 24 hand fixtures: the model
and the sandboxed JavaScript implementation agree step for step, every closure
descriptor the implementation reports was produced by the model, and both
satisfy the 42 hand-written expectations (outcome, step staging, return frame
count, depth bound, descriptor count, emission order). Each kind of expectation
was confirmed to fail when its expected value is corrupted.

**[gate.shen](gate.shen)** is the registered TC0-A gate evaluator
(`tc0-a-qualification` in `.pi/fenrir-workflow.json`), with the manifest
`spec/tc0/tc0-a-requirements.json`. It replaced the Python evaluator on 13
November 2026; [the switch record](../campaigns/tc0/G1_SHEN_EVALUATOR_SWITCH.md)
says on what basis and what differs. It keeps the former gate's rows, claims
and aggregation: any required FAIL gives FAIL, else BLOCKED, else UNKNOWN, else
PASS. Its verdict counts as a qualification only while the manifest is
owner-accepted and the workflow names this evaluator. Each comparison runs as
its own harness process, with the JavaScript implementation sandboxed.

An evaluator error, a check that does not report, or a check the evaluator
does not know is UNKNOWN, never a pass. Rows on a committed tree:

| Row | Status | Why |
| --- | --- | --- |
| source-identity | PASS on a clean tree | |
| toolchain-pinned | PASS | The gate runs on the flake's `shen-jit` output (Shen/JIT v0.7, pinned by commit and hashes) |
| unit-suite | PASS | |
| hand-agreement-and-replay | PASS | 24 cases, 42 expectations, strict replay admitted for all 24 |
| exact-arithmetic | PASS | C guest against the model, 8,745 programs |
| exhaustive-small | PASS | 5,695 programs |
| three mutant rows | PASS | 3,940, 233 and 975 programs |
| catalog-coverage | PASS | [coverage.shen](coverage.shen): 112 of 112 catalog transitions, over the run's hand and exhaustive traces |
| discovery-reduction-replay | PASS | [reduction.shen](reduction.shen): arm-by-position found at case 12, 64 to 17 nodes; reverse-operands at case 0, 64 to 15 nodes; both replayed |
| candidate-boundary | PASS | Existing JavaScript probe tool |
| requirement-ledger | PASS | Existing JavaScript checker |
| independent-repair-fresh | PASS | [repair-evaluation.shen](repair-evaluation.shen): all ten steps |
| independent-repair-isolation | PASS, with the recorded owner waiver | |
| solo5-guest-agreement (optional, new) | PASS | 5,774 programs |

Verdict on a committed tree, 13 November 2026: **PASS**, 15 of 15 required rows and all six claims, in about two minutes, with the recorded repair-isolation waiver reported. That was a direct run, not a run through the workflow controller on a supported runner, so there is no qualification receipt yet. It includes the HEAD-drift fix of PR #6: the final
check reads HEAD directly and compares it with the head recorded by the
source-identity row.

## TC1: effects and handlers

```sh
sh harness/run-tc1-handlers.sh          # model against the JavaScript implementation
sh harness/run-solo5-pure-call.sh tc1   # model against the Solo5 guest
```

**[tc1-handlers.shen](tc1-handlers.shen)** checks both slices of the TC1 effect
contract ([spec/tc1/EFFECTS.md](../spec/tc1/EFFECTS.md), a draft for owner
review): tail-resumptive handlers, and explicit one-shot resumptions with
`resume` and `discontinue`. On twenty hand fixtures the Shen model
(`models/tc1/handler-machine.shen`) and an independent JavaScript
implementation (`runtime/tc1/handler-machine.mjs`) agree step for step over
625 steps, both satisfy 51 handwritten expectations (outcome, order of
performed operations, emission order, and three complete hand-derived step
traces), and six defects injected into the implementation are each detected.

The same twenty programs run in the Solo5 guest (the C machine was extended)
and agree with the model step for step. The two checks are optional gate rows,
`tc1-handler-slice` and `tc1-handler-guest`.

Which machine runs a program is decided by its schema; `common.shen` loads
both models. `expectations.shen` holds the expectation checks the hand-case
and handler programs share. Performs are read from step records: a user effect
produces no event.

Not done for TC1: generated or exhaustive handler programs, reduction, strict
replay and catalog coverage.

## TC1: structured tasks and bounded channels (slice C1)

```sh
sh harness/run-tc1-tasks.sh             # hand fixtures, model against the JavaScript implementation, ~3 s
sh harness/run-tc1-task-explore.sh      # exhaustive-small: the commuting obligation, ~4 min
```

Contract: [spec/tc1/CONCURRENCY.md](../spec/tc1/CONCURRENCY.md), draft 1, for
owner review (its §13 lists the provisional choices). Model
`models/tc1/task-machine.shen` (new; every non-C1 step of a task is the handler
machine's `tc1.step`, unchanged); independent implementation
`runtime/tc1/task-machine.mjs` (each task a thread extending the JavaScript
handler machine by import). The schedule is an explicit input of both: a list of
task IDs, one per step. A policy (lowest, highest, seeded random, FIFO
production, production random, or a script) is turned into such a list by
`tools/tc1/task-schedule.mjs`; the model replays it and rejects any choice that
is not Runnable in its own state.

**[tc1-tasks.shen](tc1-tasks.shen)**: 18 hand fixtures
(`fixtures/tc1/task-hand-cases.mjs`), expectations written from the contract
before either machine existed, each under 8 or 9 schedules: 151 runs (54 of
them production schedules), 7,167 model steps. Model and sandboxed
implementation agree step for step on all 151 (step records include events,
the scheduling-point flag and the Runnable set); 619 handwritten expectations
hold; every schedule a production policy recorded is a production schedule by
the model's own records. All nine injected defects are killed: stale waiter (6
runs), waiter not woken (15, plus 2 crashes not counted), waiter woken twice
(6), eager cancellation (19), LIFO channel (7), no sibling cancellation (14),
capacity off by one (7), lost wakeup on close (8), lost wakeup on await (48).
Each of the twelve kinds of expectation was confirmed to fail when its expected
value is corrupted. One expectation was wrong when the machines first ran (it
assumed task IDs independent of the schedule); the machines were right, and it
is recorded in the fixture file's `CONTRADICTIONS`.

**[tc1-task-explore.shen](tc1-task-explore.shen)**: grammar G
(`tools/tc1/task-enumerate.mjs`), 3,600 programs of 2–3 tasks and one or two
channels of capacity 1–2, the count also derived in Shen from the alphabets.
For each program, ALL reference schedules and ALL production schedules are
explored on the model, depth first, deduplicated on (full machine state,
observation so far), with exact schedule counts:

| | States | Edges | Schedules | Observation classes |
| --- | --- | --- | --- | --- |
| Reference | 6,418,123 | 16,445,093 | 3,696,932,815,483,313,948,689 | 15,808 |
| Production | 2,669,664 | 3,346,356 | 11,937,126 | 15,808 |

No bound hit (400 steps per schedule, 2,000,000 states per exploration; the
largest exploration had 8,901 states). On all 3,600 programs the two
observation sets are equal and the production set is contained in the reference
set. Both broken variants fail the check: production not switching after
`send` on 493 programs, cancellation delivered at any step (a pure step reading
another task's request) on 373. The sandboxed implementation runs one witness
schedule for every one of the 15,808 reference observation classes and agrees
with the model step for step on all (777,583 steps). The defects run on the
first witness of each program only, a sample, reported and not required: all
but `stale_waiter` are killed there.

Not done for C1: generated (random) programs beyond G, reduction, strict replay
tapes, catalog coverage, the Solo5 guest, the frontend. Evidence is bounded
exploration, development grade; the fixtures, both machines and the harness
share one author lineage.

## What is still not Shen

| Piece | Now | Notes |
| --- | --- | --- |
| Guest image build: generate programs, validate, lower to C data, compile | JavaScript (`tools/solo5/freerun-pure-call.mjs --build-only`) | The harness trusts this only to produce the two inputs it is given; a wrong batch shows up as a comparison failure or an identity mismatch |
| Second implementation | JavaScript (`runtime/tc0/`) and C (`backends/solo5/pure-call/`) | Stays non-Shen on purpose: it has to be independent of the model |
| Validator | JavaScript | Natural fit for Shen sequent rules; this is also Fenrir's type checker in the amendment |
| Generators, enumerator, reducer | JavaScript | Plain list processing |
| Solo5 host tooling of the earlier Docker profile | Python and Go | Superseded in part by the stock-tender lane |

## Limits of what runs today

- The individual harness programs report development evidence,
  `qualification: UNKNOWN`. Only the gate issues a verdict.
- The model's integers are decimal strings (`models/tc0/i64.shen`), because
  Shen/JIT integers are 62-bit. `tools/tc0/check-i64.mjs` compares that
  arithmetic with exact results on 5,478 boundary cases.
- The harness and the model run in one Shen process. A bug in Shen/JIT itself
  could affect both; the guest is the independent side.
- Entry input is fixed at `["int","0"]`.
- Shen/JIT is pinned in the flake (`nix build .#shen-jit`). The runner scripts
  use that output when nix is available; see [jit.sh](jit.sh).
