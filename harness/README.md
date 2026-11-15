# Harness in Shen

The owner's direction (12 November 2026): the machinery around the Shen model
should itself be Shen, not Python or JavaScript. This directory is where it
moves to, piece by piece. Host: Shen/JIT 0.7, using its own JSON, buffer and
subprocess libraries.

## What runs today

```sh
sh harness/run-solo5-pure-call.sh          # Solo5 guest against the model, full scope, ~5 s
sh harness/run-solo5-pure-call.sh exact    # exact arithmetic: C guest against the model, ~4 s
sh harness/run-solo5-control.sh            # Solo5 guest under host-selected steps, strict replay, ~20 s
sh harness/run-solo5-tasks.sh              # TC1-C1 tasks in the guest, host-selected schedules and guest FIFO, ~20 s
sh harness/run-tc1-task-loop.sh            # TC1-C1 generated family, coverage, campaigns, replay, ~2 min
sh harness/run-model-vs-candidate.sh       # JavaScript implementation against the model, ~11 s
```

Solo5 checks need Solo5 v0.9.3 at the pinned commit. `harness/solo5.sh` picks, in order,
`FENRIR_SOLO5` (a directory), a hand-built `build/vendor/solo5`, or the flake's
`nix build .#solo5` output; with none available the Solo5 row is BLOCKED (and
`frontend/test.sh` says it skipped Solo5). Shen/JIT works the same way (`FENRIR_SHEN_JIT`,
`harness/jit.sh`).

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

**[solo5-control.shen](solo5-control.shen)** is the host side of
[the control protocol](../spec/solo5/pure-call-control-v1.md): the guest takes a step
only when this program asks for one. It launches the stock `solo5-spt` with the guest's
two net devices on its own pipes (`--net:ctlin=@0 --net:ctlout=@2`; no helper process),
frames and parses every byte itself, and fails closed. For each program it boots the
guest, checks Hello and Init/Ready against the batch and against SHA-256s it computes
itself over the artifact bytes it gives the model, then sends Run requests on a schedule
it chooses, compares each returned step with the model's next step in this process,
and at the first difference sends Terminate. It then:

- runs every program in `normal`, `reverse-operands` and `wrap-overflow` mode, and checks
  against the unchanged free-run guest over the same batch that each controlled run
  stopped exactly at the first diverging step and reported what the free run did;
- shows a stop mid-program and that the guest does not move without a request (silence
  for 300 ms, unchanged digest and epoch, a half-sent request answered only when whole);
- records a tape of each hand and TC1 run, replays each on 3 cold boots (one on 10) with
  byte-identical frames required, re-records all and requires identical tapes, and
  rejects 16 kinds of tape drift;
- sends 25 hostile requests to the real guest and feeds 21 hostile guest outputs through
  its own parser, plus three non-responding peers, which must be HarnessTimeout or a
  protocol failure, never a pass; and checks the spec's byte vectors.

| Scope | Programs | Steps compared | Result |
| --- | --- | --- | --- |
| Hand (`/1`, `/2`), TC1 fixtures, every 25th 5-node exhaustive program | 271 | 4,658 | No difference; `reverse-operands` caught on 196, `wrap-overflow` on 15, each at the exact first diverging step |
| Replay | 43 tapes × 3 cold boots, one × 10 | — | Exact on every boot; re-recordings byte-identical |

The negative tests and the rejection each must produce:

| Group | Tests (expected) |
| --- | --- |
| Tape drift | wrong artifact hash, protocol version, machine profile, guest image (`Incompatible:*`); missing, extra, reordered record (`Structure:Sequence`), and each renumbered to look consistent (`Diverged` at the first differing frame); edited response (`Diverged`), edited without resealing (`TapeIntegrity:Digest`); terminal claimed and then run on (`Structure:AfterTerminal`), terminal claimed early but consistent (`Diverged`); truncated tape, missing footer (`TapeIntegrity`) |
| Hostile host → guest (Error code, exit 3) | bad magic, wrong direction, unknown type, bad header, out-of-order and duplicate sequence, oversize, truncated header and payload, bad trailer, control byte, non-canonical number, reordered keys, kind/type mismatch, budget 0 and 65, Run before Init, second Init, wrong artifact, protocol, batch and mode, Run after completion, garbage after Terminate, hangup |
| Hostile guest → host | bad magic, wrong direction, unknown type, bad header, truncated header and payload, duplicate and out-of-order sequence, oversize, bad trailer, control byte, not JSON, kind/type mismatch, wrong response type, more steps than requested, epoch gap, wrong Hello protocol, wrong Ready artifact, an Error frame (`GuestError`), garbage after Bye; and the unmodified output as a positive control |
| Non-responding peer | `sleep` in place of the tender, and the real guest left without a request: `HarnessTimeout`; a peer dying mid-frame: `Protocol:Truncated` |

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
and agree with the model step for step.

Which machine runs a program is decided by its schema; `common.shen` loads
both models. `expectations.shen` holds the expectation checks the hand-case
and handler programs share. Performs are read from step records: a user effect
produces no event.

The TC1 loop, each program its own harness process:

```sh
sh harness/run-tc1-exhaustive.sh        # grammar H up to 7 nodes, ~30 s
sh harness/run-tc1-generated.sh         # generated family G, ~11 s
sh harness/run-tc1-reduction.sh DEFECT  # one discovery-reduction-replay campaign, 8-25 s
sh harness/run-tc1-strict-replay.sh     # ~9 s
sh harness/run-tc1-gate.sh              # the proposed TC1 gate, about 15 min (15 min 21 s measured; runs the TC0-A gate and the nine optional rows too)
```

