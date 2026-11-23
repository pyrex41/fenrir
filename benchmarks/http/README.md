# Bounded HTTP service benchmark

The Fenrir entry `parse-head` consumes one complete HTTP/1.1 request head,
including its terminating empty line. Ingress must split pipelined requests
and stop buffering at 8192 bytes. The parser accepts GET requests with one
nonempty Host field and selects Home for `/`, Status for `/status`, or Item
for `/items/` followed by ASCII digits. An Item carries the byte offset and
length of the digits in the supplied head, preserving leading zeroes. Missing
routes produce a distinct decision. The decision includes whether the client
requested connection close. Malformed or oversized requests have separate
outcomes.

Run `python3 benchmarks/http/check-router.py TARGET` on macOS ARM64 with
`macos-arm64` or `solo5-arm64-spt`. These checks compile the parser with
request fixtures and inspect every routing decision. The Rust reference is a
socket service and can be built with `rustc --edition=2021 -O reference.rs`.

On Apple Silicon, run `sh benchmarks/http/build-mac.sh OUTPUT` to build the
Fenrir service. Start it with a numeric loopback port (0 selects an available
port); it prints its bound address to stderr. The C adapter owns the sockets,
splits heads, and writes responses. Compiled Fenrir validates each head and
selects its status, closure policy and body. Up to 64 connection threads can
perform I/O concurrently. Router calls serialize around the current native
runtime's shared heap.

Run `python3 benchmarks/http/check-service.py FENRIR_BINARY RUST_BINARY` to
verify exact HTTP bytes on loopback, pipelining, fragmented writes, malformed
input, an abandoned partial head and concurrent independent clients. The delayed-reader case leaves the first of 32 pipelined 6,000-byte item responses unread while another connection completes a status request, then checks every byte after draining the pipeline.

For matched Mac measurements, run
`python3 benchmarks/http/build-references.py NEW_BUILD_DIR`, then build Fenrir
into `NEW_BUILD_DIR/fenrir`. The reference build records compiler versions,
arguments, source hashes, and binary hashes. The sweep verifies those binary
hashes and includes the build record in its environment receipt.

Build the Nim reference individually with
`nim c -d:release --overflowChecks:on --out:NIM_BINARY reference.nim`.
It uses a single async socket event loop, a 64-client cap, an 8192-byte head
limit, and five-second read and write timeouts. Include its executable as the
third argument to `check-service.py` to run the same wire corpus against all
three implementations.

For the idiomatic Elixir deployment, run `elixir/run.sh build` in this
directory, then `elixir/run.sh 0` or `python3 elixir/check.py`. Mix locks
Bandit, Plug and their dependencies. One acceptor admits up to 64 clients.
Bandit handles HTTP parsing, connection lifecycle and response headers.
The checks compare status, content type and body on persistent connections.
Bandit's 8192-byte limits apply to individual request lines and header fields.
The native services apply 8192 bytes to the complete head. Keep the Bandit
deployment in the idiomatic-service comparison when reporting overload or
header-limit results.

Build the Solo5 service on the Mac with `sh benchmarks/http/build-spt.sh OUTDIR`
and launch it with `python3 benchmarks/http/run-spt.py OUTDIR PORT`. Pass
OUTDIR after the binary arguments to `check-service.py` to run the same
loopback corpus against this deployment. The Darwin ingress handles TCP,
splits request heads and writes responses. It sends each complete or
limit-sized head to one persistent ARM64 SPT guest through two pipe-backed
Solo5 network devices. The guest runs compiled Fenrir parsing and routing and
returns four scalar fields (status, close flag, body selector/offset and length).
One call is in flight at a time. Neither Docker nor the guest needs network
access to terminate client TCP connections.

Build the matched C guest with `sh benchmarks/http/build-spt.sh C_OUTDIR c`.
Both deployments use the same ingress source, frame protocol, guest device
driver and response writer. Run
`python3 benchmarks/http/measure-spt.py FENRIR_OUTDIR C_OUTDIR NEW_RESULT_DIR`
for the single-client latency experiment. The runner checks the wire corpus,
opens one persistent connection per guest, then rotates 256-request batches
over four routes. It retains individual request latencies, warm-up samples,
binary hashes and a paired elapsed-time interval. This experiment has one
outstanding request and does not establish sustainable capacity or loaded p99.

