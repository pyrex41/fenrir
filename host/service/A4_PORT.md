# A4 host port: not integrated

This branch adds a bounded model and a Fenrir program refinement harness. The OTP
host remains A3. Do not use the A4 migration program on a service store, or count
the A4 model/guest evidence as observed OTP, SQLite, or crash-campaign evidence.

The host changes in keen-ptolemy `4c4454c` need a separate port, not a cherry-pick:

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
