# Standalone source-bound evidence

Use Node 22.19+ and Git on macOS or Linux. No Pi, CLM, model session, or npm
install is required. From a clean checkout, review the named command in
[`.pi/fenrir-workflow.json`](../../.pi/fenrir-workflow.json), then pin the
**full** commit you intend to measure:

```sh
node tools/evidence/run.mjs workflow-tests --head FULL_COMMIT
node tools/evidence/run.mjs tc0-a-qualification --head FULL_COMMIT --shen-jit /existing/install
node tools/evidence/run.mjs tc1-qualification --head FULL_COMMIT --shen-jit /existing/install
```

The latter two reuse the existing stock evaluator commands and require an
explicit, already-installed Shen/JIT root. This only skips implicit bootstrap
in the launcher: the evaluators themselves can still invoke Nix and build or
run guests, Erlang and other prerequisites. Do not use those checks as cheap
smokes. This tool does not make an unsupported runner or toolchain supported.
`--timeout-seconds N` can only lower the manifest's bound. The child gets a
private HOME/TMPDIR, and a PATH of absolute directories outside the checkout;
an explicit `FENRIR_SOLO5` is forwarded to the check for a prebuilt Solo5
installation. Arbitrary inherited variables and credentials are not passed
through.

`PASS`, `FAIL`, `UNKNOWN`, and `BLOCKED` exit `0`, `1`, `2`, and `2`.
Inspect the JSON for the exact distinction. Development verdicts describe the
command only. Evaluator verdicts describe the validated external report
(one `fenrir.check.v1` object on stdout with the matching nonce, source and
config identities, agreeing exit status and retained gate report). A PASS
requires that evaluator's full claim set; TC1 does not inherit TC0's claim set.
**Every standalone receipt has `qualification: UNKNOWN`.** Any raw evaluator
qualification fields and reported claims are kept as attributed evidence;
this is not a Pi/controller qualification receipt, adds no gate or claim, and
must not be used to advance the workflow or supersede an authority record.

Receipts, process-group metadata, bounded logs, and a snapshot of the
referenced `gate.json` are private local files under `build/evidence-runs/`.
They bind the full Git commit and tracked bytes/modes, workflow config,
declared authority, launcher executable and Git, and (when supplied) Shen/JIT
binary and libraries. Each retained file has a SHA-256 digest. The referenced
gate report must come from a new stock evaluator output directory; logs and
the gate report copy retain what was observed, not a copy of the entire
build tree or every subordinate artifact referenced by the report.

The runner checks clean source and identity before and after execution and
refuses unsafe paths. The POSIX process group is bounded by a watchdog, an
8 MiB combined output cap, and a bounded termination/join. The evaluator frame
has a separate 512 KiB cap. A checkout lease is shared with the Pi controller
to prevent overlap, but no Pi approval, run state, or receipt is read or
written. If cleanup is unresolved, the lease is held. Do not automatically
remove `.pi/fenrir-workflow-runs/controller.lock`. Inspect its owner PID,
`build/evidence-runs/<runId>/launch.json` and process group (if present), the
receipt, and evaluator artifacts before clearing an abandoned lease.

This is **not a sandbox**: ignored outputs/caches and external tools are not
all in the source snapshot; this does not attest to dynamic libraries,
network/device isolation, or disk usage of the evaluator's own output files.
Only trusted, reviewed source/config and toolchains should be used. A
same-user process can escape a process group, modify files transiently, or
tamper with local receipts and logs. Preserve receipts externally if needed,
and verify their digests before relying on retained files.

## ARM64 development capture (no qualification)

On a reviewed native ARM64 Linux runner with the existing sandbox prerequisites,
prepare the pinned outputs and run from a clean checkout:

```sh
nix build --no-link .#shen-jit .#solo5 .#erlang
commit=$(git rev-parse HEAD)
nix develop --command node tools/evidence/run.mjs arm-development-tc1 --head "$commit"
```

