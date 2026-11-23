# host/service: stage A3, the accepted-job service on OTP, SQLite and Solo5

Stage A3 of [04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §8: "SQLite
adapter under an OTP supervisor, Fenrir worker in Solo5, black-box crash and history
tests against the contract". The Fenrir handler
([examples/service/accepted-job.fen](../../examples/service/accepted-job.fen)) runs
unchanged as a Solo5 guest; the OTP host supervises the tender processes and discharges
the handler's one durable operation, `Store.commit`, against SQLite. The host is
infrastructure with a stated contract, [CONTRACT.md](CONTRACT.md): named assumptions,
each mapped to the tests that exercise it, none covered by Fenrir's proofs.

**A3 development evidence only.** Host-only checks run without a guest; the
Solo5 campaign requires Linux and the pinned or explicit tools. See
[INTEGRATION.md](INTEGRATION.md) for integration and provenance. The intended campaign's
evidence is *observed history accepted; bounded crash campaign* (development grade,
`qualification: UNKNOWN`). An accepted history is one recorded execution consistent
with the A1 model, not a claim about executions that were not run.

```
sh host/service/check-host-only.sh  # local OTP/SQLite/codec tests; no guest or history checker
sh host/service/check.sh quick     # requires shared dependencies in INTEGRATION.md
sh host/service/check.sh full      # higher campaign bounds; same dependencies
```

The host-only runner uses a local C compiler and SQLite headers/library (set
`SQLITE_PREFIX` if they are not in the compiler's default paths), and Erlang/OTP
28 on `PATH`. Results are `build/host/service/host-only-*/unit.json`.

By default the full-stack runner obtains its host prefix with `nix build .#fenrir-a3-tools`
on x86-64 or ARM64 Linux. The locked nixpkgs provides Erlang/OTP 28.5.0.7, SQLite
3.53.3 (CLI, headers and libraries), GCC 16.2.0 and Node 22.23.3. Set
`FENRIR_A3_TOOLS` to use a prebuilt prefix with the same `bin`, `include` and `lib`
layout instead. The runner elaborates the handler
(or uses the committed artifact copy when the frontend's emit fails; see below), builds
the guest image, runs the unit tests, the campaigns and the history checker, and writes
`build/host/service/<run>/report.json`.

With the flake inputs already cached, check both Linux host outputs and the
separate TC1 OTP pin without building either toolchain:

```sh
nix eval --offline --impure --json --file tests/host/pinned-tools.nix
```

## Architecture as built

The campaign driver is privileged and is not a client transport.

```
campaign driver (its own BEAM; client, recorder, fault injector, file auditor)
   |  {packet,4} external terms on fds 3/4 of the node (priv/node-launch)
service node (BEAM OS process)                       -- killed and restarted by campaigns
   fenrir_node            privileged control channel; impersonates test principals
   fenrir_service_sup     one_for_one
     fenrir_holder        ETS owner (volatile_mailbox mutant only)
     fenrir_store         the SQLite adapter, one connection --> fenrir_sqlite_port (C, port)
     fenrir_worker_sup    one_for_one
       fenrir_worker wN   one solo5-spt per request --> priv/spt-launch --> solo5-spt
     fenrir_front         authenticated submit / internal delivery / volatile outbox
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
- **Tenant authority.** OTP resolves a provisioned bearer credential to a tenant
  before picking that tenant's guest entry. The guest's `Tenant t` must agree with the
  independent host scope before SQLite is touched. This is a bounded submit boundary,
  not production authentication; see [trust boundary](CONTRACT.md#tenant-trust-boundary).
- **SQLite binding: a C port program** ([c_src/fenrir_sqlite_port.c](c_src/fenrir_sqlite_port.c)),
  built with gcc against nixpkgs' sqlite. Chosen over a NIF library (esqlite, exqlite)
  because it has the fewest unpinned inputs (nixpkgs' sqlite and gcc, nothing from hex),
  and because it puts SQLite in its own OS process, which the campaigns kill -9 in the
  middle of a transaction. It executes statements and holds no storage logic; the
  transaction is written in [fenrir_store](src/fenrir_store.erl). A counting VFS shim
  over the unix VFS lets a campaign kill the program before its n-th write or fsync.
- **Storage.** WAL journal, `synchronous=FULL` (SQLite requests a WAL sync before
  `COMMIT` returns; with `NORMAL` a committed transaction can be lost on power loss), foreign keys
  on, 50 ms busy timeout, all checked at open. See [storage validation](STORAGE_VALIDATION.md)
  for what process crashes and VFS counters do (and do not) establish.
  Tables `tenants(tenant, next)`,
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

On the same host, run `python3 host/service/test/fault-controls.py build/host/service/RUN/config.term`
after `check.sh` to repeat the diagnostic controls. Each builds a disposable module
variant that kills an unrelated node or process, suppresses a kill or a lost
acknowledgment, or stalls an outbox/snapshot read. The controls require unverified
injections to leave no `fault` event and require stalled reads to leave recorder gaps.
They are not additional campaign coverage.
To reproduce the false evidence on `2cc8d0e`, pass that revision's run config
and append `--baseline /path/to/baseline-checkout`. To reproduce the follow-up
recovery snapshot, history gap format and wrong-tender regressions at
`43eea72`, use that revision's config and append `--gap-baseline /path/to/checkout`.
To reproduce cross-boot observation substitution at `001db56`, append
`--observe-baseline /path/to/checkout` to that revision's config.

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

### Replaying supervised recovery on Apple Silicon

With the repository's ARM64 Solo5 Docker image and Shen/JIT available, run
`sh host/service/check-supervised-recovery.sh`. Set `FENRIR_SOLO5_IMAGE` or
`FENRIR_SHEN_JIT` to select a local Solo5 image or Shen installation.
The script emits the v1 handler from source, compares its bytes with the
committed artifact, builds a two-tenant SPT guest and starts the OTP service
inside ARM64 Linux. It loses the SQLite commit acknowledgement, waits for store
replacement, kills the worker, retries through ingress and drains one pending
job with duplicate delivery. The printed evidence directory retains the
guest descriptor, container ID, supervisor log, model history and verdict.
Its timing sample measures worker kill to successful retry and runner start
to observed empty queue. Both intervals include the guest boots they trigger.

Pass `erlang` to `check-supervised-recovery.sh` to substitute the bounded
Erlang v1 handler for the guest worker under the same worker supervisor. Its
requests enter through the same authenticated front and commit through the
same SQLite store. The worker uses OTP messaging directly. This comparison
therefore includes the cost of the guest boundary in the Fenrir deployment.
The history identifies the worker implementation.

Pass `elixir` to exercise the independent Elixir GenServer implementation.
The script verifies the pinned Elixir 1.19.5 / OTP 28 distribution, compiles
the worker with warnings as errors and places it under the same supervisor.
The Elixir worker builds its own guarded transaction and interprets the store
reply for fresh submissions, replay, conflict and completion.

The recovery history also exercises a conflicting submission after restart,
the same key accepted independently by a second tenant, replay of that
tenant's receipt, and draining its job. The test compares the first tenant's
store snapshot before and after the second tenant's work. To compare runs,
pass their output directories to
`python3 benchmarks/durable/compare-recovery.py DIR1 DIR2 ...`.

Pass `rust` to run the bounded Rust v1 worker. A supervised Erlang port
adapter sends the command to a persistent Rust process, decodes its
transaction and submits it to the shared store under the authenticated scope.
On a definite store reply, Rust computes the application response. Store
failures propagate through the same front-end outcome contract. The binary
uses optimized code with overflow checks; the run retains the compiler
version. This path includes two port round trips for a successful request.

Pass `nim` to select the Nim implementation over the same persistent packet
adapter as Rust. Both native references can also be built on the Mac and
checked with `python3 benchmarks/durable/check-ports.py RUST_BINARY NIM_BINARY`.
The 72 packet cases cover both tenant IDs, both keys, both digest values,
both completion flags, and fresh, replayed and conflicting store replies.

### Direct ARM64 accepted-job worker

Run `sh host/service/check-supervised-recovery.sh fenrir-native-spt` on Apple
Silicon to compile `examples/service/accepted-job.fen` into a persistent SPT
worker and exercise it against OTP and SQLite. Then run
`sh benchmarks/durable/native/check-mac-recovery.sh SPT_RUN_DIRECTORY` for
the macOS executable. The Mac runner relocates the original image descriptor
and copies its tender for the supervisor's admission checks. The campaign
then installs the selected native port and runs the service locally.

The compiler binds the typed `Store.commit` application operation to the packet
adapter. Fenrir constructs the transaction, waits in the native call while OTP
commits it, and interprets the typed reply. An aborted store operation can leave
a pending call without a reply. The next command makes that activation unwind
before starting another. The adapter encodes typed values and freezes the
command/reply vocabulary to the accepted-job schema. The recovery fixture
uses two tenants, two keys, two digests and job IDs 0–1.

Both runs write a checked history, a worker image digest and recovery timings.
The Mac run also records its local OTP version. To compare any set of accepted
runs, pass their directories to `python3 benchmarks/durable/compare-recovery.py`.
This campaign exercises lost acknowledgement, process restart, retry, conflict,
tenant isolation, duplicate delivery and backlog drain at the recorded bounds.
