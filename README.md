# Fenrir / Gleipnir

**Current stage: working research prototypes and a developing test harness—not a
usable or qualified programming language yet.** Fenrir is the planned language;
Gleipnir is the development, exploration and conformance harness.

## How far along are we?

We have moved beyond plans: there are executable Shen models, independently
structured development candidates, checked artifacts, hand fixtures, generated
counterexamples, reduction and strict replay. A small arithmetic candidate has
also run natively inside Solo5 with an external Shen comparison.

**TC0-A (the pure slice, G1) has a provisional, development-grade gate PASS:
single-author differential agreement, not independent qualification.** The gate
registered as `tc0-a-qualification` returns PASS on 15 of 15 required rows and all
six claims; committed receipts are in [`campaigns/tc0/receipts/`](campaigns/tc0/receipts/).
What that PASS does not establish is listed under
[Limits of the TC0-A PASS](#limits-of-the-tc0-a-pass): the model, candidate,
evaluator and injected defect share one author lineage, the repair was isolated by
instruction only, the scopes are bounded and the evaluator runs trusted-local. See
[the review](campaigns/tc0/G1_EVALUATOR_REVIEW.md). Later source changes need a
fresh run. Slices B and C, full TC0, native execution and everything after them
are not qualified.

## Limits of the TC0-A PASS

An external review (17 October 2026) re-ran the gate from a clean checkout and
reproduced every published count. It also found these limits, which stay open
until fixed:

- **No independent implementation.** One author lineage wrote the Shen model, the
  JS candidate, the Python glue that translates between them and the evaluator.
  Agreement rules out divergence, not a shared misreading of the spec. Only the
  exact-arithmetic ledger has a third-party oracle (Python integers).
- **The repair was easy to localize.** The S3 workspace withholds the mutant tooling
  but ships `tests/tc0/pure-data.test.mjs`. With the defect applied, three of its tests
  fail and point at the match arm. The repairer shared the packet author's model
  family, with isolation by instruction only.
- **Catalog coverage is self-referential.** The 112 transition keys are listed in
  `tools/tc0/pure-call-coverage.mjs`, not derived from `spec/tc0/pure-call-demo.json`,
  and the catalog has had no independent review.
- **Mutant rows are weaker than the plan's §16.** A kill is any trace difference,
  without a required classification or a retained reduced reproducer (bad-overflow
  has none). Three of the twelve mandatory mutants exist, and there is no
  equivalent-mutant control.
- **The oracle compares control flow, events and outcome**, not intermediate values,
  so a wrong value that affects neither goes unseen.
- **Most review decisions were the packet author's.** The owner registered the gate
  and accepted the isolation waiver; aggregation, survivor policy, protected inputs
  and the claim mapping were decided by the packet author
  ([decisions](campaigns/tc0/G1_EVALUATOR_REVIEW.md#decisions-2026-10-11)).
- **The candidate carries its own mutant switches** (`reverseOperands`,
  `armByPosition`, `wrapOverflow` in `runtime/tc0/pure-call-machine.mjs`).

A percentage would be misleading: a small demonstrated arithmetic/closure slice
is very different from the compiler, runtime and tools needed for the full vision.
Think of this as **early executable bootstrap work, before the first qualified
language release**.

| Area | What exists | What is not established |
| --- | --- | --- |
| Specification | v0.2 architecture, core contract and phased plan | Full frozen, executable acceptance authority |
| Pure-language development | Shen models and an independent candidate for the whole TC0-A expression grammar (schema `/2`: calls, closures, Bytes, TrapCode, tuples, datatypes, match, byte primitives, eq); closed validator; 24 hand fixtures; catalog coverage 112/112; every program of a bounded grammar up to 5 nodes (5,695) agreeing on two Shen ports; an exact-arithmetic ledger | Qualified TC0-A evaluation; independent catalog review |
| Counterexample loop | Generated discovery and typed reduction for three candidate mutants, exact original/minimized replay, and an S3 clean-room repair packet with a frozen, sandboxed evaluator; one independent repair evaluated DEVELOPMENT-PASS | Enforced repairer isolation (repair 1 used instruction-only isolation) and qualified acceptance |
| Native arithmetic spike | Small C/Solo5 candidate; historical model comparisons, hand cases, generated failure and cold replay | Full language backend, machine-level determinism, native startup/counter closure |
| Native host | Go orchestration, bounded readers/output, source inventories, owned process/container cleanup, session/replay and selected campaigns | Current-source live validation of recent repairs; full hostile-peer/corpus/perturbation obligations |
| Qualification | Registered TC0-A gate: provisional development-grade PASS with all six claims, under waivers and the [limits](#limits-of-the-tc0-a-pass) above; requirement ledger, pinned toolchain flake, measured candidate sandbox | Waiver-free G1 (enforced repairer isolation, an isolated evaluator); B/C/full TC0 qualification |
| Later language/product phases | Requirements and dependency order | Qualified handlers, concurrency/lifetimes/time, production compiler/runtime, practical surface language, package tooling and deployment |

The current pure candidates are development machines, not a production Fenrir
compiler or end-user language distribution. See [`runtime/tc0/`](runtime/tc0/),
[`models/tc0/`](models/tc0/) and [`tools/tc0/`](tools/tc0/) for the executable work.

## Latest pure-language progress

The integrated pure-call demo now has a second closed schema,
`tc0-a-pure-call-demo/2`. It adds the remaining TC0-A built-in data surface:
`Bytes`, the `TrapCode` enum, tuples (`tuple`/`project`), declared and
recursive datatypes (`construct`/`match` with exhaustive, duplicate-free
arms), `bytes_length`, `bytes_index` (`Bounds` trap), `bytes_concat` and
structural `eq` over equality-compatible types. Schema `/1` is unchanged and
still rejects all of these. Each feature is implemented independently in the
validator, the JS candidate and the Shen model, and is recorded in
[`spec/tc0/pure-call-demo.json`](spec/tc0/pure-call-demo.json) (catalog `/2`).

Evidence from this pass (development only):

- 10 new hand fixtures (`fixtures/tc0/pure-data-hand-cases.mjs`) agree step for
  step with the Shen model (shen-scheme v0.26 Linux binary), and all 19
  pure-call hand cases pass strict replay through `tc0-pure-call-oracle`.
- Five injected candidate defects were each caught by that check: a
  `bytes_index` off-by-one bound, a non-tail match arm, reversed tuple fields,
  a shallow `eq` and swapped constructor metadata.
- `tests/tc0/pure-data.test.mjs` adds 25 validator, machine, reducer and replay
  tests.

**Generated discovery and reduction (S2) over the data constructs.** A finite
deterministic family (`tools/tc0/pure-data-generate.mjs`, 24 configurations)
uses every schema `/2` construct in each case. The campaign driver
`tools/check-tc0-pure-call-reduction.py` now takes `--family` and `--mutant`.
It adds a data-specific candidate-only mutant, `--arm-by-position`, which
selects a match arm by the constructor's declared position instead of its
name. Each reduction proposal is revalidated and confirmed against fresh Shen
and candidate observations. A proposal is accepted when it keeps the same
discrepancy class; the outcome may change. New typed rules: `if-to-branch`,
`project-tuple-literal`, `match-to-arm`, `prim-to-operand`,
`call-to-argument` and `drop-tuple-element`, plus pruning of unused datatypes.

```sh
python3 -I tools/check-tc0-pure-call-reduction.py --shen-executable build/toolchain/shen-scheme \
  --family pure-data --mutant arm-by-position --max-cases 24 --wall-seconds 300 --output build/tc0/s2/arm.json
node tools/tc0/check-pure-call-failure-replay.mjs build/tc0/s2/arm.json build/tc0/s2/arm-replay.json
```

| Family / mutant | Discovered at | Attempts (accepted) | Nodes | Exact replay (first divergence) |
| --- | --- | --- | --- | --- |
| pure-data / arm-by-position | case 12 of 24 (cases 0–11 are equivalent declared-order survivors) | 35 (18) | 64 → 17 | original epoch 88, minimized epoch 29 |
| pure-data / reverse-operands | case 0 | 30 (10) | 64 → 15 | original epoch 20, minimized epoch 2 |
| pure-call / reverse-operands (regression) | case 0 | 36 (8) | 37 → 18 | original epoch 27, minimized epoch 9 |

The minimized arm-by-position failure returns the same value as the model
(`Rect`'s arm returns the same field as `Sq`'s). Only the step trace shows the
wrong arm was entered. A cold repeat of both pure-data campaigns reproduced
every observation, the reduction history and both failures identically. The
only difference was the Shen loader's nonsemantic `run time:` line. The
reverse-operands discovery at case 0 is trivial: every case emits from a
tuple. Reductions are smallest-found by typed rules, not globally minimal.

**Exhaustive-small scope.** `tools/check-tc0-pure-data-exhaustive.py` runs every
program of a bounded grammar G (defined in `tools/tc0/pure-data-enumerate.mjs`;
I64/Bool/Bytes/Opt/Pair/Tri expressions over all schema `/2` constructs plus an
emitting `tap` call). `Tri` is a three-constructor enum matched in all six arm
orders. It uses one Shen batch and one candidate batch. Counts per
size are hand-derived in the tests.

| Max nodes | Programs | Shen/candidate agreement | Outcomes | reverse-operands killed / survived | arm-by-position killed / survived | Time |
| --- | --- | --- | --- | --- | --- | --- |
| 5 | 5,695 | 5,695 / 5,695 (max 47 steps) | 4,350 Ok, 595 DivZero, 517 Bounds, 233 Overflow | 3,940 / 1,755 | 975 / 4,720 | ~82 s |

Survivors are programs on which that mutant is equivalent, for example
programs with no collected operand pair or no `Some`-first match; no mutant
crashed. Two subtle injected candidate defects that the hand fixtures do not
target were each caught at bound 4: a bytes `eq` that ignores the last octet
(4 programs disagree) and `bytes_length` of empty bytes returning 1
(37 programs disagree).

**G0 exact-arithmetic ledger.** `tools/check-tc0-exact-arithmetic.py` runs 2,908
programs through the full pure-call machine (core §17). They are the boundary
product V × V for `add`/`sub`/`mul`/`div`/`lt`/`le`/`gt`/`ge` and `neg` over V.
V spans the I64 extremes, ±2^53 and 2^53 + 1, the multiplication boundary
±3037000499/3037000500, 2^62 and small signed values. One more program carries
function, node and binding IDs above 2^53 and 2^64, with a closure whose captures
must be ordered numerically. Expected outcomes come from Python's exact integers.
Both Shen ports and the candidate were exact on all 2,908: 2,587 Ok, 302 Overflow,
19 DivZero, and the correct capture order. An injected off-by-one I64 bound in the
model was flagged on the 15 results equal to the maximum.

**Requirement ledger (G0 row).** [`spec/tc0/requirement-ledger-a.json`](spec/tc0/requirement-ledger-a.json)
lists each TC0-A and G1-relevant G0 requirement with its evidence or its gap, and
`tools/tc0/check-requirement-ledger.mjs` keeps it honest: no verdict statuses, every
cited file exists, and every open row states its gap. Current rows: 24 with
development evidence and 3 deferred to B/C. The mandatory bad-overflow mutant (`--wrap-overflow`, two's-complement wrap
instead of the trap) is now in the candidate; it is killed on exactly the Overflow
programs of the exhaustive scope (233 at 5 nodes).

**Candidate execution boundary (G0 row, measured).** `tools/tc0/sandbox.mjs` runs a
candidate inside a fresh network namespace (`unshare -n`) under Node's permission
model, with an empty environment. Reads are limited to the candidate tree and its
inputs; there are no writes beyond a named output, and no child processes, workers
or addons. `tools/tc0/check-sandbox.mjs` measures it with eight benign probes
packaged as candidate patches. Each probe first runs without the sandbox as a
control, to show the action really happens. Effects are measured from outside
where possible: file hashes, a local TCP listener, and canary strings only a
successful probe could print. All eight capabilities are obtained in the control
and denied in the sandbox: writing the protected model, writing a new file,
reading a secret file, reading the model source, reading an environment
credential, spawning a process, starting a worker thread and connecting to the
network. The baseline candidate's output is byte-identical inside and outside the
sandbox. The hand-case and exhaustive checkers take `--sandbox`, and the S3
evaluator uses it for every step that runs the untrusted repaired candidate. Its
regression suite needs processes and scratch files, so it gets the network and
environment isolation only, and the report says so. Not bounded: CPU, memory and
time (watchdogs remain), Node's own startup reads, side channels, and defects in
the kernel or the permission model. This is measured development evidence, not a
qualified isolation claim.

**Second Shen port.** The Yggdrasil-shaken oracle was rebuilt for the schema `/2`
model: an eval-free shen-cl/SBCL slice that matched host Shen on all 19 hand cases.
On all 5,695 exhaustive-small programs it produced traces identical to
shen-scheme v0.26. The bootstrap steps are in the
[workflow README](.pi/extensions/fenrir-workflow/README.md). Two ports agreeing
supports portability only, not semantic truth (core §17).

**Invalid programs.** `tools/tc0/pure-data-invalid.mjs` applies 27 named single
mutations to a generated seed: duplicate IDs, bad hex, tuple arity, projection
range, unknown or ill-typed constructors, non-exhaustive, duplicate or
ill-scoped match arms, `eq`/byte primitive typing, datatype declaration errors,
non-serializable entry and source-map gaps. Each case records the rejection it
must produce. The tests check the exact rejection class, and that the runner
exits nonzero without output, so invalid artifacts never execute.

**Catalog coverage.** `tools/tc0/check-pure-call-coverage.mjs` maps every step of
the Shen-agreeing traces to a catalog transition: dispatch by tag, collect/ready by
operation, trap routing by code, frame kinds (from a frame stack simulated from the
step records and checked against each step's depth), tail-call contexts, emit and
root event sequences. These come from the 24 hand cases and the 5,695
exhaustive-small programs; each exhaustive program is admitted only when its trace
hash matches the Shen-agreeing one. It covers **112 of 112** transitions the catalog
defines for schema `/2`, and no step maps outside the catalog. Five fixtures were
added for the last 18 gaps: `gt`/`ge`/`mul`, Overflow from `sub`, `neg` minimum,
`mul` and minimum ÷ −1, exact values around 2^53, and unwinding through `let`
initializers and `if` conditions. This covers the catalog's named transitions, not
every frame/context combination.

**TC0-A gate (owner-reviewed, registered).** [`spec/tc0/tc0-a-requirements.json`](spec/tc0/tc0-a-requirements.json)
is a versioned manifest of 15 required rows and 1 optional row.
[`tools/check-tc0-a-gate.py`](tools/check-tc0-a-gate.py) runs every row freshly
against a clean, committed HEAD and aggregates per TC0-GATE. That includes
rebuilding an S3 packet and re-evaluating the retained independent patch. After
the owner's review decisions
([`campaigns/tc0/G1_EVALUATOR_REVIEW.md`](campaigns/tc0/G1_EVALUATOR_REVIEW.md)), it
is registered as `tc0-a-qualification`. It returns a development-grade PASS:
15 of 15 required rows, all six claims, and one recorded waiver (instruction-only
repairer isolation). Each run's `gate.json` records a SHA-256 per evidence file;
copies are committed under [`campaigns/tc0/receipts/`](campaigns/tc0/receipts/). A negative control with a
subtly broken candidate gave FAIL.

**S3 repair packet and independent repair 1.** See
[`campaigns/tc0/S3_REPAIR_PACKET.md`](campaigns/tc0/S3_REPAIR_PACKET.md).
`tools/tc0/s3-prepare.mjs` builds a clean-room workspace: a history-free export
with the arm-by-position defect made unconditional in the candidate, the retained
original and minimized failures, and evaluator-side tooling withheld.
`tools/check-tc0-s3-repair.py` is the frozen evaluator. It checks protected inputs
and the allowed path, replays the exact original failures against the preserved
defective original, then checks the patch fresh: retained failures, hand cases,
regressions, held-out generated and exhaustive scopes, and a mutation control.
Dry runs fail the untouched, overfit and tampered workspaces, and pass the reference
and a minimal one-line fix. Both passing patches are self-authored evaluator
checks, not independent repairs. A fresh local subagent then repaired the
candidate from the workspace alone, without being told the defect: a one-line fix
selecting the match arm by constructor name. The frozen evaluator gave it
DEVELOPMENT-PASS on all 10 steps, including the 5,051 held-out exhaustive programs
with the candidate sandboxed. Caveats: the subagent's isolation was by instruction,
not enforced, and it shares a model family with the packet author; see
[`campaigns/tc0/s3/independent-repair-1.md`](campaigns/tc0/s3/independent-repair-1.md).

Not established: a repair under enforced repairer isolation, and anything at the B/C level (`Outcome`, `SendResult`,
`ReceiveResult` and the runtime operations). B/C qualification remains **UNKNOWN**.

## Latest native-host progress

The recent Go host pass added executable checks for:

- Exact consistency between Node lowering data and its generated C data header.
- Docker-reported command/entrypoint/path/arguments against intended launch argv.
- Recorded replay command policy, mode, image and guest-path consistency.
- Partial campaign attempt counts bounded by the selected plan.
- Versioned **build receipt v2**, binding the actual compilation command to the
  unchanged fixed recipe and canonical fuel, without reinterpreting old receipts.

The pass retained fail-before vectors: 19 header/data contradictions, 14 launch
metadata contradictions, seven recorded-command contradictions, two partial-count
contradictions and seven compilation-command contradictions. Additional vectors
check swapped replay identities, unsafe representation tokens and preflight order.
These are **adapter/unit development evidence**, not live security certification.
Daemon launch checks occur after launch; receipt consistency is not independent
binary-to-fuel attestation.

Latest local measurements from that pass:

- Pinned Nix **Go 1.27.1** full host race suite: PASS (12.428s), including all 13
  retained real Node hand lowerings.
- Node TC0/lowering regressions: 88 PASS in the same pass, before later Go-only
  repairs.
- Approved workflow development checks: PASS; these test the controller, not
  language conformance.
- Live Shen transport test: skipped in that test invocation, therefore unmeasured.
- **No new native compilation, guest, replay or peer attempts in this pass.**

Historical native evidence includes 13 arithmetic hands and a finite 16-case
generated family whose first evaluated case exposed the operand-order mutant.
Retained reductions found a 9 → 6 → 3-node failure; a valid one-node proposal lost
the failure. This is not full generated coverage or a global-minimality proof.
Later selected campaigns add bounded observations, not full-corpus qualification.
See the [native host README](tools/solo5/native-arithmetic/README.md) and
[repair handoff](tools/solo5/native-arithmetic/REPAIR_HANDOFF.md).

## Current blocker and next steps

**The latest native closure pass is blocked before its live bootstrap.** The local
Docker daemon is responding again, but both exact retained stock/control images
are absent. The local archive search did not locate an image backup. No pull,
rebuild, replacement image or guest execution was performed during restore review.

An exact restore needs the original Docker/OCI archive or a registry recovery
source containing those immutable identities. **Planned remedy (direction amendment,
11 October 2026):** instead of further recovery attempts, open a new reviewed
dependency epoch that rebuilds the images from a pinned Nix flake, records new
identities and leaves the old receipts historical (never rewritten). That epoch has
not been opened yet; see the [execution plan §4 and §18](03_PHASED_EXECUTION_PLAN.md#18-first-concrete-implementation-assignment).

Other outstanding gates before live work:

1. Finish ownership-specific current resource review while preserving the old
   failed run's missing-ownership uncertainty. New cleanup success does not erase
   a historical failure.
2. Reconcile inherited attempt accounting with retained evidence. The recorded
   hardening totals are 26 guest attempts / 17 two-build attempts / 7 peer scenarios;
   final reconciliation remains incomplete.
3. Explicitly review the proposed cumulative 160/72/40 envelope. It is **not yet
   effective**; existing v1 limits remain 100 executions / 40 two-build attempts,
   with the prior peer scope capped at 24.
4. Complete remaining saved-report/footer consistency checks and live prerequisites.
5. Only after those gates, perform one fresh arithmetic bootstrap, stopping without
   retry on cleanup ambiguity; then measure the bounded hostile-peer and corpus scope.

The larger project milestone is still a **qualified pure TC0-A repair loop**:
complete model/candidate/evaluator coverage, retain discovery/reduction/exact-original
replay, obtain an independent repair and validate it freshly. Broader native-host
work does not substitute for that milestone. Under the direction amendment, native
hardening outside named blockers is frozen until G1, and the workflow controller is
to gain semantic development checks for the pure slice so the agent loop is checked
against language behavior rather than only controller tests.

The amendment also sets the long-term direction: Fenrir programs deploy as
single-application unikernels whose declared effects determine the image's
capabilities. This is a plan, not an implemented or qualified property; see
[vision §7](01_FULL_VISION.md#7-solo5-as-the-first-isolated-backend) and
[plan §19](03_PHASED_EXECUTION_PLAN.md#19-direction-amendment-unikernel-target-and-agent-back-pressure).

Overall language qualification and native startup/counter closure remain
**UNKNOWN** beyond TC0-A. TC0-A has a provisional, development-grade PASS under the
recorded waivers and [limits](#limits-of-the-tc0-a-pass).

## Plans and task packets

- [Full vision](01_FULL_VISION.md)
- [Tiny core v0.2](02_TINY_LANGUAGE_CORE.md)
- [Vertical-slice execution plan and gates](03_PHASED_EXECUTION_PLAN.md)
- [Original review](review.md)
- [Workflow research](workflow_research.md)
- [Pure calls/closures next-slice packet](campaigns/tc0/NEXT_SLICE.md)
- [Native host closure packet](campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md)
- [Development build receipt v2](spec/solo5/native-arithmetic-demo/build-receipt-v2.md)

Task packets propose work; they do not authorize execution or prove completion.
The historical v0.1 specification ZIP and superseded TC0 lineages are in [`attic/`](attic/), not current authority.

## Running development checks

The project-local [Pi workflow extension](.pi/extensions/fenrir-workflow/README.md)
drives bounded development work alongside `pi-clm` continuous context. Review the
manifest, available prerequisites and finite scope before starting; do not resume
a blocked pass merely because some tests pass. Its manifest registers the TC0-A
gate as `tc0-a-qualification`; the controller never promotes development checks
to a qualification verdict.

```sh
# Controller tests only; Node 22.19+, no downloaded dependencies/model calls.
npm test

# TC0 and native-lowering Node regressions.
node --test tests/tc0/*.test.mjs tests/solo5/native-arithmetic-lowering.test.mjs
```

The TC0 Shen toolchain is pinned by the repository flake (x86-64 Linux): shen-scheme
v0.26, shen-cl `dff7445` built from the S41.2 kernel, Yggdrasil `a40d8c5`, and SBCL,
Node 22, Python and Go 1.27 from one nixpkgs release. Sources are fetched by Nix
and locked in `flake.lock`.

```sh
nix run .            # links build/toolchain/shen-scheme to the pinned host oracle
node tools/tc0/dev-check-pure-call-oracle.mjs
python3 -I tools/check-tc0-pure-data-exhaustive.py --shen-executable build/toolchain/shen-scheme \
  --max-nodes 5 --output build/tc0/exhaustive-5.json
python3 -I tools/check-tc0-exact-arithmetic.py --shen-executable build/toolchain/shen-scheme \
  --output build/tc0/exact-arithmetic.json
nix shell nixpkgs#sbcl -c node tools/tc0/build-shaken-oracle.mjs \
  --yggdrasil "$(nix build --no-link --print-out-paths .#yggdrasil)/bin/yggdrasil" \
  --shen-cl "$(nix build --no-link --print-out-paths .#shen-cl)"
```

For Go host tests, pinned toolchain instructions and optional explicit Shen/Node
integration vectors, use the [native host README](tools/solo5/native-arithmetic/README.md).
Live commands additionally require the exact images and reviewed isolation/cleanup
prerequisites; ordinary unit tests do not supply them.

Private development captures live under ignored `build/` and workflow journals.
They are local source-bound evidence, not automatically available from a clean
checkout. Gate summaries (`gate.json`, with evidence digests) are copied into
`campaigns/tc0/receipts/`; the bulk evidence they hash stays under `build/`.
