# TC0-A completion record and P2 handoff

Status: S1–S3 development work is present on master, and the owner-reviewed `tc0-a-qualification` gate recorded PASS at `1db7471` under the waivers in [`G1_EVALUATOR_REVIEW.md`](G1_EVALUATOR_REVIEW.md). Master has since advanced to `8cc4c92`; no gate receipt at that exact source is recorded in this checkout. The evaluator header and protected ledger retain descriptions predating registration. Their cleanup is a separate reviewed authority change; the structural ledger checker does not make stale prose a prerequisite for a read-only gate refresh. Until it passes, current-head G1 is UNKNOWN. This file records delivered work and the next transition; it is not acceptance authority.

## Activation and finite limits

Inspect the live workflow state before starting. Do not resume an exhausted budget or edit a prior journal. The finite drive below is an example for a fresh, explicitly approved run; it does not authorize automatic renewal.

### Run A — supported-runner G1 refresh only

Use a Linux x86-64 runner with Nix; the current flake does not provide a measured macOS qualification path. Record runner identity, checkout commit, pinned Shen resolution, resource limits and timeout. Missing prerequisites are BLOCKED.

Human command in Pi:

```text
/fenrir-workflow drive --turns=120 --minutes=120 --repairs=6 Verify the Linux x86-64 runner and pinned toolchain; run only tc0-a-qualification on clean committed HEAD, retain its controller receipt and evidence identities, then checkpoint and stop for receipt review. Do not modify authority inputs or start P2.
```

Review the displayed manifest and confirm this finite run. Non-UI mode requires explicit human approval. The controller receipt, including source/configuration hashes, executable/evidence identities and cleanup, is the qualification artifact; a standalone report is supporting evidence. PASS ends Run A; any non-PASS retains its reasons and stops progression.

### Run B — separately reviewed P2 development

After reviewing a fresh G1 PASS, prepare and approve a P2 task packet with exact handler semantics, versioned profile/catalog, allowed paths, protected A baseline, authority changes, component checks and finite budgets. Then start a new bounded run:

```text
/fenrir-workflow drive --turns=120 --minutes=120 --repairs=6 Follow the separately reviewed P2 task packet and 03_PHASED_EXECUTION_PLAN.md §6: implement one minimal dynamic-handler vertical slice, select and run its relevant development checks, retain failures/reduction/replay, and stop at the packet budget or an authority change. Keep affected G1 evidence historical after protected-source edits; do not claim G2 before its reviewed evaluator runs A and B rows on final source.
```

This command is a template, not authorization for an unprepared packet. G1's program enumeration provides no concurrency, fairness, crash, retry or partition qualification. New claims need explicit fault models, schedule/monitor identities and replay evidence. Optional backend and surface-language work is outside both runs.

## Read and baseline

Read 02_TINY_LANGUAGE_CORE.md §§1–4, 11–18 and 03_PHASED_EXECUTION_PLAN.md §§3–5, 15–18. Inspect existing validators, machines, catalogs, replay and oracle runners before extending them. Read any repository-local instructions before modifying an external checkout. No external checkout edits are planned.

Retain baseline evidence without overwriting:

- build/tc0/closure-alias-development.json
- build/tc0/closure-alias-replay-final.json
- build/tc0/closure-alias-replay-repeat.json
- build/tc0/closure-alias-final-tests.tap
- build/tc0/reduction-development.json and reduction-repeat-comparison.json

Old source-bound evidence is historical after relevant changes; regenerate affected evidence under new filenames. Record source/toolchain hashes, commands, bounds, cap hits and cleanup in each development bundle.

## S1 — closed integrated pure-call demo (development exit recorded)

The schema `/1` and `/2` implementation, closed validator, catalog, independent Shen/candidate machines, hand traces and replay identity are present. The recorded G1 run includes 24 hand cases and catalog coverage. Treat the exact gate report and its source identity as the evidence; this section's criteria are retained as the acceptance history, not a new assignment.

