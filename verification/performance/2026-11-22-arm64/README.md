# ARM64 kernel measurements, 22 November 2026

Apple M5, Mac17,2. The Mac run used the fastest eligible reference separately for each kernel. The Solo5 run used an optimized C guest and the same tender as Fenrir. Ratios are Fenrir elapsed time divided by reference elapsed time. Intervals are paired bootstrap 95% intervals.

| Target | Kernel | Reference | Pairs | Ratio | 95% interval |
|---|---|---|---:|---:|---:|
| macos-arm64 | search | rust | 20 | 1.094 | 1.068–1.117 |
| macos-arm64 | check | rust | 20 | 0.972 | 0.959–1.001 |
| macos-arm64 | router | rust | 15 | 0.985 | 0.970–1.005 |
| macos-arm64 | stream | rust | 80 | 1.796 | 1.751–1.835 |
| macos-arm64 | **Geometric mean** | | | **1.171** | **1.160–1.186** |
| solo5-arm64-spt | search | c | 12 | 5.752 | 5.551–5.937 |
| solo5-arm64-spt | check | c | 12 | 5.636 | 5.305–6.013 |
| solo5-arm64-spt | router | c | 12 | 1.506 | 1.451–1.568 |
| solo5-arm64-spt | stream | c | 12 | 4.750 | 4.553–4.880 |
| solo5-arm64-spt | **Geometric mean** | | | **3.902** | **3.808–3.997** |

The combined kernel verdict includes elapsed and peak-memory gates. macos-arm64 returned `meets-threshold`. solo5-arm64-spt returned `above-threshold`. Service capacity and installation have separate release gates.

## Integrated package kernel results

The integrated package combines the two-at-a-time prover queue append and
the four-group framed-log decoder. Both scorecards reproduced from their
raw inputs. All 818 packaged source files matched the release archive
before and after measurement. The later segmented prover queue is a
separate experiment.

| Target | Geometric mean elapsed ratio | 95% interval | Kernel verdict |
|---|---:|---:|---|
| macos-arm64 | 1.129× | 1.116–1.139 | meets-threshold |
| solo5-arm64-spt | 3.717× | 3.654–3.789 | above-threshold |

[Integrated reports and source checks](integrated-kernel-reports.tar.gz) ·
[Packaged source](fenrir-source-integrated.tar.gz) ·
[Later segmented prover measurements](segmented-prover-reports.tar.gz).

The subsequent prover snapshot uses the segmented queue and defers reading a
certificate byte until a formula is ready. Its four-kernel mean was 1.082×
on macOS and 3.546× on Solo5. All eight memory comparisons passed. The Mac
campaign shared the host with an Elixir HTTP load test. Sources that differ
from the integrated package are included alongside both scorecards and their
six input reports. [Updated prover campaign](updated-prover-kernel-reports.tar.gz).

Reconstructing the integrated source archive with those six changed files
produced the measured sources and built offline as
`/nix/store/azp07bf8jgaaqjr1qzqmzri0hap46qbd-fenrir-0.1-dev`.
That installed package passed the CLI and four-application rehearsal on both
targets. [Updated package rehearsal](updated-prover-package-rehearsal.tar.gz).

A subsequent framed-log experiment retained four counter groups across each
chunk traversal. On the mixed 1 MiB input, allocations fell from 394,743 to
263,799 and collections from 449 to 277. On single-key input allocations rose
from 131,227 to 131,355 with 128 collections in both cases. The isolated
stream timing was 1.674× Rust on Mac (95% interval 1.640–1.697) and 4.013× C
on Solo5 (3.846–4.220). The Solo5 stream still exceeds the 2× ceiling.
The table above records the earlier full campaign. The isolated experiment
includes the timed decoder source, typed artifacts, samples and heap profiles.
[Download the framed-log reports](stream-chunk-reports.tar.gz).

In the 12 separately instrumented guest pairs, Fenrir spent a median
2.270 ms per MiB outside block reads and console writes, compared with
0.303 ms for C. Median block reads took 0.373 ms and 0.366 ms respectively.
These values come from subtracting the read and write durations within
each sample before taking the median. A separate instrumented Fenrir run
spent 0.234 ms of 2.953 ms in garbage collection. The largest remaining
cost is in guest processing outside device I/O. The available timers do
not distinguish constructor allocation from decoding or summary formatting.

The [raw report archive](kernel-reports.tar.gz) includes all six input reports and both scorecards. Each scorecard records its input digests. Extract the archive and reproduce a target’s score from this checkout with

```sh
tmpdir=$(mktemp -d)
tar -xzf verification/performance/2026-11-22-arm64/kernel-reports.tar.gz -C "$tmpdir"
python3 benchmarks/kernel-scorecard.py "$tmpdir/macos-arm64/prover/report.json" "$tmpdir/macos-arm64/router/report.json" "$tmpdir/macos-arm64/stream/report.json"
```

