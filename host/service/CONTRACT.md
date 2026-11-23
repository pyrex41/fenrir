# A3 host contract: the OTP supervisor and the SQLite storage adapter

Draft 1 • 15 November 2026 • For owner review

The host of stage A3 ([04_DIRECTION_AMENDMENT.md](../../docs/design/04_DIRECTION_AMENDMENT.md) §8) is
**infrastructure with a stated contract**: OTP code that supervises Solo5 tender
processes and a SQLite adapter that discharges the handler's durable effect. Nothing here
is covered by Fenrir's proofs. Each statement below is a **named assumption** that the
Fenrir side (the handler program, [spec/service/HANDLER.md](../../spec/service/HANDLER.md),
the A1 model) relies on, with the tests that exercise it. Tests are bounded campaigns:
they can show an assumption broken, they never show it holds.

Original A3 evidence: *observed history accepted; bounded crash campaign*, development
grade, `qualification: UNKNOWN`. That campaign has not been rerun on PR10; see
[INTEGRATION.md](INTEGRATION.md). The table lists the original tests and campaigns,
not a record that they all ran in this integration.

## 1 What the host promises the handler (storage contract)

| Id | Assumption | Where | Exercised by |
| --- | --- | --- | --- |
| **A-CONTRACT** | `Store.commit(Tx)` does to the tenant's store exactly what HANDLER.md §3 (`models/service-a2/store-contract.shen`) says: capability, guard (`Always`, `Once k`, `Pending j`), the writes in order with N = Next, the reply | `fenrir_store:body/5` and `apply_writes/5` | unit `store_contract` (15 cases); `a2_runs`: all 68 distinct (request, replies) runs of the A2 refinement reproduced with the replies the Shen model gives; `hand_traces` (11); every campaign history checked against A1 |
| **A-ATOM** | One commit is one SQLite transaction (`BEGIN IMMEDIATE` … `COMMIT`): after any crash the file holds either all of a commit's writes or none of them | `fenrir_store:run_tx/3` | `sqlite_kills`: kill -9 of the SQLite port program before the n-th statement, before the n-th file write and before the n-th fsync of the request's transaction, for every n until the request completes unharmed; `crash_points` s1–s4; the audit of the SQLite file after every crash; mutants `two_transactions`, `no_transaction` |
| **A-SERIAL** | Transactions on a store are serial: `BEGIN IMMEDIATE` takes the write lock before the guard is read, so a transaction never upgrades a read lock and no two commits interleave; the adapter is one process with one connection | `fenrir_store` | `busy`; `two_workers` (2 workers, concurrent pairs; observed only, see §6) |
| **A-DUR** | A reported commit survives a crash of every host process: WAL journal and `synchronous=FULL` (SQLite requests WAL sync before `COMMIT` returns), both checked at open and the adapter refuses to start otherwise | `fenrir_store:open_configured/2` | `settings_wal_full`, `settings_refuse_non_wal_database`, `settings_wal_commit_requests_sync` (FULL vs OFF VFS calls); crash scenarios (process crashes only). **Power loss is not tested** ([validation plan](STORAGE_VALIDATION.md)); `sync_off` is NOT DETECTED by the crash campaign |
| **A-BUSY** | `SQLITE_BUSY` (another connection holds the write lock; 50 ms busy timeout) is the outcome `busy`: nothing applied, retryable; never reported as success or as a rollback of committed work | `fenrir_store:run_tx/3`, `finish/5` | `busy` (submit and delivery); unit `settings_busy_is_distinct_outcome`; mutant `busy_as_success` |
| **A-INDET** | A commit whose acknowledgment is lost (the `COMMIT` statement was sent and no answer came back) is reported as `indeterminate`, never as a rollback; a retry with the same key returns the recorded receipt and makes no second mutation | `fenrir_store:finish/5`; `fenrir_worker:outcome/3`; `fenrir_front` | `lost_ack` (the port program kills itself after `COMMIT` completes, before answering); `sqlite_kills` during the commit's writes and fsync; `crash_points` w3, w4, s3 |
| **A-TENANT** | OTP binds each submit invocation to a tenant. The guest's serialized `Tenant t` is a claim checked against that binding, not proof of authority. A mismatched claim aborts before SQL; all authorized tenant-table queries use the bound tenant; a matching scope without a configured tenant is `Unauthorized` at the adapter. | `fenrir_authority`, `fenrir_front`, `fenrir_worker`, `fenrir_store:commit/2` | unit `credential_scopes_front_dispatch`, `guest_scope_mismatch_cannot_read_or_write`; full-run units `authenticated_guest_submit`, `real_guest_wrong_tenant_is_rejected`; existing per-tenant fixtures and A1 `authority.frame` observations |
| **A-DEDUP** | The request-key table (key, payload digest, receipt) is consulted inside the same transaction as the writes | `fenrir_store:guard_check/4` | `retries`; mutant `no_dedup` |
| **A-JOBS** | Job records are durable rows; the runner delivers every pending job at least once (it re-reads pending jobs from SQLite on every pass) and the `Pending` guard absorbs duplicates | `fenrir_runner`, `fenrir_store` | `duplicates` (each job delivered twice with opposite outcomes, plus deliveries of finished and unknown jobs); every crash scenario ends with a drained runner; mutant `volatile_mailbox` |