For offered-load experiments run
`python3 benchmarks/http/sweep.py BUILD NEW_OUTPUT --target solo5 --seconds 10 --rates 500 2000 8000`.
Use `--target mac` for native Fenrir, Rust and Nim. BUILD contains the
executables and guest directories named above. The Go client schedules
arrivals independently of completions across 16 persistent lanes by default.
A busy lane preserves the original due time of its next request. Every result
records scheduled requests, validated responses, transport errors, response
mismatches, missed arrivals, per-second backlog and scheduled-arrival p50/p99.
A five-second drain window bounds additional starts after the offered load
ends. Short sweeps locate rates for the ten-minute capacity runs.

Use `python3 benchmarks/http/assess-rate.py RESULT.json ...` to check the
request census and each one-second backlog sample. For positive clearance
evidence the sampled backlog must return to at most one outstanding request
per connection lane at least once each minute and at the final cutoff. This
is a sufficient operational test for recurrent draining. A ten-minute run shows sustained growth when all samples meet their cadence,
every later minute's minimum backlog exceeds the preceding minute's maximum,
and the final minute's minimum exceeds the connection count. Other patterns
without clearance evidence remain unconfirmed. The report includes the per-minute
minimum, median, maximum and final backlog. Passing a ten-minute run
establishes a lower bound on sustainable capacity at the tested rate.

Each sweep records the load settings, executable hashes, and hashes of the
HTTP sources present in the checkout. Executables supplied from an earlier
build retain their own identities. For matched Solo5 runs the runner checks
that both ingress binaries are byte-identical, resolves the Docker tag once,
and launches both guests with that image ID.

Run `python3 benchmarks/http/check-rust-router.py` to check the Rust
socket service's parser directly against the same 27 input heads as
`check-router.py TARGET`. Both checks compare the route, connection-close
decision, and byte range for item IDs. The parser corpus includes a complete
8192-byte head, an oversized head, and a truncated head.

Run `python3 benchmarks/http/check-nim-router.py` to compare the Nim service
parser with the same 27 heads. It checks status, content type, response bytes
and the connection-close flag. For item routes the expected response bytes
come from the byte range specified by the corpus.

Run `python3 benchmarks/http/measure-router-spt.py NEW_OUTPUT_DIR` for the
Solo5 kernel comparison. The Fenrir and C guests each parse the same 27 heads
100 times per boot and validate all four response fields on every call. One
warmup pair precedes twelve alternating pairs. The in-guest monotonic interval
includes routing and validation. Ingress, sockets, VM boot and console output
are outside that interval. The report retains the corpus, source and image
hashes, paired times, median ratio and paired bootstrap interval.

Run `python3 benchmarks/http/measure-router-mac.py build/http-mac-trial` on
Apple Silicon with the frontend toolchain available. The output directory
must be new. Each timed loop parses 200 rounds of the shared request corpus.
Fenrir, Koka and C check four decision fields, including item offsets.
Rust and Nim check the equivalent status, media type, body bytes and close
flag returned by their service parsers. File reads, compilation, sockets
and startup are outside the timer. Peak RSS covers the whole process.
The report retains a discarded first block, fifteen rotated measured blocks,
per-process receipts and paired median time ratios. C is diagnostic on Mac.
Set `KOKA` to the pinned compiler executable. Koka decodes the binary corpus
into vectors before starting its monotonic timer. The report selects the
fastest of Rust, Nim and Koka and compares peak RSS against the same reference.

The load driver records three timing histograms for valid responses. PreviousRequest
measures how long an earlier request occupied the same connection lane after the
new request was due. Dispatch measures time from lane availability or due time,
whichever came later, until the client starts the fetch. Fetch covers the HTTP
exchange and response validation. The assessor reports upper bounds for each
phase's p99 from power-of-two nanosecond buckets. Percentiles across phases
do not add. The release latency metric is the nearest-rank p99 from scheduled arrival to completion among valid responses. The driver counts invalid responses, transport errors, and missed arrivals separately. A run with no valid responses reports zero for all three latency statistics.

