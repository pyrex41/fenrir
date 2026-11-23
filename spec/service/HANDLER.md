# Accepted-job handler in Fenrir (stage A2)

Draft 1 • 15 November 2026 • For owner review

Stage A2 of [04_DIRECTION_AMENDMENT.md](../../docs/design/04_DIRECTION_AMENDMENT.md) §8: "the
handler written as a Fenrir program against `atomic`, `once`, `jobs.stage` library
interfaces". The program is [examples/service/accepted-job.fen](../../examples/service/accepted-job.fen);
the language contract it needs is [spec/tc1/DURABLE.md](../tc1/DURABLE.md) (durable
effects discharged by the host); the contract it must refine is A1,
[ACCEPTED_JOB.md](ACCEPTED_JOB.md) and its executable model. This document states
the **storage contract** between them: what the host's `Store.commit` does to a
tenant's store. Its executable statement is
[models/service-a2/store-contract.shen](../../models/service-a2/store-contract.shen),
which works on A1's store shape; where text and code disagree the code is the
contract and the text is wrong. Evidence status: *bounded exploration passed*,
development grade, `qualification: UNKNOWN`.

## 1 The shape of the handler

One request is one run of the program: the host starts it with the request as the
entry input, answers its durable operations, and takes its result as the response.

- **Input** `Command`: `(Submit Cap Key Digest Payload)` (A1's `[submit T K D]`, with
  the tenant's capability `(Tenant T)` and the payload) or `(Complete Cap Job Ok)` (A1's
  `[complete T J Ok]`).
- **Durable effect** `Store`, class durable, one operation `commit : Tx --> Reply`. It is
  the program's whole residual row, so the image's manifest names exactly one
  capability: a store that discharges `Store.commit` under this contract.
