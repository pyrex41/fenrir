# Fenrir / Gleipnir

Fenrir is an experimental language with checked arithmetic, algebraic data types, pattern matching, and structured tasks. Its compiler emits native ARM64 code for macOS and for Solo5 guests. Gleipnir is the companion harness for exploring possible executions, saving counterexamples, and replaying them against an executable model written in Shen.

This **developer preview** runs four applications on both targets. It is intended for people trying the language, inspecting the compiler, or reproducing the experiments. Independent clean-machine installation and service performance qualification remain open.

## Build a native ARM64 program

On an Apple Silicon Mac with Nix and Apple Command Line Tools, run these commands from the repository root. The packaging script includes working-tree sources and prints the installed package path.

```sh
package=$(sh tools/aarch64/package-mac.sh)
mkdir -p build/preview
"$package/bin/fenrir" build --target macos-arm64 examples/recursive-sum.fen -o build/preview/sum
./build/preview/sum 10
```

The program sums the integers from 1 through 10 and prints `55`. To record that observation and replay it against the binary:

```sh
"$package/bin/fenrir" record macos-arm64 build/preview/sum 10 build/preview/sum-run.json
"$package/bin/fenrir" replay build/preview/sum build/preview/sum-run.json
```

For Solo5, the Mac hosts an ARM64 Linux Docker engine. The same source builds as a guest and runs under the Solo5 `spt` tender. The installation guide covers the pinned toolchain image, guest commands, trap diagnosis, and the independent installation exercise. [Native installation and replay guide](NATIVE_GUIDE.md)

## What runs today

| Application | What it exercises |
|---|---|
| [Propositional prover](benchmarks/prover/README.md) | Search for a proof or countermodel with an explicit step budget. An independent checker validates the proof certificate. |
| [HTTP service](benchmarks/http/README.md) | Parse requests, select routes, and serve responses. On Solo5 the host handles TCP and the guest executes the Fenrir handler. |
| [Durable jobs](benchmarks/durable/README.md) | Submit a job, lose its acknowledgement, restart the worker, and retry. Gleipnir checks the resulting history against the service contract. |
| [Framed log](benchmarks/framed-log/README.md) | Decode length-prefixed records across input chunks, aggregate by key, and verify the final summary. |

## What the measurements establish

On one Apple Silicon development host the tested candidate passed all four macOS kernel time and memory thresholds. Its geometric mean elapsed time was **0.997×** the fastest eligible reference for each workload. Those references were Rust for search and routing, Koka for checking, and Nim for streaming. On Solo5 the same package took **2.949×** optimized guest C across the four kernels, above the 1.5× target. These measurements cover the kernels. Network latency and durable-service throughput have separate qualification runs. [Scorecards and release criteria](WORK_FILE.md)

## Explore the project

- Read the [developer preview article](PREVIEW.md) for a worked example and the design motivation.
- Start writing programs with the [surface language](spec/tc1/SURFACE.md) and [examples](examples).
- Inspect the [Gleipnir harness](harness/README.md) and [native proof scope](verification/aarch64/README.md).
- See the [development history](DEVELOPMENT_HISTORY.md) for earlier experiments, architectural decisions, and qualification records.
