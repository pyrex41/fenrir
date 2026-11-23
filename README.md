# Fenrir

Fenrir is a statically typed functional language for programs that need to recover from failure. Its compiler generates native ARM64 code ahead of time for macOS and Solo5. An executable model written in Shen defines how programs behave. Gleipnir explores possible executions and can replay the sequence of events that led to a failure.

The developer preview runs four applications on both targets: a propositional prover, an HTTP service, a framed-log processor, and a durable job service. The job service shows what recovery means in practice. If the worker commits a job and dies before replying, the client can retry and get the original receipt. [Read the worked example](docs/PREVIEW.md).

## Build a native ARM64 program

On an Apple Silicon Mac with Nix and the Apple Command Line Tools, run these commands from the repository root.

```sh
package=$(sh tools/aarch64/package-mac.sh)
"$package/bin/fenrir" run --target macos-arm64 examples/recursive-sum.fen 10
```

This compiles the example and runs it with input `10`. It prints `55`, the sum of the integers from 1 through 10. The [native guide](docs/NATIVE_GUIDE.md) covers building a standalone executable, running the same source on Solo5, and recording and replaying a run.

## Documentation

- [Language reference](spec/tc1/SURFACE.md) and [example programs](examples)
- [Gleipnir](harness/README.md) — models, schedules, and counterexample replay
- [Benchmarks](benchmarks) and [alpha status](docs/WORK_FILE.md) — reference implementations, measured performance, and open release criteria
