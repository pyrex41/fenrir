# Supervised recovery on Apple Silicon

Build the Fenrir Solo5 service and obtain a checked recovery history first.

```sh
sh host/service/check-supervised-recovery.sh fenrir-native-spt
```

Pass the printed recovery directory as the first argument to
`benchmarks/durable/native/check-mac-recovery.sh`. Run once for each worker
with the same Solo5 directory. The second argument selects
`fenrir-native-mac`, `rust`, `nim`, `erlang`, or `elixir`. Each invocation
prints a new Mac build directory, checks its history against the service model,
and compares its events with the Solo5 run.

From the repository root, pass those five Mac directories in the same order
to the paired experiment. The output directory must be new.

```sh
ERL_FLAGS='+S 1:1' python3 benchmarks/durable/paired-recovery.py build/recovery-comparison \
  "$fenrir_build" "$rust_build" "$nim_build" "$erlang_build" "$elixir_build"
```

Each of ten blocks rotates the starting worker, runs all workers sequentially
with fresh OTP and SQLite state, and checks every history. Each run retains
its build digests, event history, model verdict, database and raw timings.
The runner checks the compiled service modules, native port adapter, SQLite executable, OTP record and scenario digest across workers. It also checks each worker’s build identity across blocks. The paired report records those hashes and gives Fenrir/reference elapsed-time ratios and bootstrap
intervals for acknowledgement, retry, restart and drain. A null ratio means
the reference clock recorded zero for at least one denominator.

The five workers share the OTP supervisor and SQLite adapter. Fenrir, Rust
and Nim execute application decisions across a native process boundary.
Erlang and Elixir execute theirs inside the BEAM. The observed times include
these boundary costs. This scenario measures bounded recovery with one
pending job. Sustained commit capacity, saturated backlog drain, and
independent deployment comparisons need separate workloads.

For the bounded backlog experiment, run
`python3 benchmarks/durable/repeat-recovery.py MAC_BUILD NEW_OUTPUT --workload backlog`.
This fills both keys for each of two tenants, restarts the worker, then
delivers each of four pending jobs twice. The history checker validates the
observed submissions, duplicate deliveries and drained database snapshot on
every repetition. Timings cover fresh submissions and drain separately.
The four-job workload uses keys 0 and 1 in each tenant.

Run `sh host/service/check-supervised-recovery.sh fenrir-native-spt backlog`
for the same scenario on Solo5 ARM64. Compare the emitted evidence directory
with the individual checked Mac runs using `compare-recovery.py`.

Pass `--workload backlog` to the paired experiment to compare fresh submissions
and verified drain across the same rotated worker builds. Every measured
history must match across all workers and blocks before the report is written.

Use the Solo5 workload `wide-backlog` to repeat the restart and drain scenario
with request keys starting at 2³². Job IDs are assigned independently by SQLite.

With wide-key worker builds, select `--workload fresh-commits` for repeated
or paired Mac measurements, or pass `fresh-commits` as the second argument to
the Solo5 supervised runner. Each run submits 128 distinct tenant/key pairs
with one outstanding request. It records every acceptance latency, batch
elapsed time, SQLite writes and syncs, and a model-checked final snapshot.
This short closed-loop workload measures fresh commit cost. Sustained service
capacity requires a separate timed offered-load experiment.

Select `c-native-spt` in the Solo5 supervised runner for the matched C guest.
It builds the transaction and interprets the commit reply in C, sharing
Fenrir's packet adapter, devices, tender, OTP supervisor and SQLite path.
Use `compare-recovery.py` on both checked evidence directories.

The supervised runner's `rollback` workload kills the SQLite port after
the first transactional write. It verifies the target PID and exit status,
requires the restarted store to match its initial snapshot, and retries the
request. The output includes the fault witness in `fault.json` and the
model-checked history in `history.json`.

For a paired native fault run, run the Solo5 supervised runner with
`fenrir-native-spt rollback`, then pass its printed evidence directory to
`sh benchmarks/durable/native/check-mac-recovery.sh SPT_RUN fenrir-native-mac rollback`.
The Mac runner checks both histories against Shen and compares their events.
Use the same workload argument on both commands for `backlog` or `wide-backlog`.

For a paced Solo5 run, set `FENRIR_COMMIT_RATE` (requests per second) and
`FENRIR_COMMIT_SECONDS`, then select workload `paced-commits`. One client
submits distinct keys on absolute deadlines in arrival order. Each recorded
acknowledgement includes queueing from its scheduled arrival. Service times
start at actual dispatch. Run `python3 benchmarks/durable/assess-paced.py
RUN/timings.json` to reconstruct the outstanding queue at each second and
the final drain time. The workload retains the entire history and snapshot
for checking. The Shen history reader currently accepts up to 64 MiB per JSON
file. A 128-commit Mac history took 16,034 bytes including its final snapshot.
At that observed size per commit, 600 seconds at 2,400 commits/s would produce
about 172 MiB, before accounting for longer identifiers. The Shen checker supports chunked v1 histories with continuous model state.
The paced recorder on both targets writes up to 1,024 events per file after
timing finishes, then publishes the manifest. The Mac repeat and paired
runners compare ordered event counts and SHA-256 digests across runs and
storage formats. The recorder still holds its samples and final snapshot in
memory, and the final observation must fit within one chunk. Model-checking
cost at sustained capacity remains to be measured.