Mac service sweeps also sample the server process with Darwin ps before,
during (every five seconds), and after each client run. CPU per completed
request includes connection warm-up and drain in its numerator. The samples
retain cumulative process CPU and RSS. The assessor divides the change in
process CPU seconds by the time between the first and last samples to report
average occupied cores, and cross-checks CPU per completed request and
maximum sampled RSS. The largest observed RSS is a sampled
lower bound on peak memory. Solo5 sweeps apply the same sampling to the Darwin
TCP ingress child, identified by its executable path. The resource row names
its process scope. Both HTTP guests receive a 32 MiB memory budget through
the tender. The offered-rate sweep pins both tenders to the same Linux VM CPU (default 0, selectable with `--guest-cpu`) and
checks the effective affinity inside each container before startup. The report
records the guest CPU mask and configured memory capacity in bytes. The TCP
ingress and load client run on the Darwin host. Before and after each client run,
the harness verifies the tender executable and reads its Linux RSS and lifetime
RSS high-water mark from /proc/1/status. It also records MemTotal and MemAvailable
from the Linux VM. Those VM counters include other processes sharing the VM.

Use `--blocks 10` to collect ten paired repetitions at each offered rate.
Each block runs every implementation at every rate and rotates which service
runs first for that rate. The JSON records the zero-based block and rate
index. All blocks reuse the service processes started by the sweep, so these
measurements describe persistent services. For the release latency comparison,
use the same offered rate for Fenrir and the selected capacity reference.

Run `python3 benchmarks/http/paired-latency.py SWEEP_DIR REFERENCE RATE` to
report the p99 ratio in each block and a seeded paired-bootstrap 95% interval
for the median ratio once ten pairs are available. Smaller runs retain every
ratio and the median and report a null interval. Select REFERENCE from the capacity experiment and RATE
from 70% of the slower measured capacity before comparing latency. Short runs
can exercise the analysis; the duration and pair-count field identifies them.

The load driver retains one 64-bit latency per scheduled request for exact
percentiles. Its 64-million-request ceiling permits a ten-minute run at
100,000 requests/s using 480 MB for the latency array. The maximum array is
512 MB, plus the Go runtime, transports, and per-lane timing counters.

After building the Bandit service, run the common offered-load driver with
`ERL_FLAGS='+S 1:1' python3 benchmarks/http/sweep.py build/http/elixir NEW_OUTPUT --target elixir --seconds 15 --rates 1000`.
Run `python3 benchmarks/http/capacity.py NEW_OUTPUT` to summarize Bandit's
own sustained and failed offered-rate bounds. Short runs verify the harness.
A sustained bound requires a ten-minute run that meets the response and
backlog criteria.
The sweep records the BEAM version, scheduler flags, lockfile digest, process
samples, and the same response and latency census as the native services.
This measures the idiomatic deployment separately from the matched native
capacity comparison. The first path selects the Mix artifact directory. Its compiled BEAM modules
and application descriptors are hashed in the sweep receipt.

For sweeps created with resume support, repeat the same sweep command with
`--resume` after an interruption. The harness checks the recorded environment,
driver, server binaries, source hashes and workload before accepting existing
rows. It starts fresh server processes and marks newly measured rows with
`RestartedServerSession`. Each completed row becomes visible by atomic rename.

If an external event invalidates a measurement, preserve the raw row and
record its filename and reason in an `exclusions.json` object in the sweep
directory. The paired latency report rejects pairs containing an excluded
row. Apply the same exclusions when selecting a throughput reference.

Run `python3 benchmarks/http/capacity.py SWEEP_DIR` to inspect capacity
bounds for each server. At each offered rate every scheduled block must
sustain the load to establish a lower bound. A higher rate where every
block fails the response criteria or shows sustained backlog growth supplies an upper bound under the
assumption that capacity is monotonic. Missing, excluded, short, and
inconclusive rows cannot establish either bound. A wrong response is a
correctness failure. The report lists affected workers and withholds
reference selection and throughput comparison until the mismatch is resolved. Contradictory bounds
require another measurement. To narrow overlapping bounds, add intermediate
rates to a matched sweep. Once one reference's sustained rate reaches every
other reference's failing rate and both Fenrir and the selected reference
have two-sided bounds, the report gives 70% of the slower measured sustainable
rate (rounded down to whole requests per second) for the paired latency run.