[Download the source archive](fenrir-source.tar.gz). SHA-256 `69e13f342c87db42e2ad3f64eb4963c26a4c90cabd76f13d00f67efef4c4a37e`. The archive rebuilt offline to `/nix/store/7mrmq77h9yyjndzpri7ngqk7rmsm8znv-fenrir-0.1-dev`. The shared compiler and runtime hashes in all six reports matched its sources. Raw report archive SHA-256 `ae56ca9d1f2adeb3a736ea2b7617cd10c07ae6bea2c35ebb32493e82f0ba688c`.

## Prover queue update

The working prover copies two successive pending formulas per recursive
append, preserving FIFO order and the shared suffix. In a direct 20-pair
comparison against the preceding implementation, Solo5 search elapsed time
fell 2.9% and certificate checking fell 5.0%. Both targets passed checks of
queue order and retained input queues for prefix lengths 0 through 128.

The subsequent complete kernel campaign gave a Mac geometric mean of 1.161×
(95% interval 1.142–1.171) and a Solo5 mean of 3.854× (3.792–3.906).
Mac passed every elapsed and memory gate. Solo5 passed all memory gates;
its search and checking times were 5.554× and 5.451× C, respectively,
and the mixed stream was 4.751× C. The integrated source package below includes this queue change.

The [queue campaign archive](queue-kernel-reports.tar.gz) contains the exact
updated Fenrir module, three suite reports per target, and both scorecards.
Archive SHA-256 `210f8c61d7e1da83a5091767bc9b9af3e3b61a2b519418bf82c8d3cf4d851384`.

## Mac reference implementations

| Implementation | Proof search (ms) | Certificate check (ms) | Router (ms) | Mixed stream (MiB/s) |
|---|---:|---:|---:|---:|
| Fenrir | 10.05 | 7.06 | 0.855 | 157.3 |
| Rust | 9.27 | 7.28 | 0.869 | 282.9 |
| Nim | 18.91 | 14.81 | 5.066 | 272.9 |
| Koka | 12.96 | 8.47 | 5.538 | 70.2 |
| Shen/JIT | 15.32 | 13.61 | — | 63.6 |
| C | — | — | 0.684 | — |

Elapsed columns show medians. Each prover process ran 5,000 corpus rounds.
The router processed 200 rounds of 27 request heads. Stream throughput includes
process launch, reading 1 MiB, and emitting the verified summary. A dash means
this campaign has no measurement. C is an additional Mac router measurement.
The planned Mac router gate uses the fastest of Rust, Nim and Koka. Elixir
and Erlang participate in service comparisons.

On the mixed stream, both Fenrir targets allocated 394,743 managed objects
and collected 449 times for 131,072 frames. The instrumented Solo5 run spent
0.443 ms in collection out of 3.603 ms total (12.3%).
Median time to first output was 3.053 ms for the Fenrir guest and
0.675 ms for the C guest. The decoder emits the summary after
the complete input has been validated.

The 12 instrumented Solo5 pairs also distinguish device calls from the rest
of stream processing. Each row gives medians in milliseconds. For each
sample, the last column subtracts measured reads and writes before taking
the median.

| Guest | Elapsed | Sector reads | Console writes | Outside reads and writes |
|---|---:|---:|---:|---:|
| Fenrir | 3.103 | 0.371 | 0.035 | 2.702 |
| C | 0.717 | 0.368 | 0.043 | 0.312 |

The remainder includes aggregation, decoding, runtime work and summary formatting.

## Prover work rates

One search round visits 83 tableau nodes across ten formulas. One checking
round accepts six certificates. Rates below use the median elapsed time for
5,000 validated rounds. Mac timings include process startup; Solo5 timings
start inside the guest.

| Target | Worker | Million nodes/s | Million certificates/s |
|---|---|---:|---:|
| macOS ARM64 | Fenrir | 41.30 | 4.25 |
| macOS ARM64 | Rust | 44.79 | 4.12 |
| macOS ARM64 | Nim | 21.95 | 2.03 |
| macOS ARM64 | Koka | 32.02 | 3.54 |
| macOS ARM64 | Shen/JIT | 27.08 | 2.20 |
| Solo5 ARM64 | Fenrir | 66.74 | 8.13 |
| Solo5 ARM64 | C | 388.54 | 46.12 |

## Mac durable-worker recovery

Ten rotated blocks compared five workers behind the same Erlang/OTP 29
supervisor and SQLite 3.53.3 store with WAL and synchronous FULL. All 50
recordings reproduced the same 18-event history. Each duplicate request
produced zero SQLite VFS writes and syncs. Each recovery started with one
pending job and recorded two delivery attempts.

