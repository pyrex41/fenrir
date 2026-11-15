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
