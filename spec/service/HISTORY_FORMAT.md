# Service history format (stage A3)

Draft 1 • 15 November 2026 • Schema `fenrir.service.history/1`

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
