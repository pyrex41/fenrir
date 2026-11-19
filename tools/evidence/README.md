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
arbitrary inherited variables and credentials are not passed through.

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

Fast tests (temporary commits and mock evaluators, no language qualification):

```sh
node --test tests/evidence/*.test.mjs
```
