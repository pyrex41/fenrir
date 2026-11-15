# Service history format (stages A3 and A4)

Draft 1 • 15 November 2026 • Schemas `fenrir.service.history/1` (A3) and `/2` (A4, section 4)

A history is what an observer outside the service saw during one run of the real
stack (host/service: OTP host, SQLite adapter, Fenrir handler as a Solo5 worker). The
campaign driver ([host/service/test/fenrir_drive.erl](../../host/service/test/fenrir_drive.erl))
writes it; [harness/service-history.shen](../../harness/service-history.shen) decides
whether the A1 model ([models/service/accepted-job.shen](../../models/service/accepted-job.shen))
admits it. The driver runs in its own BEAM, which no fault touches, so its record of
what clients were told is complete; what it could not see is written as such.

## 1 Document

```json
{"schema": "fenrir.service.history/1", "tenants": 3, "scenario": "...", "events": [ ... ]}
```

Other members are ignored by the checker (`family`, `mutant`, `note`; the checker's own
negative tests add `expect` and `expect_index`). Values use the canonical observation of
[ACCEPTED_JOB.md](ACCEPTED_JOB.md) section 3: a receipt is `[tenant, key, digest, report,
job]`, an event is `["accepted", receipt]` or `["conflict", tenant, key]`, a store is
`[reports, jobs, keys, next]` with each list sorted by its first field.

## 2 Events

| Event | Meaning | Model step(s) the checker allows |
| --- | --- | --- |
| `["submit", t, k, d, OUT]` | a submit request and what the service answered | see OUT |
| `["complete", t, j, ok, OUT]` | a delivery of job j's result (by the runner or a client) | see OUT |
| `["respond", EVENT]` | the client was told EVENT (the front confirmed it was in its outbox) | `[respond EVENT]` |
| `["respond-refused", EVENT]` | the front refused to deliver EVENT: not in its outbox | none; EVENT must not be in the model's outbox |
| `["crash", "node"]` | the service node (the BEAM OS process) died: kill -9, `erlang:halt`, or found dead; it was restarted from the SQLite file | `[crash]` |
| `["fault", WHAT, POINT]` | a tender, worker, store process or SQLite port program died and the node survived | none (informational; the faulted request's own outcome says what it did) |
| `["observe", STORES]` | the stores as the service's API reported them (one read transaction) | none; the model's stores must equal STORES |
| `["drained"]` | the job runner found no pending job | none; the model must have no pending job |
| `["concurrent", [EVENT...]]` | submits/deliveries issued at once over several workers | the members in some order |
| `["gap", WHY]` | the recorder lost events | none: the verdict is indeterminate |

OUT, the outcome the service reported for a request:

| OUT | Meaning | Model |
| --- | --- | --- |
| `["accepted", receipt]`, `["conflict", t, k]` | the program's response | the label's step, with exactly this response |
| `["delivered"]` | a delivery's response (A1: no response) | `[complete t j ok]`, response none |
| `["other"]` | a response that is not an A1 event (for example `Refused`) | the label's step with response none (a submit therefore never matches) |
| `["busy"]`, `["aborted"]`, `["refused"]` | nothing was applied (store busy; definitely not applied; request outside the image's domain) | no step |
| `["indeterminate"]` | a commit may have happened and no response exists (lost acknowledgment, a crash between commit and response, a dead worker) | the label's step, with its response lost, **or** no step |

A crash of a single tender, worker or port program is not A1's `crash`: A1's crash
empties the whole outbox, while the real outbox lives in the front process and survives
those faults. Only the death of the node (which takes the front with it) is A1's crash.

## 3 Verdicts

- **accepted**: some execution of the model, label by label as above, gives every
  recorded response, has stores equal to every observation, no pending job at every
  `drained`, and every property predicate of
  [accepted-job-properties.shen](../../models/service/accepted-job-properties.shen) holds on
  each of its states and edges. Evidence: *observed history accepted*, nothing more.
- **rejected**: no such execution; the verdict names the first event after which no
  model state is consistent with the history, the reason, and, for an observation, the
  property checks that the *observed* stores fail (a diagnostic, not part of the verdict).
- **indeterminate**: the history records a gap, or the set of consistent model states
  exceeds the checker's bound (4,096). Never an acceptance.

## 4 Schema `fenrir.service.history/2` (stage A4)

Draft 1 • 15 November 2026. A history of a run that may upgrade the service
([UPGRADE.md](UPGRADE.md)). It is checked against the A4 model
([models/service-a4/upgrade.shen](../../models/service-a4/upgrade.shen)) and its
properties ([upgrade-properties.shen](../../models/service-a4/upgrade-properties.shen))
by [harness/service-history-upgrade.shen](../../harness/service-history-upgrade.shen),
which [service-history.shen](../../harness/service-history.shen) loads; a history of schema
`/1` is checked against the A1 model exactly as in sections 1–3, by the same code as
before. Everything in sections 1–3 holds for `/2`, with these additions:

- **Receipts** have the representation of the version that accepted the request
  (UPGRADE.md §2.1): `[t, k, d, r, j]` under v1, `[t, k, d, r, j, 2]` under v2.
- **Stores** of schema 2 have jobs `[id, report, status, attempts]`.
- `["observe", STORES, UPGRADE]`: the stores and the durable upgrade state, read by the
  service's API; UPGRADE is `["v1"]`, `["prepared", img]`, `["migrated", img]` or
  `["v2", img]`, with img `"good"` when the recorded image is the v2 image the campaign
  built and `"bad"` otherwise. The model's stores and upgrade state must both be equal.
  The `/1` form `["observe", STORES]` is still accepted and compares the stores only.
- OUT `["unavailable"]`: a request refused with nothing applied (no version in force, a
  fenced commit, a worker being replaced). No step, like `busy`.
- `["upgrade", STEP, (IMG,) OUT]`, an operator's upgrade step: STEP `"begin"` (with IMG
  `"good"` or `"bad"`), `"abort"`, `"migrate"` or `"cut-over"`; the model labels
  `[begin-upgrade img]`, `[abort-upgrade]`, `[migrate]`, `[cut-over]`.

| OUT of an upgrade step | Model |
| --- | --- |
| `["ok"]` | the label's step, response none |
| `["refused"]` | `begin`: the step with response `refused` (an image the host cannot discharge), or the label not enabled in the model state; the other steps: the label not enabled |
| `["changed"]`, `["busy"]`, `["aborted"]` | no step (nothing applied) |
| `["indeterminate"]` | the label's step, **or** no step |

A stale run (a request on a worker of an old version, held across an upgrade step) is
recorded as an ordinary submit or delivery when its outcome is known, after the
upgrade events that happened while it was held. It needs no event of its own: if the
store fenced it, its outcome is `unavailable` (no step); if it was applied, the checker
finds no model state that applies a v1 transaction after migrate, so a store that does
not fence is caught by its responses or by the next observation.