| Program | What it checks | Measured |
| --- | --- | --- |
| [tc1-exhaustive.shen](tc1-exhaustive.shen) | Every program of grammar H up to 7 nodes, model against implementation, six defects | 12,693 programs, 263,222 steps, all agree |
| [tc1-generated.shen](tc1-generated.shen) | The 2,048 programs of family G (`tools/tc1/handler-generate.mjs`), beyond H: multi-operation effects, closures under other handlers, clauses continuing after resume, discontinue, traps; the handler behaviours its traces exercise ([tc1-features.shen](tc1-features.shen)); six defects | 2,048 agree over 80,611 steps; all ten behaviours exercised (7 to 332 programs each); every defect killed (21 to 572 programs) |
| [tc1-reduction.shen](tc1-reduction.shen) | Discover the first generated program showing a defect's discrepancy class, reduce by typed handler-aware proposals accepted only on fresh observations of the same class, replay original and minimized strictly | forgotten_resume and double_resume 61 to 4 nodes; outermost_handler 61 to 23; shallow_resume 56 to 12 |
| [tc1-strict-replay.shen](tc1-strict-replay.shen) | Tapes ([tc1-replay.shen](tc1-replay.shen), `tools/tc1/handler-replay.mjs`) for the hand fixtures and the retained failures (`fixtures/tc1/handler-retained-failures.json`) | 20 of 20 admitted; 8 retained admitted without the defect, 8 diverge at the retained epoch with it |
| [tc1-coverage.shen](tc1-coverage.shen) | Every handler step of the hand, exhaustive and generated traces against the hashed catalog `spec/tc1/handler-catalog.json`, with depth changes | 29 of 29 transitions; none outside the catalog |

Each of these was shown to fail when it should, on a copy of the tree: an
implementation fault made default (2,048 to 1,744 agreeing, hand fixtures
disagree, tapes not admitted), the generator without closures (one behaviour
unexercised), a wrong discrepancy class or a defect that always crashes (no
discovery), an edited retained case (campaign does not match it) or epoch
(replay does not diverge there), a wrong catalog pin, a removed, an extra and
a contradicted transition.

The proposed TC1 gate ([tc1-gate.shen](tc1-gate.shen), manifest
`spec/tc1/tc1-requirements.json`) on a committed tree, 15 November 2026: 18 of
21 required rows PASS; `tc0-a-gate`, `guest-hand-fixtures` and
`guest-exhaustive-small` are BLOCKED where Solo5 is not built, so the verdict
there is BLOCKED. Authority UNREGISTERED, qualification UNKNOWN.

Nine optional rows (`required: false`; no claim and no required row relies on
them, so the verdict is that of the 21 required rows) run after the required
ones. Each reads its harness program's own report, and none can pass without
that report: `task-hand-fixtures` (`tc1-tasks.shen`: PASS on `development-pass`,
FAIL on `development-fail`, UNKNOWN without a report),
`task-commuting-obligation` (`tc1-task-explore.shen`, about 4 min under an
1,800 s limit: PASS only with `scope_complete`, exactly 3,600 programs, no bound
hit, the obligation holding, both broken variants failing the check on some
program and every witness agreeing; UNKNOWN for an incomplete or truncated scope
or no report; FAIL otherwise) and `solo5-control-replay` (`solo5-control.shen` at
stride 25, about 20 s: PASS on `development-pass`, FAIL on `development-fail`,
BLOCKED where Solo5 or the guest build is unavailable, UNKNOWN on a timeout or no
report).

The last four cover the durable and typing work, each reading its
program's own report (none can pass without it; no claim relies on them):
`durable-hand-fixtures` (`tc1-durable.shen`: PASS on `development-pass`, FAIL on
`development-fail`, UNKNOWN without a report or on a timeout), `durable-guest`
(`solo5-durable.shen` over control protocol v2 on the D1 hand fixtures: PASS on
`development-pass` with every program agreeing, FAIL on a failing report, BLOCKED
where Solo5 or Shen/JIT is unavailable or the guest build exits nonzero, UNKNOWN on a
timeout or no report), `durable-validator-differential`
(`tools/tc1/validator-differential.mjs` against the validator at the parent of the D1
edit, read from git at a pinned revision and digest: PASS only with all 137,469 verdicts
identical and the 10 corpora at their pinned program counts, 24,153 programs; a
difference or other counts is FAIL; no old copy or no report is UNKNOWN) and
`typing-differential` (`typing/run.shen`, about 2.5 min: PASS only on
`development-pass` with no family whose acceptance disagrees and no probe on which the
Shen side departs from the contract; a derivation search out of budget, no report or a
timeout is UNKNOWN; FAIL otherwise). The validator differential is still meaningful
after the later effect-name fix (b4f4af2): run against the pre-D1 validator with the
current one, all verdicts are identical, so that fix changes no verdict on these corpora.

Each of the four was shown non-PASS on the real failing condition, reverted afterwards:
an expectation of the D1 fixtures changed (FAIL), `FENRIR_SOLO5=/nonexistent` (BLOCKED)
and an edited protocol vector (FAIL) for the guest, the validator changed so the input
schema check is gone (FAIL, 24,153 verdicts differ), and for typing the effect-set order
check removed from the JavaScript validator (FAIL), a derivation budget of 50 (UNKNOWN)
and a 5 s limit (UNKNOWN). The typing differential does not notice the removed input
schema check: its families do not exercise it.