The `two_thirds_capacity_comparison` field uses the full set of matched
references. If Fenrir sustains at least two-thirds of every reference's
failing rate, its throughput meets the target under the monotonicity
assumption. If Fenrir fails at or below two-thirds of any reference's
sustained rate, its throughput falls below the target. Other bounds leave the
comparison undetermined. The release also requires the paired latency and
experimental-quality gates in WORK_FILE.md.

Use `python3 benchmarks/http/paired-latency.py LATENCY_DIR --capacity CAPACITY_DIR`
to assess loaded latency. The command derives the reference and offered rate
from the capacity sweep and checks host, concurrency, binaries, benchmark
sources and Solo5 container identity across experiments. For ten or more
ten-minute pairs it compares the paired median p99 ratio's 95% bootstrap
interval to 1.5. An interval spanning the threshold leaves the result open.
The linked report records the capacity block count. Its combined
`throughput_and_latency_gate` requires ten or more capacity blocks as well
as ten eligible latency pairs for a pass. A shorter capacity experiment can
identify candidate rates for a follow-up measurement.

Pass additional sweep directories to `capacity.py` or after `--capacity` in
the paired latency command to refine a bracket with new offered rates. All
directories must have matching build, host, workload duration, connection
count and block count. The driver may reside in a different results directory
when its digest matches. Overlapping rates are rejected to prevent a copied
sample from counting twice.

Each new sweep records the worker, its zero-based position in the rotated block, and the SHA-256 of the sweep environment in every sample. Capacity analysis, paired latency analysis, and interrupted-run recovery verify these fields. A null `sample_origin_version` in an analysis identifies an older sweep where the worker is inferred from the filename. Its timings remain available for exploration, and the combined throughput and latency release verdict is undetermined.


Darwin sweeps record the host's maximum logical CPU count from
`sysctl -n hw.logicalcpu_max`. For matched native Mac runs, the capacity-linked
report evaluates `single_core_throughput_and_latency_gate` when the capacity
and latency runs both used a one-logical-CPU environment. On larger hosts
and for older samples without this measurement it reports `undetermined`.
The ordinary throughput and latency verdict describes the measured deployment.
The load driver shares that host.

When Mac service build receipts are present, the sweep checks the application
sources as well as the executable hashes before starting the servers. A
changed Fenrir route, server adapter, build script, Rust source or Nim source
requires rebuilding that executable or running against its original sources.

The load generator records its own user and system CPU nanoseconds using
process resource counters immediately before releasing the connection lanes
and after the offered interval and drain. The assessment reports mean CPU
cores and CPU microseconds per completed request. Percentile sorting and JSON
output occur after this measurement. Older rows have no driver CPU reading.

For a separate Darwin contention experiment, build with
`sh benchmarks/http/build-mac.sh OUTPUT --profile-lock`. After printing its
listening address, the server writes one JSON line to stderr when each
connection closes. Capture stderr continuously or redirect it to a file.
Sum `wait_ns` and `held_ns` across connections and divide by total `calls`
to obtain mean lock acquisition and critical-section durations. Counts include
warmup requests. The critical section includes the compiled routing call and
copying its scalar decision. The capacity sweep rejects a lock-profiled build
receipt because the clock reads affect the measurement.

Mac sweep samples taken while the load driver runs include recent Darwin process CPU percentages for the server, driver, and sum of other visible processes. One core corresponds to 100%. These observations help interpret host contention. Enforced CPU allocation is a separate qualification requirement.

Each paired latency result includes the observed Darwin CPU percentages for the server process (the ingress on Solo5), the load driver, and all remaining processes. The sample count, median, and peak are reported separately for each worker. One hundred percent represents one logical CPU. Older trials without observations report null.

The load driver allows up to 128 million scheduled requests per trial. It reserves eight bytes per request for exact nanosecond latency samples, up to 1,024,000,000 bytes for the sample array. The reported driver peak RSS includes its other allocations.

Pass `--driver-from PRIOR_SWEEP` when starting a new rate grid with a previously measured load generator. The runner checks the recorded source and binary digests before launching servers and records the original Go toolchain. Use the same load.go revision in both sweeps.

Solo5 memory method 2 also reads PID 1 resident bytes from smaps_rollup at each endpoint. When cgroup v2 exposes memory.peak, the receipt records the lifetime high-water mark for the entire container, including helper processes and charged cache. This has a different scope from the tender process and from VM-wide available memory.