| Worker | Fresh acceptance (µs) | Duplicate acceptance (µs) | Worker kill to successful retry (µs) | Runner start to verified empty (µs) |
|---|---:|---:|---:|---:|
| Fenrir | 294.5 | 118 | 2874.5 | 376.5 |
| Rust | 284.5 | 119 | 2967.5 | 408 |
| Nim | 298 | 117 | 2798.5 | 390.5 |
| Erlang | 237.5 | 67.5 | 181 | 289 |
| Elixir | 242 | 70 | 176.5 | 283.5 |

Cells are medians of ten event timings. The native workers run behind OS
ports, while the Erlang and Elixir workers run inside BEAM. Restart times
therefore include the cost of replacing each worker in its deployment.
The fault receipts identify the SQLite port termination after commit with
a lost acknowledgement. These measurements cover recovery with one pending
job. Service capacity and loaded p99 have separate experiments.

The [recovery reports](mac-recovery-reports.tar.gz) contain the paired
summary, binary identities, raw timings, fault records, histories and replay
verdicts. Archive SHA-256 `1d65c7bc383e5f5a40e2a008a6a2fc2400bd8b202a29209c7da663f0a2f09357`.

## Solo5 durable-service measurements

Both workers used the same OTP supervisor, SQLite WAL with synchronous FULL,
and one VM CPU. The table gives scheduled-arrival-to-acknowledgement p99 in
milliseconds. Every run passed history replay and the independent database
checks. Fenrir and C made the same number of SQLite VFS writes and syncs in
each pair.

| Offered commits/s | Seconds per worker | Order | Fenrir p99 (ms) | C p99 (ms) |
|---:|---:|---|---:|---:|
| 100 | 600 | Fenrir, C | 7.879 | 8.551 |
| 800 | 30 | Fenrir, C | 6.839 | 6.727 |
| 800 | 30 | C, Fenrir | 6.383 | 52.704 |
| 1,000 | 30 | Fenrir, C | 1,005.164 | 290.952 |
| 1,000 | 30 | C, Fenrir | 190.429 | 6.892 |

The 100/s pair cleared its backlog by the end of the offered interval. At
1,000/s Fenrir had higher p99 in both orders, with substantial variation
between blocks. The short probes included concurrent diagnostic activity on
the host. The release comparison still requires replicated ten-minute capacity
runs and latency at 70% of the slower measured capacity.

The [raw service measurements](durable-service-probes.tar.gz) contain per-commit
timings, offered-rate assessments, SQLite check results, replay verdicts and
paired build identities for all ten runs. To reconstruct queue depths and p99
from the raw samples, extract the archive and pass a worker's timings.json to
`python3 benchmarks/durable/assess-paced.py`. Archive SHA-256
`20b79eef344aef76c5cbac8165d6c9efa124a5d6585fe103bc37416833016148`.

## Mac HTTP at 70,000 requests/s

Each worker received 42 million scheduled requests across 16 persistent connections during one ten-minute run. Other development and verification processes were active on the host.

| Worker | Valid | Outstanding at cutoff | p99 (ms) | Server CPU µs/completed |
|---|---:|---:|---:|---:|
| Fenrir | 42,000,000 | 7 | 0.129 | 18.58 |
| Rust | 42,000,000 | 10 | 0.321 | 26.54 |
| Nim | 42,000,000 | 15 | 1.642 | 13.51 |

Extract the [70,000 requests/s archive](mac-http-70000.tar.gz) and the [80,000 requests/s archive](mac-http-80000.tar.gz) into separate directories. Run `python3 benchmarks/http/capacity.py RATE_70000_DIR RATE_80000_DIR` to reproduce the combined bounds.

## Mac HTTP at 80,000 requests/s

One ten-minute block used 16 persistent connections and scheduled 48 million
requests per worker. The driver allowed five seconds after the offered
interval to dispatch outstanding work. Workers ran in the order shown.

| Worker | Valid | Missed | Invalid | Transport errors | Outstanding at cutoff | p99 (ms) | CPU µs/completed | Sampled max RSS (MiB) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Fenrir | 48,000,000 | 0 | 0 | 0 | 10 | 0.145 | 21.29 | 2.22 |
| Rust | 47,394,050 | 605,950 | 0 | 0 | 948,704 | 15,597.584 | 28.79 | 2.47 |
| Nim | 48,000,000 | 0 | 0 | 0 | 309,605 | 4,036.360 | 12.51 | 139.75 |

p99 covers valid responses from scheduled arrival through completion. The
missed count records requests that the driver could not dispatch before its
cutoff. CPU and RSS cover the Darwin server process. Development checks
also ran on the measurement host during this block. Capacity ranking and
release latency require additional rates and replicated runs.

Over the final five minutes of offered load, Fenrir completed 80,000
requests/s and its outstanding count went from 7 to 10. Rust completed
78,283 requests/s and its outstanding count rose from 433,617 to 948,704.
Nim completed 79,013 requests/s and its outstanding count rose from 13,599
to 309,605. Nim eventually returned every response during drain, but the
increasing queue explains why this sample supplies no sustained-capacity
lower bound for Nim. Rates use the completion-counter deltas and observed
monotonic timestamps at seconds 300 and 600.