Two more optional rows cover tasks through the stack, ledger row `TC1-C-TASKS`:
`task-solo5-guest` (`solo5-tasks.shen` over control protocol v3, about 45 s: PASS on
`development-pass` with no failure and no undetected defect, FAIL otherwise, BLOCKED
without Solo5 / Shen/JIT or when the guest build exits nonzero, UNKNOWN on a timeout or no
report) and `task-loop-closure` (`tc1-task-loop.shen`, about 135 s under a 600 s limit:
PASS needs `development-pass`, coverage status `complete`, the catalog pin holding, the
run's retained failures matching the committed `fixtures/tc1/task-retained-failures.json`
and every retained tape as expected; FAIL otherwise; UNKNOWN on a timeout or no report).

The accepted-job contract (A1) and its Fenrir handler (A2) are not part of slice TC1
and are not rows of this gate; they have their own proposed gate, below.

Not done for TC1: exhaustive exploration beyond grammar H, and reduction
campaigns for the two defects that show only through later values.

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

The two programs are optional rows of the proposed TC1 gate (`task-hand-fixtures`,
`task-commuting-obligation`), with ledger row `TC1-C-TASKS`; the contract is a
draft, so no claim relies on them.

**[solo5-tasks.shen](solo5-tasks.shen)** (`sh harness/run-solo5-tasks.sh`, about
20 s, 1,338 tender boots): the same slice in the Solo5 guest
(`backends/solo5/pure-call/tasks.c` over the unchanged handler machine), over control
protocol v3 ([spec/solo5/pure-call-control-v3.md](../spec/solo5/pure-call-control-v3.md)),
where the scheduler choice is an input. Batch: the 18 hand fixtures and every 50th
program of G (72). Measured 15 November 2026:

