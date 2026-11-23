# Framed log profile 1

The wire format is a sequence of unsigned big-endian 16-bit lengths, each
followed by that many bytes. The first body byte is a key (0 through 63).
The remaining bytes are opaque payload. A length of zero rejects at the
first length byte. An invalid key rejects at the key byte. EOF inside a
length or body rejects at the first missing byte, including after good frames.

For each observed key emit one ASCII line in ascending numeric key order:
key, record count, payload byte count and sum of unsigned payload bytes,
in decimal separated by single spaces and terminated by LF. Empty input
produces empty output. Rejects produce no summary, print "reject OFFSET"
with LF to stderr and exit 1. All counts fit unsigned 64 bits within the
benchmark scope (up to 1 TiB of input).

Stream with one 1..65536 byte input buffer and 64 fixed-size aggregates.
Retain no payload after consuming a chunk. The optional command-line chunk
size defaults to 8192. The first summary line is available only after EOF.

On Apple Silicon, run `python3 benchmarks/framed-log/measure.py OUTPUT_DIR`
with a new directory to build Fenrir and the Rust, Nim, Koka and Shen/JIT references, validate the
correctness corpus, and collect 20 rotated groups on the maximum-length,
single-key stream. Empty-input launches give a startup reading. Each workload
timing includes launch, parsing, and output. A separate set of runs collects
Darwin peak RSS with the same inputs and order. The report retains the counters, input and binary hashes, and the paired median
Nim/Rust and Fenrir/Rust elapsed-time ratios with percentile bootstrap intervals. The
measurement includes process launch, warm-cache file reads and summary output.
Compiler timing and warm-up rows are recorded separately. For a longer repeat,
append `--rotation-cycles 8` to collect 80 groups, alternating complete forward
and reverse rotations. Each implementation runs equally often in each position.

The Fenrir decoder in `processor.fen` accepts successive byte chunks through
`feed` and returns a typed summary or rejection offset through `finish`.
Run `python3 benchmarks/framed-log/check-fenrir.py TARGET` with
`macos-arm64` or `solo5-arm64-spt`. The check splits each short stream at
every byte boundary and also feeds 100,000 frames through a single decoder.
This exercises compiled parsing and aggregation. For accepted input, `next-line` returns one canonical ASCII row and the remaining
keys per call. For rejected input, `rejection-line` formats the error offset.
Build the macOS ARM64 application with `sh benchmarks/framed-log/build-mac.sh OUTPUT`.
It reads stdin, takes an optional chunk size, writes accepted rows to stdout and
writes a rejection offset to stderr with exit status 1. Its C adapter owns the
read buffer and pins the Fenrir decoder between calls. Parsing, aggregation and
decimal formatting execute in compiled Fenrir. On Apple Silicon, build the block-input guest with
`sh benchmarks/framed-log/build-spt.sh OUTPUT` and run
`python3 benchmarks/framed-log/check-spt.py OUTPUT`. The SPT device is named
`input`; supply the logical byte length as the guest argument. Pad the device
to whole 512-byte sectors (at least one). The guest ignores padding, reads up
to 8192 logical bytes per feed and writes summary or rejection to the console.
Exit codes 0, 1 and 2 indicate success, malformed input and host/device failure. Both host and guest checks place a malformed frame after a valid prefix ending one byte before the 512-byte sector and 8192-byte feed boundaries. They verify the absolute rejection offset and absence of partial summary output.

Run `python3 benchmarks/framed-log/measure-spt.py NEW_OUTPUT_DIR` on the Mac
to build both ARM64 guests and measure the optimized C reference against Fenrir.
Both guests use the same SPT tender, block adapter, sector reads and console.
One warm-up pair precedes twelve alternating pairs. Each timing starts inside
the guest before stream processing and ends after the summary write. Docker
startup, staging the input, guest boot and elapsed-time reporting are outside
that interval. The runner checks every output and retains console lines,
guest and input hashes, paired timings and a bootstrap interval.

