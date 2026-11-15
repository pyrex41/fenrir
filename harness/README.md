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
| Guest image build: generate programs, validate, lower to C data, compile | JavaScript (`tools/solo5/freerun-pure-call.mjs --build-only`, `tools/solo5/control-pure-call-build.mjs`) | The harness trusts this only to produce the two inputs it is given; a wrong batch shows up as a comparison failure or an identity mismatch |
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
