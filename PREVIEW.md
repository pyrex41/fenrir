# Fenrir developer preview: one source, two ARM64 targets

A client submits a job. The service commits it. The acknowledgement disappears, so the client submits the same request again. What should the second submission observe?

That question is one reason Fenrir and Gleipnir share a repository. Fenrir gives us a language in which to write the worker. Gleipnir gives us a way to explore the ordering of commits, replies, retries, and crashes, then keep a failing execution small enough to replay. For this service, an accepted request key must continue to identify the committed job after recovery. The Erlang supervisor and SQLite store are explicit parts of the experiment. [Durable service](benchmarks/durable/README.md)

## From a formula to an observable result

The prover makes the same idea easy to try without setting up a service. Its input is a formula and a search budget. For the implication `z → z`, written `> z z`, three steps suffice. The public driver reports the case name, outcome, steps consumed, and witness:

```text
identity proof 3 ssx
open model 2 0
limited exhausted 1 -
```

The middle case is the single atom `a`, with countermodel zero. The last case gives the identity formula only one step. Budget exhaustion has its own outcome, so a caller can distinguish it from finding a countermodel. The native guide includes the complete three-line input and commands to reproduce these rows on both targets. [Run the prover corpus](NATIVE_GUIDE.md)

## What we learned from comparing implementations

The Mac and Solo5 executables share an ahead-of-time ARM64 compiler. In the measured Mac candidate the geometric mean across proof search, certificate checking, HTTP routing, and framed-log processing was 0.997× the elapsed time of the selected references. On Solo5 the corresponding ratio was 2.949× guest C. A result on one target tells us surprisingly little about the other when the reference implementations and execution environments differ. [Benchmark criteria and scorecards](WORK_FILE.md)

One hypothesis was that the prover spends much of its time copying a persistent queue. A C version using that representation helped narrow the question. Across the ten scored cases it copied eight existing cells while constructing 79 queue cells in total. On a separate 160-step branching proof it copied 698 of 819. Both numbers matter: the short corpus is a poor stress test for copying, while the wider proof makes that cost visible. [Prover workloads and reproduction instructions](benchmarks/prover/README.md)

The preview is a place to try these programs, change them, and inspect what happened. The CLI can record a result or a source-located trap and replay it against the same image. The current limits include independent installation testing, whole-image proof coverage, and Solo5 performance. [Try the native quickstart](README.md#build-a-native-arm64-program)