### Tenant trust boundary

- **Submit ingress.** `fenrir_front:submit(Credential, Key, Digest, Payload)` has
  no tenant selector. The trusted operator provisions a `submit_credentials`
  map in the OTP application config, from binary SHA-256 fingerprints of
  random 32-byte bearer tokens to tenant IDs in `0..tenants-1`. Absent bindings
  deny every submit; malformed bindings refuse supervisor start. Missing,
  unknown or malformed credentials never dispatch a worker. The token is not
  forwarded to the worker or encoded into the image or guest protocol.
- **Guest invocation.** OTP selects the pre-lowered entry for the authenticated
  tenant and request. Its `Cap.Tenant(t)` input is useful to the handler but is
  not an unforgeable wire token. The separate per-invocation scope stays in the
  host worker. Each `Store.commit` checks the guest's claim against that scope
  before reading a guard, releasing a receipt, or writing. Mismatches do not get
  a guest reply. The front checks the response kind against the request and
  binds submit receipts to tenant, key and digest (conflicts to tenant and key).
  A mismatch is indeterminate and does not enter the outbox; it cannot undo a
  commit. Neither can a busy or denied later host call erase evidence of an
  earlier commit in the same session. This enforces a tenant frame and response
  correlation, not per-operation privileges within a tenant or confidentiality
  against a hostile platform.
- **Trusted components.** Same-VM Erlang code, supervisor/configuration, store,
  durable-job runner, image metadata and launch environment are trusted.
  `deliver/3` takes scope from a trusted job row (or a fixture on the test
  control pipe). `respond/1`, `outbox/0`, all-tenant snapshots, direct worker/store
  calls and the controller's fds are privileged, not client APIs. The controller
  intentionally impersonates fixtures using fresh per-boot credentials so its
  tenant-labelled A1 schedules are unchanged. The scope tuple is not security
  against arbitrary Erlang code, distribution/RPC access or host compromise.
- **Not production authentication.** This checks possession of a pre-provisioned
  bearer token for a finite demo domain; there is no client transport, issuer,
  identity proof, secret distribution, expiry, revocation, rotation, auditing or
  protection of tokens from trusted OTP inspection. The owner must choose those
  before exposing an ingress, and must keep the privileged controller separate.

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
| `w2_request_before_commit` | worker, the HostRequest received, before `fenrir_store:commit/2` |
| `w3_commit_before_reply` | worker, the commit returned, before the Reply frame |
| `w4_reply_before_response` | worker, the HostReply step acknowledged, before the program's response |
| `f1_after_response` | node, the response written to the client, before the next command |
| `s1_after_begin` … `s4_after_commit` | store, after `BEGIN IMMEDIATE`; after the first write; before `COMMIT`; after `COMMIT` returned |
| port `before_statement n`, `write n`, `sync n` | the SQLite port program kills itself (SIGKILL) before its n-th statement, file write or fsync from the moment it is armed (a counting VFS shim over SQLite's unix VFS) |
| port `lose_ack` | the port program kills itself after `COMMIT` completed, before writing the answer |

Actions: `kill_tender` (kill -9 of solo5-spt), `kill_worker` (exit kill), `kill_store`
(exit kill of the adapter process), `kill_port` (kill -9 of the port program),
`kill_node` (kill -9 of the BEAM OS process), `halt_node` (`erlang:halt(86,
[{flush,false}])`). After a node death the driver audits the file as the crash left it and
restarts the node from it.

Each named injection requires evidence for the armed point, action and target:
the original BEAM exit status plus its fault receipt, a monitored Erlang process
death, or the exact OS port's SIGKILL wait status. A lost acknowledgment also
requires the port's post-COMMIT diagnostic (not a SQL reply), SIGKILL, and the
expected state change before the retry. `no_transaction` and
`respond_before_commit` do not run `lost_ack`: neither has a COMMIT whose
acknowledgment controls the response to the target request. They still run their
other mutant scenarios.

For tender kills the driver compares the hook's PID with the active request's
tender PID captured by the worker at spawn, before fault injection. A recorder
gap, including a timeout during a recovery snapshot, is an evidence error;
it cannot count as a mutant detection.

A recorded observation must come from the boot that received its snapshot
request. It can retry while that boot's store restarts. If the node exits before
the snapshot arrives, the driver records a gap and stops the scenario without
substituting a snapshot from another boot. An intentional fault before a
recovery observation still restarts the node and observes the new boot.

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
finite domain and the worker refuses others); production client authentication.
