# Pi + CLM handoff — Fenrir / Gleipnir

Rewritten 15 November 2026. The previous version (8 October 2026) described
`master` at `4661a63`, an absent qualification evaluator, shen-scheme and a
blocked native closure packet. Read this first when opening Fenrir in a new
session with Pi and `pi-clm`.

## Start a fresh session

```sh
git status --short --branch
git log -5 --oneline --decorate
git remote -v
git branch -a
```

Most of the work described below is on the development branch
`claude/keen-ptolemy-w9d7ve`, **not on `master`**. `git log master..<branch>`
shows the difference. Do not rely on any commit id written in a document,
including this one; check the live tip. Documents may also say "master" for an
older moment: [04_DIRECTION_AMENDMENT.md](04_DIRECTION_AMENDMENT.md) records
`4898e7b` as of 12 November.

Toolchain: use Nix, not stored paths.

```sh
export FENRIR_SHEN_JIT=$(nix build --no-link --print-out-paths .#shen-jit)   # Shen/JIT 0.7
export FENRIR_SOLO5=$(nix build --no-link --print-out-paths .#solo5)         # Solo5, pinned commit, stock spt tender
```

`harness/jit.sh` and `harness/solo5.sh` do this when the variables are unset.
Without Solo5, Solo5 rows are BLOCKED, not passed. Other flake outputs:
`.#fenrir-a3-tools` (OTP 28, SQLite; `sh host/service/check.sh` builds it) and
`.#aarch64-verification` (Rocq 9.3, AArch64 binutils, qemu-user).

Open Pi with its project extension and keep `pi-clm` loaded:

```sh
pi -e ./.pi/extensions/fenrir-workflow/index.ts
```

or open Pi in the trusted project and run `/reload`. Light checks: `npm test`
(workflow controller) and `node --test 'tests/**/*.test.mjs'`. Many harness
checks take minutes and gigabytes; see their times in
[harness/README.md](harness/README.md) before starting one.

Suggested first message to the Pi agent:

> Read `PI_CLM_HANDOFF.md` and the documents it lists completely. Check the
> live branch, remote, worktree and workflow manifest. Preserve UNKNOWN and
> BLOCKED states; workflow tests and CLM annotations are continuity evidence,
> not language qualification. Do not reuse old approvals or infer a new
> execution budget. Do not decide the owner's open choices.

## What to read

1. [README.md](README.md): status table per build step.
2. [04_DIRECTION_AMENDMENT.md](04_DIRECTION_AMENDMENT.md): rulings, §8 service
   stages, §9 evidence vocabulary, §10 build order B0 to B6.
3. [harness/README.md](harness/README.md): what every check does and measured.
4. [campaigns/RECONCILIATION_2026-11.md](campaigns/RECONCILIATION_2026-11.md): the
   open branches and the B0 order (a recommendation; the owner merges).
5. Contracts, all drafts for owner review: `spec/tc1/` (EFFECTS, SURFACE,
   TYPING, CONCURRENCY, DURABLE), `spec/service/` (ACCEPTED_JOB, HANDLER,
   HISTORY_FORMAT, UPGRADE), `spec/solo5/` (control protocols v1, v2, v3),
   [host/service/CONTRACT.md](host/service/CONTRACT.md).
6. Proof lanes: [verification/aarch64/](verification/aarch64/README.md)
   (PLAN.md, ABI.md), [verification/universal/](verification/universal/README.md),
   [verification/service/](verification/service/README.md).
7. [03_PHASED_EXECUTION_PLAN.md](03_PHASED_EXECUTION_PLAN.md) for gates and
   TC0 requirements; [.pi/extensions/fenrir-workflow/README.md](.pi/extensions/fenrir-workflow/README.md)
   for the controller.

## Project and evidence boundary

Shen holds the language semantics; independent implementations (JavaScript, C
guest) and thin host adapters check behaviour against it. All of them come from
**one author lineage**, so agreement is consistency, not independent judgement.

Use the amendment §9 words exactly: *model property proved*, *implementation
refinement proved*, *bounded exploration passed*, *observed history accepted*.
Bounded exploration is not proof. Gate verdicts (PASS, FAIL, UNKNOWN, BLOCKED,
DEFERRED) are separate.

**Nothing here is a qualification.**

