# Developer preview review at 458dcff

Four independent GPT-6.2 Astra reviews at high reasoning effort used systems, composition, algorithms, and first-user perspectives inspired by Linus Torvalds, John Backus, Donald Knuth, and Peter Norvig. Each surveyed the whole repository and traced selected claims through implementation and evidence. These are simulated reviews. The findings below distinguish fresh executions from retained experiments.

## Disposition in the working candidate

The observations below describe the reviewed revision. The candidate now preserves a child’s trap during unwinding and completes scope abandonment before the next clause effect. The candidate checks compare ordered emissions, outcomes, and native exit status with Shen on both ARM64 targets. The CLI exposes its [standalone profile](../spec/native/standalone-v1.json), performs target admission checks, and records the profile identity in new image receipts. The [rescored archived measurements](performance/2026-11-22-arm64/validated-package-kernel-rescore.json) use one interval per selected comparison. Performance figures belong to the archived benchmark package.

## Native cancellation can erase a child failure

Save this program as `cancel.fen` and run the three commands from the repository root.

```text
(define main {I64 --> I64}
  input -> (let child (spawn (lambda (_ : Unit) (/ 1 input)))
    (do yield
        (cancel child)
        (match (await child)
          ((Ok n) -> (do (emit "ok" n) 0))
          (Cancelled -> (do (emit "cancelled" 1) 1))
          ((Failed code) -> (do (emit "failed" 2) 2))))))
```

```sh
sh frontend/fenrir.sh run cancel.fen fifo
sh bin/fenrir run --target macos-arm64 cancel.fen 0
sh bin/fenrir run --target solo5-arm64-spt cancel.fen 0
```

Shen emits `failed` and ends in `Trap ChildFailed`. Both native targets emit `cancelled` and return 1 successfully. Recording and replaying the native dispatches reproduces the native outcome. The specification preserves a trap once unwinding has started. The native abort path yields and joins with cancellation checks, and fiber completion copies the cancellation request into the terminal cancellation flag. A regression should exercise requests before the trap, during unwinding, and after termination. Check child outcome, parent outcome, and emitted events against the model under each applicable dispatch order. [Cancellation delivery](../spec/tc1/CONCURRENCY.md) · [Native scheduler](../runtime/native/scheduler.c)

## Abandoning a scope allows an extra observable child action

Save the following as `abandon.fen` and run the same model and target commands as above. The channel starts empty. Only the handler can unblock the child, by closing the channel *after* it discards the continuation that owns the child’s scope.

```text
(effect Stop (stop I64 --> I64))
(define main {I64 --> I64}
  n -> (let c (channel I64 1)
         (handle Stop
           ((stop x k) -> (do (discontinue k) (close c) yield (emit "after" x) 42))
           (scope (let worker (spawn (lambda (_ : Unit)
                               (do (receive c) (emit "child" 7) 9)))
                    (do yield (perform Stop stop n)))))))
```

All three runs return 42. Shen emits only `after`. Both native images emit `child` and then `after`. The specified abandonment cancels and joins the children before control returns to the handler. Native code marks the resumption as used and processes abandonment after the clause returns. Test cancellation of blocked receivers and senders and check complete event histories. This defect and the lost child trap are independent reasons to withhold a native structured-concurrency conformance claim. [Scope abandonment](../spec/tc1/CONCURRENCY.md) · [Native effect runtime](../runtime/native/managed.c)

## A valid handler composition fails to compile

Save this program as `composed.fen` and repeat the commands above with that filename, omitting `fifo` for the Shen run.

```text
(effect Ask (ask I64 --> I64))
(effect Observe (observe I64 --> I64))
(define main {I64 --> I64}
  n -> (handle Observe
         ((observe y) -> (+ y 100))
         (handle Ask
           ((ask x k) -> (perform Observe observe (resume k (+ x 1))))
           (+ 10 (perform Ask ask n)))))
```

Shen returns 111. Both native builds reject the nested use of `resume` at code generation. Binding the result first, as in `(let y (resume k (+ x 1)) (perform Observe observe y))`, gives Shen the same answer and returns 111 on both native targets. A useful nanopass here would give effectful intermediate expressions explicit evaluation order before handler lowering. Its verifier should check one-shot use and preservation of the evaluation order, including observable effects and traps. [Native resume lowering](../tools/aarch64/managed-image.mjs) · [Effect semantics](../spec/tc1/EFFECTS.md)

## A target limit is visible as a language trap