- **Result** `Response`: `(Accepted Receipt)` or `(Conflict T K)` for a submit (A1's
  events `[accepted R]`, `[conflict T K]`), `Delivered` for a delivery (A1: no response),
  `Refused` for a reply the handler does not expect (never reached by the correct
  handler; mapped to A1's "no response").

The library (`atomic`, `once`, `jobs-stage`) is the first part of the program file,
since there is no module system: `atomic cap guard build` performs
`Store.commit (Tx cap guard (build unit))` where `build : (Unit --> Writes)` has **no
effects**, so a transaction body cannot itself make a host request (DURABLE.md §8;
`tests/frontend/bad/durable-perform-inside-atomic.fen` and
`examples/service/mutants/commit-inside-atomic.fen` are rejected); `once key` is the
guard `(Once key)`; `jobs-stage writes` adds `StageJob` to a write set.

## 2 Vocabulary

```text
Cap     (Tenant t)
Receipt (Receipt tenant key digest report job)          A1's [receipt T K D R J]
Guard   Always | (Once key) | (Pending job)
Write   (PutReport digest payload) | StageJob | (StageJobOf report)
        | (RecordKey key digest) | (Finish job ok)
Writes  Done | (Then Write Writes)
Tx      (Tx Cap Guard Writes)
Reply   (Committed Receipt) | (Recorded digest Receipt) | Applied | Skipped | Unauthorized
```

## 3 What `Store.commit (Tx cap guard writes)` does

On the system state `[sys Stores Outbox Trace]` of A1, acting on stores only:

1. **Capability.** `cap` is `(Tenant t)`; if t is not a tenant (0 ≤ t < N), the reply is
   `Unauthorized` and nothing changes. Otherwise the commit acts on t's store
   `[store Reports Jobs Keys Next]` and on no other (A1 authority).
2. **Guard**, evaluated on t's store before any write:
   - `Always`: apply.
   - `(Once k)`: if k is recorded with digest d and receipt r, the reply is
     `(Recorded d r)` and nothing changes; otherwise apply.
   - `(Pending j)`: if t has a pending job j, apply; otherwise the reply is `Skipped`
     and nothing changes.
3. **Apply** the writes, in order, with N = Next:
   - `(PutReport d p)` adds the report `[N d]` (the payload is carried but A1 abstracts
     it by its digest: the A1 store keeps no payload);
   - `StageJob` adds the job `[N N pending]` (the job of this commit's report);
   - `(StageJobOf r)` adds the job `[r r pending]`;
   - `(RecordKey k d)` adds the key entry `[k d [receipt t k d N N]]`;
   - `(Finish j ok)` sets the status of every job with id j to `done` (ok) or `failed`.
   Next becomes N + 1 if a `PutReport`, `StageJob` or `RecordKey` was applied, else
   stays N. New entries go first in their lists, as in A1.
4. **Reply**: `(Committed r)` with the receipt r of the `RecordKey` write when there
   was one, else `Applied`.

Atomicity: all of 1–4 is **one step** of the host on one store, as A1's `submit` is.
The guest is stopped while it happens (DURABLE.md §4).

**When a run's requests are answered** (*provisional*). In A1 a submit is one step.
The host answers a run's **first** request within the step of the label that started
the run (`submit` or `complete`); each further request of the same run is a
scheduling point (amendment §14): the run waits as a volatile item
`[inflight T Run]` in the outbox, an internal step `[internal host T I]` answers its
next request, and a crash loses it. A handler with one commit per request therefore
has exactly A1's steps; a handler with two (the `two-commits` mutant) exposes the state
between them.

## 4 The refinement claim and how it is checked

> For every reachable A1 state and every `submit`/`complete` label, running the Fenrir
> handler on the Shen TC1-D1 model, with the A1 store as its host under §3, gives
> exactly A1's next state and response.

`sh harness/run-service-fenrir.sh` (harness/service-fenrir.shen) checks it by bounded
exploration at A1's default scope, and then:

- the same distinct runs (program, request, host replies) through the sandboxed
  JavaScript TC1-D1 implementation and through the Solo5 guest over control protocol
  v2, step for step against the model;
- hand-written wrong handlers (§5), each explored as its own machine against every A1
  property, each caught with a replayable shortest counterexample, or rejected
  statically.

Determinism (DURABLE.md §6) is what makes a sample of runs complete: a run is a
function of the request and the replies, so every edge of the exploration is covered
by one of the distinct (request, replies) runs, which are counted.

## 5 Mutants of the handler

Hand-written variants of the program under
[examples/service/mutants/](../../examples/service/mutants/), each with one change:

| Mutant | Change |
| --- | --- |
| `respond-before-commit` | the response is decided from the request before the commit's reply is known (a receipt with ids 0 and 0), then the commit is made |
| `two-commits` | report and key entry in one commit, the job in a second commit (`StageJobOf`) |
| `no-key-check` | the guard is `Always` instead of `once key` |
| `wrong-tenant` | the commit uses the other tenant's capability |
| `conflict-undetected` | a recorded key is answered with its receipt whatever the digest |
| `undeduplicated-delivery` | a delivery's guard is `Always` instead of `Pending job` |
| `commit-inside-atomic` | the transaction body performs `Store.commit` itself (a round trip per write) |
| `equivalent-control` | the same handler written differently (the digest test before the match; the write set in another order); must not be flagged and must give A1's graph |

## 6 For the owner to confirm

1. The vocabulary of §2 as the A2 storage contract, in particular `RecordKey` as a
   write separate from the `once` guard, and `Finish` unconditional (deduplication is
   the handler's `Pending` guard).
2. A run's first request is answered in the step of its label; later ones are
   scheduling points (§3).
3. `Refused` for replies the handler does not expect, mapped to "no response".
4. Capabilities are forgeable in D1 (DURABLE.md §9): the host acts on the store the
   capability names, so a wrong-tenant handler is caught by `authority.frame`, not
   refused.
5. The payload is carried to the store and dropped by A1's abstraction.

## 7 Measured

15 November 2026, A1's default scope, `sh harness/run-service-fenrir.sh`: the handler
gives A1's graph exactly (251,374 product states, 122,801 system states, 1,093,203
edges, no violation); 3,336,483 handler steps compared with A1's, none differ; 68
distinct runs, agreeing step for step in the JavaScript TC1-D1 implementation and in
the Solo5 guest (10,808 steps each). Mutants: see
[harness/README.md](../../harness/README.md) ("Service example A2"): each caught or
rejected as predicted, at the predicted lengths, plus one unpredicted catch
(wrong-tenant also by `retry.replay`).
