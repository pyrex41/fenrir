# Pi + CLM handoff — Fenrir / Gleipnir

Updated 2026-10-08. Read this first when opening Fenrir on a new developer
machine with Pi and `pi-clm`.

## Start a fresh session

Clone or update the repository, then check the current branch, worktree and
remote before doing anything:

```sh
git clone git@github.com:pyrex41/fenrir.git
cd fenrir
git status --short --branch
git log -5 --oneline --decorate
git remote -v
```

The source snapshot inspected for this handoff was `master` at `4661a63`; a
fresh fetch confirmed those three native-host commits were already on
`fenrir/master`. The handoff itself is committed after that snapshot. Recheck
the live tip on arrival instead of relying on this recorded SHA.

From the repository, open Pi with its project extension and keep `pi-clm`
loaded:

```sh
pi -e ./.pi/extensions/fenrir-workflow/index.ts
```

Or open Pi in the trusted project and run `/reload`. Read this file, `README.md`,
`03_PHASED_EXECUTION_PLAN.md`, `.pi/extensions/fenrir-workflow/README.md`, and
`campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md` before selecting work.

Suggested first message to the Pi agent:

> Read `PI_CLM_HANDOFF.md` and the linked current plans/checkpoints completely.
> Check the live branch, remote, worktree and configured workflow manifest.
> Continue with one bounded development slice. Preserve UNKNOWN/BLOCKED states;
> workflow tests and CLM annotations are continuity evidence, not language
> qualification. Do not reuse old approvals or infer a new execution budget.

## Project and evidence boundary

Fenrir is the planned language; Gleipnir is its development and conformance
harness. The intended ownership is Shen for language semantics and generators,
ShenCheck for campaigns, replay, corpus, minimization and evidence, independent
candidates for behavior, and thin host adapters for transport. The current
prototype still has ownership gaps described in `03_PHASED_EXECUTION_PLAN.md`
and `workflow_research.md`; do not treat the architecture goal as implemented.

The project is early executable bootstrap work. It has Shen models, candidate
implementations, fixtures, reduction/replay evidence and a narrow Solo5 arithmetic
spike. **TC0-A / G1 qualification is still UNKNOWN; independent candidate repair
has not been executed.** A green development or controller test does not qualify
the language.

The project-local `fenrir-workflow` extension and its manifest are tracked at
`.pi/extensions/fenrir-workflow/` and `.pi/fenrir-workflow.json`. Keep `pi-clm`
loaded alongside it. `pi-clm` projects conversational context; the workflow
stores bounded phase/check state and can publish a CLM continuity annotation.
Neither a CLM summary, checkpoint nor controller status is a qualification
verdict. The controller does not transform or edit `LIVE_CONTEXT.md`.

`.pi/fenrir-workflow-runs/` is ignored local state. Its old run IDs, receipts and
checkpoint files are not part of this handoff and may not exist on the new
machine. Reconstruct working context from tracked documents and current source.
Start a new controller run only after reviewing its displayed manifest and
prerequisites; a prior run approval does not carry across code changes or
sessions. The extension's `drive` flow asks for explicit human authorization in
UI mode and has finite turn/time bounds.

## Current state and next useful work

The `4661a63` native-host pass hardened data-header consistency, Docker launch
identity, recorded replay command checks, attempt accounting and build receipt
v2. Its recorded Go race and Node development checks cover the measured host
slice only. They do not establish live native startup/counter closure or language
qualification.

The current native closure packet is blocked before a fresh guest bootstrap:
the exact retained stock/control container images are unavailable locally. Do
not substitute a rebuild or different image while preserving old receipts. The
packet also lists unresolved ownership review, attempt-account reconciliation,
the proposed cumulative envelope, report/footer checks and live prerequisites.
Keep the older failed-run uncertainty intact. Restore exact immutable inputs and
recheck those gates before any new live bootstrap.

In parallel, the larger useful milestone remains a qualified pure TC0-A repair
loop: complete the model/candidate/evaluator slice, find and reduce a defect,
replay its exact original failure, obtain an independently reviewed candidate-
only repair, then evaluate it freshly. The configured workflow currently has
only `workflow-tests`; the required `tc0-a-qualification` evaluator is absent by
design. Do not invent one or promote workflow checks to qualification.

The native candidate/replay evidence index and strict repair boundary are in
`tools/solo5/native-arithmetic/REPAIR_HANDOFF.md`. Historical build outputs live
under ignored `build/`; those are machine-local and source-bound. Recreate fresh
outputs only after checking their exact source, toolchain and immutable-image
prerequisites.

## Toolchain pointers

Use the repository's own commands rather than copying absolute `/nix/store`
paths from the previous Mac. `tools/solo5/native-arithmetic/README.md` documents
the pinned Go 1.27.1 host build, Node lowering, Shen executable selection and
output locations. `FENRIR_SHEN_EXECUTABLE` must point to a local executable from
the intended pinned Shen checkout. A missing Shen executable means the live
comparison was skipped, not passed. Root `npm test` runs the project checks
documented in `package.json`; controller tests remain development evidence.