- The registered gate is `tc0-a-qualification` in
  [.pi/fenrir-workflow.json](.pi/fenrir-workflow.json): `sh harness/run-gate.sh`,
  evaluator `harness/gate.shen` (Shen since 13 November 2026). The evaluator
  exists and is registered; the old statement that it is absent is false. The one
  recorded qualification PASS (`1db7471`, owner waivers) came from the Python
  evaluator and is historical. For the Shen gate only direct runs exist. No
  controller receipt has been produced, so **TC0-A / G1 qualification is
  UNKNOWN on the current source**.
- The TC1 gate and the service gate are proposed and not registered. Their
  reports say development-pass, authority UNREGISTERED, qualification UNKNOWN.
  Registering them is the owner's call.
- `pi-clm` projects conversational context; the workflow stores bounded
  phase and check state. Neither a CLM summary, a checkpoint nor a controller
  status is a verdict. `.pi/fenrir-workflow-runs/` is ignored local state; old
  run ids and receipts may not exist on a new machine. Start a controller run
  only after reviewing its manifest and prerequisites.

## Current state

Per step; details and measured numbers are in the README table and the harness
README.

- **B0** (merging open pull requests): not done; the owner's. The AArch64
  content is on the development branch through a merge; the pull requests are
  untouched.
- **B1** Solo5 guest with host-selected steps and strict replay, stock `spt`,
  x86-64 only.
- **B2** TC1 handlers H1 and H2 through model, JavaScript, C guest, generation,
  reduction, replay, 29-transition catalog.
- **B3** frontend in Shen; typing as sequent rules with a fixed checker.
- **B4** tasks and channels (slice C1) through the stack, protocol v3,
  53-transition catalog. **D1** durable effects, protocol v2.
- **B5** service example A1 to A4, including the real stack on OTP and SQLite.
- **B6** AArch64: three proved profiles (unary, expr, call); closures, data and
  Solo5 on AArch64 not done.
- **Universal claim through Búri:** open, with findings.

Standing limits: x86-64 Solo5 only, no KVM; `sync_off` is not detected by the
A3 campaign (power loss is not simulated); host adapters are named assumptions,
not covered by Fenrir's proofs.

## Next useful work

1. **Owner decisions** that block progress, not to be guessed: EFFECTS §6 and
   §11, SURFACE §8, CONCURRENCY §13 (including the combined durable and task
   questions), the ACCEPTED_JOB §6 and HANDLER §6 choices, DURABLE §12, UPGRADE
   §11, and host CONTRACT.md draft 1.
2. **B0**: the owner merges the open pull requests; see the reconciliation note
   for the suggested order and what must change in one of them.
3. **Gate registration** (TC1, service) and a **G1 controller run** on a
   supported Linux x86-64 runner to obtain a receipt: owner's call; a development
   run does not substitute.
4. **AArch64**: [PLAN.md](verification/aarch64/PLAN.md) lists, in order, several
   parameters, calls inside expressions, stack-overflow handling, then closures
   and data with a heap model. Correspondence with Arm's own semantics is open.
5. **Búri**: [verification/universal/README.md](verification/universal/README.md)
   §8 lists what Búri would need (rules for `cond`, `and`, `or`; assertions in
   certificates; checker behaviour on the pinned Shen/JIT). Changes belong in
   Búri, not here.
6. Smaller known gaps are written in each document's "not covered" section;
   pick one slice, keep to its scope, and record contradictions found.

## Older material (state as of 2026-10-08, not rechecked)

- The native Go host and the closure packet
  [campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md](campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md)
  were blocked then because the exact retained stock and control Docker images
  were unavailable; the packet also listed open items (ownership review,
  attempt-account reconciliation, a proposed 160/72/40 envelope not in effect,
  report and footer checks). Do not substitute a rebuilt image or reuse old
  approvals. Whether any of this changed was not rechecked. The stock-tender
  Solo5 lane needs neither Docker nor those images and does not close the packet.
- Native evidence index and strict repair boundary:
  [tools/solo5/native-arithmetic/REPAIR_HANDOFF.md](tools/solo5/native-arithmetic/REPAIR_HANDOFF.md);
  Go host build instructions: [tools/solo5/native-arithmetic/README.md](tools/solo5/native-arithmetic/README.md).
  Ignored `build/` outputs are machine-local and source-bound.
- Earlier handoff text said independent candidate repair "has not been
  executed". It was executed once (DEVELOPMENT-PASS under instruction-only
  isolation, same model family as the packet author):
  [campaigns/tc0/s3/independent-repair-1.md](campaigns/tc0/s3/independent-repair-1.md).
