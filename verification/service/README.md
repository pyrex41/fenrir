# Service example: accepted work is durable (model level)

First stage (A0) of the application example in
[04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §8:

> A tenant-scoped request atomically writes business state, records a durable
> job, records its retry result, and then returns acceptance.

**Status: model property proved.** [AcceptedJob.v](AcceptedJob.v) is an abstract
transition system and theorems about it. It is not connected to Fenrir source
programs, the Shen machines, a compiler or a database. It is not a TC0
qualification artifact and changes no gate.

## Run

Checked with Coq 8.18.0 (`apt-get install coq` on Ubuntu 24.04).

```sh
sh verification/service/check.sh
```

The script compiles in a fresh directory under `build/` and fails unless the
proofs check and every audited theorem is closed under the global context (no
axioms, no admitted lemmas).

## The model

- Each tenant has a durable store: reports, jobs with a status, a
  request-key table holding the payload digest and the receipt to replay, and
  an id counter.
- `submit t k d` is the whole request transaction as a pure function on one
  tenant's store. A new key adds the report, a `Pending` job and the retry
  record together and returns a receipt. A known key returns the recorded
  receipt, or `Conflict` if the digest differs. Receipts are created nowhere
  else.
- `complete j ok` is a worker delivery. Only a `Pending` job changes.
- The system has durable stores, a volatile outbox of computed responses, and
  the trace of responses clients have received. Steps: submit (also a client
  retry), complete (also a duplicate delivery), respond, crash. A crash empties
  the outbox. A response that is never sent is the lost-response case.

## What is proved

For every reachable state, over every interleaving of those steps:

| Theorem | Statement |
| --- | --- |
| `tenant_frame` | A step under tenant *t* leaves every other tenant's durable store unchanged |
| `atomic_records` | Report, job and retry record exist together: each retry record points at its report and job, each report has its job and a retry record, each job has its report, and report ids are unique |
| `acceptance_durable` | If a client was told `Accepted rc`, then `rc` is the recorded receipt for its tenant, key and digest, and its report and job are in durable state |
| `retry_safe` | After an acknowledged acceptance, the same request returns the same receipt and leaves the store unchanged; the same key with another digest returns `Conflict` and leaves the store unchanged |
| `crash_preserves` | A crash changes neither durable state nor the client-visible trace |
| `duplicate_delivery_absorbed` | Delivering a job twice equals delivering it once, whatever the second outcome says |
| `terminal_stable` | A `Done` or `Failed` job keeps that status under every step |
| `delivery_terminates` | After a delivery of job *j*, *j* is not `Pending` |
| `VolatileMailbox.accepted_job_lost` | Negative control: if the job is a volatile message instead of part of the transaction, a client can be told `Accepted` while no job obligation exists (commit, send, crash, accept) |

## What is assumed or not covered

1. **Storage contract (assumed).** A transaction is installed atomically and a
   crash loses only volatile state. Transactions on one tenant are serial: the
   model has no concurrent transactions, so it says nothing about isolation
   levels.
2. **Write isolation, not confidentiality.** `tenant_frame` is a frame
   property. It does not show that one tenant's data cannot influence another
   tenant's observations.
3. **No liveness.** `delivery_terminates` and `terminal_stable` say what a
   delivery achieves. That a delivery eventually happens is a scheduling and
   availability assumption, not a theorem.
4. **No indeterminate commit.** The client either receives the response or does
   not. A storage layer whose commit acknowledgment can be lost needs a third
   outcome at the adapter; this model has no adapter.
5. **No external effects.** The job's work is a status change. An email or
   payment needs a receiver-side idempotency contract or exposed duplication.
6. **No authentication, revocation, leases, fencing or retention.** The tenant
   capability is a step label; retry records are never deleted.
7. **Ids, keys and digests are natural numbers.** Collision resistance of a
   real digest is outside the model.

## Next stage (A1)

State the same contract as an executable Shen model, and have Gleipnir explore
submit/complete/respond/crash schedules against it, with the volatile-mailbox
variant kept as a mutant that must be caught.