The [raw HTTP sweep](mac-http-80000.tar.gz) includes the three request
censuses, per-second backlog, timing histograms, process samples, build
identities and capacity bounds. Extract it and run
`python3 benchmarks/http/capacity.py EXTRACTED_DIRECTORY` to reproduce
the capacity assessment. Archive SHA-256 `f2b83bb2c08c295fe0783bb141600b0d6794380cb21aec379a7f0efb170b286d`.

A subsequent Rust reference change writes small response headers and bodies
together. In ten alternating 15-second pairs at 80,000 requests/s, median p99
fell from 500.155 ms to 0.309 ms. Both builds returned all 12 million responses
across their ten samples. The tables above identify the earlier Rust build.
The revised reference requires fresh ten-minute capacity measurements.
[Raw response-write comparison and both Rust sources](mac-http-rust-response-writes.tar.gz).

## CPU scope of the Mac HTTP measurements

The Mac HTTP services share the Apple Silicon host with the loopback client.
Darwin schedules the connection threads. Fenrir used 1,022.10 server CPU
seconds over a 602.36-second sampling interval in the first 80,000 requests/s
run, averaging 1.70 cores. The single-core service gate remains open.

On this M5, Virtualization.framework reported a generic VM range of 1 to 64
vCPUs. Apple's compatible macOS restore catalog returned build 26B131.
Its `mostFeaturefulSupportedConfiguration` requires at least two vCPUs
and 4 GiB of RAM. A guest configured to those requirements would support a
two-vCPU deployment comparison. Qualifying a one-core comparison requires a
separately verified CPU restriction or compatible guest configuration.

## Package with long-certificate support

The [updated source archive](fenrir-source-long-certificates.tar.gz) includes
the long-certificate fix. Its SHA-256 is
`599dc8e18f7a4493ae01b705811132aab8b2b4eba605c7336b8d13a27efa1ff5`.
An offline rebuild from the extracted archive reproduced
`/nix/store/n36llr1455fbvnfp5gll6x1b2p7nj6d5-fenrir-0.1-dev`.
The developer-machine installation rehearsal passed for this package on both
targets. It exercised CLI trap diagnosis and replay, proof search and checking,
framed-log processing, an HTTP route edit, and supervised durable recovery.
Both recovery histories contained the same 18 events and were accepted.
[Rehearsal logs, CLI receipts and application manifest](long-certificate-package-rehearsal.tar.gz).

On each target the installed command accepted a valid 273-byte certificate
and rejected a corrupted one. The installed certificate suite accepted seven
proofs and rejected 21 mutations per target. The original scorecards above identify the earlier candidate.

## Integrated source package

The [integrated release candidate](fenrir-source-integrated.tar.gz) includes the
queue update, long-certificate support and the chunked counter implementation.
The extracted archive rebuilt offline to `/nix/store/mhikhhfcpixw8z87ijla08f84517728j-fenrir-0.1-dev`.
On each target the installed package produced the expected 29-node distribution
proof and preserved a saved decoder state when two suffixes updated different
key groups. The integrated kernel scorecards appear above.

## Independent installation exercise

Download the [scalar-register compiler package source](fenrir-source-scalar-compiler.tar.gz).
Use a separate Apple Silicon Mac with Nix, Git, and a running ARM64 Linux
Docker engine. Start in the directory containing the downloaded archive.
Run the following in a fresh shell. Keep the resulting exercise directory
for review.

```sh
(
  set -eu
  echo '12fa3a20e9c93146e1d0a8dbf8a38bf13ad8094e5748d562bf2cb2ad6a73dd78  fenrir-source-scalar-compiler.tar.gz' | shasum -a 256 -c -
  exercise=$(mktemp -d "$PWD/fenrir-exercise.XXXXXXXX")
  echo "$exercise"
  mkdir "$exercise/source"
  tar -xzf fenrir-source-scalar-compiler.tar.gz -C "$exercise/source"
  cd "$exercise/source"
  package=$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths "path:$PWD#fenrir")
  test "$package" = /nix/store/qx6cmq4bmq8ynlr2bipv4mcn0bs5iqw1-fenrir-0.1-dev
  tc="$package/bin/fenrir-toolchain"
  "$tc" python3 tools/solo5/setup.py --repeats 1
  FENRIR_SOLO5_IMAGE=$("$tc" python3 -c 'import json; print(json.load(open("build/solo5/setup.json"))["image_id"])')
  export FENRIR_SOLO5_IMAGE
  cd "$exercise"
  { sw_vers; sysctl -n hw.model; uname -m; echo "$package"; echo "$FENRIR_SOLO5_IMAGE"; } > environment.txt
  src="$package/libexec/fenrir"
  "$tc" sh "$src/tests/native/check-package.sh" "$package/bin/fenrir" "$exercise/cli" > cli.log 2>&1
  "$tc" sh "$src/tests/native/check-package-apps.sh" "$package" "$exercise/apps" > apps.log 2>&1
)
```

