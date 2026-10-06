# Four-hour native arithmetic integration sprint

Task proposal only; not acceptance authority or qualification. One new finite human-confirmed run: at most 200 assistant turns, 240 elapsed minutes, 8 repair attempts. No automatic renewal, push or deployment.

## Goal

Connect existing TC0 arithmetic semantics to the measured Solo5 isolation/transport backend. Build an independently structured native C arithmetic-demo candidate, externally checked against the existing Shen arithmetic/expression model, with strict recorded choices, retained original mutant failure and cold replay. Prefer a small working vertical slice over broader language support.

This is early development integration, NOT G1/G4/G5 qualification. G4 still depends on G3. No full-A, native-machine determinism, compiler, native stack/tail-call or security-closure claim.

## Human steering — next action on resume

Prioritize migrating the new native-arithmetic host build/session/model-transport orchestration from Python to Go before extending hand cases, replay or generation. Use Nix Go 1.27.1 pinned at nixpkgs revision `8c6b39505383e6d5dcb431f00cb3597b71f8045c` (available locally at `/nix/store/v0l8ihkyjdqqx97g0b8lkllicmalj0lq-go-1.27.1/bin/go`). Do not silently use the older machine-wide Go or download a different toolchain.

Keep Node for Pi integration; retain existing artifact-validator authority unchanged during migration. Keep the C candidate and Shen semantic models unchanged. The Go host must invoke Shen directly, preserve canonical framing/admission, independently decoded transition comparisons, source/artifact identities, bounded process/container cleanup and isolation policy. Do not hide Python behind a Go wrapper or grow new Python orchestration. Preserve prior evidence as historical and obtain fresh Go-host evidence for the admitted control and retained mutant before continuing the remaining sprint milestones. Retire only superseded new sprint Python adapters after equivalent behavior is demonstrated; do not rewrite unrelated historical tooling or trusted evaluator inputs.

This steering changes the implementation priority, not the existing finite sprint budgets, qualification status or security/authority boundaries.

## Baseline and fixed boundaries

Read the three v0.2 plans and inspect spec/tc0/arithmetic-demo-frames.json, tools/tc0/artifact.mjs, runtime/tc0/expression-machine.mjs, models/tc0/{arithmetic,expression-machine}.shen, tools/check-tc0-expression.py and the current Solo5 protocol/build/runner. Confirm prerequisites and exact independent model launch before investing in the C implementation.

Previous clock evidence: .pi/fenrir-workflow-runs/4147a82c17f66722/96b52933-e78e-4284-b8d5-0983693318a9/checkpoint-64.json. It is historical dependency evidence, not new-run qualification. Recheck relevant dependency sources/images and cleanup.

Do not edit existing models, goldens, fixtures, catalogs, validators, semantic evaluators, old transport/clock code, vendor sources, .pi configuration/controller/tests or the three plans. New development artifacts do not silently amend those inputs or become evaluator authority. If a semantic gap or required authority change is discovered, retain a distinguishing case and stop for review.

New candidate/integration files may live under:

- backends/solo5/native-arithmetic/ — C candidate machine and guest; explicit bounded representations.
- tools/solo5/native-arithmetic/ — artifact admission/lowering, isolated build, framed adapter, recording/replay and development comparison entry point.
- spec/solo5/native-arithmetic-demo/ — explicit unqualified supported-profile identity and transport/lowering contracts, separate from existing TC0 catalog.
- tests/solo5/ — new tests only.
- build/solo5/native-arithmetic-<run>/ — retained private source-bound evidence, original mutant binaries, reports and diagnostics.

The host semantic oracle runs outside the guest. Candidate C must not import, execute or be generated from Shen/model transition code. Host artifact lowering is not permission to compute candidate results or emit an oracle trace on its behalf. The native guest must execute its own state machine and supply observations that the external development comparator independently checks.

Preserve native-tick startup canary, stock images/defaults, existing tender/seccomp/descriptor policy, noexec build tmpfs, network-none/device-free/nonprivileged isolation and process-group/container cleanup. Use immutable installed toolchain paths rather than host Xcode setup. Do not change security policy to deny raw clocks in this sprint. Use no clocks at all in this pure candidate, while retaining native/startup closure UNKNOWN.

## S1 — closed native pure transition slice (first priority)

