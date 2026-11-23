# Fenrir

A native language with a specification you can execute.

Fenrir is an experimental, statically typed functional language that compiles ahead of time to ARM64 on macOS and Solo5. Its rules are written in Shen. You can run a Fenrir program through those rules to see when a task may run, what cancellation must clean up, and which failures a caller can observe.

The idea is to develop applications and their semantics together. Write down what a program should do, compile it, and compare what happened with what the rules permit. When the two disagree, the most useful bug report is a small program, the choices that led to the failure, and the first observable difference. An implementation agent can use that same evidence to check a repair.

[Build a native program](#build-a-native-arm64-program) · [Walk through a service](docs/PREVIEW.md) · [Explore the models](models/tc1)

## How Fenrir is built and checked

1. **Read the source.** The frontend is written in Shen. It reads a `.fen` file, resolves names, checks types and effects, and emits a JSON representation of the program. Source locations travel with it so a trap can point back to the expression that caused it. [Frontend](frontend)
2. **Run the rules or build an executable.** The Shen model evaluates that representation one step at a time. The native compiler, written in JavaScript, lowers it to ARM64 assembly and links it with the runtime as a Mac executable or a Solo5 guest image. The standalone profile specifies the entry point and resource limits. [Models](models/tc1) · [Compiler](tools/aarch64) · [Runtime](runtime/native) · [Execution profile](spec/native/standalone-v1.json)
3. **Compare executions.** Gleipnir explores bounded sets of programs and schedules, checks observations against the model, and retains counterexamples for replay. The harness also runs deliberately broken implementations to check whether its tests can detect the difference. [Gleipnir harness](harness/README.md)

### Can a cancelled child still produce an event?

A Fenrir task can start a child inside a scope. The scope owns the child. If the program abandons that scope, it must cancel the child and wait for it to finish before continuing.

A short test makes the order visible. The child waits on an empty channel and will emit `child` if it gets past the wait. The parent performs an effect called `Stop`. Its handler discards the suspended computation containing the child’s scope, closes the channel, lets another task run, then emits `after` and returns `42`. By the time the channel closes, the child should already be gone.

| Execution | Events in order | Return value |
|---|---|---|
| Shen model | `after` | `42` |
| Native runtime before the fix | `child`, `after` | `42` |

Both runs returned the expected answer. The extra event exposed the bug. The regression now checks the event sequence and the result on both native targets. [Read the program](tests/native/discontinue-joins-child.fen)

## From language rules to a real service

A client submits a job. The service commits it. The worker dies before the acknowledgement reaches the client. What should happen when the client retries?

Here is the transaction in the Fenrir worker:

```text
(define submit {(Tuple Cap I64 I64 Bytes) --> Response}
  cap key digest payload ->
    (decide cap key digest
      (atomic cap (once key)
        (lambda (u : Unit)
          (jobs-stage (Then (PutReport digest payload) (Then (RecordKey key digest) Done)))))))
```

The lambda describes the writes as data. It stores the report, records the request key and digest, and stages the job. The host checks the tenant’s key and applies the writes in one SQLite transaction. On a retry with the same digest, `decide` returns the original receipt and the database still contains one job. Reusing the key with a different digest produces a conflict.

An Erlang/OTP supervisor restarts the worker. In the recovery exercise, the Mac worker and the Solo5 guest produced the same 18 ordered events, and the Shen service model accepted both histories. [Worker source](examples/service/accepted-job.fen) · [Walkthrough and recorded histories](docs/PREVIEW.md)

## What runs today

The developer preview has immutable algebraic data types, exhaustive pattern matching, closures, checked integer arithmetic, and inferred effect sets. An effect handler can resume a suspended computation once or discard it. Tasks have scopes, and channels have bounded capacity. [Language reference](spec/tc1/SURFACE.md) · [Example programs](examples)

| Application | What it exercises |
|---|---|
| [Prover and certificate checker](benchmarks/prover/README.md) | Recursive proof search with distinct outcomes for a proof, a countermodel, and an exhausted budget. |
| [HTTP service](benchmarks/http/README.md) | Parsing request bytes and routing requests behind a host transport. |
| [Framed-log processor](benchmarks/framed-log/README.md) | Decoding and aggregating records that cross input-chunk boundaries. |
| [Durable jobs](benchmarks/durable/README.md) | Transactional writes, retries, worker restart, and recovery. |

The core is monomorphic and shares declarations through textual includes. The standalone runtime supports 16 live child tasks. `fenrir profile` prints its limits, and `fenrir check --target TARGET SOURCE` checks whether a program can compile for that target. Durable services and remote peers use their own host runners.

Independent installation testing and Solo5 performance remain open alpha work. The compiler proofs cover specific subsets against an instruction model. Whole-image correctness remains open. [Alpha plan and measurements](docs/WORK_FILE.md) · [Proof scope](verification/aarch64/README.md)

## Build a native ARM64 program

On an Apple Silicon Mac with Nix and the Apple Command Line Tools, first build the Fenrir toolchain from a checkout:

```sh
git clone https://github.com/pyrex41/fenrir.git
cd fenrir
nix build .#fenrir
```

Nix puts the CLI at `./result/bin/fenrir`. Use it to compile the example into an executable, then run that executable with input `10`. It prints `55`, the sum of 1 through 10.

```sh
./result/bin/fenrir build --target macos-arm64 examples/recursive-sum.fen -o ./sum
./sum 10
```

To reproduce the cancellation check above, run the same file through the model and the Mac runtime. Both emit only `after` and finish with `42`.

```sh
./result/bin/fenrir model --profile fenrir-native-standalone/1 tests/native/discontinue-joins-child.fen
./result/bin/fenrir run --target macos-arm64 tests/native/discontinue-joins-child.fen 0
```

The Solo5 target uses an ARM64 Linux Docker engine and the Solo5 toolchain image. The native guide covers setup, source-located traps, and recording and replaying runs. [Native guide](docs/NATIVE_GUIDE.md)

## Where the ideas come from

- **Koka** is the main language influence. Its effect types make a function’s interactions with its environment visible in its type. Fenrir’s current frontend infers a finite set of effects for each function. [Koka language book](https://koka-lang.github.io/koka/doc/book.html)
- **Shen** supplies the language for writing the frontend and the executable rules. Its pattern matching lets a rule describe a machine state and the step it can take next. [Shen](https://shenlanguage.org/) · [Task machine](models/tc1/task-machine.shen)
- **Elixir and Erlang/OTP** informed task ownership, supervision, and recovery. OTP also supplies the supervisor in the durable-service example. [Elixir task supervision](https://hexdocs.pm/elixir/Task.Supervisor.html)
- **MirageOS and Solo5** informed the deployment goal of shipping an application and its runtime in one image with a small interface to the host. Solo5 is already a native target. [MirageOS](https://mirage.io/) · [Solo5](https://github.com/Solo5/solo5)

## Open experiments

An independent Maude model explores bounded crash-and-retry histories for the job service and compares them with Shen. A separate experiment draws on Perceus to ask when an immutable update can reuse storage in place. Even if a program uniquely owns a parent cell, another parent can still share its child. Fenrir’s native runtime currently uses tracing garbage collection. [Maude comparison](verification/maude/README.md) · [Perceus paper](https://www.microsoft.com/en-us/research/publication/perceus-garbage-free-reference-counting-with-reuse/) · [Constructor reuse experiment](models/compiler/README.md)

The longer-term question is whether reusable pieces of executable semantics can themselves be specialized into efficient implementations. There are smaller questions to tackle today. Can two applications share a generic queue while hiding its representation? What should cancellation do after a durable commit but before the receipt arrives? Can you find another program whose native history disagrees with Shen? [Design direction](docs/design/04_DIRECTION_AMENDMENT.md) · [Preview review and reproducers](verification/developer-preview-review.md)