The Mac repeat and paired runners accept `--workload paced-commits` with
the same two environment variables. Each run verifies the number of checked
history events, the offered schedule and p99 against its raw samples, then
writes the reconstructed per-second queue to `0/paced.json` for that run.

For fresh and paced commits, `check-fresh-store.py DATABASE COMMIT_COUNT`
independently checks both tenant counters and every persisted report, payload,
pending job and retry receipt in a single read transaction. It verifies SQLite integrity, foreign keys, the store format version, and
the v1 schema and upgrade metadata before streaming ordered rows from SQLite. The Mac repeat runner also retains this result alongside
the Shen history verdict.

The Solo5 supervised runner writes `commit-check.json` for fresh and paced
workloads. It checks the offered schedule, accepted event count, batch
throughput and p99 against the raw timing samples, then verifies the persisted
rows independently. For paced workloads the receipt also includes the queue
at each one-second boundary and the drain time past the cutoff.

For a paced run with an accepted history, the workload check reports
`offered_rate_verdict`. A sustained observation requires at least 600 seconds,
all scheduled commits accepted, and at most one outstanding request at some
second boundary in each minute and at the final boundary. One request is the
client's in-service allowance. A short run or unconfirmed clearance leaves
capacity open. Cross-worker throughput and latency comparisons require
replicated runs at matched rates.
The paired paced report retains each worker's verdict in block order.
`replicated_sustained_lower_bound` gives the offered rate for workers that
sustain it in every block across at least ten repetitions. A single offered
rate can establish the same lower bound for several workers. Ranking their
capacities requires additional offered rates.

Paced Solo5 runs pin the container to Linux CPU 0 and use one online BEAM
scheduler. To compare a native Fenrir guest and C guest at the same offered
rate, run each with `check-supervised-recovery.sh`, then pass their output
directories to `python3 benchmarks/durable/compare-paced-spt.py FENRIR C`.
It replays the histories, checks the SQLite rows and pacing samples, and
compares the container, loaded module files, SQLite adapter, CPU budget and
connection settings. Each sample records its guest image digest, peak and final outstanding counts,
and time to drain after the offered interval. The report gives separate p99
values for scheduled arrival to dispatch, dispatch to acknowledgement, and
scheduled arrival to acknowledgement. It computes each percentile from the
individual commit samples. For each request it also splits dispatch delay into time spent waiting for
the preceding commit and time from becoming eligible to actual dispatch.
Eligibility begins at the later of scheduled arrival and preceding completion.
The p99 of each component is reported independently.

For a matched pair, set `FENRIR_RECOVERY_IMAGE` to the first run's recorded
`container.id` when launching the second worker. The runner resolves the
local image before launch and records the ID it actually uses. This keeps
the OTP and SQLite environment identical even if a later Docker build
produces a different image manifest.

For a rotated Solo5 campaign, run
`python3 benchmarks/durable/paired-paced-spt.py NEW_DIRECTORY --rate 100 --seconds 600 --blocks 10`.
The command runs the workers serially, alternates the first worker each block,
pins the recovery container after the first run, and replays each history.
The numbered reports retain both run directories. After every completed block,
`summary.json` records the median paired Fenrir/C p99 ratio at that offered
rate. The bootstrap interval is available after ten pairs. A replicated sustainable lower bound requires
ten completed pairs and a sustained verdict in every block for that worker.
The p99 comparison at the offered rate requires both workers to sustain every
ten-minute block in at least ten alternating pairs. An interval entirely at or
below 1.5× meets the latency threshold at that rate.
Capacity ranking and the p99 measurement at 70% of the slower capacity require
runs at additional rates.
Pass `--recheck` with the original directory, rate, duration and block count
to reconstruct the paired results from recorded histories, timing samples,
database rows and binaries. The recheck writes separate numbered reports and
`rechecked-summary.json` and leaves the original measurements in place.

New fresh and paced commit runs write `resources.json` immediately before
and after the measured load while SQLite is open. Each snapshot reports
the BEAM and SQLite port PIDs and resident bytes (Darwin ps RSS or Linux
/proc/PID/status VmRSS). It also records the database, WAL and shared-memory
index file lengths in bytes. A missing file is null. These observations
measure endpoint residency and logical file size. Lifetime peaks and
filesystem allocation require separate measurements.