Record which source expression trapped, why that input overflows, and what
response you observed after the HTTP route edit. Retain the CLI receipts,
both logs, `environment.txt` and `apps/summary.json`. If a command fails,
record its error and the last successful step. The scalar-register compiler package passed the full developer-machine rehearsal on both
targets, including the source edit, trap replay and four applications.
The independent engineer's installation and replay remain open.
[Updated rehearsal logs, receipts and application manifest](scalar-compiler-package-rehearsal.tar.gz).

The updated prover source release passed all 16 native runtime fixtures on macOS ARM64 and Solo5 ARM64 spt (32 executions). These cover the tracing heap, suspended roots, saved handler state, FIFO task and channel operations, cancellation, and scope cleanup. [Runtime fixture report and command transcripts](updated-prover-runtime-fixtures.tar.gz) binds each result to the source and executable hashes and records the Solo5 image identity. The harness builds these fixtures directly against the runtime in the extracted source release.

All 19 roundtrip fixtures declaring an effect matched Shen's observations on both released-source targets (38 comparisons). The dispatch fixture recorded and replayed FIFO and explicitly reversed output order on each target. Both rejected an unavailable task, a prematurely exhausted schedule, and trailing choices. The [handler and dispatch archive](updated-prover-handlers-replay.tar.gz) includes model and native output, build transcripts, executable hashes, both dispatch images, and the replay inputs. These tests cover the repository's declared-effect roundtrip corpus and its two-task dispatch scenario.

The updated source release passed the default bounded accepted-job exploration for two tenants, two keys and two digests with up to three submits, two deliveries, two responses and one crash. Shen visited 251,374 monitored states and 1,093,203 transitions without truncation or a property violation. The JavaScript implementation matched all 629,165 distinct runtime edges. Ten mutant variants exercised every monitored check. A separate run replayed all 20 host history fixtures and matched their expected verdicts (five accepted, fourteen rejected, one indeterminate). The [exploration report, raw edge stream, counterexamples and history results](updated-prover-service-exploration.tar.gz) include the source archive digest. These model and JavaScript runs complement the two native deployments' lost-commit-ack recovery histories.

On the ten-logical-CPU Mac, the Elixir/Bandit HTTP deployment with one BEAM scheduler sustained both 1,000 and 10,000 requests/s for ten minutes each. The client validated 600,000 and 6,000,000 responses respectively, with zero errors, invalid responses or outstanding requests at the end. Observed p99 was 0.665 ms and 0.136 ms respectively. Each rate has one sample and the run establishes a 10,000 requests/s lower bound for this deployment. The [Bandit campaign archive](mac-http-bandit-ten-minute.tar.gz) includes the sweep inputs, environment, raw client measurements and capacity assessment.

The released native workers produced identical model-accepted histories for a SQLite port killed mid-write (5 events per target), four queued jobs drained after a worker restart (15), and the same restart with keys starting at 2³² (15). The mid-write case checked the restarted snapshot and empty queue before retry. Each drain observed eight delivery attempts and an empty pending queue. The [paired native fault receipts](updated-prover-native-faults.tar.gz) include all six histories, model verdicts, worker identities and the Mac runner extended to select the workload.

The updated Solo5 prover binaries were profiled by counting instructions in the released Fenrir assembly and optimized C assembly on matching corpus rounds. The difference between two rounds and one round removes one-time setup. Search executed 13,249 counted instructions in Fenrir and 5,223 in C, including 5,146 and 436 explicit SP-relative instructions respectively. Checking executed 10,383 and 3,699, including 3,844 and 330 SP-relative instructions. Fenrir's search-steps and verify-step accounted for 7,893 and 6,676 instructions per corpus round. Counts exclude callees outside each instrumented assembly unit, including the collector and library routines, and carry no timing interpretation. The [raw counts, instrumented assembly and counter generator](solo5-prover-instruction-counts.tar.gz) support prioritizing register retention in the traversal loops.

A Solo5 assembly experiment retained eight frequently referenced scalar slots in callee-saved registers in search-steps and verify-step. Both guest variants returned the expected totals at 50,000 corpus rounds. Across twenty alternating paired samples after warmup, median variant/release elapsed time was 0.935 for search (paired bootstrap 95% interval 0.891–0.975) and 0.880 for checking (0.849–0.927). The [experiment and executable receipts](solo5-prover-scalar-registers.tar.gz) include the transformer, binaries, and in-guest measurements. General compiler adoption requires typed slot selection, preserving roots and address-taken storage, and restoring registers on every exit including tail calls. This experiment used the shared development Mac during the HTTP campaign.

