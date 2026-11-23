# Fenrir developer preview: one source, two ARM64 targets

A client submits a job. The service commits it. The acknowledgement disappears, so the client submits the same request again. What should the second submission observe?

The client gets the original receipt back. Here is the Fenrir code that decides what to submit to storage and how to answer the client. [Accepted-job worker](../examples/service/accepted-job.fen)

```text
(define submit {(Tuple Cap I64 I64 Bytes) --> Response}
  cap key digest payload ->
    (decide cap key digest
      (atomic cap (once key)
        (lambda (u : Unit)
          (jobs-stage (Then (PutReport digest payload) (Then (RecordKey key digest) Done)))))))
```

On the first submission, the lambda describes three writes. It stages a job, stores the report, and records the request key and digest. The Erlang host authenticates the tenant, and its SQLite adapter checks the tenant’s key and commits the writes in one transaction. Suppose that transaction commits and the worker dies before the client sees the reply. When the client retries, the guard finds the recorded key. For the same digest, `decide` returns `Accepted` with the stored receipt and the database still contains one job. Reusing the key with a different digest returns `Conflict`. [Storage and handler contract](../spec/service/HANDLER.md)

Gleipnir explores bounded orderings of these events in the Shen model. In a separate recovery exercise, an Erlang supervisor restarts the worker and the harness checks the resulting service history. The native macOS ARM64 worker and the Solo5 ARM64 SPT guest produced the same 18 ordered events in the retained recovery run. Both used host-side SQLite. The test used two tenants and one-byte payloads. It checked the service’s job records and receipts. [Recovery exercise and reference workers](../benchmarks/durable/README.md) · [Recorded histories and verdicts](../verification/performance/2026-11-22-arm64/prover-validated-four-apps.tar.gz)

The preview has a monomorphic core and textual includes. Abstract modules, generic collections, and the interaction between task cancellation and durable requests are open design work. The CLI publishes its standalone execution profile with `fenrir profile`. It supports 16 simultaneously live children. Use `fenrir check --target macos-arm64 SOURCE` or `fenrir check --target solo5-arm64-spt SOURCE` to check whether a program can be compiled for that target. Durable workers and remote peers need their service or system runner. [Current language surface](../spec/tc1/SURFACE.md)

## From a formula to an observable result

The prover makes the same idea easy to try without setting up a service. Its input is a formula and a search budget. For the implication `z → z`, written `> z z`, three steps suffice. The public driver reports the case name, outcome, steps consumed, and witness:

```text
identity proof 3 ssx
open model 2 0
limited exhausted 1 -
```

The middle case is the single atom `a`, with countermodel zero. The last case gives the identity formula only one step. Budget exhaustion has its own outcome, so a caller can distinguish it from finding a countermodel. The native guide includes the complete three-line input and commands to reproduce these rows on both targets. [Run the prover corpus](NATIVE_GUIDE.md)

## What we learned from comparing implementations

The Mac and Solo5 executables share an ahead-of-time ARM64 compiler. Across four benchmark harnesses, the archived candidate took 0.997× the elapsed time of the selected Mac references by geometric mean (95% interval 0.836–1.151). The quickstart builds the current checkout. To reproduce the measured package, use the [archived candidate source](../verification/performance/2026-11-22-arm64/prover-validated-corpus-source.tar.gz). The prover and framed-log timings include process launch, while the routing harness times work inside a running process. On Solo5 the corresponding ratio was 2.949× guest C. A result on one target tells us surprisingly little about the other when the reference implementations and execution environments differ. [Benchmark criteria and scorecards](WORK_FILE.md)

One hypothesis was that the prover spends much of its time copying a persistent queue. A C version using that representation helped narrow the question. Across the ten scored cases it copied eight existing cells while constructing 79 queue cells in total. On a separate 160-step branching proof it copied 698 of 819. Both numbers matter: the short corpus is a poor stress test for copying, while the wider proof makes that cost visible. [Prover workloads and reproduction instructions](../benchmarks/prover/README.md)

Two small programs changed how we test the runtime. In one, a cancellation arrived while a child was unwinding a division trap. The native parent used to observe cancellation and return successfully. It now sees the failure. In the other, a handler discards a continuation containing a child blocked on a channel. The child must be cancelled and joined before the handler closes the channel. The old and corrected programs both return 42, but the old runtime let the child wake and emit an extra event. We now compare the ordered events as well as the outcome against Shen on both native targets. [Review and reproductions](../verification/developer-preview-review.md)

The preview is a place to try these programs, change them, and inspect what happened. The CLI can record a result or a source-located trap and replay it against the same image. The current limits include independent installation testing, whole-image proof coverage, and Solo5 performance. [Try the native quickstart](../README.md#build-a-native-arm64-program)