The Mac paired fresh and paced reports retain each worker's two resource
snapshots in block order. The recorder checks that BEAM and its SQLite port
are distinct processes and that both identities survive the measured interval.

Mac paired reports record the host model, OS release, logical CPU maximum and
OTP scheduler counts. The single-core budget is verified only when the host
exposes one logical CPU and both normal and dirty CPU scheduler counts are one.

The Mac and Solo5 paired reports also give a replicated upper bound when
every one of at least ten runs at a rate shows sustained backlog growth.
Over at least ten minutes, the minimum outstanding count in each later
minute must exceed the preceding minute's maximum, and the final window
must stay above one outstanding request. A short run, a persistent plateau
or a single late spike leaves this upper bound open. All contributing runs
must still pass the history and database checks.

Set `FENRIR_PROFILE_VFS=1` for a separate fresh-commit or paced-commit experiment to collect `vfs_time_ns.write` and `vfs_time_ns.sync` in timings.json. These cumulative durations measure the SQLite VFS delegate's write and sync calls during the batch, including time waiting inside those calls. Divide each by the commit count for its mean contribution per commit. The same profile records `store_transaction_ns` around the v1 store’s transaction call, including the SQL port round trips, transaction body, and commit acknowledgement. Subtract write and sync time from that interval for the remaining store time. Subtract the transaction interval from summed service time for the combined worker, transport, and other host time. It cannot be assigned to the worker alone. Capacity runs leave VFS timing disabled. Both paired runners retain the raw timings from profiled runs and exclude them from replicated capacity bounds. The Solo5 runner also leaves the latency threshold undetermined for profiled runs.

Fresh and paced runs identify where the application worker executes in
`resources.json`. Native Mac workers and persistent Solo5 tenders have a
separate OS PID and resident byte count at each endpoint. Erlang and Elixir
workers share the reported BEAM process. The per-request guest has no
persistent worker to sample between requests. Endpoint RSS does not establish
peak memory or a private-memory total across processes.

Combine the completed block records from several Solo5 offered rates with
`python3 benchmarks/durable/capacity-spt.py RATE_DIRECTORY...`. Each input
comes from the paired runner. Pass `--replay` to resolve the original worker
logs, replay Shen histories, read back SQLite rows, check binary digests, and
reconstruct pacing before aggregating. The report identifies whether it used
recorded or replayed evidence. It verifies consistent deployments and duration, and uses replicated
bounds to assess the two-thirds throughput gate against C. Once both workers
have sustained and failing bounds, the latency comparison uses 70% of the
slower sustained bound, rounded down to whole commits/s. Include a campaign
at that exact rate to obtain its p99 verdict.

For the Mac comparison, pass the `paired.json` files from distinct offered
rates to `python3 benchmarks/durable/capacity-mac.py`. The report gives each
worker's observed capacity bounds. Release scoring requires matched builds,
a single-core host and BEAM budget, and ten rotated ten-minute blocks per
rate across Fenrir, Rust, Nim, Erlang, and Elixir. The latency comparison uses
the reference selected by the capacity bounds and reports a paired bootstrap
interval at 70% of the slower sustained bound.

Add `--replay` to the Mac capacity command to verify each block's raw
acknowledgement timings, queue assessment, Shen history, persisted rows,
and worker build hashes against the paired report. Replay requires the
original run directories and worker builds.

The `timeout-after-commit` workload exercises a client deadline while a
committed response is held at the delivery boundary. It observes the
accepted receipt in the front's outbox, expires a five-millisecond receive
deadline, retries with the same key, then releases the first response.
Both responses must carry the same receipt and exactly one job must remain
pending. The history records the two submissions, two response deliveries,
and durable observations. The separate fault record identifies the deadline
and the response gate. Use this workload with either native recovery runner.

To diagnose tail latency, run `python3 benchmarks/durable/assess-paced.py
--latency-components RUN/timings.json` on a paced run. The added fields
average the same requests at or above the recorded p99, including ties.
Service, time waiting for the previous commit, and delay after the request
became eligible to dispatch sum to the mean acknowledgement latency of those
requests. Service includes the guest, transport, ledger, and host scheduling.

To replay the archived 120,001-event checker comparison after extraction,
run `python3 benchmarks/durable/replay-archived-pair.py EXTRACTED cached SHEN_JIT_PREFIX`.
Use `canonical` to replay the other implementation. The runner checks the
header and all chunk digests before starting Shen/JIT. It compares the
complete verdict after substituting the extracted history path for the
original one. Use the Shen/JIT 0.7 prefix recorded in the timing evidence
when reproducing the original configuration.

If a Solo5 paired campaign stops during validation, pass `--resume` with
the original output directory, rate, duration and block count. The runner
revalidates existing worker logs, checks saved block reports against replay,
and runs workers whose logs are absent. A changed measurement fails before
the corresponding summary update. Preserve partial logs for diagnosis if
a worker stopped before writing a complete trial.
