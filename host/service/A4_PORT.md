# A4 host port: adapter slice only

The service node and worker still run A3/v1. The adapter reads the durable
schema and phase after `BEGIN IMMEDIATE` and before the v1 tenant guard, and
refuses stale v1 requests (including receipt retries) in `migrated` or `v2`.
Malformed metadata fails closed; the v1 adapter cannot reopen a store already
in those later phases. A legacy v1 store is adopted in one transaction; a
SQLite `user_version` marker distinguishes adopted databases from legacy ones,
so missing phase metadata after adoption is not interpreted as v1. Older
unfenced binaries must not be used to open a prepared database. Restart in
`prepared` also requires the same tenant domain; it cannot add tenants.

The isolated `fenrir_store:maintenance/1` contract is enabled only by supplying
an explicit live local `maintenance_operator` PID when starting the normal
adapter. The service supervisor, controller, ingress, runner, and guest do not
provide access to it. The operator owns `prepare`, `abort`, and session
creation. Prepare records a fresh durable generation and two pins, each made
from the raw SHA-256 digests of the descriptor, artifact, image, and tender.
Pins here are *supplied by a trusted caller after admission*: this layer does
not admit a manifest or boot an image. The exclusive volatile session binds the
exact preparation and migration pin to a monitored execution PID and a host
reference. `read`, `validate_install`, and `close` require the owner's PID
and reference. Owner/operator death, adapter restart, or abort invalidate the
session. Trusted local Erlang code and the store file remain host-side assumptions;
this is not isolation from arbitrary code running inside the OTP VM.

`validate_install` is a dry run. It consumes the session, locks the database,
checks the exact current preparation and the captured job/key/report/payload/
counter snapshot, and validates the v2 job attempts and unchanged key/receipt
rows. No rows or schema are changed. The real installation must repeat those
checks inside its own write transaction. A lost acknowledgement for a metadata
commit is indeterminate and resolved by reading durable state after restart,
never by claiming rollback. Do not run the migration guest on this adapter;
there is no migration effect endpoint, v2 submit path, or cut-over operation.

Do not count the A4 model/guest checks or the adapter fixtures as full-stack A4
history or crash-campaign evidence. The tests inject later metadata states in
temporary stores to challenge the fence; those fixtures do not perform an upgrade.

## Development checks

- `sh host/service/check-host-only.sh` on ARM64 Linux, Erlang/OTP 28:
  140 unit checks passed. The nine A4 cases cover metadata adoption and restart,
  stale writes and retries, scoped submission while prepared, concurrent SQLite
  writer refusal, image/session mismatch and revocation, exact migration
  projection, and a lost metadata commit acknowledgement.
- The unchanged A3 `sh host/service/check.sh quick` passed on ARM64 Linux
  with an explicit tool prefix and pinned-source Shen/JIT and Solo5 builds:
  338 campaign histories, 197 clean normal histories, all 14 SQLite sweeps,
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
3. **Couple identity, version and store transaction.** Persist the admitted handler
   and migration identities (not just the v2 artifact hash and mutable descriptor
   paths). Revalidate the exact admitted identities at use/restart, with no version
   fallback. Select the worker version on the host; in the same write transaction
   as the mutation enforce the durable version/phase and the existing request
   scope. Validate the staged rows against the snapshot and the preservation
   obligations. Install rows plus schema/phase atomically. Test a v1 commit
   racing install, stale v1 after migration and cutover, descriptor replacement,
   and recovery at each durable phase. A SQLite commit with an unknown outcome
   must remain indeterminate, not be recoded as a refusal or rollback.
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
