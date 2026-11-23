# Fenrir

Fenrir is an experimental, statically typed functional language that compiles ahead of time to ARM64 on macOS and Solo5. Its specification is a program you can run. The rules for effects, tasks, and cancellation are written in Shen. Gleipnir explores bounded schedules and saves counterexamples for replay. The native compiler and runtime are checked against what the model says a program can do. [Executable models](models/tc1)

One bug shows why this matters. A child task was waiting on a channel when an effect handler discarded the computation that owned it. Shen cancelled the child before the handler continued. The native runtime let it wake up and emit one more event. Both runs returned `42`. Comparing their event histories exposed the bug, and the same program now guards the fix on both targets. [Regression program](tests/native/discontinue-joins-child.fen)

Fenrir takes its approach to effect typing from Koka. It infers the effects a function can perform, and a handler can resume a suspended computation once or discard it. The language also has immutable algebraic data types, exhaustive pattern matching, checked integer arithmetic, scoped tasks, and bounded channels. Elixir’s supervised tasks helped shape the concurrency design. The durable-job demo uses an actual Erlang/OTP supervisor to restart a Fenrir worker after a lost acknowledgement. [Koka language book](https://koka-lang.github.io/koka/doc/book.html) · [Elixir task supervision](https://hexdocs.pm/elixir/Task.Supervisor.html) · [Durable-job walkthrough](docs/PREVIEW.md)

Fenrir’s native runtime uses tracing garbage collection. An experiment inspired by Perceus tracks ownership of parent and child cells separately to test when an immutable update can reuse storage in place while preserving older snapshots. [Perceus paper (Microsoft Research)](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/) · [Fenrir’s constructor reuse experiment](models/compiler/README.md#constructor-reuse-contract)

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
- [Benchmarks](benchmarks) — a propositional prover, HTTP service, framed-log processor, and durable jobs
- [Alpha status](docs/WORK_FILE.md) — measured performance and open release criteria
