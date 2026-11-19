# A4 host port: adapter and sequential worker pilot

The default service node and supervisor still run A3/v1. The adapter reads the durable
schema and phase after `BEGIN IMMEDIATE` and before the v1 tenant guard, and
refuses stale v1 requests (including receipt retries) in `migrated` or `v2`.
Malformed metadata fails closed; the default A3 adapter cannot reopen a store
in those later phases. A legacy v1 store is adopted in one transaction; a
SQLite `user_version` marker distinguishes adopted databases from legacy ones,
so missing phase metadata after adoption is not interpreted as v1. Older
unfenced binaries must not be used to open a prepared database. Restart in
any upgraded phase requires the same tenant domain; it cannot add tenants.

The isolated `fenrir_store:maintenance/1` contract is enabled only by supplying
an explicit live local `maintenance_operator` PID when starting the normal
adapter. The service supervisor, controller, ingress, runner, and guest do not
provide access to it. The operator owns `prepare`, `abort`, `cut_over`, and session
creation. Prepare records a fresh durable generation and two pins, each made
from the raw SHA-256 digests of the descriptor, artifact, image, and tender.
Pins here are *supplied by a trusted caller after admission*: this layer does
not admit a manifest or boot an image. The exclusive volatile session binds the
exact preparation and migration pin to a monitored execution PID and a host
reference. `read`, `validate_install`, `install`, and `close` require the owner's PID
and reference. Owner/operator death, adapter restart, or abort invalidate the
session. Denied calls never revoke it: operator death cleanup belongs to the
monitor even when a call is received first. Trusted local Erlang code and the
store file remain host-side assumptions;
this is not isolation from arbitrary code running inside the OTP VM.

`validate_install` is a dry run; `install` repeats the same checks under a
SQLite write lock and consumes the session. It compares the exact preparation
and captured job/key/report/payload/counter snapshot, then validates job attempts,
keys and receipts against the only permitted projection. Installation adds the
v2 columns in place, backfills terminal attempts, and writes schema 2 and
`migrated` phase in the same transaction. Existing receipts remain v1 and both
handler contracts are fenced until the operator cuts over using the exact
generation and handler pin. A lost commit acknowledgement remains indeterminate;
reopen the opted-in adapter and read durable state to resolve it.

The `commit_v2/4` entry accepts a host-derived tenant scope, admitted
handler pin and original request, plus a `Tx2` value. It checks the two exact
accepted-job write shapes against the host request (including payload and job ID),
and checks the durable phase and handler pin inside the write transaction.
It preserves v1 receipts on retries, creates v2 receipts for new keys, and
finishes a pending job and counts its attempt in one transaction. The
unversioned snapshot API refuses after installation.

The opt-in worker pilot boots stock Solo5 v1, migration, and v2 guests on a
temporary store. `fenrir_a4_upgrade` admits the exact source-bound migration and
v2 contracts, checks the request table and input-bound batch digest, then uses
the existing OTP operator/session capability. Each v2 launch checks the pin in
force and loads the pinned descriptor, artifact, image, and tender again; it
launches private copies of the image and tender from those checked bytes, not
from the descriptor's original paths. The launch directory and launcher are
trusted host configuration and the image builder is a trusted source of images.
The migration process is itself the monitored owner. It reads one row at a
time from a bounded snapshot, stages typed rows, and asks the store to validate
and atomically install them. A changed snapshot can be explicitly refreshed by
the same admitted owner. It does not send maintenance authority to the guest.

Run `sh host/service/check-a4-workers.sh` on ARM64 Linux with the explicit
tool prefixes named in the script. The pilot compares each v2 guest's response
to its one store reply before the front will publish it, and records one `/2`
history with independent SQLite phase and store observations. The report
requires the verifier's exit and exactly the expected verdict for every
control. No crash campaign is claimed for this pilot.

## Development checks

- `sh host/service/check-host-only.sh` on ARM64 Linux, Erlang/OTP 28:
  145 unit checks passed. The 14 A4 cases cover scope and session revocation,
  exact snapshot/projection, racing v1 writes, partial-DDL rollback, lost
  install acknowledgement, restart, cut-over, old/new receipts and delivery
  deduplication.
- The unchanged A3 `sh host/service/check.sh quick` passed on ARM64 Linux
  with an explicit tool prefix and pinned-source Shen/JIT and Solo5 builds:
  152 unit checks, 338 campaign histories, 197 clean normal histories, all 14 SQLite sweeps,
  and all 18 history controls as expected. Six semantic mutants were caught,
  the equivalent control stayed clean, and `sync_off` remains undetected by
  the process-kill campaign. Qualification is `UNKNOWN`.
- `host/service/test/fault-controls.py` on that quick campaign: all eleven
  fault/observation substitutions were rejected and the same-boot observation
  retry was accepted.
- The real worker pilot migrated four rows with ten host requests, returned an
  old receipt unchanged, issued and retried a new v2 receipt, preserved job
  state across restart, refused unauthorized migration and submit, and refused
  a substituted descriptor. The sequential `/2` checker admitted the observed
  history; its seven controls cover wrong pins, gaps, skipped observations,
  claimed faults, lost work, altered receipts, and wrong unavailability.

## Remaining work

Remaining host work from keen-ptolemy `4c4454c`, not a cherry-pick:

1. **Integrate supervisory cut-over and recovery.** The pilot explicitly
   restarts the front with v2 worker names; it does not automatically route
   traffic by durable phase, preserve a live outbox across worker replacement,
   manage the maintenance operator under the default supervisor, or recover
   hosting automatically across each upgrade phase. Keep the existing OTP
   credential-to-scope binding and the trusted delivery path. Do not add the
   upstream unscoped `request_on/2`.
2. **Port the A4 campaign, not only its checker.** The `/2` pilot is sequential
   and does not accept crash, fault, or concurrent-group events. Port the A4 matrix into the
   current campaign driver and report, with a planned denominator, per-row
   exit/verdict and tender/image identity, observed fault effects, and explicit
   recorder gaps carried across restart. A missing row, lost or unobserved
   fault, infrastructure failure, or missing verifier verdict cannot certify
   the normal path or count as a mutant caught. Run equivalent controls as
   healthy cases and require semantic counterexamples for genuine mutants.
   Do not re-pin the gate from the upstream report; there is no local A4 host
   campaign evidence to pin.

Power-loss/fsync qualification is out of scope. The proposed experiment needs
separate approval; no such experiment is required by the model or guest
development checks.
