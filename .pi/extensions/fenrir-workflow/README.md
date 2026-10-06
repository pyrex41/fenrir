# Fenrir development workflow for Pi

A project-local controller for **building Fenrir and Gleipnir**, starting with executable TC0-A. It works alongside the installed `pi-clm` continuous-context extension without changing its implementation or editing its context mirror.

This is a deliberately serial, bounded workflow. The current coding session is the worker; there is no recursive agent fleet, generated-script execution service, or paid nested model invocation. Get one independently checked slice working before adding parallel editors.

## Load and start

From this repository, grant Pi project trust if prompted, then `/reload`. Pi discovers `.pi/extensions/fenrir-workflow/index.ts`. Alternatively, load it explicitly for a session:

```sh
pi -e ./.pi/extensions/fenrir-workflow/index.ts
```

Keep `pi-clm` loaded. No global settings or extensions need modification. Loading does not start work.

```text
/reload
/fenrir-workflow drive --turns=120 --minutes=120 Build TC0-A and the bounded Solo5 backend spike; keep missing qualification UNKNOWN.
```

`drive` displays the full command/authority manifest and finite budgets, asks one human confirmation in UI mode, and starts autonomous continuation. Non-UI mode requires prior explicit `approve`. Reload is needed once after installing code; do not reuse the old approval after controller changes. No repeat nudges are needed within the authorized budget. Budget exhaustion, cancellation, unavailable prerequisites, unresolved cleanup and authority changes still stop the drive.

The separate `inspect` → `approve` → `start` commands remain supported.

**Inspect and review before approval.** `approve` pins the configured commands and evaluator authority on the active branch. It is not qualification. Start/resume are human-command-only; the model has no corresponding authorization tool.

A custom goal can follow the start options, for example:

```text
/fenrir-workflow start --turns=20 --minutes=30 Build canonical TC0-A arithmetic artifacts, the Shen evaluator and an independent candidate; retain the first reduced implementation failure.
```

The goal stays inside the TC0-A profile. Six demonstration claims remain required for completion, even when the current development slice is smaller.

## Control

| Command | Meaning |
| --- | --- |
| `status` | Show branch state, current-source gate status, receipts and active runner |
| `inspect` | Show configured argv, protected paths, ignores and required claims |
| `approve` | Explicitly approve the current manifest and evaluator/specification hashes |
| `drive` | Review/confirm and start one finite development run (default 120 turns/120 minutes); no auto-renewal |
| `start` | New bounded run; no old receipts are inherited |
| `pause` | Pause continuation and cancel an owned running check |
| `stop` | Stop the run and cancel owned work; late results cannot revive it |
| `resume` | Resume a paused/blocked run without replenishing its time/turn budgets |
| `cleanup` | Human acknowledgement of external cleanup; does not promote incomplete receipts |

Human steering pauses automatic continuation. Reload, session start, fork and branch navigation require explicit resume. An inherited run in another session requires a fresh start rather than sharing its lease. Native compaction preserves the branch-local state and does not replace `pi-clm`'s projection.

Assistant turns, including tool-driven turns, charge the limit. A timer aborts an active operation at the time boundary. These are workflow bounds, not hard token/spending ceilings or a guarantee against hostile OS processes. Exhausted bounds require a newly authorized run, not an automatic renewal. Two settlement boundaries without phase progress pause the loop. Repair attempts are separately capped.

## Worker tools and phases

```text
select → build → measure ──FAIL──→ repair → measure
          ↑         │                         │
          └─────────┴── PASS, qualification UNKNOWN
                    │
          all required qualification rows PASS
                    ↓
                  verify ──FAIL──→ repair
                    │
                  PASS → assess → completed
```

- `fenrir_status`: inspect actual branch state and current gate evidence.
- `fenrir_progress`: report a phase result. Reports cannot authorize execution or establish qualification.
- `fenrir_check`: execute one already-approved named check synchronously and retain a receipt.
- `fenrir_checkpoint`: store concise state, evidence hashes, gaps and next action; create a continuity annotation through `live_context_annotate`.

The fixed phase instructions focus on: canonical artifacts and hand traces; explicit pure transitions; Shen and an independent candidate; defect injection/discovery/reduction; exact original-failure replay; candidate-only repair; fresh qualification. No push/deploy authorization is implied.

`measure` requires a fresh matching PASS/FAIL execution receipt. `verify` and `assess` require all configured qualification checks against the current source and all six claims:

1. `canonical-program`
2. `hand-derived-trace`
3. `model-candidate-agreement`
4. `defect-discovered-and-reduced`
5. `exact-original-failure-replay`
6. `fresh-repair-evaluation`

Missing qualification evidence or an unregistered qualification evaluator stays UNKNOWN and does **not** stop development: a green development check returns to build. Do not invoke a nonexistent evaluator. Legacy verify-phase runs can report `changed` with changed-source artifact evidence to return to build; this never grants claims. Actual UNKNOWN/BLOCKED check execution, unavailable prerequisites, unresolved cleanup and authority drift stop the drive. Success still requires all six independently qualified claims. A status/checkpoint alone does not reset the stall guard.

## Continuous-context integration

The extension registers **no context transformation**. It never reads/writes `LIVE_CONTEXT.md` and does not change CLM settings or cancel native compaction.

Workflow control is persisted as `fenrir-workflow-state-v1` custom entries on the active Pi branch, outside editable conversation summaries. It is reconstructed with `getBranch()`, not all abandoned session entries.

