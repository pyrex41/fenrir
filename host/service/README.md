# host/service: stage A3, the accepted-job service on OTP, SQLite and Solo5

Stage A3 of [04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §8: "SQLite
adapter under an OTP supervisor, Fenrir worker in Solo5, black-box crash and history
tests against the contract". The Fenrir handler
([examples/service/accepted-job.fen](../../examples/service/accepted-job.fen)) runs
unchanged as a Solo5 guest; the OTP host supervises the tender processes and discharges
the handler's one durable operation, `Store.commit`, against SQLite. The host is
infrastructure with a stated contract, [CONTRACT.md](CONTRACT.md): named assumptions,
each mapped to the tests that exercise it, none covered by Fenrir's proofs.

**Evidence status: observed history accepted; bounded crash campaign.** Development
grade, `qualification: UNKNOWN`. Every history a campaign records is checked against the
A1 model ([harness/service-history.shen](../../harness/service-history.shen)); an accepted
history says that this recorded execution is consistent with the contract, nothing about
executions that were not run.

```
sh host/service/check.sh          # quick, about 5 minutes here (A3 and A4)
sh host/service/check.sh full     # every campaign repeated 5 times, about 10 minutes
```

It builds everything through nix (`nix build .#fenrir-a3-tools`: Erlang/OTP 28.5,
SQLite 3.53.3, gcc, node 22, pinned by the flake's nixpkgs input), elaborates the handler
(or uses the committed artifact copy when the frontend's emit fails; see below), builds
the guest image, runs the unit tests, the campaigns and the history checker, and writes
`build/host/service/<run>/report.json`.

## Architecture as built

```
campaign driver (its own BEAM; client, recorder, fault injector, file auditor)
   |  {packet,4} external terms on fds 3/4 of the node (priv/node-launch)
service node (BEAM OS process)                       -- killed and restarted by campaigns
   fenrir_node            control channel
   fenrir_service_sup     one_for_one
     fenrir_holder        ETS owner (volatile_mailbox mutant only)
     fenrir_store         the SQLite adapter, one connection --> fenrir_sqlite_port (C, port)
     fenrir_worker_sup    one_for_one
       fenrir_worker wN   one solo5-spt per request --> priv/spt-launch --> solo5-spt
     fenrir_front         submit / complete / respond, volatile outbox
     fenrir_runner        delivers pending jobs (at least once)
```

- **Pipes.** An Erlang port gives the child stdin and stdout only. The tender wants the
  guest's `ctlin` on a descriptor (fd 0 here) and `ctlout` on another (fd 2), with the
  console kept apart. [priv/spt-launch](priv/spt-launch) is one `exec` line with no
  semantics: `solo5-spt --mem=32 --net:ctlin=@0 --net:ctlout=@2 IMAGE 2>&1 1>CONSOLE`, so
  the port's stdin is `ctlin`, the port's stdout is `ctlout` and fd 1 is a console file.
  `exec` keeps the process id, so the port's `os_pid` is the tender's (kill -9 works).
- **Protocol.** [fenrir_worker](src/fenrir_worker.erl) speaks control protocol v2
  ([spec/solo5/pure-call-control-v2.md](../../spec/solo5/pure-call-control-v2.md)):
  Hello checked against the image descriptor (protocol, machine profile, batch, program
  count), Init with the request's entry (artifact hash, schema, fuel 5000), Run 64 steps
  at a time, each HostRequest handed to the store, the Reply frame, the HostReply step
  echo checked, the program's result from the TaskTermination outcome, Terminate, Bye,
  exit status 0 and no trailing output. Framing is parsed strictly in v1 §4 order
  ([fenrir_proto](src/fenrir_proto.erl)); every byte vector of the v1 and v2 vector files
  is checked by the unit tests. Any deviation kills the tender and the request has no
  response.
- **One request per boot.** The protocol runs one program per boot (v1 §6), and v2 lowers
  the entry input into the image (v2 §3), so the image ([tools/build-image.mjs](tools/build-image.mjs),
  which drives the A2 build step `tools/solo5/control-durable-build.mjs` unchanged)
  holds one entry per request of a finite domain: 3 tenants, 3 keys, 2 digests (payload =
  the digest octet, A2's abstraction), deliveries of jobs 0–7 with both outcomes, 66
  entries. A request outside the domain is refused before anything runs.
- **SQLite binding: a C port program** ([c_src/fenrir_sqlite_port.c](c_src/fenrir_sqlite_port.c)),
  built with gcc against nixpkgs' sqlite. Chosen over a NIF library (esqlite, exqlite)
  because it has the fewest unpinned inputs (nixpkgs' sqlite and gcc, nothing from hex),
  and because it puts SQLite in its own OS process, which the campaigns kill -9 in the
  middle of a transaction. It executes statements and holds no storage logic; the
  transaction is written in [fenrir_store](src/fenrir_store.erl). A counting VFS shim
  over the unix VFS lets a campaign kill the program before its n-th write or fsync.
- **Storage.** WAL journal, `synchronous=FULL` (the WAL is fsynced before `COMMIT`
  returns; with `NORMAL` a committed transaction can be lost on power loss), foreign keys
  on, 50 ms busy timeout, all read back at open. Tables `tenants(tenant, next)`,
  `reports(tenant, id, digest, payload)`, `jobs(tenant, id, report, status)`,
  `request_keys(tenant, key, digest, receipt fields)`, each keyed by tenant. One
  `BEGIN IMMEDIATE … COMMIT` per `Store.commit`.
- **Outcomes.** `busy` (SQLITE_BUSY: nothing applied), `aborted` (definitely not
  applied), `indeterminate` (the `COMMIT` was sent and no answer came back, or the worker,
  store or node died after a commit could have happened). The handler's `Reply` type has
  no failure constructor, so a busy or indeterminate commit cannot be told to the program:
  the worker ends the run without a reply (DURABLE.md §4 allows "answers exactly once,
  or never") and the client gets the outcome.
- **Capability manifest.** [fenrir_manifest](src/fenrir_manifest.erl) reads the residual
  row from the artifact (as `residualEffects` of tools/tc0/pure-call-artifact.mjs does,
  and requires the image build's row to be the same) and refuses to start a worker unless
  every residual effect, operation, operation type and datatype is the one the adapter
  discharges (`Store.commit : Tx --> Reply` of HANDLER.md §2).

## Campaigns

Deterministic and seeded; each scenario on a fresh SQLite file and a fresh node, with a
history checked by the Shen checker and a direct audit of the file (integrity check,
journal mode, A1's store invariants on the raw rows, and every acceptance a client was
told present in the file) after every crash and at the end. Families: `hand_traces`
(spec/service/hand-traces.json), `a2_runs` (the 68 distinct runs of the A2 refinement,
[tests/host/a2-runs.json](../../tests/host/a2-runs.json), each set up so that the store
gives that run's replies), `random_schedules`, `retries`, `duplicates`, `crash_points`
(9 fault points × the kills that apply × {submit, delivery}: 60 combinations), `sqlite_kills`, `lost_ack`, `busy`,
`two_workers`, and the host mutants. The report's `campaigns` member has the exact counts.

## Stage A4: the versioned upgrade

[spec/service/UPGRADE.md](../../spec/service/UPGRADE.md) on this stack; named assumptions
in [CONTRACT.md](CONTRACT.md) §7. The same check runs it (`check.sh` builds three images:
the v1 handler, the v2 handler [examples/service/accepted-job-v2.fen](../../examples/service/accepted-job-v2.fen)
with `contract_version` 2, and the migration program
[examples/service/migrate-v1-v2.fen](../../examples/service/migrate-v1-v2.fen) with
contract `migration` and fuel 100,000; each artifact's hash is pinned in
[artifacts/](artifacts)).

- **Durable upgrade state** in the `meta` table: `schema` (`…/1`, `…/2`), `upgrade`
  (`v1`, `prepared`, `migrated`, `v2`) and, from begin-upgrade on, the v2 image's artifact
  hash and the two descriptors. The adapter refuses to open a file whose schema it does
  not know, whose schema and state disagree, or whose columns are not its schema's.
- **Fencing in the store.** A commit's constructor is its contract version (`Tx` 1,
  `Tx2` 2). After `BEGIN IMMEDIATE` the adapter reads `meta` and refuses (`stale`) a
  commit whose version is not in force; the worker ends the run without a reply and the
  client is told `unavailable`. This holds for a worker the supervisor does not know
  (the campaigns start one and hold its run across migrate and cut-over).
- **Version-pinned workers.** A worker takes the image of the version in force when it
  starts and re-checks before each run; on a change it stops and its supervisor restarts
  it with the new image. (The first campaign run found the need: a crash after the
  cut-over had committed but before the workers were replaced left v1 workers whose every
  commit was fenced. Safety held; the service was unavailable until a restart.)
- **Migration.** `fenrir_upgrade:migrate/0` boots the migration image; its host requests
  go to the adapter's migration session: `read i` (row 0 takes a snapshot in one read
  transaction), `stage row`, `install n`: one transaction that compares the current rows
  with the snapshot (`Changed` if a v1 commit came in between, and the program reads
  again), adds the `attempts` and `r_version` columns, replaces every job and key row by
  the staged ones and writes `meta`. SQLite's DDL is transactional: after any crash the
  file is wholly v1 or wholly v2.
- **Orchestration API** (node commands, [src/fenrir_upgrade.erl](src/fenrir_upgrade.erl)):
  `{begin_upgrade, V2Image, MigrationImage}` (both manifests checked: contract 2 and the
  migration contract), `migrate`, `cut_over` (then every worker is restarted),
  `abort_upgrade`, `upgrade_state`; and, for the campaigns, `{async, Req}` /
  `{await, Ticket}`, `{async, {detached, Req}}` (a v1 worker outside the supervisor),
  `{release, Point}` for the fault action `pause`.
- **Histories** of the A4 families are schema `fenrir.service.history/2`
  ([HISTORY_FORMAT.md](../../spec/service/HISTORY_FORMAT.md) §4), checked against the A4
  model; the A3 families still write `/1` and are checked against A1 as before.

Families: `upgrade_load`, `upgrade_crash` (40 fault combinations: the begin, migrate and
cut-over transactions, inside the install, in the migration guest, after migrate, between
migrate and cut-over, after the cut-over committed), `upgrade_stale` (5 variants),
`upgrade_cas`, `upgrade_manifest`, and 10 A4 host mutants (CONTRACT.md §7). The report's
`campaigns` and `host_mutants` members have the counts.

Measured 15 November 2026 (development container, no KVM). `check.sh quick` (about 5
min): development-pass, 469 scenarios; the A4 families 48 scenarios (40 crash points
once, 5 stale variants, load, cas, manifest), 540 requests, 18 node crashes, every
history accepted, every audit clean; 78 unit tests; 31 checker tests as expected.
`check.sh full` (581 s): development-pass, 792 normal scenarios (A3's families 556, all accepted as
before, plus 236 A4: 200 crash scenarios, 25 stale, 5 load, 5 cas, 1
manifest), 4,634 requests, 282 node crashes, every history accepted. A4 host mutants (7
or 8 scenarios each): no_fencing, migration_drops_pending, migration_two_transactions,
keys_not_migrated, receipt_rewritten, cutover_before_migration, stale_workers,
no_manifest_check and volatile_upgrade_state caught; equivalent_control_a4 not flagged.
`no_fencing` is caught only through a v1 delivery (a v1 submit's positional INSERT into
the v2 table fails on its own, so a stale v1 submit is refused by accident of the schema,
not by fencing); `cutover_before_migration` and `migration_two_transactions` are caught
by the audit and by the node's refusal to reopen the inconsistent file, not by a history
(the scenario ends with the refused restart).

## Artifact

The handler is elaborated by `sh frontend/fenrir.sh emit examples/service/accepted-job.fen`,
run from the repository root. An artifact's source map carries the file as named on the
command line, so the name is repository-relative and the bytes are the same on every
machine. [artifacts/accepted-job.json](artifacts/accepted-job.json) is a committed copy of
that emit and its SHA-256 is pinned in
[artifacts/accepted-job.sha256](artifacts/accepted-job.sha256). check.sh uses the
frontend when it works and the copy otherwise, requires the pinned hash either way, and
says which in the report (`artifact_source`). The copy first committed with this stage was
emitted under an absolute worktree path while the frontend's second validator did not yet
know the durable schema; it was re-emitted and re-pinned on 15 November 2026, and reports
from before that name the earlier hash.

## Files

| Path | What |
| --- | --- |
| [src/](src) | the OTP host: store, worker, protocol, manifest, front, runner, supervisor, node |
| [c_src/fenrir_sqlite_port.c](c_src/fenrir_sqlite_port.c) | the SQLite port program |
| [priv/](priv) | descriptor plumbing for the tender and the node (no semantics) |
| [test/](test) | campaign driver and recorder, campaigns, unit tests, report |
| [CONTRACT.md](CONTRACT.md) | the named assumptions and the tests that exercise each |
| [../../harness/service-history.shen](../../harness/service-history.shen) | the history checker; format [spec/service/HISTORY_FORMAT.md](../../spec/service/HISTORY_FORMAT.md) |
| [../../tests/host/histories/](../../tests/host/histories) | the checker's negative tests: fabricated histories with their expected verdicts |
