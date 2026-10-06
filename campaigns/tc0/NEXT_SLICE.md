# Next TC0-A development workflow

Status: prepared, not started or qualified. This is a task packet, not acceptance authority.

## Activation and finite limits

The previous run e38e2587-ec81-44a2-9f44-741c1bdfed23 is paused at 120/120 turns, with confirmed cleanup, no active check and no occupied lease (measured with fenrir_status during preparation). Do not resume exhausted bounds or edit its journal.

Human command in Pi:

```text
/fenrir-workflow drive --turns=120 --minutes=120 --repairs=6 Follow campaigns/tc0/NEXT_SLICE.md: integrate the closed pure call/closure demo, then bounded generated reduction and strict replay if budget permits; retain fresh independent Shen evidence, keep qualification UNKNOWN, stop at authority-review boundaries, and checkpoint without automatic renewal.
```

No reload is needed for this task packet. Review the displayed authority manifest and confirm the drive. In non-UI mode the controller requires explicit human approval. This command authorizes one finite run, not each future row in the roadmap. Follow-ons may proceed within that budget only when their development dependencies are measured; later drives require fresh authorization.

Use existing controller tools: select → build → measure; failed development checks → repair → measure. The only registered check is `workflow-tests` (development). A fresh PASS with missing qualification returns to build. Do not call the unconfigured `tc0-a-qualification`. No controller/configuration/protected-test changes are required by this packet.

## Read and baseline

Read 02_TINY_LANGUAGE_CORE.md §§1–4, 11–18 and 03_PHASED_EXECUTION_PLAN.md §§3–5, 15–18. Inspect existing validators, machines, catalogs, replay and oracle runners before extending them. Read any repository-local instructions before modifying an external checkout. No external checkout edits are planned.

Retain baseline evidence without overwriting:

- build/tc0/closure-alias-development.json
- build/tc0/closure-alias-replay-final.json
- build/tc0/closure-alias-replay-repeat.json
- build/tc0/closure-alias-final-tests.tap
- build/tc0/reduction-development.json and reduction-repeat-comparison.json

Old source-bound evidence is historical after relevant changes; regenerate affected evidence under new filenames. Record source/toolchain hashes, commands, bounds, cap hits and cleanup in each development bundle.

## S1 — closed integrated pure-call demo (first priority)

Publish a new explicit demo schema/profile/catalog identity; do not widen arithmetic-demo/1 or pure-closure-demo/1 or relabel either as full TC0-A. Choose its exact identity after inspecting existing artifacts. Unsupported A constructors remain rejected and listed as gaps.

Implement together:

1. Closed artifact validator: named function table and entry, unique function/node/binding IDs, checked signatures, serializable input/result, source-map coverage and artifact identity. Support existing arithmetic/let/if/emit and lexical lambda/apply plus named calls. Make effects explicit; reject unknown fields/tags and wrong call/effect/type annotations.
2. Hashed catalog and concrete frame shapes: left-to-right collection, separate Ready execution, named call lookup, tail destination reuse, non-tail return restoration, trap routing, terminal and budget boundaries. Describe source-map/catalog coverage mechanically rather than with a silent fallback.
3. Independent explicit Shen and candidate machines. Candidate must not import Shen transitions; host wrappers remain transport only. Named functions have empty captures/support; closures preserve exactly {code_id,captures,capture_support:[]} with ordered stable binding IDs.
4. Hand fixtures before generated claims: forward/mutually recursive names, finite tail recursion, non-tail recursion, lexical capture and nested returned/captured aliases, higher-order calls, emit ordering, left trap suppressing a later emit, overflow and final-step completion. Retain hand-derived expected steps and independent observations. Semantic continuation-depth tests do not establish native stack guarantees.
5. New compatible replay identity: header binds the complete artifact/source map, catalog, model, candidate, toolchains, profile and bounds. Preserve singleton decisions, epochs/sites/occurrences, full trace/checkpoints and exact terminal/divergence/budget footers. Test missing/extra choices and identity/domain/site drift fail closed.

Development exit: closed validator negative tests, catalog coverage and hand traces pass; independently observed Shen/candidate traces agree; cold strict replay agrees on admitted and known divergence boundaries; old demos' regressions pass. Report supported subset and unresolved full-A requirements. This is NOT G1 PASS.

## S2 — bounded valid generation, reduction and discovery

Begin only after S1's development exit. Start with a deterministic, explicitly finite family of at most 32 cases, 200 AST nodes/case, 200 reference steps/run, and 100 reduction attempts per selected failure. Keep a wall-time watchdog and output caps; lower bounds if measured throughput requires it. Caps/truncation remain visible and cannot imply exhaustive coverage.