A checkpoint:

- Hashes existing evidence files, without rewriting or admitting them.
- Writes a private advisory checkpoint file.
- Publishes a short context note.
- Uses Pi's public nested-tool API to create a CLM continuity annotation against a real active-branch source entry.
- Resolves the previous pointer after creating the replacement.

CLM may summarize old conversation content while the controller retains phase, bounds and receipt references. The annotation points back to the durable task/checkpoint; `fenrir_status` supplies current state. Neither an annotation nor a conversational summary grants coverage. Failed annotation is reported and cannot silently satisfy the default completion requirement.

## Configure trusted checks

The manifest is `.pi/fenrir-workflow.json`. It currently registers only `workflow-tests`, a **development** check. The required `tc0-a-qualification` entry is intentionally absent: there is no TC0-A evaluator yet, and the controller must not invent one or turn its own passing tests into language qualification.

After a real evaluator exists, stop the run and separately review its implementation, fixtures and authority. Add a qualification check, for example:

```json
"tc0-a-qualification": {
  "kind": "qualification",
  "command": ["node", "tools/qualify-tc0-a.mjs"],
  "timeoutSeconds": 300,
  "authorityPaths": ["tools/qualify-tc0-a.mjs", "model", "fixtures/hand-derived", "schemas"]
}
```

This is a registration example, not an existing evaluator. The authority set must actually cover the trusted runner, oracle, goldens and gate definitions. The candidate must not import those implementations as its own transition engine. Re-inspect/reapprove after any authority change and start a fresh run; candidate repair never rewrites acceptance authority.

Check definitions accept fixed argv only; the model supplies just a check ID. No shell expansion is performed by the controller. Development checks use exit status and have no conformance claims. Qualification commands must print **one JSON report** to stdout, send logs to stderr, and exit consistently: PASS=0, FAIL=1, UNKNOWN/BLOCKED=2.

Qualification report fields:

```text
schema: "fenrir.check.v1"
nonce: FENRIR_CHECK_NONCE
checkId: FENRIR_CHECK_ID
sourceHash: FENRIR_SOURCE_SHA256
configHash: FENRIR_CONFIG_SHA256
verdict: PASS | FAIL | UNKNOWN | BLOCKED
cleanup: confirmed | unresolved
claims: unique list of independently evaluated claim IDs
evidence: unique list of retained repository-relative regular-file paths
summary: concise explanation of the measured scope and result
```

The external evaluator owns whether those claims are true. Echoing these fields or fabricating PASS is not an evaluator implementation. The controller validates framing/identity/exit agreement, source and protected-input stability, executable identity, evidence hashes and required claim coverage; it does not itself implement the language oracle.

`FENRIR_ARTIFACT_DIR` is a private output directory for retained results. Build/proof outputs belong under configured ignored output paths, not source paths. Source changes during a check invalidate the result. Unknown report fields, malformed JSON, stale identity, missing evidence and truncated/oversized output cannot PASS.

## Storage, cancellation and safety

Ignored local output: `.pi/fenrir-workflow-runs/<session-hash>/<run-id>/` contains checkpoint files and per-check stdout/stderr/receipt files. Data files are private; do not publish them without review. Receipts bind source, authority/config and executable hashes, evidence hashes, argv, outcome and recorded process-group identity. Current gate admission rechecks evidence and executable identity. Old completion entries are historical; the status tool separately reports the current-source gate.

One checkout-wide exclusive lease prevents duplicate controllers. No stale lock is automatically stolen. Normal pause/stop releases an owned lease only after confirmed cleanup. If the process crashes, inspect `controller.lock`, the recorded controller PID and retained check process groups before manually removing a stale lock. Never remove another live run's lock.

The runner uses a detached POSIX process group, closed stdin, a private HOME/TMPDIR, a minimal noncredential environment, bounded output and a watchdog. It awaits completion and process-group cleanup, kills unexpected remaining group members, and treats cancellation/timeout/background leftovers as incomplete. If escaped descendants hold output pipes open, a bounded join reports incomplete rather than waiting forever. Windows cleanup is not implemented and fails closed.

**This extension is not an OS sandbox.** Same-user code can still reach host files/network or escape a process group. Hash checks and write/edit hooks detect/prevent ordinary workflow mistakes, not hostile transient changes via arbitrary shell code. Checkpoint cleanup reports are advisory; `/cleanup` is an explicit human acknowledgement, not proof or receipt promotion. Run actual candidate builds/evaluation behind the separately tested isolation boundary required by the plans before claiming that protection. Worktrees, VM language contexts and read-only agent instructions do not replace it.

There is no cached-result resume in this controller. Orchestration checkpoints and TC0 exact semantic tapes remain separate; required checks must match the current source and evidence. It neither implements nor claims ShenCheck/TC0 replay merely by restoring its phase.

## Tests

```sh
npm test
```

Dependency-free Node tests cover the controller, manifest/hashing/lease rules, real local subprocesses, evaluator-report validation, stale evidence, source drift, cancellation/watchdogs, output limits, background processes and mocked Pi/CLM lifecycle integration. Mock evaluator fixtures are not TC0 qualification. No tests call a paid model or execute the real language.

`tools/check-fenrir-extension-load.mjs <Pi SDK root>` additionally checks registration with the actual installed Pi loader, without starting a session or model request.
