# Accepted-job contract (stage A1)

Stage A1 of the application example in
[04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §8:

> A tenant-scoped request atomically writes business state, records a durable
> job, records its retry result, and then returns acceptance.

The authoritative statement of this contract is the executable Shen model
[models/service/accepted-job.shen](../../models/service/accepted-job.shen),
with its property predicates in
[models/service/accepted-job-properties.shen](../../models/service/accepted-job-properties.shen).
This text explains them; where the two disagree, the model is the contract and
the text is wrong.

**Evidence status: bounded exploration passed, development grade.** Gleipnir
([harness/service-explore.shen](../../harness/service-explore.shen)) explores
every schedule of the step alphabet within stated finite bounds and checks
every property on every reachable state and edge. That establishes no
violation inside those bounds, nothing beyond them. It is not a gate verdict,
not a model proof (A0's Rocq theorems are the proofs) and not a refinement
claim for any implementation.

**Correspondence with the Rocq model is by reading, not proved.** Each item
below names the theorem of
[verification/service/AcceptedJob.v](../../verification/service/AcceptedJob.v)
that it was written to match. Nobody has proved that the Shen transition
system and the Rocq one are the same system, and a reader should not infer
that the Rocq theorems hold of the Shen model, or the other way round.

## 1 State

A system state is `[sys Stores Outbox Trace]`.

- `Stores` holds one durable store per tenant `0 .. N-1`. A store is
  `[store Reports Jobs Keys Next]`:
  - `Reports`: business state, report entries `[Id Digest]`;
  - `Jobs`: job records `[Id Report Status]`, status `pending`, `done` or `failed`;
  - `Keys`: the request-key table, entries `[Key Digest Receipt]`, mapping a
    request key to the payload digest it was first used with and the receipt to
    replay;
  - `Next`: the id counter.
- A receipt is `[receipt Tenant Key Digest Report Job]`. Receipts are created
  only inside the request transaction; holding one is evidence of that commit.
- `Outbox` is volatile: the set of computed but not necessarily delivered
  responses. A response event is `[accepted Receipt]` or `[conflict Tenant Key]`.
- `Trace` is what clients have actually been told, most recent first.

All of `Stores` survives a crash. `Outbox` does not. `Trace` is outside the
system (it is the clients' record) and is unchanged by a crash.

## 2 Steps

Labels, over finite parameters (tenants, keys, digests):

| Label | Effect | Response |
| --- | --- | --- |
| `[submit T K D]` request or client retry under tenant `T`'s capability | The request transaction on `T`'s store, installed in one step. New key: add report `[N D]`, job `[N N pending]` and key entry `[K D R]` with `R = [receipt T K D N N]`, set `Next` to `N+1`. Known key with the same digest: no change, the recorded receipt. Known key with another digest: no change, `conflict`. | `[accepted R]` or `[conflict T K]`, added to the outbox |
| `[complete T J Ok]` worker delivery, possibly duplicated | On `T`'s store: a `pending` job `J` becomes `done` (Ok true) or `failed` (Ok false); nothing else changes | none |
| `[respond E]` a computed response reaches a client | Enabled only when `E` is in the outbox. Adds `E` to the trace. The outbox keeps `E`, so a response can be delivered more than once | `E` |
| `[crash]` | Empties the outbox; stores and trace unchanged | none |

The exploration alphabet instantiates these over the parameters: every
`submit T K D`; `complete T J Ok` for both outcomes and every `J` from 0 to `T`'s
`Next` inclusive (the ids in use plus one id not in use, which stands for all
of them: every unused id has the same successor, the unchanged store); every
`respond E` for `E` in the outbox; `crash`.

## 3 Canonical observation (for the differential check and hand traces)

A JSON array, independent of how either side stores the state:

- state: `[Tenants, Outbox, Trace]`
- tenant: `[Reports, Jobs, Keys, Next]` with reports `[id, digest]` sorted by
  id, jobs `[id, report, "pending"|"done"|"failed"]` sorted by id, keys
  `[key, digest, receipt]` sorted by key
- receipt: `[tenant, key, digest, report, job]`
- event: `["accepted", receipt]` or `["conflict", tenant, key]`
- outbox: events without duplicates, sorted with every accepted event before
  every conflict event, accepted events by receipt fields left to right,
  conflict events by tenant then key
- trace: events in the order clients were told, oldest first
- label: `["submit", t, k, d]`, `["complete", t, j, ok]`, `["respond", event]`, `["crash"]`
- response of a step: the event the step produces, or `null`

## 4 Properties

Each property is a set of predicates. A *state* predicate is checked on every
reachable state, an *edge* predicate on every explored transition `x -l-> y`.
Some predicates read the property monitor (section 5). Code names are those of
`accepted-job-properties.shen`.

### Authority (frame property)

- `authority.frame` (edge): for every tenant `t'` other than the tenant whose
  capability the label carries, `y`'s store for `t'` equals `x`'s. A
  `respond` or `crash` label carries no tenant, so it changes no store.
- Rocq: `tenant_frame`. This is write isolation, not confidentiality.

### Atomicity (state invariant)

- `atomicity.records` (state): for every tenant `t`, its store is *good*:
  1. every key entry found by lookup, `[K D R]`, has `R = [receipt t K D Rp J]`,
     report `[Rp D]` present and a job `[J Rp St]` present for some status;
  2. every report `[N D]` has `N < Next`, a job `[N N St]`, and a key `K` whose
     lookup gives digest `D` and a receipt with report `N`;
  3. every job `[J R St]` has `J < Next` and a report with id `R`;
  4. report ids are distinct.
- Rocq: `atomic_records` (the record `good`), `reports_unique`.

### Response discipline (trace/state invariant)

- `response.durable` (state): for every `[accepted R]` in the outbox or the
  trace, `R` is *recorded* (lookup of `R`'s key in `R`'s tenant's key table
  gives `R`'s digest and `R` itself), report `[R.report R.digest]` is present
  and a job `[R.job R.report St]` is present.
- `response.commit-before-respond` (edge): a `respond [accepted R]` step is
  taken only from a state in which `R` is recorded, and a `respond E` step
  only delivers an `E` that is in the outbox.
- Rocq: `acceptance_durable`, and the second conjunct of `inv`.

### Retry safety (functional property)

- `retry.replay` (edge, runtime state only): a `submit T K D` step whose key
  `K` is already in `T`'s key table leaves every store unchanged, and responds
  with the recorded receipt if `D` is the recorded digest, else with
  `[conflict T K]`.
- `retry.issued` (edge, monitor): if the monitor holds an issued
  `[accepted R]` for `T` and `K`, a `submit T K D` step leaves stores unchanged
  and responds `[accepted R]` when `D` is `R`'s digest, `[conflict T K]`
  otherwise; if it holds an issued refusal `[conflict T K D]`, the step leaves
  stores unchanged and responds `[conflict T K]`. "Issued" includes responses
  that were lost by a crash before any client saw them.
- `retry.delivery` (edge): after a `complete T J Ok` step to `y`, delivering
  `J` again with either outcome leaves `y`'s stores unchanged.
- Rocq: `retry_safe`, `replay_same`, `replay_conflict`,
  `duplicate_delivery_absorbed`. `retry.issued` is stronger than `retry_safe`
  (it does not wait for the client to be told) and is a consequence of
  `replay_same`, `replay_conflict` and `atomic_records` read together.

### Recovery (invariant over crash steps)

- `recovery.crash-frame` (edge, crash steps): stores and trace are unchanged.
- `recovery.obligations` (edge, crash steps): every acceptance a client has
  been told whose job obligation is held in `x` is still held in `y`. An
  obligation for receipt `R` is *held* when a job record `[R.job R.report St]`
  is in `R.tenant`'s store, or a volatile job message
  `[job-message R.tenant R.job R.report]` is in the outbox. The clean model has
  no job messages; the second clause lets the predicate judge a design that
  keeps jobs elsewhere (the volatile-mailbox mutant) by what a crash does to it,
  rather than only by where it keeps them.
- With these, every other invariant is also checked on every post-crash
  state, as on every state.
- Rocq: `crash_preserves`; the invariants by `reachable_inv`.

### Progress (conditional)

Not a liveness theorem. Stated assumptions: **(F1) worker availability and
weak fairness of delivery**: for every pending job a delivery step eventually
occurs (§14's FIFO production scheduler gives weak fairness for runnable
tasks; that a worker exists and the store is reachable is an availability
assumption); **(F2)** the delivery step is not itself interrupted by a crash
(a crash between deliveries is allowed). Under them the bounded checks give:

- `progress.dischargeable` (state): for every `[accepted R]` in the trace and
  both outcomes `Ok`, the state after `complete R.tenant R.job Ok` holds the job
  `[R.job R.report St]` with `St` terminal (`done` or `failed`).
- `progress.terminal-stable` (edge): a terminal job `[J R St]` in `x` is in `y`
  with the same status.
- `progress.delivery-terminates` (edge): after `complete T J Ok`, `T` has no
  pending job `J`.
- Rocq: `delivery_terminates`, `terminal_stable`.

What the bounded check does not show: that delivery happens (that is F1), or
anything beyond the bounds.

## 5 Property monitor

The monitor is part of the explored state. Two product states with the same
system state but different monitors are different states and are never
merged (plan §6).

- `Issued`: the set of every response ever computed, recorded as
  `[accepted R]` or `[conflict T K D]` (the refusal keeps the refused digest,
  which the event itself does not carry). A crash empties the outbox but not
  `Issued`, which is how `retry.issued` reaches lost responses.

The explorer also keeps the remaining budget of each step kind in the state,
so a state at the budget edge is not merged with the same system state that
still has steps left.

## 6 Choices where the Rocq model or the amendment leaves room

1. **Outbox as a set.** Rocq's outbox is a list. Every Rocq step reads it only
   by membership (`In e (outbox x)`) or clears it, so order and duplicates are
   unobservable; the Shen model makes it a set in a canonical order. This is
   part of the model's definition, not an explorer quotient.
2. **Responding does not remove the response**, as in Rocq: duplicate response
   delivery is in the alphabet.
3. **Delivery of an unknown job id** is allowed and changes nothing, as in
   Rocq. One unused id per tenant is explored (section 2).
4. **A refused request is not recorded durably.** Rocq's `submit` does not
   store a conflict. Retrying a refused request is refused again because the
   original key entry is still there, not because the refusal was stored.
5. **Respond needs no capability**, as in Rocq (`tenant_of` is `None`).
6. **Progress**: the amendment says "completes or reaches a visible terminal
   outcome"; with the Rocq status set, both `done` and `failed` count as
   terminal and visible (to whoever reads the job record). The model has no
   job-status response to the client.
7. **Recovery's obligation** clause names volatile job messages so that a
   design keeping jobs off the durable store can be judged at all (section 4).
8. **Tenants are a finite index range**, Rocq's `nat -> tstore` restricted to
   the explored tenants. Ids, keys and digests are small naturals.

## 7 Mutants

Mutants live in [harness/service-mutants.shen](../../harness/service-mutants.shen),
outside the model file. Each is a whole machine (step function and label
alphabet) built from the model's own pieces with one change. Hand-derived
predictions, written before exploration ran, are in
[mutant-predictions.json](mutant-predictions.json).

| Mutant | Change | Aimed at |
| --- | --- | --- |
| `volatile-mailbox` | The transaction stores report and key entry; the job is a volatile message `[job-message T J R]`, which a delivery turns into a job record; a crash loses it (the amendment's required mutant, A0's `VolatileMailbox`) | recovery |
| `respond-before-commit` | `submit` computes the response and queues `[pending-commit T K D]`; a separate internal `commit` step runs the transaction later | response discipline |
| `non-atomic-write` | A new key's report and key entry are installed by `submit`; the job record by a later internal `stage` step, which also computes the response | atomicity |
| `retry-reapplies` | A known key with the same digest runs the mutation again (new report and job, new receipt) | retry safety |
| `key-reuse-accepted` | A known key with another digest is answered with the recorded receipt | retry safety |
| `cross-tenant-counter` | A new key advances every tenant's id counter (a shared counter: a write into other tenants' stores) | authority |
| `undeduplicated-delivery` | A delivery changes a matching job's status whatever it is | retry safety (delivery), progress (terminal stability) |
| `volatile-status` | Job status changes are held in memory: a crash puts every terminal job back to `pending` (added after the first run showed no mutant failing `recovery.crash-frame`) | recovery (crash frame), progress (terminal stability) |
| `failure-not-terminal` | A failed delivery leaves the job `pending` (added after the first run showed no mutant failing `progress.delivery-terminates`) | progress |
| `equivalent-control` | Lookup and delivery rewritten (filter instead of search, explicit recursion instead of map) with the same meaning | must not be flagged; same graph as the model |

## 8 Hand-derived traces

[hand-traces.json](hand-traces.json): eleven schedules with their expected
responses and final canonical state (or the step at which the schedule is not
enabled), derived from sections 1–3 by hand before either the Shen model or
the JavaScript implementation existed. Both are checked against them.

## 9 What this does not cover

Everything A0's README lists as assumed or not covered still applies: the
storage contract (atomic install, crash loses only volatile state, serial
transactions per tenant), no confidentiality, no liveness theorem, no
indeterminate commit, no external effects, no authentication or retention,
abstract ids and digests. Bounded exploration adds its own limit: only the
explored parameters and budgets.