Generate typed named-call/closure combinations including alias retention, returned closures, tail/non-tail calls and arithmetic/emit. Validate each case; document enumeration order/seed. Avoid recursive programs without a declared terminating family or explicit budget-outcome test.

Use an explicitly identified candidate-only operand-order or capture mutant, plus an equivalent control. Discover a failure from the generated family rather than inserting a hand-selected case as discovery evidence. Independently establish the expected discrepancy classification.

Implement typed reductions that preserve declarations, unique IDs, binding scope, signatures/effects and source-map coverage. Revalidate each proposal and obtain fresh independent Shen/candidate observations. Do not accept a reduction from cached mock-oracle data. Regenerate tapes for changed artifacts; retain original and smallest-found minimized cases, rejected attempts, bounds and reduction provenance. Exact replay must reproduce each artifact's same first discrepancy against the original mutant identity. Cold repeat semantic bundles; retain nonsemantic loader diagnostics separately.

Development exit: generated discovery → smaller valid failure → fresh model confirmation → strict original/minimized replay, plus equivalent-control evidence. Never claim global minimality or complete exploration from a bounded reducer/sample.

## S3 — candidate-only repair preparation and evaluation

Prepare a clean-room task packet from S2 with original candidate identity, allowed candidate files, read-only model/catalog/goldens/gate inputs, failure bundle and retained replay instructions. Preserve the defective original for exact-original replay. Repair only candidate paths; do not fix an oracle disagreement by rewriting its expected answer.

A genuinely independent agent repair/evaluation needs a separately approved execution arrangement. No nested paid model sessions are authorized here. If unavailable, retain the task packet and mark the independent-repair claim UNKNOWN rather than substituting a self-authored patch.

Freeze evaluator inputs and fresh evaluation campaign before exposing held-out cases to repair. Independently build/hash the patch and evaluate retained failures, fresh generated cases, mutation controls and regressions. Cross-patch scenario replay is distinct from exact-original replay. Trusted-local development is not enforced evaluator isolation.

## Follow-on roadmap (ordered, not automatic authorization)

| Stage | Next deliverable | Dependency / stop boundary |
| --- | --- | --- |
| S4 | Remaining full-A constructors/values, declarations, primitives, effects/serialization and complete frame/source-map catalog | S1/S2 development; introduce explicit versions and distinguishing fixtures for each extension; do not assume this demo covers full A |
| S5 | G0 exact-arithmetic/provenance ledger and enforced evaluator boundary; benign protected-write/access/credential probes | Required qualification prerequisites; platform enforcement must be measured, not replaced by path rules |
| S6 | Independently reviewed evaluator/requirement manifest, protocol and replay mutants, finite exhaustive-small scope and fresh repair evaluation | Separate authority review before protecting/registering evaluator inputs or changing .pi/fenrir-workflow.json; no synthesized claims |
| G1 | Source-bound TC0-A qualification via an actually registered evaluator | All required A/G0 rows and six controller claims; any required missing evidence remains UNKNOWN/BLOCKED |
| P2 | Dynamic handlers across validator/model/candidate/generator/reducer/replay | Qualified G1; B/C-dependent fixtures remain deferred until C |
| P3 | Tasks/channels/cancellation/lifetimes/time and stale-waiter repair | Qualified G2; full TC0 freeze only after G3 |
| P4/P5 | Deterministic Solo5 profile and conservative native compiler | G3 interfaces; Solo5 startup feasibility is not deterministic execution qualification |

Keep optional backend spikes off the critical path. Do not start B/C, a hypervisor, surface language or optimization work to bypass incomplete A evidence.

## Checks, checkpoints and stopping

Synchronous development commands (not qualification):

```sh
node --test tests/tc0/*.test.mjs
```

Inspect the existing tools/check-tc0-closure.py and tools/check-tc0-reduction.py for baseline commands. Add an integration runner for the new identity instead of silently feeding integrated artifacts into old demo runners. Keep fresh independent model reports and source-verified replay admission. Run `fenrir_check` with checkId `workflow-tests` at development measure boundaries; its PASS checks the controller, not TC0 semantics. Record TC0 evidence separately with `fenrir_progress` and `fenrir_checkpoint`.

Each completed substep records current files/hashes, actual test counts, measured bounds/cap hits, semantic outcomes, source/toolchain identities, cleanup and the next executable action. Checkpoint before budget exhaustion, large handoffs and context compaction. Report phase progress, not only status, to avoid the controller's stall guard.

Stop on unavailable required prerequisites, unresolved owned-process cleanup, cancellation, authority drift or the finite budget. Stop for review before changing the trusted evaluator, qualified catalog/model/goldens, command manifest or protected paths. All work in this packet is development until independently qualified. No push, deployment, background jobs, lock/journal manipulation or implicit budget renewal.
