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
/fenrir-workflow drive --turns=120 --minutes=120 --repairs=6 Verify the Linux x86-64 runner and pinned toolchain; run only tc0-a-qualification on clean HEAD, retain its controller receipt, then checkpoint and stop for review. No P2 edits in this run.
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

The manifest is `.pi/fenrir-workflow.json`. It registers three **development** checks and the separate owner-reviewed **qualification** check:

| Check | Exercises | Typical time |
| --- | --- | --- |
| `workflow-tests` | The controller itself; no language behavior | ~30 s |
| `tc0-candidate-tests` | TC0 validators, candidate machines, generation, reduction and replay unit tests | ~15 s |
| `tc0-pure-call-oracle` | Fresh Shen-vs-candidate agreement on the pure-call hand cases, then strict replay of that fresh report | ~13 s |
| `tc0-a-qualification` | Fresh source-bound TC0-A gate across all required manifest rows and six claims | Up to 30 min; last recorded run took about 5.2 min |

The two TC0 checks give the agent loop semantic back pressure at measure boundaries (03_PHASED_EXECUTION_PLAN.md §5). They are development evidence only: no claims, no qualification credit. `tc0-a-qualification` is a distinct registered evaluator configured as a required check. Its last documented PASS is source-bound to `1db7471` and carries the waivers described in [`campaigns/tc0/G1_EVALUATOR_REVIEW.md`](../../../campaigns/tc0/G1_EVALUATOR_REVIEW.md); run it again on clean HEAD on a supported Linux x86-64 runner before treating G1 as current. Review the controller receipt, then approve P2 as a separate bounded run. The first protected-source edit makes affected G1 evidence historical; G2 must evaluate A and B rows against final source.

`tc0-pure-call-oracle` needs a Shen oracle. Because checks run with a minimal environment, it reads a fixed, ignored path instead of an environment variable:

```sh
mkdir -p build/toolchain
ln -s "$FENRIR_SHEN_SOURCE/_build/bin/shen-scheme" build/toolchain/shen-scheme
```

The existing checker tools expect the older shen-scheme layout with `lib/shen-scheme/shen.boot`. shen-scheme 0.50 no longer ships that file and is reported as BLOCKED. The repository flake now pins shen-scheme v0.26, whose Linux binary has the expected layout; the original check measured 9/9 hand cases agreeing and replaying, with an injected `sub` operand-order mutant failing on `mutual-tail-countdown`. That is environment evidence; the registered G1 gate separately exercises the current schema `/2` scope (24 hand cases in its latest documented run).

Without that link, or if the link does not resolve to a `shen-scheme` build with `lib/shen-scheme/shen.boot`, the check exits 2 and the controller records **BLOCKED** (its `blockedExitCode`), which pauses the drive rather than starting a repair. A missing oracle is never PASS and never a candidate failure. A real exit 1 can be a semantic disagreement or an oracle/tool error; read the check's stderr before repairing. Outputs go to `build/tc0/dev-check/` and are deleted at the start of each run, so stale reports cannot stand in for fresh observations.

For the fast development oracle check, only the launcher `tools/tc0/dev-check-pure-call-oracle.mjs` is in that check's `authorityPaths`. The qualification check has its own wider authority set in `.pi/fenrir-workflow.json`, including the evaluator, manifest, ledger, catalog, model, fixtures, tools, tests, S3 packet and toolchain flake. Changes to those inputs require a fresh source-bound qualification run; review authority changes before modifying the trusted evaluator or its inputs.

### Faster oracle: Yggdrasil-shaken pure-call model

The pure-call model runs through `models/tc0/pure-call-oracle.shen`, a batch driver that reads every case's initial state as data on stdin and runs them all in one process. Optionally, [Yggdrasil](https://github.com/pyrex41/yggdrasil) tree-shakes that driver and the model into an eval-free standalone SBCL executable (manifest `needs-eval=false`, `cannot-reach=eval`):

```sh
nix shell nixpkgs#sbcl -c node tools/tc0/build-shaken-oracle.mjs \
  --yggdrasil /path/to/yggdrasil --shen-cl /path/to/built/shen-cl
```

The build admits the artifact only if its observations are byte-identical to host Shen (`build/toolchain/shen-scheme`) running the same driver on every hand case. It writes `build/toolchain/tc0-pure-call-oracle/` with a stamp binding it to the SHA-256 of the three model sources. `tc0-pure-call-oracle` uses the artifact while that stamp matches and falls back to host Shen (saying so on stderr) once any model file changes; the checker refuses a stale artifact outright. Use a host with exact integers: shen-go uses float64 and silently loses the I64 overflow traps, while shen-cl/SBCL and shen-scheme are exact.

Measured on the 9 hand cases, on a 4-CPU machine running other builds: the oracle alone went from ~4.9 s (one Shen process per case, ~600 `-e` expressions each) to ~0.64 s batched on host Shen and ~0.43 s shaken. End to end, the check went from ~15 s to ~8–9 s; the shaken and batched host runs are within noise of each other, because the remaining time is candidate runs and strict replay. A stat-keyed digest cache (`tools/tc0/digest-cache.mjs`, `build/cache/`) avoids rehashing large toolchain binaries such as the 123 MB Node executable on every run.

The repository flake now pins this toolchain (`nix build .#shen-scheme .#shen-cl .#yggdrasil`; `nix run .` links `build/toolchain/shen-scheme`). The shen-cl package performs the bootstrap below inside the Nix sandbox. The manual steps remain for reference.

Bootstrapping shen-cl without a prior shen-cl build (verified in a Linux cloud session on 11 October 2026, environment evidence only):

```sh
git clone https://github.com/pyrex41/yggdrasil && (cd yggdrasil && nix shell nixpkgs#go -c go build -o ../ygg .)
git clone https://github.com/Shen-Language/shen-cl && cd shen-cl
make fetch FetchCmd="curl -sSOL"          # kernel 41.2 sources
mkdir -p compiled                          # precompile with nixpkgs' Tarver S41.2 SBCL port:
printf '(load "scripts/build.shen")\n(build)\n' | $(nix build --no-link --print-out-paths nixpkgs#shen-sbcl)/bin/shen-sbcl
nix shell nixpkgs#sbcl -c make build-sbcl  # bin/sbcl/shen
```

The REPL reports `empty stream` and exits once stdin ends; check that `compiled/` holds every kernel file before building. With Yggdrasil `a40d8c5`, shen-cl `dff7445` and SBCL 2.6.8, the schema /2 model shook to an eval-free slice (`needs-eval=false`, `cannot-reach=eval`, kernel `42-s42.20260825`) and passed parity on all 19 hand cases. It also produced per-program traces identical to shen-scheme v0.26 on all 5,051 exhaustive-small programs (`tools/check-tc0-pure-data-exhaustive.py --oracle-artifact`) and on the 2,908-program exact-arithmetic ledger. On the large exhaustive batch, the shaken artifact was slower than host shen-scheme (about 88 s versus 66 s), so batch size decides which oracle is faster.

A development check MAY declare `blockedExitCode` (an integer from 2 to 125) for an unavailable prerequisite. Only that exact exit maps to BLOCKED; every other nonzero exit is FAIL. Qualification checks cannot declare it; their JSON report owns the verdict.

The registered `tc0-a-qualification` entry runs `python3 -I tools/check-tc0-a-gate.py` with the authority paths listed in `.pi/fenrir-workflow.json`. That set must continue to cover the trusted runner, oracle, goldens and gate definitions. The candidate must not import those implementations as its own transition engine. Re-inspect/reapprove after any authority change and start a fresh run; candidate repair never rewrites acceptance authority.

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