The compiler now retains up to eight frequently accessed scalar slots in allocating tuple-argument loops. All 26 source-annotated native fixtures passed on each target. An ABI caller seeded x19–x26 and checked their values after running each prover kernel on both targets. The measured source snapshot differed from the updated prover release archive only in tools/aarch64/managed-image.mjs. On Solo5, 20 directly paired 50,000-round runs yielded median new/previous elapsed ratios of 0.940 for search and 0.931 for checking. The full scorecard passed on Mac (1.005×) and remained above threshold on Solo5 (3.468×). The [compiler source, fixture logs, paired timings and four-kernel reports](scalar-compiler-results.tar.gz) record the development candidate. These measurements shared the Mac with a service load campaign.

The scalar-register compiler release built offline. All 818 archived files matched the measured source snapshot and all 816 installed source files matched the archive. The installed package passed the CLI and four-application rehearsal on both targets, including both 18-event durable recovery histories. The same source and packaged toolchain passed 38 Shen/native handler comparisons and both dispatch replay checks. [Source and installation manifests, rehearsal logs and recovery histories](scalar-compiler-package-rehearsal.tar.gz).

The scalar compiler package HTTP guest and matched C guest used identical Darwin ingress binaries, 32 MiB guest memory and the same Linux VM CPU (CPU 0, verified before tender startup). The five-second probe at 1,000 requests/s returned all 5,000 responses per worker and ended with no outstanding requests. At 5,000/s both returned all 25,000 responses after drain, with 295 outstanding for Fenrir and 1,937 for C at the end of offered load. The probe shared the Mac with a native HTTP load test and supplies candidate rates only. [Guest binaries, ingress, environment and probe samples](scalar-solo5-http-probe.tar.gz).

The Solo5 HTTP sweep now records tender RSS and its lifetime high-water mark, Darwin ingress RSS samples, and whole-VM Linux MemTotal and MemAvailable separately. It checks the executable and effective CPU affinity of the measured process and binds samples to its full container ID. Each guest served 200 verified responses in the [instrumentation probe](solo5-http-memory-probe.tar.gz). VM-wide availability includes unrelated work. Tender high-water marks accumulate from startup across rates.

A Solo5 emitter experiment initialized six- and seven-field constructors directly, zeroing their unused words in the generated stores to preserve structural equality. The framed-log guest passed its 13 correctness cases and returned exact summaries for three key distributions at 1 MiB and 16 MiB. Each comparison used 24 alternating pairs after warmup. On the 16 MiB mixed workload, variant/release elapsed time was 0.980 (95% interval 0.966–1.023). The single-key interval was 0.946–0.993, and the spaced-eight interval was 0.952–1.015. The release compiler retains its existing initialization strategy because the mixed workload showed no clear gain. [Generated-code candidate, guest binaries, summaries and paired samples](stream-wide-constructors.tar.gz).

The packaged scalar compiler's certificate checker accepted seven valid witnesses on each target. Across those witnesses it rejected every one-rule substitution with either other legal rule (686), every strict prefix (343), and all seven witnesses when supplied against either of the two frozen countermodel formulas (14). The corpus includes a 273-rule branching witness. Both builds reported the same typed artifact hash. [Per-target results, checker harness and inputs](scalar-prover-rule-substitutions.tar.gz).

Reassessment of the eight archived ten-minute HTTP samples confirmed sustained backlog growth for the earlier Rust server at 80,000 requests/s. Each successive minute's minimum backlog exceeded the preceding minute's maximum throughout the run. That sample already failed the response criteria. The Nim sample at the same rate remained inconclusive. The other six samples retained their sustained-rate verdicts. The assessor now recognizes sustained growth as independent evidence of exceeding capacity even when all responses eventually validate. [Archived sample hashes and reassessed verdicts](http-backlog-reassessment.json).

At 80,000 requests/s for ten minutes with 16 connections, revised Rust returned all 48,000,000 expected responses with zero errors or misses. Its p99 was 0.244 ms and ten requests were outstanding at cutoff. Earlier Rust validated 47,394,050, missed 605,950 and had 948,704 outstanding at cutoff. These are separate one-block campaigns on the shared Apple M5 host. They used identical Go load-client source and different driver binaries. The source, binary and worker assignment were verified against each run's own manifest. The revised result establishes a Rust capacity lower bound. [Rust comparison and revised raw sample](mac-http-revised-rust-80000.tar.gz).

The packaged native durable workers completed the same 128 fresh commits and model-accepted 129-event history on both targets with the resource recorder enabled. Before and after the run, the main SQLite file measured 4,096 bytes on each target, while the open WAL grew from 41,232 to 3,732,752 bytes. Final SQLite port RSS was 3,915,776 bytes on Mac and 2,195,456 bytes in the Solo5 deployment's Linux host. BEAM RSS and the shared-memory index size are recorded separately. These are endpoint snapshots outside the timed interval. [Storage measurements, histories, database checks and recording code](durable-storage-resources.tar.gz).