Publish a new explicit demo schema/profile/catalog identity; do not widen arithmetic-demo/1 or pure-closure-demo/1 or relabel either as full TC0-A. Choose its exact identity after inspecting existing artifacts. Unsupported A constructors remain rejected and listed as gaps.

Implement together:

1. Closed artifact validator: named function table and entry, unique function/node/binding IDs, checked signatures, serializable input/result, source-map coverage and artifact identity. Support existing arithmetic/let/if/emit and lexical lambda/apply plus named calls. Make effects explicit; reject unknown fields/tags and wrong call/effect/type annotations.
2. Hashed catalog and concrete frame shapes: left-to-right collection, separate Ready execution, named call lookup, tail destination reuse, non-tail return restoration, trap routing, terminal and budget boundaries. Describe source-map/catalog coverage mechanically rather than with a silent fallback.
3. Independent explicit Shen and candidate machines. Candidate must not import Shen transitions; host wrappers remain transport only. Named functions have empty captures/support; closures preserve exactly {code_id,captures,capture_support:[]} with ordered stable binding IDs.
4. Hand fixtures before generated claims: forward/mutually recursive names, finite tail recursion, non-tail recursion, lexical capture and nested returned/captured aliases, higher-order calls, emit ordering, left trap suppressing a later emit, overflow and final-step completion. Retain hand-derived expected steps and independent observations. Semantic continuation-depth tests do not establish native stack guarantees.
5. New compatible replay identity: header binds the complete artifact/source map, catalog, model, candidate, toolchains, profile and bounds. Preserve singleton decisions, epochs/sites/occurrences, full trace/checkpoints and exact terminal/divergence/budget footers. Test missing/extra choices and identity/domain/site drift fail closed.

Development exit: closed validator negative tests, catalog coverage and hand traces pass; independently observed Shen/candidate traces agree; cold strict replay agrees on admitted and known divergence boundaries; old demos' regressions pass. Report supported subset and unresolved full-A requirements. This development exit alone is not G1 PASS; the registered evaluator owns that verdict.

## S2 — bounded valid generation, reduction and discovery (development exit recorded)

Status (development): runs for the pure-call family and the schema /2 data family with two candidate-only mutants (`reverse-operands`, `arm-by-position`) plus the default equivalent control. Each mutant was discovered from its generated family, reduced against fresh Shen observations and replayed Exact for both the original and the minimized failure; the data campaigns were also cold-repeated. Measured results are in README.md. Invalid-program generation (27 named mutations with expected rejection classes) and an exhaustive-small Shen-vs-candidate scope (every program of a bounded grammar up to 5 AST nodes, 5,051 programs) now run as well; see README.md.

Begin only after S1's development exit. Start with a deterministic, explicitly finite family of at most 32 cases, 200 AST nodes/case, 200 reference steps/run, and 100 reduction attempts per selected failure. Keep a wall-time watchdog and output caps; lower bounds if measured throughput requires it. Caps/truncation remain visible and cannot imply exhaustive coverage.

Generate typed named-call/closure combinations including alias retention, returned closures, tail/non-tail calls and arithmetic/emit. Validate each case; document enumeration order/seed. Avoid recursive programs without a declared terminating family or explicit budget-outcome test.

Use an explicitly identified candidate-only operand-order or capture mutant, plus an equivalent control. Discover a failure from the generated family rather than inserting a hand-selected case as discovery evidence. Independently establish the expected discrepancy classification.

Implement typed reductions that preserve declarations, unique IDs, binding scope, signatures/effects and source-map coverage. Revalidate each proposal and obtain fresh independent Shen/candidate observations. Do not accept a reduction from cached mock-oracle data. Regenerate tapes for changed artifacts; retain original and smallest-found minimized cases, rejected attempts, bounds and reduction provenance. Exact replay must reproduce each artifact's same first discrepancy against the original mutant identity. Cold repeat semantic bundles; retain nonsemantic loader diagnostics separately.