Create a channel, spawn 16 children whose first operation receives from it, then close the channel and return 42. Shen, Mac, and Solo5 return 42. With 17 live children, Shen returns 42 and both native targets report `TaskLimit`. The native ABI explicitly budgets 16 child stacks. The C1 specification classifies a configured live-task bound as a harness limit. Decide which outcome a caller can depend on, expose the target profile and check the boundary at 16 and 17, including a second batch after children finish. [C1 bounds](../spec/tc1/CONCURRENCY.md) · [Native ABI](aarch64/PLAN.md) · [Task entry](../runtime/native/task-entry.c)

## What an outside user can run

The installed CLI on the development Mac built and replayed the sum of 1 through 10 on macOS and Solo5, returning 55 on both. Both prover drivers returned `goal proof 3 ssx` for the identity formula. The same CLI accepts the accepted-job worker and the remote ledger sources at type checking, but the standalone Mac build reports internal JavaScript exceptions for these programs. The worker needs its service adapter. The ledger needs a peer. A useful public interface would identify the execution profile, report the missing binding at the source, and point to its runnable example. A separately observed pure closure over eight integers also passes Shen and exceeds the native emitter's seven inline captures. Require source-located diagnostics or native support for each advertised construct. Independent clean-machine installation remains open. [Public CLI](../bin/fenrir) · [Durable worker runner](../benchmarks/durable/README.md) · [Remote harness](../harness/run-tc1-remote-run.sh)

## What the measurements support

Fresh rescoring of the archived candidate reproduced the Mac geometric mean of **0.997×** (paired 95% interval 0.836–1.151) and Solo5 **2.949×** (2.827–3.117). Solo5 search, checking, routing, and streaming took 4.327×, 3.336×, 1.263×, and 4.149× guest C respectively. The Mac score combines process-level and in-process timings. The scorecard also reports two intervals for the same 15 paired Mac routing ratios, one spanning parity and one excluding it. Compute the selected reference interval once and reuse it throughout the report before drawing a routing-specific conclusion. The aggregate thresholds and measured point estimates survive this finding. The README quickstart builds the checkout, whose prover source differs from the archived benchmark package. [Scorecard implementation](../benchmarks/kernel-scorecard.py) · [Candidate source and scorecards](../docs/WORK_FILE.md)

The algorithms review checked the independent truth-table classification of all 5,618 two-atom formulas through seven nodes and reran a small native budget and countermodel corpus on both targets. The small scored search visits 83 states and copies eight existing queue cells. A separate branching input visits 160 states and copies 698. Keep both kinds of input when comparing representations. Treat launch time, warm computation, allocation, and peak memory as separately attributable costs. HTTP capacity, service latency at matched load, and independent installation still need qualification. [Prover controls](../benchmarks/prover/README.md) · [Release criteria](../docs/WORK_FILE.md)

## Which design decisions come next

1. **Establish observable task and effect semantics on both targets.** Preserve child failures during unwinding. Finish abandoning a captured scope before the handler can perform another effect. Use the runnable examples above as oracle comparisons and compare the entire event sequence as well as the final outcome. Run these checks during candidate validation. Native replay establishes reproducibility within an image.
2. **Give programs a target profile.** State which entry signatures, effects, adapters, capture sizes, and task limits the backend supports. Have checking, compilation, the model, and receipts agree on that profile. The closed scalar Rocq proofs end at a handwritten instruction model. Managed execution, the scheduler, and the adapter still require other evidence. [Proof scope](aarch64/README.md)
3. **Design module interfaces and parametric data around one real library.** A contributor should be able to implement a queue, hide its constructors, use it with both formulas and job identifiers, and replace its representation without editing either client. This puts qualified names, exports, type parameters, and separate checking to a practical test. Passing an effectful callback through a generic traversal is a later test for effect polymorphism. [Current surface](../spec/tc1/SURFACE.md)
4. **Give cancellation across a durable boundary a contract.** The service demo has a pinned ABI, one active native command, and a guarded SQLite transaction. The independent Maude comparison covers a bounded retry contract. Neither establishes what cancelling a language task should do after a commit but before a receipt is observed. Specify that history, including ownership of the pending reply and cleanup of the waiter. Check one durable job, a stable receipt on retry, and no surviving waiter. [Native binding](../benchmarks/durable/native/build.mjs) · [Maude comparison](maude/README.md)

The review sampled source across the frontend, Shen models, ARM64 compiler, native effects, heap and scheduler, host adapters, benchmarks, replay, proof boundaries, and packaging. It combined new targeted executions with inspection and rescoring of archived evidence. Full performance campaigns, whole-image verification, independent machine setup, and external service qualification were outside this review.