1. Freeze a small explicit supported subset after inspection: Unit/Bool/I64 literals and inputs, var/let/if, exact arithmetic/comparison/not and emit, with published operand collection/Ready/unwind/root boundaries supported where compatible. Reject everything else before execution, including calls/closures/Bytes/tuples/B/C tags. Never claim omitted frames are implemented.
2. Keep existing artifact/source-map identity and existing model rules. Introduce only the separate native adapter/profile identity and reviewed-in-development lowering mapping. Do not feed a new incompatible artifact into an old validator as though it were accepted.
3. Lower validated artifacts to bounded, inspectable data tables/encoding with stable node/binding IDs, no embedded expected answers. Independently test lowering fidelity and enforce bounds before isolated guest launch. Reject duplicate/unknown/missing/malformed records, integer/range errors and cap overflow; no numeric-token or serialization shortcuts.
4. Implement explicit C control/environment/continuation data, not native recursion for target stepping. Check I64 operations without C signed-overflow/undefined behavior; retain mathematical hand expectations around 2^53, min/max, wide multiply, negative division, min/-1 and zero division.
5. Host selects every singleton semantic decision. Guest requests bind artifact/profile/run/sequence/epoch/site and return independently decoded state/observations. Compare all supported transition facts to independent Shen observations, not just final answers. Specify any transport stuttering explicitly; do not silently erase semantic steps.
6. Hand cases: left operand trap suppresses later emit; left-to-right emit order; selected if branch only; lexical shadowing; exact boundary arithmetic; unwind; completion on last permitted step; explicit budget boundary. Distinguish infrastructure watchdog/crash/protocol outcomes from modeled traps.

S1 exit: isolated native guest runs multiple admitted artifacts, independent model agreement on supported hand transitions, invalid artifacts never launch, strict cold replay of a completing case, existing regressions remain passing. If budget runs short, this is the priority deliverable.

## S2 — bounded discovery, retained failure and exact replay

Proceed only after S1 evidence. Start at <=16 typed finite generated arithmetic/emit cases, <=100 AST nodes and <=200 reference steps/case. Expand to <=32 cases only after measuring throughput. Explicit watchdog/output/memory/input caps remain infrastructure bounds, never invented language traps.

Use a separately identified candidate-only operand-order or overflow mutant plus accepted control. Discover a discrepancy from the generated family, retain expected/observed prefix and first divergence, and preserve original source/options/binary identity. Reuse existing typed reduction infrastructure only where compatible; otherwise bounded artifact reductions must be revalidated and rechecked with fresh independent model/native executions. Retain original and smaller failure, rejected attempts and cap hits; no global-minimality claim.

Exact replay binds original guest/bindings/tender/images/compiler/model/catalog/artifact/input/initial state/environment and all bounds, choices, epochs/sites/domains, prefix/checkpoints and final completion/divergence/budget boundary. Missing/extra/reordered/incompatible tapes reject before execution where possible, and at the first observable discrepancy otherwise. No fresh randomness fallback. Crash/watchdog replay remains Incomplete absent an independently validated captured boundary.

S2 exit: generated native mutant failure with retained reproducer, strict cold original failure replay, smaller valid failure if achievable, accepted control and fresh repeated evidence. If reducer/replay adaptation requires authority changes, stop rather than rewrite acceptance inputs.

## S3 — consolidate, not independent repair substitution

Rerun current-source native hand/generated/control/mutant/replay checks and relevant Solo5/TC0/controller regressions. Retain benign isolation probes when directly supported by existing infrastructure. Check protected sources/images before and after, owned cleanup, exact executable/toolchain identities and all unknowns.

Prepare a candidate-only counterexample/repair handoff, but do not substitute self-repair for a genuinely independent agent or invoke nested paid agents. No qualification registration or required claim promotion. End with executable commands, evidence paths, supported subset, retained failure and next review boundary.

## Orchestration and stopping

Use fenrir_status as state authority. At each measured component: select/build -> approved workflow-tests development check -> measure -> next build; record independent native/Shen results separately. workflow-tests does not qualify the language; tc0-a-qualification is absent and must not be invoked. Checkpoint after each milestone and before compaction/budget exhaustion.

Continue autonomously within this one finite run until S1/S2/S3 evidence is gathered, a required prerequisite is unavailable, cleanup is unresolved, authority/security boundaries would be crossed, the user cancels, or the budget expires. Do not manufacture four hours of work once the authorized deliverable or a blocker is reached. Missing qualification alone is not a development blocker; unknown execution prerequisites are.