Development exit: generated discovery → smaller valid failure → fresh model confirmation → strict original/minimized replay, plus equivalent-control evidence. Never claim global minimality or complete exploration from a bounded reducer/sample.

## S3 — candidate-only repair preparation and evaluation (development result recorded with waiver)

Status (development): packet and frozen evaluator prepared and dry-run; see `campaigns/tc0/S3_REPAIR_PACKET.md`. One candidate-only repair evaluated DEVELOPMENT-PASS under the instruction-only independence waiver; see `campaigns/tc0/s3/independent-repair-1.md`.

Prepare a clean-room task packet from S2 with original candidate identity, allowed candidate files, read-only model/catalog/goldens/gate inputs, failure bundle and retained replay instructions. Preserve the defective original for exact-original replay. Repair only candidate paths; do not fix an oracle disagreement by rewriting its expected answer.

A genuinely independent agent repair/evaluation needs a separately approved execution arrangement. No nested paid model sessions are authorized here. If unavailable, retain the task packet and mark the independent-repair claim UNKNOWN rather than substituting a self-authored patch.

Freeze evaluator inputs and fresh evaluation campaign before exposing held-out cases to repair. Independently build/hash the patch and evaluate retained failures, fresh generated cases, mutation controls and regressions. Cross-patch scenario replay is distinct from exact-original replay. Trusted-local development is not enforced evaluator isolation.

## Follow-on roadmap (ordered, not automatic authorization)

| Stage | Next deliverable | Dependency / stop boundary |
| --- | --- | --- |
| G1 refresh | Verify a supported Linux x86-64 runner; run the registered gate on clean HEAD, retain the controller receipt, and stop for review. | Separate Run A; non-PASS retains its verdict and stops progression. |
| P2 / G2 | Separately review a task packet, implement one dynamic-handler vertical slice, then evaluate final-source A and B rows. | Separate Run B after G1 receipt review; protected-source edits make affected G1 evidence historical. |
| G1 waiver retirement | Enforced repairer isolation and an isolated evaluator, with separately reviewed boundary evidence and fresh rows. | Needed before relying on the gate beyond its accepted G1 scope; do not silently upgrade the waiver. |
| P3 / G3 | Tasks, channels, cancellation, lifetimes, time and stale-waiter repair; then full TC0 freeze. | Depends on qualified G2; deferred B/C requirements remain explicit. |
| P4/P5 | Deterministic Solo5 profile and conservative native compiler. | Depends on G3 interfaces; the optional thin slice after G1 is development evidence only. |

Keep optional backend spikes off the P2 critical path. Do not treat schema `/2`, a bounded campaign, or the recorded G1 waiver as full TC0, waiver-free isolation, native qualification or production readiness.

## Checks, checkpoints and stopping

Synchronous development commands (not qualification):

```sh
node --test tests/tc0/*.test.mjs
```

Use the schema `/2` integration runners and the registered gate; do not feed integrated artifacts into old demo runners. Keep fresh independent model reports and source-verified replay admission. Use `tc0-candidate-tests` and `tc0-pure-call-oracle` for development feedback. The G1 gate is a separate qualification check, not a development check. `workflow-tests` checks the controller, not TC0 semantics. Record each P2 phase, current hashes, bounds, semantic outcomes and cleanup with `fenrir_progress` and `fenrir_checkpoint`.

Each completed substep records current files/hashes, actual test counts, measured bounds/cap hits, semantic outcomes, source/toolchain identities, cleanup and the next executable action. Checkpoint before budget exhaustion, large handoffs and context compaction. Report phase progress, not only status, to avoid the controller's stall guard.

Stop on unavailable required prerequisites, unresolved owned-process cleanup, cancellation, authority drift or the finite budget. Stop for review before changing the trusted evaluator, qualified catalog/model/goldens, command manifest or protected paths. The recorded G1 result applies only to its cited source and approved waivers; new P2 work remains development until evaluated by the updated gate. No push, deployment, background jobs, lock/journal manipulation or implicit budget renewal.