Ten rotated Mac blocks measured 128 fresh commits each for the packaged Fenrir worker and the Rust, Nim, Erlang and Elixir workers. All 50 runs produced the same 129-event history and passed full SQLite row verification for both tenants. Across the five deployments the median SQLite process RSS after load was 3,899,392 bytes each. The median main database, WAL and shared-memory index lengths were 4,096, 3,732,752 and 32,768 bytes respectively for every worker. Native worker processes run separately from BEAM and SQLite; these counters describe the two named shared components. [Per-worker resource snapshots, rotated timings and checked histories](durable-five-worker-resources.tar.gz).

In two rotated Mac blocks with one normal and one dirty CPU scheduler, all five durable workers acknowledged all 5,000 scheduled commits per run at 1,000/s over five seconds. All ten 5,001-event histories matched and passed Shen and database row checks. The [five-worker paced receipts](durable-mac-paced-five-workers.tar.gz) include raw acknowledgement timings, resource snapshots and the one-scheduler host probe. The Mac exposes ten logical CPUs. The results describe a shared host with one BEAM scheduler and do not establish ten-minute capacity.

The durable history checker now reuses a structural fact when testing terminal-job preservation. Unchanged job lists, and lists that add a single job ahead of the entire prior list, preserve every old terminal entry. Other changes still check each old terminal job. On 15 alternating pairs of the same 5,001-event history, median elapsed time fell 9.6% (candidate/previous 0.904, paired bootstrap 95% interval 0.876–0.955). Both predicates agreed on all 441 pairs of lists of up to two entries from a four-job alphabet. The twenty retained history fixtures retained their verdicts and the default model exploration passed. [Checker changes, differential checks, replay timings and exploration](durable-terminal-history-replay.tar.gz).

The completed revised Mac block selected Rust as the faster eligible reference at 80,000/s: Rust sustained the offered load while Nim failed the response criteria. Nim validated 45,873,479 responses and had 2,474,175 requests outstanding at cutoff. Fenrir in this block used the earlier compiler build and sustained the rate. An upper bound for revised Rust and capacity evidence for the newly packaged Fenrir server remain outstanding. [Full three-worker block including Nim and reference selection](mac-http-revised-block-80000.tar.gz).

The updated terminal-job predicate replayed the two ten-minute Solo5 durable histories at 100 commits/s. Each history contained the same 60,001 events. Both accepted verdict records exactly matched those produced before the change. Replay took 98.1 seconds for the Fenrir recording and 107.5 seconds for C on the shared development Mac. These durations measure the history checker. [Chunked histories, prior and new verdicts, and replay timings](durable-terminal-long-replays.tar.gz).

### Darwin argument parsing and package rehearsal

The [candidate source archive, package identity, and CLI rehearsal](darwin-input-package-rehearsal.tar.gz) cover the Darwin decimal-input change. The installed CLI built and ran edited programs, rejected malformed direct Darwin inputs, and replayed the recorded arithmetic and task traps on macOS ARM64 and Solo5 ARM64 spt. All 818 installed source files matched the archived contents. The archive also contains the two Nix flake files. Its identity report lists the differences from the scalar-compiler snapshot used for performance measurements. The candidate still requires performance qualification and independent installation.

The same installed candidate passed the [four-application rehearsal on both targets](darwin-input-application-rehearsal.tar.gz). Each prover run accepted seven certificates, rejected 21 mutations, and passed 30 fuel-boundary checks. Both HTTP services passed wire and concurrency checks and served the edited route. Both durable workers produced the same 18-event recovery history. This developer rehearsal overlapped the exploratory Solo5 HTTP capacity sweep on the same machine.

### Clock-enabled package

The [clock-enabled source and developer rehearsal](clock-package-rehearsal.tar.gz) include the editable source archive, package identity, CLI replay receipts, all four application checks, and all 35 Shen/JavaScript clock traces. Eight virtual-clock fixtures passed on each native target. A requested 25 ms live sleep measured 32.202 ms on Darwin and 32.824 ms on Solo5. Both service histories passed the 18-event recovery check. The packaged HTTP and framed-log binaries differ from the scalar-compiler release used for earlier performance measurements.

A compiler experiment combined signed division and multiplication by the same positive power of two. The framed-log guest replaced five instructions with one mask at each of two sites after biasing the signed operand. On the mixed corpus, 30 alternating pairs after warmup produced a candidate/baseline median elapsed ratio of 1.021 (paired bootstrap 95% interval 1.001–1.036). All 62 outputs matched the frozen summary digest. These exploratory runs shared the host with other testing. The compiler retains the prior lowering. [Candidate source, guest binaries, assembly, corpus and paired timings](stream-rounding-experiment.tar.gz)