| Check | Measured |
| --- | --- |
| Reference, recorded schedules | the 151 (fixture, schedule) runs of `tc1-tasks.shen` (54 of production policies), the host naming every task: 151 of 151 agree with the model step for step, 7,167 steps; every production policy's schedule is a production schedule by the model's records |
| Reference, exploration witnesses | the G sample under one witness schedule per reference observation class, found in-process by the exploration of `tc1-task-explore.shen` (loaded as a library): 248 witnesses, 248 agree, 11,507 steps, no bound hit; consecutive steps of one task go in one Run |
| FIFO, guest's own scheduler | all 90 programs: the guest chooses, the host replays each choice on the model: 90 of 90 agree (4,051 steps), every guest schedule is a production schedule by the model's records and equals the FIFO schedule the batch declares |
| Guest defects | `cancel-off-point` killed on 18 runs, `lost-wakeup` on 48, `capacity-off-by-one` on 7, `fifo-reversed` on 18 of 18 FIFO runs (each of the 18 still agrees with the model and is a production schedule: only the comparison with the declared FIFO schedule catches it); no crash |
| Strict replay | 169 tapes (151 reference, 18 FIFO), each on 2 cold boots: all byte-identical; the 18 FIFO runs re-recorded: byte-identical tapes. The Run frames name the chosen tasks, so a tape binds its schedule |
| Negatives | 18 tape drifts (v1's 16, an edited schedule choice, a header naming the other scheduler), 15 hostile-host inputs (Run without a task under `reference`, with one under `fifo`, an unallocated task, non-canonical task, reordered keys, over budget, a v2 Reply frame, the v1 Init template, unknown scheduler and mode, the v2 protocol, Run after a deadlock, ...), 5 hostile guest outputs (Deadlock without a wait graph, a wait graph while Running, a record of another task, an unknown execution) and 10 v3 byte vectors: each as expected |

Free run: task programs are refused (the lowering rejects them for the free-running
image, which has no scheduler input); `guest.c` never sees one.

**[tc1-task-loop.shen](tc1-task-loop.shen)** (`sh harness/run-tc1-task-loop.sh`,
about 2 minutes; `stride N` samples G for coverage): the loop closed for C1 as the
handler slice closed it. Measured 15 November 2026:

| Part | Measured |
| --- | --- |
| Generated family | `tools/tc1/task-generate.mjs`, seed 1, 200 programs beyond G (3 or 4 tasks, nested scopes, a handler inside a task, a scope abandoned by `discontinue`, traps, one or two channels of capacity 1–2, close, cancel, await, channels made inside tasks), each under five policies: 1,000 runs (400 production), 84,452 model steps; model and sandboxed implementation agree on all 1,000; every production policy's schedule is a production schedule by the model's records; 736 complete, 264 deadlock. All nine defects killed there (stale waiter 4, waiter not woken 84, woken twice 43, eager cancel 254, LIFO 13, no sibling cancel 234, capacity 42, lost wakeup on close 29, on await 184; 2 crashes not counted) |
| Catalog coverage | [spec/tc1/task-catalog.json](../spec/tc1/task-catalog.json) (`tc1-task-catalog/1`, 53 transitions, pinned by SHA-256 in the harness): every C1 step of 151 hand traces, 15,808 exhaustive witnesses (all 3,600 programs of G, 777,583 steps) and 1,000 generated traces maps to a transition; 383,708 C1 steps classified, 485,494 handler steps inherited; 0 outside the catalog, 0 control, 0 depth and 0 scheduling-point mismatches, and every pure step is not a scheduling point; 53 of 53 transitions exercised; the channel queue invariant (§4) held after every model step of the hand and generated runs |
| Campaigns | four of the nine defects, each discovered on the first generated (program, schedule) showing its class, then reduced by typed, schedule-aware proposals (`tools/tc1/task-reduce.mjs`; every proposal revalidated, its schedule re-derived for it, accepted only when fresh model and implementation runs show the same class; 0 crashes, 0 proposals where model and implementation disagree): `lifo_channel` (received-other-value) 62 → 23 nodes, 138 → 52 schedule steps; `lost_wakeup_await` (termination-without-awaited) 78 → 10 nodes, 168 → 22 steps; `no_sibling_cancel` (failure-without-sibling-cancel) 61 → 11 nodes, 47 → 31 steps; `capacity_off_by_one` (send-admitted-over-capacity) 67 → 19 nodes, 110 → 40 steps. The 8 (program, schedule) pairs are retained in `fixtures/tc1/task-retained-failures.json` and the run must find exactly them |
| Strict replay | `tools/tc1/task-replay.mjs`, tapes that bind the schedule (its hash in the header, each step's task): 151 hand tapes replay exactly and are admitted; each retained failure's tape diverges at exactly its retained epoch with its defect and is admitted without (16 tapes); tapes with an edited choice, an edited step, another schedule, another program or another catalog are refused |

Every new check was shown able to fail: an edited catalog with the old pin
(`catalog_pin_holds` false), a wrong depth change for `scope/enter` with the pin
updated (depth mismatches), a wrong scheduling-point flag for `yield` (point
mismatches), a queue check made too strict (violations), and an edited retained
epoch (retained replay and matching fail) each turned the run into
`development-fail`.

Evidence is bounded exploration, development grade; the fixtures, the machines (Shen,
JavaScript, C) and the harness share one author lineage. Discovery takes the first
policy that shows the class (all four took `lowest` or `highest`); the reducer's
schedule-only proposals (another policy with fewer switches) were offered but none was
accepted in these campaigns.

## TC1: durable effects (slice D1)

```sh
sh harness/run-tc1-durable.sh        # model against sandboxed JavaScript, hand fixtures, ~1 s
sh harness/run-solo5-durable.sh      # the same fixtures in the Solo5 guest over control protocol v2, ~4 s
```

Contract: [spec/tc1/DURABLE.md](../spec/tc1/DURABLE.md). A durable effect that no user
handler encloses is a host request: the machine stops in `HostWait` with a
`HostRequest` observation and continues only with the host's reply, typed at the
boundary (an ill-typed reply is `HostViolation`, not a trap). Model:
[models/tc1/durable-machine.shen](../models/tc1/durable-machine.shen), a new file on
top of the unchanged handler machine; JavaScript:
[runtime/tc1/durable-machine.mjs](../runtime/tc1/durable-machine.mjs), extending the
JavaScript handler machine; C: `backends/solo5/pure-call` (`pc_reply`), driven over
[protocol v2](../spec/solo5/pure-call-control-v2.md) by
[solo5-durable.shen](solo5-durable.shen). Measured on 15 November 2026:

| Check | Result |
| --- | --- |
| Hand fixtures ([fixtures/tc1/durable-hand-cases.mjs](../fixtures/tc1/durable-hand-cases.mjs)), expectations written from DURABLE.md before any machine ran | 16 cases (12 Completed, 3 HostViolation, 1 AwaitingHost); model and sandboxed JavaScript agree step for step, 244 model steps; all 51 expectations hold; each of the 5 expectation kinds is shown able to fail (a perturbed expectation is reported) |
| Contradictions | one: the model accepted a reply with a field too many for a field-less constructor and then failed; the model was wrong, fixed, no expectation changed (`CONTRADICTIONS` in the fixture file) |
| JavaScript defects (killed / survived / crashed) | `double_reply` 10/6/0, `late_request_record` 15/1/0, `early_request` 15/1/0, `host_first` 2/14/0, `stale_handler` 1/15/0, `unchecked_reply` 3/13/0, `seq_reuse` 1/15/0 |
| Solo5 guest, protocol v2, one step per request | 16 of 16 agree with the model at every step: 244 steps, 568 frames, 15 replies sent; the 3 ill-typed replies are refused by the guest with `BadReply` before the program runs |
| Strict replay | 16 tapes exact on 3 cold boots each, re-recorded byte-identically; 3 v2 tape negatives (edited reply value `Diverged`, dropped reply `Structure:AfterTerminal`, reply while running `Structure:ReplyNotAwaited`); 7 hostile replies (`BadState`, `BadReply` ×4, `BadPayload`, `NotRunning`); 5 v2 byte vectors |
| v1 unchanged | `run-solo5-control.sh` after the change: 271 programs, 4,658 steps, defects 196 and 15, 43 tapes exact, as before |
| Validator | [tools/tc1/validator-differential.mjs](../tools/tc1/validator-differential.mjs) against the validator before the edit: 137,469 verdicts on 24,153 programs of 10 existing corpora plus 6 mutation kinds aimed at the edit, all identical |

Two hostile-tape predictions were wrong and corrected after the first run: a dropped
reply was predicted to diverge live and is refused earlier by the structure check, and
the reply-while-running edit was first written at the wrong frame.

## Service example A2: the handler in Fenrir

```sh
sh harness/run-service-fenrir.sh                  # default A1 scope, ~2 min (guest ~8 s)
sh harness/run-service-fenrir.sh replay-retained  # the 13 retained counterexamples, ~9 s
```

[examples/service/accepted-job.fen](../examples/service/accepted-job.fen) is the
accepted-job handler as a Fenrir program (8 functions, 121 nodes), with `atomic`,
`once` and `jobs-stage` as library functions in the same file; storage contract
[spec/service/HANDLER.md](../spec/service/HANDLER.md),
[models/service-a2/store-contract.shen](../models/service-a2/store-contract.shen).
[service-fenrir.shen](service-fenrir.shen) loads the A1 explorer and turns each handler
into an A1 machine: a `submit`/`complete` label runs the program on the Shen TC1-D1
model with the label's request as input and the A1 store as the host.

Default scope (A1's): 2 tenants, 2 keys, 2 digests; at most 3 submits, 2 deliveries,
2 responses, 1 crash. Measured on 15 November 2026:

| What | Result |
| --- | --- |
| Refinement | The handler's machine has A1's graph exactly: 251,374 product states, 122,801 system states, 1,093,203 edges, no violation of any of the 12 checks. Every handler step taken (3,336,483, the explorer's and the predicates') was compared with A1's `svc.step` from the same state: none differ |
| Runs | 88 run prefixes computed, 68 distinct completed runs (request, host replies); by determinism they cover every edge |
| JavaScript | the sandboxed TC1-D1 implementation agrees with the model on all 68 runs, 10,808 steps |
| Solo5 guest | protocol v2, all 68 runs agree at every step (10,808 steps, 68 replies, 21,956 frames); 68 tapes replay exactly on one cold boot each (quick mode) |

Handler mutants ([examples/service/mutants/](../examples/service/mutants/)), predictions
in [spec/service/fenrir-mutant-predictions.json](../spec/service/fenrir-mutant-predictions.json)
written before exploration; shortest counterexample per property (aim in bold):

| Mutant | Caught by | States |
| --- | --- | --- |
| respond-before-commit | **response 2** (`response.durable`), retry 2 | 251,374 |
| two-commits | **atomicity 1**, response 2, progress 3 | 677,782 (the in-flight second commit) |
| no-key-check | **retry 2**, atomicity 2, response 2 | 519,054 |
| wrong-tenant | **authority 1**, retry 2 (not predicted: the other tenant's key table answers) | 251,374 |
| conflict-undetected | **retry 2** | 176,142 |
| undeduplicated-delivery | **retry 2** (`retry.delivery`), progress 3 | 251,374 |
| commit-inside-atomic | **rejected statically** by the frontend: `Store` is not allowed in the lambda `atomic` wants at `(Unit --> Writes)` | — |
| equivalent-control | nothing; A1's graph | 251,374 |

Every predicted length was right; the one difference is the unpredicted retry failure
of wrong-tenant. All 13 counterexamples are retained in
[spec/service/counterexamples-a2](../spec/service/counterexamples-a2) and replay.
Limits: A1's scope only; capabilities are forgeable (DURABLE.md §9), so wrong-tenant
is caught dynamically, not refused; the host is A1's store under the stated contract,
not SQLite (that is A3); one author lineage for handler, contract, machines and harness.

## Service example A3: the real stack, history checked

```sh
sh host/service/check.sh          # quick; full: sh host/service/check.sh full
sh harness/run-service-history.sh FILE.json|LISTFILE   # check recorded histories
```

Stage A3 runs the A2 handler unchanged as a Solo5 guest under an OTP supervisor, with
SQLite behind the storage adapter ([host/service/README.md](../host/service/README.md),
contract [host/service/CONTRACT.md](../host/service/CONTRACT.md)). The campaigns record
every externally visible event as a history
([spec/service/HISTORY_FORMAT.md](../spec/service/HISTORY_FORMAT.md)) and
[service-history.shen](service-history.shen) decides whether the A1 model admits it: a
model execution with the same labels and responses, the observed stores, and every A1
property predicate holding on its states and edges (the model's own `svc.step` and
`svcp.*` functions; nothing reimplemented). Indeterminate outcomes and concurrent groups
are explored as choices. Verdicts: accepted, rejected (first inadmissible event),
indeterminate. Evidence: *observed history accepted; bounded crash campaign*. The
checker's negative tests ([tests/host/histories](../tests/host/histories), 18 fabricated
histories at stage A3, 31 files with A4's 13: a response without a commit, a duplicated mutation on retry, a cross-tenant
effect, a job lost after acceptance and others, with accepted controls) are run by every
check. Measured numbers: [04_DIRECTION_AMENDMENT.md](../04_DIRECTION_AMENDMENT.md) §8,
stage A3.

## The proposed service gate

```sh
sh harness/run-service-gate.sh          # the proposed service gate, about 5 min (4 min 43 s measured)
```

[service-gate.shen](service-gate.shen), manifest
[spec/service/service-requirements.json](../spec/service/service-requirements.json)
(`proposed`; authority UNREGISTERED, qualification UNKNOWN; not registered in the
workflow), on [gate-core.shen](gate-core.shen) with the same aggregation rule as the other
gates. It gathers the accepted-job work (contract A1, handler A2), which is not slice
TC1, so the TC1 gate has no row for it. Ten required rows, each reading the report of a
harness program: `source-identity`, `toolchain-pinned`, `service-unit-tests`
(`tests/service`), `a1-exploration` (`service-explore.shen` at the pinned scope: the model
complete and not truncated, every mutant caught, the equivalent control unflagged;
truncated or another scope is UNKNOWN), `a1-model-vs-js-differential` (629,165 runtime
edges), `a2-refinement` (`service-fenrir.shen`: the handler gives the A1 model's next state
and response on every edge, 3,336,483 steps), `a2-js-agreement`, `a2-solo5-agreement`
(the handler's runs in the host-controlled Solo5 guest, quick mode; BLOCKED without
Solo5), `a2-handler-mutants` (six caught, the control unflagged, `commit-inside-atomic`
rejected statically) and `retained-counterexamples-replay` (22 A1 and 13 A2 files, each in
a fresh process). Fields the rows rely on are those the programs report; nothing was
added to them. Bounded exploration at the stated scope, development grade; the
Shen-to-Rocq correspondence is by reading (ledger row `SERVICE-ACCEPTED-JOB`).

Five optional rows follow the required ones; none backs a claim, and an optional row's
FAIL, BLOCKED or UNKNOWN does not change the aggregate (the aggregation rule counts
required rows). Each decides on the fields its program reports and nothing was added to
them.

`a3-host-quick` (ledger row `SERVICE-A3-HOST`) runs the host,
`sh host/service/check.sh quick` (Erlang/OTP and SQLite from `.#fenrir-a3-tools`, about
6.5 min measured). It was pinned to stage A3's report (10 campaigns, 8 host mutants, 18
negative tests); stage A4 extended the same check, and the row now pins stages A3 and A4
together, as one row because it is one run: PASS only on `development-pass` with the unit
tests passing and all 15 campaigns' histories accepted (the 10 of A3 and `upgrade_cas`,
`upgrade_crash`, `upgrade_load`, `upgrade_manifest`, `upgrade_stale`; none rejected or
indeterminate, audits clean, scenario checks ok), the normal stack flagging nothing, every
one of the 18 host mutants but the documented `sync_off` caught (by `caught_by_history_checker`,
`caught_by_scenario_checks` or `caught_by_sqlite_audit`), `sync_off` reported as not
detectable by this campaign (power loss is not simulated), both equivalent controls
(`equivalent_control`, `equivalent_control_a4`) unflagged, and each of the history
checker's 31 negative tests (18 of A3, 13 of A4) `as_expected`; BLOCKED without the tools
or Solo5; UNKNOWN on a timeout or no report; FAIL otherwise.

Four optional rows cover stage A4 (ledger row `SERVICE-A4-UPGRADE`; the A4 history
negatives and host families are in `a3-host-quick`), at the A4 scope of
`harness/run-service-upgrade.sh` (2 tenants, 1 key, 2 digests; 2 submits, 2 deliveries, 1
response, 1 crash, 1 dispatch, 4 upgrade steps; cap 1,500,000), pinned by the evaluator:

| Row | Runs | PASS needs |
| --- | --- | --- |
| `a4-model` | `service-upgrade.shen` (about 6.5 min, about 4.3 GB) | `status` development-pass; `hand_traces.all_agree`; `model` complete, not truncated, 545,360 product states, 64,676 system states, 3,511,584 edges, no violation; `a1_subscope.agree` with both sub-scope models complete; each of the 12 mutants has `pass` and `caught_by`, `equivalent-control` caught by nothing; no entry in `properties_never_failing_on_a_mutant`, and in `checks_never_failing_on_a_mutant` only `recovery.obligations` and `progress.terminal-stable`, which A1's mutants cover. Truncation, another scope, graph or mutant set, a crash or no report is UNKNOWN |
| `a4-fenrir-refinement` | the frontend on the v1 and v2 handlers, the migration and the mutants of `examples/service/mutants-a4`, then `service-upgrade-fenrir.shen` sandboxed (about 6.5 min) | `refinement.refines`, `same_graph_as_a4_model`, `steps_differing` 0 of 8,652,088, `compare_and_swap_checks` 84 with `compare_and_swap_failures` 0, no violation, `javascript_sample` ran sandboxed and agrees on every one of 189 runs, 6 Fenrir mutants caught and both equivalent controls unflagged. Same UNKNOWN conditions |
| `a4-solo5-agreement` | `solo5-durable.shen` quick on the sample of the row above | the guest driven on as many `programs` as the sample has runs, all `programs_agreeing_with_model`; BLOCKED without Solo5 or when the guest cannot be built |
| `a4-retained-replay` | `replay` of each of the 43 files of `spec/service/counterexamples-a4` and 16 of `counterexamples-a4-fenrir`, each in a fresh process | every file reports `reproduced`; another count, no report or no elaboration in the run is UNKNOWN |

The proposed gate's full run, with these rows, takes about 30 minutes; it runs the heavy
programs strictly one after another (the A1 exploration peaks near 7.6 GB, A4 near 4.3
GB). The limits of the A4 rows are the ledger row's gaps: bounded scope (1 key, 2
submits), one author lineage, the choices of UPGRADE.md section 11 unconfirmed by the
owner, no rollback after migrate, the fencing of a stale v1 submit resting on a
column-count accident (as the A4 author reported), and fsync honesty untested.

