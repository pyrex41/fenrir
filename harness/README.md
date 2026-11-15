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
sh harness/run-tc1-gate.sh              # the proposed TC1 gate, about 9 min (runs the TC0-A gate and the three optional rows too)
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

Three optional rows (`required: false`; no claim and no required row relies on
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
report). The accepted-job exploration (`service-explore.shen`) is not a row: it
checks the service contract of application example A1, which is not part of
slice TC1.

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

Not done for C1: generated (random) programs beyond G, reduction, strict replay
tapes, catalog coverage, the Solo5 guest, the frontend. Evidence is bounded
exploration, development grade; the fixtures, both machines and the harness
share one author lineage.

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
histories: a response without a commit, a duplicated mutation on retry, a cross-tenant
effect, a job lost after acceptance and others, with accepted controls) are run by every
check. Measured numbers: [04_DIRECTION_AMENDMENT.md](../04_DIRECTION_AMENDMENT.md) §8,
stage A3.

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