The development heap marks scalar leaves immediately and visits only the pointer fields indicated by each object's mask. In 80 alternating measured guest pairs following warmup, the mixed stream elapsed ratio to the clock-enabled package was 0.977 (paired bootstrap 95% interval 0.966–0.988). A separate 80-pair instrumented run measured collection time at 0.828 (0.819–0.836), with identical allocation and collection counts. Every guest summary matched the expected digest. The workload shared the host with other testing. All 18 runtime fixtures passed on Mac and Solo5. The change awaits a packaged four-kernel comparison. [Source, guests, profile counters and raw paired timings](stream-heap-marking.tar.gz)

The heap-marking change was also tested on the prover against the clock-enabled package. Both runtime builds used identical generated ARM64 assembly for each lane. Forty alternating measured pairs after warmup, with 50,000 corpus rounds per guest execution, gave candidate/baseline elapsed ratios of 1.000 for search (95% interval 0.995–1.001) and 0.998 for checking (0.995–1.0003). Both intervals include parity. All guests returned the expected case counts. These shared-host measurements support no prover speedup claim. [Matched guest binaries, typed artifacts, raw output and intervals](prover-heap-marking.tar.gz)

An isolated prover variant short-circuited bit membership for masks between the atom bit and twice its value, and reused that check during insertion. With the same updated collector in both guests, 40 alternating pairs of 50,000 corpus rounds after warmup gave candidate/baseline median elapsed ratios of 1.023 for search (95% interval 1.022–1.027) and 1.020 for checking (1.016–1.023). Every run returned its expected case count. The shared-host trial favored the existing implementation in both lanes, so the released formula code remains the benchmark source. [Candidate and baseline source, guest binaries, assembly and raw times](prover-mask-range.tar.gz)

The Mac durable-service campaign's first ten-minute Fenrir/Rust pair completed at 100 offered commits/s. Both workers acknowledged all 60,000 commits and independently produced the same accepted 60,001-event history. Readback verified 30,000 jobs per tenant across the four SQLite tables with WAL and synchronous FULL. Fenrir's p99 was 3.713 ms and Rust's was 3.826 ms. Maximum backlog at one-second boundaries was zero and four respectively, with zero at cutoff for both. This single block used one BEAM scheduler on a shared ten-logical-CPU Mac. The replicated capacity and loaded latency gates remain open. [Raw timings, histories, databases and verdicts](durable-mac-first-ten-minute-pair.tar.gz)

A diagnostic Solo5 durable-service pair used the same recovery image, host binaries, one-CPU allocation, SQLite settings, and 200-request schedule. Each guest produced the same checked history and database rows. Summed dispatch-to-acknowledgement time was 433.8 ms for Fenrir and 371.5 ms for C. The store transaction accounted for 370.7 and 304.6 ms respectively. The residual outside the transaction includes worker, transport and host scheduling. This single two-second pair on a shared development machine cannot rank workers or establish sustainable throughput. [Pair, raw timings, build hashes and history verdicts](durable-solo5-transaction-pair.tar.gz)

A Solo5 prover experiment added an equality check before testing whether an
atom is present in a fact mask. With the retained compiler and runtime,
40 alternating measured pairs per lane after two warmup pairs gave a
candidate/baseline median of 0.9988 for search (paired 95% interval
0.9979–0.9996) and 1.0039 for checking (1.0012–1.0058). Each guest produced
the expected case count over 50,000 rounds. The shared development host also
ran the durable service campaign. The released prover keeps its existing
membership test. [Sources, guest images, and raw in-guest timings](prover-atom-equality.tar.gz)

In the scalar-package Mac HTTP trial at 80,000 scheduled requests/s, the
first three minutes each ended five requests behind. Minute four ended
5,346 behind. Minutes five through ten completed 75,878–78,179 requests/s
and the run reached cutoff 979,771 requests behind. The slowest valid
request took 13.790 s, including 13.790 s waiting for its connection lane's
preceding request and 0.251 ms in the subsequent HTTP fetch. These timings
locate the observed delay at the client lane and leave the cause of the rate
shortfall unresolved. Per-minute rates use differences between observed
completion counts and monotonic timestamps. [Raw timeline and build](packaged-fenrir-http-80000.tar.gz)

The Darwin server averaged 1.66–1.69 CPU cores during each of the first
three minutes of that trial. In minutes five through ten it averaged
2.63–2.71 cores while completing fewer requests. The highest sampled server
RSS was 2,326,528 bytes in both intervals. CPU intervals use the samples
nearest each minute boundary on the harness clock. Completion counts use
the driver's timeline, which starts after connection warmup. The observations
do not isolate CPU frequency, contention, or time inside the shared runtime
lock. [Per-minute CPU deltas, timestamps and raw trial digest](packaged-fenrir-http-cpu.json)