Both measurement scripts accept a second argument, `long` (default) or
`mixed`. The mixed corpus is 1 MiB of eight-byte frames, with five payload
bytes per frame. Each of 2048 cycles visits all 64 keys in the same permutation.
Every timed sample must emit the 64 expected ASCII rows in numeric key order.
The long corpus stresses payload scanning; the mixed corpus stresses record
dispatch and key updates. Compare like profiles and retain both results.

The decoder accepts keys 0 through 63. While reading a chunk it carries four
groups of sixteen keys as separate arguments. A sparse group stores its
first even/odd key pair directly. When another pair arrives, the group
expands into eight pair slots. Each pair keeps independent record counts,
payload lengths and sums for its two keys. Chunk boundaries retain all four
groups in the decoder state so a saved state can resume with either suffix.

The `adjacent-eight` and `spaced-eight` diagnostics each feed 131,072 records
with the same payloads and visit the eight logical keys in the same order.
Keys 0 through 7 occupy one counter group. Multiples of eight from 0 through
56 occupy four groups with two pairs per group. Once populated, both cases
have the same tree depth. The comparison measures how grouping updates
affects processing, including formatting and emitting eight summary lines.

For a key-distribution diagnostic, select `single-key`. It uses the mixed
profile's 131,072 frames with identical lengths, payload bytes and ordering,
and sets every key byte to zero. The expected output is a single summary
row. Comparing the two profiles includes the cost of constructing and
emitting their different summaries as well as updating the counters.

The Mac Shen/JIT reference calls Darwin read and write through the pinned
FFI library. Shen owns frame decoding, payload summation, 64 per-key
aggregates, rejection offsets and summary formatting. Each sample includes
loading the FFI library and the Shen source. Set `FENRIR_SHEN_JIT` to the
installation directory when running the generated launcher directly.

The Koka reference uses a bounded Darwin read buffer. Frame validation,
payload summation, group counters, and summary formatting execute in Koka.
Set `KOKA` to the pinned Koka executable when it is outside PATH.

For I/O attribution in a Solo5 guest, prefix the decimal input length with
`p` in the tender command. The guest emits the canonical result followed
by `read_ns`, `write_ns` and `elapsed_ns`. Read timing covers sector reads
per chunk, and write timing covers console output of the result. This mode
samples extra guest clocks. The report includes median read, write and total
time for each worker. For each sample it also subtracts read and write duration
from elapsed time before computing the median. That remainder includes decoding,
aggregation, heap work, formatting and adapter overhead. The paired scorecard uses the ordinary `t`
prefix and measures total elapsed time.

For Fenrir heap counts, pass `fenrir-profile` after the output path to
`build-spt.sh` and use the `p` input prefix. The guest counts successful
managed slot allocations and collections through summary serialization.
The profile also reports `collection_ns`, the accumulated guest clock time around collections, including clock sampling overhead. Divide this value by `elapsed_ns` for the collection share of a profiled run.
Divide allocations by logical input MiB to compare corpus profiles. The
standard Fenrir and C scorecard builds omit these counters. The Solo5 report builds a separate instrumented guest, verifies its output on the same corpus, and records its digest and counters under `fenrir_heap`.

Mac reports include a separate Fenrir heap run over the same input. The
profiled binary writes its canonical summary to stdout and a JSON object
with input bytes, successful managed allocations, collections and collection
time in nanoseconds to stderr. Build it with
`sh benchmarks/framed-log/build-mac.sh OUTPUT fenrir-profile`.
The report retains the binary digest and allocations per logical MiB.

Mac reports also include a separate rotated run for `first_output_ns`. The
clock starts before process launch and stops when the reader observes the
first stdout byte. Every run must emit the full canonical summary and exit
successfully. The Solo5 profiling run measures from entry to stream
processing through the return of the first nonempty summary console write.
An empty accepted stream reports `-1` in the guest profiler. The paired
guest throughput samples use the ordinary timer without profiling clocks.
