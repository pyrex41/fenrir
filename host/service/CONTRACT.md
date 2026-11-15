# A3/A4 host contract: the OTP supervisor and the SQLite storage adapter

Draft 1 • 15 November 2026 • For owner review

The host of stage A3 ([04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §8) is
**infrastructure with a stated contract**: OTP code that supervises Solo5 tender
processes and a SQLite adapter that discharges the handler's durable effect. Nothing here
is covered by Fenrir's proofs. Each statement below is a **named assumption** that the
Fenrir side (the handler program, [spec/service/HANDLER.md](../../spec/service/HANDLER.md),
the A1 model) relies on, with the tests that exercise it. Tests are bounded campaigns:
they can show an assumption broken, they never show it holds.

Evidence status: *observed history accepted; bounded crash campaign*, development grade,
`qualification: UNKNOWN`.

## 1 What the host promises the handler (storage contract)

| Id | Assumption | Where | Exercised by |
| --- | --- | --- | --- |
| **A-CONTRACT** | `Store.commit(Tx)` does to the tenant's store exactly what HANDLER.md §3 (`models/service-a2/store-contract.shen`) says: capability, guard (`Always`, `Once k`, `Pending j`), the writes in order with N = Next, the reply | `fenrir_store:body/5` and `apply_writes/5` | unit `store_contract` (15 cases); `a2_runs`: all 68 distinct (request, replies) runs of the A2 refinement reproduced with the replies the Shen model gives; `hand_traces` (11); every campaign history checked against A1 |
| **A-ATOM** | One commit is one SQLite transaction (`BEGIN IMMEDIATE` … `COMMIT`): after any crash the file holds either all of a commit's writes or none of them | `fenrir_store:run_tx/3` | `sqlite_kills`: kill -9 of the SQLite port program before the n-th statement, before the n-th file write and before the n-th fsync of the request's transaction, for every n until the request completes unharmed; `crash_points` s1–s4; the audit of the SQLite file after every crash; mutants `two_transactions`, `no_transaction` |
| **A-SERIAL** | Transactions on a store are serial: `BEGIN IMMEDIATE` takes the write lock before the guard is read, so a transaction never upgrades a read lock and no two commits interleave; the adapter is one process with one connection | `fenrir_store` | `busy`; `two_workers` (2 workers, concurrent pairs; observed only, see §6) |
| **A-DUR** | A reported commit survives a crash of every host process: WAL journal, `synchronous=FULL` (the WAL is fsynced before `COMMIT` returns), both read back at open and the adapter refuses to start otherwise | `fenrir_store:open_configured/2` | unit `settings_wal_full`; every crash scenario (process crashes only). **Power loss is not tested** (§6); mutant `sync_off` is NOT DETECTED by this campaign |
| **A-BUSY** | `SQLITE_BUSY` (another connection holds the write lock; 50 ms busy timeout) is the outcome `busy`: nothing applied, retryable; never reported as success or as a rollback of committed work | `fenrir_store:run_tx/3`, `finish/4` | `busy` (submit and delivery); unit `settings_busy_is_distinct_outcome`; mutant `busy_as_success` |
| **A-INDET** | A commit whose acknowledgment is lost (the `COMMIT` statement was sent and no answer came back) is reported as `indeterminate`, never as a rollback; a retry with the same key returns the recorded receipt and makes no second mutation | `fenrir_store:finish/4`; `fenrir_worker:outcome/3`; `fenrir_front` | `lost_ack` (the port program kills itself after `COMMIT` completes, before answering); `sqlite_kills` during the commit's writes and fsync; `crash_points` w3, w4, s3 |
| **A-TENANT** | Per-tenant isolation in the schema: every table is keyed by tenant; a commit touches only the rows of the tenant its capability names; a capability naming no tenant is `Unauthorized` | `fenrir_store:schema/0` | unit `unknown_tenant_unauthorized`, `negative_tenant_unauthorized`, `tenants_are_separate`; every `observe` (A1 `authority.frame` through store equality) |
| **A-DEDUP** | The request-key table (key, payload digest, receipt) is consulted inside the same transaction as the writes | `fenrir_store:guard_check/4` | `retries`; mutant `no_dedup` |
| **A-JOBS** | Job records are durable rows; the runner delivers every pending job at least once (it re-reads pending jobs from SQLite on every pass) and the `Pending` guard absorbs duplicates | `fenrir_runner`, `fenrir_store` | `duplicates` (each job delivered twice with opposite outcomes, plus deliveries of finished and unknown jobs); every crash scenario ends with a drained runner; mutant `volatile_mailbox` |

## 2 What the supervisor promises

| Id | Assumption | Exercised by |
| --- | --- | --- |
| **S-RESPONSE** | A response reaches a client only after the commit it reports has returned: the worker returns the program's result, and the program decides it from the commit's reply | `crash_points` w4, f1; mutant `respond_before_commit` |
| **S-RESTART** | Workers, the store process and the SQLite port program are restarted; all state that must survive is in SQLite (the front's outbox is volatile, as A1's is) | `crash_points` with `kill_tender`, `kill_worker`, `kill_store`, `kill_port`, `kill_node`, `halt_node`; recovery checks after each |
| **S-MANIFEST** | A worker is not started for an image whose residual effect row (DURABLE.md §2, read from the artifact) names an effect, operation, operation type or datatype the adapter does not discharge | unit `manifest_refuses` (6 variants), `supervisor_refuses_worker_on_manifest` |
| **S-IDENTITY** | A worker refuses an image whose file, tender or artifact hash differs from its descriptor, and a session whose Hello or Ready does not name the descriptor's protocol, profile, batch, program, artifact and schema | unit `image_sha_mismatch_refused`, `tender_sha_mismatch_refused`, `hello_batch_mismatch_refused`, `hello_wrong_image_refused` |
| **S-FRAMING** | Control protocol v2 framing exactly as specified, guest frames parsed strictly and failing closed | unit `vector` (every byte vector of pure-call-control-v1/-v2.vectors) |

## 3 Where the fault points are

| Point | Place |
| --- | --- |
| `w1_before_request` | worker, after the first Steps response, before the guest's host request |
| `w2_request_before_commit` | worker, the HostRequest received, before `fenrir_store:commit` |
| `w3_commit_before_reply` | worker, the commit returned, before the Reply frame |
| `w4_reply_before_response` | worker, the HostReply step acknowledged, before the program's response |
| `f1_after_response` | node, the response written to the client, before the next command |
| `s1_after_begin` … `s4_after_commit` | store, after `BEGIN IMMEDIATE`; after the first write; before `COMMIT`; after `COMMIT` returned |
| port `before_statement n`, `write n`, `sync n` | the SQLite port program kills itself (SIGKILL) before its n-th statement, file write or fsync from the moment it is armed (a counting VFS shim over SQLite's unix VFS) |
| port `lose_ack` | the port program kills itself after `COMMIT` completed, before writing the answer |

Actions: `kill_tender` (kill -9 of solo5-spt), `kill_worker` (exit kill), `kill_store`
(exit kill of the adapter process), `kill_port` (kill -9 of the port program),
`kill_node` (kill -9 of the BEAM OS process), `halt_node` (`erlang:halt(137,
[{flush,false}])`). After a node death the driver audits the file as the crash left it and
restarts the node from it.

## 4 How a real fault maps to A1

A1's `crash` empties the outbox and keeps the stores; the real outbox is the front's
process state, so only a node death is A1's `crash`. A tender, worker, store or port death
ends the in-flight request with `aborted` (definitely nothing applied) or `indeterminate`
(a commit may have happened), and the checker allows exactly the corresponding A1
behaviours (HISTORY_FORMAT.md §2).

## 5 Host mutants

Each is selected by the store's `mutant` setting, outside the normal code path.

| Mutant | Change | Expected |
| --- | --- | --- |
| `volatile_mailbox` | job records kept in an ETS table owned by a process of the node, not in SQLite (amendment §8, required) | caught |
| `respond_before_commit` | the reply is computed from a read and returned at once; the transaction runs about 200 ms later | caught |
| `two_transactions` | report and key entry in one transaction, the job record in a second | caught |
| `busy_as_success` | on `SQLITE_BUSY`, a `Committed` reply is fabricated from a read and nothing is written | caught |
| `no_dedup` | the `Once` guard is not consulted; the key entry is written with `INSERT OR REPLACE` | caught |
| `no_transaction` | every statement autocommits (no `BEGIN IMMEDIATE`/`COMMIT`) | caught |
| `sync_off` | `synchronous=OFF` | **not detectable by this campaign**: kill -9 of a process leaves the OS page cache intact, so every write the process made survives; only power loss or a kernel crash would show the difference, and neither is simulated |
| `equivalent_control` | guard read by another query, the counter written first, the writes in reverse order | must not be flagged |

## 6 Not covered

Power loss, fsync honesty of the disk and filesystem, disk corruption and torn writes;
SQLite itself; OTP itself; the Solo5 tender and the host kernel (trusted as built); any
isolation contract between several workers beyond what was observed (the adapter is one
process, so commits from two workers are serialized there; no read-then-write isolation
is claimed); performance; requests outside the image's request domain (control protocol
v2 lowers entry inputs into the image, so the image holds one entry per request of a
finite domain and the worker refuses others); authentication of clients.

## 7 Stage A4: the versioned upgrade

Draft 1 • 15 November 2026. The host side of [spec/service/UPGRADE.md](../../spec/service/UPGRADE.md)
§10, as named assumptions. The A4 model and its properties are the contract; the
campaigns of [test/fenrir_campaign_a4.erl](test/fenrir_campaign_a4.erl) record histories
of schema `fenrir.service.history/2` ([HISTORY_FORMAT.md](../../spec/service/HISTORY_FORMAT.md)
§4) checked against the A4 model, and audit the SQLite file after every crash and at the end
(A3's audit plus: the schema, the upgrade state and the columns agree; under schema 2 a
job's attempts are 0 exactly while it is pending and 1 once finished; every told receipt is
recorded with its representation).

| Id | Assumption | Where | Exercised by |
| --- | --- | --- | --- |
| **U-STATE** | The durable upgrade state is the `meta` table: `schema` (`fenrir.host.service-store/1` or `/2`), `upgrade` (`v1`, `prepared`, `migrated`, `v2`), and from begin-upgrade on the v2 image's artifact SHA-256 and the two image descriptors. It is written only by the upgrade transitions, each one `BEGIN IMMEDIATE … COMMIT` that checks the current state first | `fenrir_store:transition/2` | unit `upgrade_full_cycle_in_the_adapter`; `upgrade_crash` at `begin_upgrade_*`, `cut_over_*` with `kill_port`, `kill_store`, `kill_node`; mutant `volatile_upgrade_state` |
| **U-OPEN** | The adapter refuses to open a store whose schema it does not know, whose schema and upgrade state disagree, or whose columns are not those of its schema | `fenrir_store:check_meta/2` | unit `upgrade_unknown_schema_refused_at_open`, `upgrade_inconsistent_state_refused_at_open`, `upgrade_v2_columns_under_schema_1_refused_at_open`; mutants `cutover_before_migration`, `migration_two_transactions` (the node does not restart on the half-migrated file) |
| **U-FENCE** | Every commit carries its contract version in band (`Tx` 1, `Tx2` 2); the store reads `meta` inside the commit's own transaction and refuses (`stale`, nothing applied, no reply; the client is told `unavailable`) a commit whose version is not in force (UPGRADE.md §3, §4.3) | `fenrir_store:fence/2` | unit `upgrade_v2_commit_fenced_while_v1`, `upgrade_full_cycle_in_the_adapter`; `upgrade_stale` (a v1 run held at `w2_request_before_commit` on a worker the supervisor does not know, across migrate and across cut-over, a submit and a delivery; and on a supervised worker across migrate); mutant `no_fencing` |
| **U-MIGRATE** | The migration session: `read 0` takes a snapshot of every job and key row in one read transaction; `install n` is ONE transaction that checks `prepared`, the row count and that the rows still equal the snapshot (else `Changed`, nothing applied), adds the v2 columns, replaces every job and key row by the staged ones, writes `schema` /2 and `upgrade` `migrated`. SQLite's DDL is transactional, so a crash anywhere leaves the file wholly v1 (`prepared`) or wholly v2 (`migrated`). The host installs the rows the Fenrir program computed, checking only their shape | `fenrir_store:migration_install/2` | unit `upgrade_install_changed_after_a_commit`, `upgrade_install_refused_unless_prepared`; `upgrade_cas` (a v1 commit between snapshot and install); `upgrade_crash` at `i1_after_begin` … `i6_after_commit`, `m1_before_request`, `m2_before_install`, `u_after_migrate`, and a node kill between migrate and cut-over; mutants `migration_drops_pending`, `keys_not_migrated`, `receipt_rewritten`, `migration_two_transactions` |
| **U-VERSION** | A worker's image is the one of the version in force: the configured v1 image in `v1`/`prepared`, none in `migrated` (requests are `unavailable`), the recorded v2 image in `v2`. A worker checks this when it starts and again before each run, and stops (to be restarted by its supervisor with the right image) when the version in force changed; `cut_over` restarts the workers at once | `fenrir_worker:init/1`, `handle_call/3`; `fenrir_upgrade:cut_over/0` | `upgrade_load`, `upgrade_crash` at `cut_over_after_commit` and `u_after_cut_over_meta` (the cut-over committed, its reply lost: the workers replace themselves on the next request); mutant `stale_workers` |
| **U-MANIFEST** | `begin_upgrade` admits only a v2 handler image whose manifest is exactly contract 2 and a migration image whose manifest is exactly the migration contract (`fenrir_manifest:contract_version/1`; a descriptor whose claimed `contract_version` differs is refused) | `fenrir_upgrade:begin_upgrade/2`, `fenrir_manifest` | unit `manifest_v2_handler_is_contract_2`, `manifest_migration_program_is_migration_contract`, `manifest_descriptor_claiming_another_contract_refused`; `upgrade_manifest` (5 inadmissible image pairs refused, the state stays `v1`); mutant `no_manifest_check` |
| **U-RECEIPT** | A key row keeps the representation of the receipt recorded for it (`r_version` 1 or 2) across the migration; a replay returns it unchanged | `fenrir_store:guard_check/5`, `insert_rows/3` | `upgrade_load`, `upgrade_crash` (every pre-upgrade request retried after the upgrade: same digest the recorded receipt, other digest conflict); mutants `receipt_rewritten`, `keys_not_migrated` |

Fault points added for A4 (section 3's mechanism): `begin_upgrade_before_commit`,
`begin_upgrade_after_commit`, `cut_over_before_commit`, `cut_over_after_commit` (store,
the transition's transaction); `i1_after_begin`, `i2_after_compare`, `i3_after_ddl`,
`i4_mid_rows`, `i5_before_commit`, `i6_after_commit`, `i7_between_transactions` (store,
the install; i7 in `migration_two_transactions` only); `m1_before_request`,
`m2_before_install` (the migration guest's session); `u_after_migrate`,
`u_after_cut_over_meta` (the orchestration); and the action `pause`, which holds the
process at the point until the driver releases it (stale runs, the compare-and-swap).

Host mutants (A4):

| Mutant | Change | Expected |
| --- | --- | --- |
| `no_fencing` | the store applies a commit whatever its version | caught |
| `migration_drops_pending` | the install does not insert pending job rows | caught |
| `migration_two_transactions` | the install commits the schema change and the job rows, then the key rows and `meta` in a second transaction | caught |
| `keys_not_migrated` | the install inserts no key rows | caught |
| `receipt_rewritten` | the install records every receipt as version 2 | caught |
| `cutover_before_migration` | `cut_over` is allowed in `prepared` | caught |
| `stale_workers` | `cut_over` does not restart the workers and workers do not re-check the version in force (fencing still on) | caught |
| `no_manifest_check` | `begin_upgrade` admits any images | caught |
| `volatile_upgrade_state` | the upgrade state is kept in memory, not in `meta` | caught |
| `equivalent_control_a4` | the install inserts the key rows before the job rows | must not be flagged |

Not covered by A4: replacing a running guest (a run is never migrated); more than one
schema step (v1 → v2 only); rollback between migrate and cut-over and after cut-over (not
supported, UPGRADE.md §4.5); several nodes or several adapters on one file (the fencing
read is per transaction, so it would hold, but it is not exercised); power loss, as A3.