## Service example A4: a versioned upgrade that preserves pending work

```sh
sh harness/run-service-upgrade.sh                    # the A4 model, ~7 min, ~4.3 GB
sh harness/run-service-upgrade.sh 2 1 2 1 1 1 1 1 3 200000   # a small scope, ~10 s
sh harness/run-service-upgrade.sh replay-retained    # the 43 retained counterexamples, ~10 s
sh harness/run-service-upgrade-fenrir.sh             # Fenrir handlers + migration, JS, Solo5, ~7 min
sh harness/run-service-upgrade-fenrir.sh replay-retained   # the 16 retained counterexamples
```

Contract [spec/service/UPGRADE.md](../spec/service/UPGRADE.md) (draft 1, version-pinned
runs, every job migrated by one atomic transition, fencing in the commit); model
[models/service-a4/upgrade.shen](../models/service-a4/upgrade.shen) on A1's own transaction
for v1, properties [upgrade-properties.shen](../models/service-a4/upgrade-properties.shen)
(A1's, carried across the upgrade on the v1 view of a state, and pending, receipts,
version and manifest checks: 18 checks in 10 properties). [service-upgrade.shen](service-upgrade.shen)
loads the A1 explorer as a library and explores the A4 model breadth first over
[State Monitor Budget], with six budgets (submits, deliveries, responses, crashes,
dispatches, upgrade steps). Evidence: *bounded exploration passed*, development grade.

