# A4 host port: adapter slice only

The service node and worker still run A3/v1. The adapter reads the durable
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

The isolated `commit_v2/4` entry accepts a host-derived tenant scope, admitted
handler pin and original request, plus a `Tx2` value. It checks the two exact
accepted-job write shapes against the host request (including payload and job ID),
and checks the durable phase and handler pin inside the write transaction.
It preserves v1 receipts on retries, creates v2 receipts for new keys, and
finishes a pending job and counts its attempt in one transaction. The
unversioned snapshot API refuses after installation. No service-node API or
worker calls `commit_v2/4`; do not run the migration guest on this adapter.

Do not count the A4 model/guest checks or the adapter fixtures as full-stack A4
history or crash-campaign evidence. Tests perform actual adapter upgrades on
temporary stores with trusted fixture projections; no deployed worker served
v2 and no upgrade ran through a guest.

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

## Remaining work

Remaining host work from keen-ptolemy `4c4454c`, not a cherry-pick:

1. **Preserve scoped ingress and publication.** `fenrir_front:submit/4` authenticates
   a credential before choosing a worker and supplies a host-derived `{tenant,T}`
   separately from the request to `fenrir_worker:run/3`. Keep that API, the trusted
   `deliver/3` path, the worker's request binding, and per-operation scope checks
   inside the store. Add an exact scoped decoder for v2 receipts while retaining the
   v1 receipt decoder for v2 retries of pre-upgrade keys. A stale-worker campaign
   must not reintroduce the upstream `request_on/2` path on unauthenticated
   tenant-bearing requests. Test unauthorized submission, cross-tenant guest
   requests and response mismatch under both handler versions.
2. **Give migration its own host-owned capability.** Upstream
   `fenrir_store:migration/2` uses one adapter-wide `{Rows,Staged}` session;
   `migration_read(0,…)` replaces it and the calls do not identify its owner.
   Isolate privileged maintenance from the customer and delivery paths. Bind
   `read/stage/install` in the host to the admitted migration image, one live
   migration execution, and the exact durable preparation it started under.
   Invalidate on death, abort or replacement; reject cross-session operations,
   handler-originated migration effects and installs after a replacement
   preparation. These are host checks, not guest parameters.
   Replace the adapter fixture's full-row snapshot/read with bounded,
   per-row staging and typed reply size checks at the actual worker boundary.
3. **Bind the running worker to admitted bytes.** The adapter persists and checks
   pins but does not verify artifacts itself. Revalidate the exact admitted bytes
   at every launch/restart, with no mutable path substitution or version fallback.
   Select and replace workers on the host without weakening the adapter fence;
   map stale outcomes to unavailable without publishing a receipt. Exercise
   descriptor replacement and recovery at each durable phase with real workers.
4. **Retain the A3 evidence rules when adding `/2`.** Keep `/1` strict and add
   separate `/2` histories and negative fixtures. Port the A4 matrix into the
   current campaign driver and report, with a planned denominator, per-row
   exit/verdict and tender/image identity, observed fault effects, and explicit
   recorder gaps carried across restart. A missing row, lost or unobserved
   fault, infrastructure failure, or missing verifier verdict cannot certify
   the normal path or count as a mutant caught. Run equivalent controls as
   healthy cases and require semantic counterexamples for genuine mutants.
   Do not re-pin the gate from the upstream report; there is no local A4 host
   evidence to pin.

Power-loss/fsync qualification is out of scope. The proposed experiment needs
separate approval; no such experiment is required by the model or guest
development checks.