Use `arm-development-g1` to run only G1 (no Erlang needed). No Pi configuration,
approval, or session is used to select these commands. The internal preflight
selects the installed ARM flake outputs; don't pass `--shen-jit`. If the outer or
candidate PATH cannot create a network namespace, or a pinned output is
missing, the preflight blocks rather than weakening confinement. Use only a
trusted reviewed runner and toolchain. The timeout is at most 3,600 seconds
after launch; use `--timeout-seconds` to lower it.

`build/evidence-runs/<runId>/` holds the receipt, bounded outer logs, and fresh
gate reports. The separate ARM frame binds a run nonce, source SHA-256, profile
SHA-256 and the relevant manifest digests, and hashes the exact top report.
TC1 additionally runs G1 as a nested Shen process with that same binding and a
distinct role. TC1's prerequisite row binds the nested report's digest and
verdict, and the capture validates and retains both reports. Missing,
inconsistent, or oversized report evidence yields UNKNOWN. The existing
process-group watchdog is not host-level confinement; subordinate gate work
files are neither quota-bounded nor fully retained as evidence. Review and
clean up the job externally as needed.

PASS is a **development verdict**, never qualification. Neither frame nor
receipt credits claims; old repair waivers, when observed, are diagnostic
only. See the [review proposal](../../campaigns/arm64/QUALIFICATION_PROPOSAL.md)
for unmet admission requirements.

### Opt-in GitHub Actions measurement

The [manual ARM workflow](../../.github/workflows/arm64-gate-development.yml)
requires the full reviewed commit SHA and runs only when that SHA matches
both the dispatched code and workflow. It does not run on pushes, pull
requests, labels, or comments. It uses a hosted ARM64 VM job, read-only
contents permissions, no persisted checkout credential, and no organization
secrets, write token, or private cache. The Nix bootstrap uses a checksummed
public installer; all tools are realized from the checkout's locked flake.
The checkout is not elevated to run the gates.

`unshare -n` needs `CAP_SYS_ADMIN` in the current user namespace
([`unshare(2)`](https://man7.org/linux/man-pages/man2/unshare.2.html)).
The ordinary hosted runner account is **expected to be blocked**; this exact
runner image has not been measured. The workflow probes both PATHs before
any Nix realization and retains the reason in `runner.log` if blocked (there is
no evaluator receipt when the gate is never launched). A passing early probe
still needs the capture's own preflight. No `sudo` for measurement, capability
changes, namespace wrappers, relaxed seccomp, privileged containers, or
unsandboxed fallback. Elevated operations are limited to Nix installation
and enabling the Nix CLI features in its configuration. If blocked, use the
reviewed native ARM host procedure above; don't change the runner security
policy in this workflow. Artifact
retention is seven days. A job hard timeout or cancellation can prevent the
upload; missing output is not evidence.

GitHub [requires a manual workflow to exist on the repository's default
branch](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
`--ref` selects the branch after registration; it cannot bootstrap a
branch-only workflow in the upstream repository. Once available on the
default branch, a maintainer can dispatch the exact reviewed branch by
supplying its SHA:

```sh
gh workflow run arm64-gate-development.yml --ref REVIEWED_BRANCH \
  -f expected_head=FULL_COMMIT -f gate=tc1
```

Without an upstream merge, an authorized maintainer could use a disposable
scratch repository **only if copying the source is approved**, setting its
default branch to the exact reviewed commit without rebasing, adding secrets,
or including a self-hosted runner. Review the other workflow triggers before
publication, or keep Actions disabled until the default branch is seeded.
This would test hosted infrastructure using the same SHA, not establish
upstream authority or overcome the likely namespace blocker. An unpublished
local SHA cannot be dispatched on GitHub.

Fast tests (temporary commits and mock evaluators, no language qualification):

```sh
node --test tests/evidence/*.test.mjs
```