Default scope: 2 tenants, 1 key, 2 digests; at most 2 submits, 2 deliveries, 1 response,
1 crash, 1 dispatched run, 4 upgrade steps. Measured on 15 November 2026:

| What | Result |
| --- | --- |
| Hand traces ([spec/service/upgrade-hand-traces.json](../spec/service/upgrade-hand-traces.json), written after the model and before anything ran) | 12 of 12 agree on the first run; no contradiction to record |
| A4 model | 545,360 product states (517,760 without the monitor), 64,676 system states (8,385 in each of `v1`, `prepared`, `migrated`; 39,521 in `v2`), 3,511,584 edges, depth 12, no violation, not truncated, no disabled alphabet step; 30 s |
| A1 sub-scope | the A4 model with no dispatch and no upgrade step gives A1's graph exactly at the same parameters (1,578 product states, 565 system states, 6,887 edges) |
| Fenrir machine ([service-upgrade-fenrir.shen](service-upgrade-fenrir.shen)) | v1 handler (A2's, unchanged), [accepted-job-v2.fen](../examples/service/accepted-job-v2.fen) and [migrate-v1-v2.fen](../examples/service/migrate-v1-v2.fen) on the Shen TC1-D1 model, with the A4 host contracts ([store-contract-v2.shen](../models/service-a4/store-contract-v2.shen)): the A4 model's graph exactly; 8,652,088 steps compared with the model's, none differ; 84 compare-and-swap checks (a v1 commit between the migration's snapshot and its install: `Changed`, nothing applied, then the migration of the new state), none fail |
| Runs | 1,048 run prefixes, 189 distinct completed runs (24 v1, 32 v2, 133 migration) |
| JavaScript | the sandboxed TC1-D1 implementation agrees on all 189 runs, 48,332 steps |
| Solo5 guest | protocol v2, all 189 runs agree at every step (48,332 steps, 1,962 replies, 97,609 frames), fuel 5000 (the batch's `fuel`, new optional member) |

Model mutants ([service-upgrade-mutants.shen](service-upgrade-mutants.shen)), predictions
in [spec/service/upgrade-mutant-predictions.json](../spec/service/upgrade-mutant-predictions.json)
written before they ran; the shortest counterexample per property (aim in bold) and, for
receipts, the retry check. Every predicted length was right at the default scope.

| Mutant | Caught by (length) |
| --- | --- |
| migration-drops-pending | **pending 3** (`pending.preserved`), atomicity 3, response 3, progress 4 |
| migration-not-atomic | **version 3** (`version.transitions`, `version.readable`), pending 3, progress 4 |
| cutover-before-migration | **version 2** (`version.transitions`; `version.readable` 3), pending 3, progress 4 |
| stale-v1-commit (no fencing) | **version 4** (`version.readable`), pending 4, progress 5 |
| keys-not-migrated | **receipts 3** (`receipts.immutable`; `receipts.retry-stable` 5: the retry re-applies), atomicity 3, response 3 |
| receipt-rewritten | **receipts 3** (`receipts.immutable`; `receipts.retry-stable` 5: the retry returns another receipt), response 3 |
| deliver-to-v1 | **version 5** (`version.readable`: a finished job with no attempt counted) |
| no-manifest-check | **manifest 1** |
| volatile-upgrade-state | **recovery 2** (`recovery.crash-frame`), version 2, pending 4 and progress 5 (not predicted: after the crash v1 is in force on a migrated store) |
| v2-shared-counter | **authority 4** |
| v2-duplicate-delivery-counted | **retry 5** (`retry.delivery`), version 6 |
| v2-retry-reapplies | **retry 5** (`retry.replay`), receipts 5, atomicity 5, response 5 |
| equivalent-control | nothing; the model's graph |

The last three were added after the first (small-scope) run showed authority and retry
never failing on an upgrade mutant; they were predicted before they ran. A1's
`recovery.obligations` and `progress.terminal-stable` fail on no A4 mutant (A1's mutants
cover them). Fenrir mutants ([examples/service/mutants-a4](../examples/service/mutants-a4),
predictions [upgrade-fenrir-mutant-predictions.json](../spec/service/upgrade-fenrir-mutant-predictions.json)):
v2-forgot-count-attempt (**version 5**), v2-stage-attempt-one (**version 4**),
migrate-drops-pending (**pending 3**, atomicity 3, response 3, progress 4),
migrate-rewrites-receipts (**receipts 3**, retry-stable 5, response 3), migrate-drops-keys
(**receipts 3**, retry-stable 5, atomicity 3, response 3), migrate-wrong-attempts
(**version 4**), all at the predicted lengths; v2-equivalent-control and
migrate-equivalent-control give the model's graph. Retained counterexamples:
[spec/service/counterexamples-a4](../spec/service/counterexamples-a4) (43, one per violated
check) and [counterexamples-a4-fenrir](../spec/service/counterexamples-a4-fenrir) (16); all
replay.

Two findings on the way. The migration was first written with one `snapshot` reply
holding every row: it ran in the Shen model and the JavaScript implementation but not in
the Solo5 guest, because control protocol v2 limits a host reply to 512 bytes
(`GuestError Oversize`); it now reads one row per request (UPGRADE.md §5). The Solo5
durable batch fixed fuel at 200, too few for a migration; `control-durable-build.mjs`
now takes an optional `fuel` from the programs file (default unchanged).

The real stack: [host/service/README.md](../host/service/README.md) ("Stage A4") and
[CONTRACT.md](../host/service/CONTRACT.md) §7; histories of schema `/2` are checked
against the A4 model by [service-history-upgrade.shen](service-history-upgrade.shen),
loaded by [service-history.shen](service-history.shen) (13 new negative and positive tests
in [tests/host/histories](../tests/host/histories), `a4-*.json`; `/1` histories are checked
as before).

## What is still not Shen

| Piece | Now | Notes |
| --- | --- | --- |
| Guest image build: generate programs, validate, lower to C data, compile | JavaScript (`tools/solo5/freerun-pure-call.mjs --build-only`, `tools/solo5/control-pure-call-build.mjs`) | The harness trusts this only to produce the two inputs it is given; a wrong batch shows up as a comparison failure or an identity mismatch |
| Second implementation | JavaScript (`runtime/tc0/`) and C (`backends/solo5/pure-call/`) | Stays non-Shen on purpose: it has to be independent of the model |
| Validator | JavaScript and Shen | The typing rules are Shen sequent rules now ([spec/tc1/TYPING.md](../spec/tc1/TYPING.md), `typing/`): structural checks, derivation search through `shen.typecheck`, and a small fixed checker that accepts or rejects each derivation; the frontend runs both and treats disagreement as a defect. `sh typing/run.sh` compares them on every family (one disagreement, the JavaScript side's, TYPING.md §11). The JavaScript validator stays as the independent second implementation. Claim: derivable under rule set R, soundness not yet proved |
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
- Entry input is fixed at `["int","0"]`, except for TC1-D1 programs, whose input is
  part of the case (fixtures) or the A1 label (the service handler).
- Shen/JIT is pinned in the flake (`nix build .#shen-jit`). The runner scripts
  use that output when nix is available; see [jit.sh](jit.sh).

## Service example A1: accepted-job exploration

```sh
sh harness/run-service-explore.sh                 # default scope below, ~2.5 min
sh harness/run-service-explore.sh 2 2 2 3 2 2 1 2000000 sandbox   # same, JS side sandboxed
sh harness/run-service-explore.sh replay spec/service/counterexamples/volatile-mailbox--recovery.json
sh harness/run-service-explore.sh replay-retained # every retained counterexample, ~6 s
```

**Evidence status: bounded exploration passed, development grade.** Not a
gate verdict (`qualification: UNKNOWN`), not a proof, not a refinement claim.

[service-explore.shen](service-explore.shen) explores the accepted-job contract
([spec/service/ACCEPTED_JOB.md](../spec/service/ACCEPTED_JOB.md); model
[models/service/accepted-job.shen](../models/service/accepted-job.shen)) breadth
first over product states (system state, property monitor, remaining budgets),
so identical system states with different monitor obligations never merge.
Every state predicate is checked on every reachable state and every edge
predicate on every explored edge. A step cut off by a budget is a counted bound
hit; exceeding the state cap is truncation, which fails the run. The first
violation of each check is a shortest schedule; one per violated property is
retained as JSON with a replay command that re-executes it in a fresh process.
Mutants are in [service-mutants.shen](service-mutants.shen), outside the model.

Scope (default): 2 tenants, 2 keys, 2 payload digests; per schedule at most 3
submits, 2 deliveries, 2 responses, 1 crash (a mutant's internal steps take no
budget). Measured on 15 November 2026 with Shen/JIT 0.7:

| What | Result |
| --- | --- |
| Hand traces ([spec/service/hand-traces.json](../spec/service/hand-traces.json), derived before the model ran) | 11 of 11 agree |
| Model | 251,374 product states (239,830 without the monitor, 122,801 system states), 1,093,203 edges, depth 8, not truncated, no violation of any of 12 checks; bound hits: 1,875,584 submit, 1,516,312 delivery, 273,752 response, 208,419 crash |
| Monitor split | 11,544 product states exist only because the monitor differs; witness: `submit(0,0,0) submit(0,0,0) crash` against `submit(0,0,0) submit(0,0,1) crash` |
| JavaScript implementation ([runtime/service/accepted-job.mjs](../runtime/service/accepted-job.mjs)), explored by its own driver | 629,165 of 629,165 distinct runtime edges identical (state, label, next state, response), none on one side only; same 239,830 states and 122,801 system states; 73,823,742 schedules within the budgets |

Mutants, shortest counterexample length per property that catches it
(aim in bold):

| Mutant | Caught by |
| --- | --- |
| volatile-mailbox | **recovery 3** (`submit, respond, crash`), atomicity 1, response 1, progress 3 |
| respond-before-commit | **response 1**, retry 2 (not predicted), progress 2 |
| non-atomic-write | **atomicity 1**, response 2, progress 3 (predicted 3 and 4) |
| retry-reapplies | **retry 2**, atomicity 2, response 2 |
| key-reuse-accepted | **retry 2** only |
| cross-tenant-counter | **authority 1** only |
| undeduplicated-delivery | **retry 2**, **progress 3** |
| volatile-status | **recovery 3**, **progress 3**, authority 3 (not predicted: a crash carries no tenant) |
| failure-not-terminal | **progress 2**, retry 2 |
| equivalent-control | nothing; same 251,374 states and 1,093,203 edges as the model |

Every property and every one of the 12 checks fails on at least one mutant;
all 22 retained counterexamples
([spec/service/counterexamples](../spec/service/counterexamples)) replay. The
last two mutants were added, with predictions, after the first run showed
`recovery.crash-frame` and `progress.delivery-terminates` failing on no mutant.
Shen time: model 17 s, differential 20 s (JavaScript side 12 s), mutants
100 s.

Limits: only the stated scope; the model and harness share one Shen process;
the Shen-to-Rocq correspondence is by reading; progress holds only under the
stated delivery-fairness and availability assumptions.
