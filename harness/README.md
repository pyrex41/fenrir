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
sh harness/run-tc1-handlers.sh                     # hand fixtures, model against the JavaScript implementation
sh harness/run-tc1-exhaustive.sh                   # 12,693 enumerated handler programs, the same comparison
sh harness/run-solo5-pure-call.sh tc1              # hand fixtures in the Solo5 guest
sh harness/run-solo5-pure-call.sh tc1-exhaustive   # the enumerated programs in the Solo5 guest
sh harness/run-tc1-random.sh                       # 20,000 generated handler programs: model, implementation, Solo5 guest; ~2.5 min
sh harness/run-tc1-random.sh 20 1000 noguest       # the same without the guest, ~1 min
sh harness/run-tc1-random-control.sh               # that check must fail with each injected defect switched on
sh harness/run-tc1-reduce.sh                       # find, shrink and replay a failure per injected defect, ~30 s
sh harness/run-tc1-gate.sh                         # the TC1 gate, about 9 minutes
```

The contract is [spec/tc1/EFFECTS.md](../spec/tc1/EFFECTS.md) (draft); its §9
has the numbers. In short:

- **[tc1-handlers.shen](tc1-handlers.shen):** twenty hand fixtures covering
  tail-resumptive handlers and explicit one-shot resumptions; model and
  implementation agree and both meet 51 handwritten expectations.
- **[tc1-exhaustive.shen](tc1-exhaustive.shen):** every program of a bounded
  handler grammar up to 7 nodes, 12,693 programs. Model and implementation
  agree on all of them, and each of the implementation's six injected defects
  is detected. The harness derives the expected program count itself and fails
  if the batch differs from it.
- **[tc1-coverage.shen](tc1-coverage.shen):** all fifteen handler step kinds of
  the contract's step table are exercised.
- **[tc1-gate.shen](tc1-gate.shen):** a separate gate for TC1 with twenty-one
  required rows. One is a passing TC0-A gate on the same commit; two are the
  checks of remote perform below. It was registered on 15 November 2026 by the
  owner's instruction, as the check `tc1-qualification` with the manifest
  `spec/tc1/tc1-requirements.json` (status `owner-accepted`); the
  [registration record](../campaigns/tc1/TC1_GATE_REGISTRATION.md) says on
  what basis, what the gate does not show, and how to revoke it. Its report
  says `authority: owner-accepted, registered` and its `qualification` is its
  verdict, by the rule the TC0-A gate uses. On a committed tree the verdict is
  PASS on 21 of 21 required rows. That was a direct run, not a run through the
  workflow controller on a supported runner, so there is no qualification
  receipt.

### Remote perform

```sh
sh harness/run-tc1-remote.sh        # the model of remote perform, explored exhaustively on small systems
sh harness/run-tc1-remote-run.sh    # the real system (Erlang/OTP supervisor, two Solo5 spt guests) against that model, ~40 s
```

Contract and numbers: EFFECTS.md §12 (§12.8 for the model, §12.11 for the
implementation). **[tc1-remote-run.shen](tc1-remote-run.shen)** starts the
supervisor of [supervisor/](../supervisor/README.md) once per schedule,
replays the event log it recorded through the model, checks the properties of
[tc1-remote-properties.shen](tc1-remote-properties.shen) on the replay, and
compares the guests' console frames and the peer's store with what the model
says.

Both are rows of the TC1 gate ([tc1-remote-rows.shen](tc1-remote-rows.shen)),
each with its negative control run first:

| Row | Evidence class | Needs | Otherwise |
| --- | --- | --- | --- |
| remote-model | Model-level bounded exploration; no implementation is run | Eight systems explored with no property failing, every step kind taken, eleven mutants killed, fourteen hand schedules passing, control failed as required | FAIL; a report with other counts is UNKNOWN |
| remote-run | Observed histories on `spt` accepted by the model | 19 hand, 40 seeded and 4 free-running schedules all accepted, every step kind taken, seven defects killed, control failed as required | FAIL; no Erlang/OTP or no Solo5 build is BLOCKED; a supervisor that does not compile, or other counts, is UNKNOWN |

Those counts are the scope after Amendment 1 of the
[registration record](../campaigns/tc1/TC1_GATE_REGISTRATION.md) (16 November
2026); they were 6, 9, 9 and 13, 40, 3, 5 when the gate was registered.

The gate's toolchain row also requires that the Erlang/OTP found by
[find-erlang.sh](find-erlang.sh), which the runner script uses too, is the
flake's `erlang` output.

A peer killed between its durable commit and its reply (EFFECTS.md §12.7,
owner ruling of 15 November 2026) is a step of the model, a hand schedule and
a possible choice of the seeded schedules in both checks, and one free-running
run kills the peer there from outside.

Three things came with the owner's rulings of 16 November 2026 (EFFECTS.md
§12.10 questions 4, 5 and 8), and each is in both checks as steps of the
model, hand schedules, a defect that must be caught, and choices open to the
seeded schedules:

- The outcome `peer_down` is now `not_delivered`, and the step
  `not-delivered` is enabled for any pending request that does not count as
  handed over, with the peer up or down. One free-running run makes the
  supervisor lose a request and report it.
- `supervisor-restart`: the supervisor loses the messages in flight and its
  record of hand-overs, and every request id issued before counts as handed
  over. In the run check the relay process is really killed and started again
  while the guests run, and the judgement also requires one relay process
  more than the restarts in the log. It is a step of scheduled runs only.
- A key reused with another argument is answered `conflict`, inside `reply`:
  the act step has a third result beside applied and replayed, and the peer's
  store file is compared record by record, argument included.

### The generated family

[tc1-generate.shen](tc1-generate.shen) builds a handler program from a list of
non-negative integers. Every decision the generator makes takes the next number,
so the list is the program; the all-zero list is the program `0`. The grammar
is the enumerator's without the 7-node bound (main bodies of up to 40 nodes),
plus more literals and arithmetic (Overflow as well as DivZero), a second
emission, and a third effect with two operations, one returning Bool. Programs
are valid by construction: types, effect sets and exactly-once use of a
resumption. The lists come from a Lehmer generator on fixed seeds.

- **[tc1-random.shen](tc1-random.shen):** 20 seeds, 1,000 programs each
  (`run-tc1-random.sh SEEDS PER_SEED` changes both). The validator accepted all
  20,000; one rejection fails the check. Model and implementation agree on all
  of them, 1,394,978 steps, and so does the Solo5 guest, built as one image per
  seed ([tc1-random-guest.shen](tc1-random-guest.shen)). The step bound is 1,000
  here, not 200: 159 programs reach it, and count as agreeing when all sides
  stop there with the same steps.

  | What the 20,000 programs do | Programs |
  | --- | --- |
  | perform an effect | 10,128 (50.6%) |
  | return from a tail-resumptive clause | 6,329 (31.6%) |
  | resume explicitly | 4,571 (22.8%) |
  | discontinue, and so abandon a suspended segment | 1,225 (6.1%) |
  | trap (2,412 Overflow, 336 DivZero) | 2,748 (13.7%) |
  | trap inside a clause | 315 (1.5%) |

  Main bodies by node count, in fives from 1–5 to 36–40: 1,503, 1,139, 1,728,
  2,172, 2,747, 3,082, 3,621, 4,008. Handlers nest up to 6 deep (1,955 programs
  have none, 7,913 nest two). All fifteen step kinds of the contract's table
  occur, and 17 of the machine's 18 rules (no MatchReturn: the family has no
  datatypes). The check fails if no program performs, resumes, discontinues or
  abandons.
- **Negative control:** with any one of the six injected defects switched on
  in the implementation, the same check on one seed fails; with none it passes.
- **[tc1-reduce.shen](tc1-reduce.shen):** for each injected defect, the first
  generated program on which it fails, shrunk on the choice list: delete
  chunks, replace a subterm by one of its own subterms, zero and lower entries;
  regenerate; keep the candidate if the defect still fails on it. A crash is
  not a failure. From 17, 17, 17, 21, 33 and 26 nodes down to 4, 4, 6, 6, 4
  and 8 (forgotten-resume, double-resume, outermost-handler, shallow-resume,
  dynamic-clause-environment, resume-returns-argument).
- **[tc1-replay.shen](tc1-replay.shen):** a fresh process regenerates each
  original and shrunk program from its recorded list and confirms that the
  undefective implementation agrees with the model and the defective one
  differs, on the shrunk program at the recorded step.

What this does not show. The family is a sample from one generator, not a
scope: 18,985 of the 20,000 programs are distinct (counted once by hand, not
by the harness), and it has no closures, datatypes, tuples or bytes, no
Unit-typed operations, and only I64-typed handles. Shrinking stops at a small
failing program, not a proven smallest one: the exhaustive family kills
outermost-handler and shallow-resume at 5 nodes and resume-returns-argument
at 7. Shrinking judges candidates against the model and the JavaScript
implementation only; the guest is not rebuilt per candidate. Replay re-runs
and re-compares; it is not strict replay against a recorded tape.

[gate-core.shen](gate-core.shen) holds what the two gates share: row
evaluation, aggregation, claims, the drift check and the controller record.
Each gate file supplies its manifest, its registration rule and its checks.
`tc1-defects.shen` holds the defect classification and the model-against-implementation
comparison the handler programs share; `tc1-step-kinds.shen` the step kinds of
the contract's table; `tc1-random-rows.shen` the gate rows for the generated
family; `expectations.shen` the expectation checks.

Which machine runs a program is decided by its schema. Performs are read from
step records: a user effect produces no event.

Not done for TC1: an exhaustive scope above 7 nodes, and strict replay.

## Frontend

`sh frontend/fenrir.sh run FILE` elaborates a program written in the surface
syntax ([spec/tc1/SURFACE.md](../spec/tc1/SURFACE.md), draft), has the
JavaScript validator check the artifact, and runs it on the model in the same
process, reusing `common.shen`. `sh frontend/test.sh` is its test suite. It is
not part of either gate.

## What is still not Shen

| Piece | Now | Notes |
| --- | --- | --- |
| Guest image build: generate programs, validate, lower to C data, compile | JavaScript (`tools/solo5/freerun-pure-call.mjs --build-only`) | The harness trusts this only to produce the two inputs it is given; a wrong batch shows up as a comparison failure or an identity mismatch |
| Second implementation | JavaScript (`runtime/tc0/`) and C (`backends/solo5/pure-call/`) | Stays non-Shen on purpose: it has to be independent of the model |
| Validator | JavaScript | Natural fit for Shen sequent rules; this is also Fenrir's type checker in the amendment |
| Generators, enumerator, reducer | JavaScript for TC0-A and the TC1 enumerator; Shen for the TC1 generated family and its shrinker | Plain list processing |
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
