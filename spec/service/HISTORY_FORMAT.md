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
| `["fault", WHAT, POINT]` | the driver verified the named injection at that point; for a verified node injection this accompanies a separate `crash` event | none (informational; the faulted request's own outcome says what it did) |
| `["observe", STORES]` | the stores as the service's API reported them (one read transaction) | none; the model's stores must equal STORES |
| `["drained"]` | the job runner found no pending job | none; the model must have no pending job |
| `["concurrent", [EVENT...]]` | submits/deliveries issued at once over several workers | every occurrence in some order, including repeated identical members |
| `["gap", WHY]` | the recorder lost events | none: the verdict is indeterminate |

For a concurrent group the checker tries each distinct event as the next
member and consumes one occurrence. It extends an ordering only while some
model state admits its prefix. Completed orderings contribute their surviving
states to the union. Step and predicate counters count the checks actually
performed, so a shared prefix can contribute once across several orders.

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

## 4 Supervised A4 pilot (`fenrir.service.history/2`)

This is the history of the opted-in supervised v1 → v2 fixture and its finite
crash campaign. In addition to `schema`, `scenario`, `tenants` and
`events`, it has `handler_pin` and `migration_pin`: distinct lowercase
256-hex strings (digest of descriptor, canonical artifact, image and tender,
concatenated in that order). An observation or begin event carrying a different
pin is rejected even if the actual rows match.

- `["upgrade","begin",HANDLER_PIN,MIGRATION_PIN,["ok"]]` records successful
  preparation. Other phase transitions use
  `["upgrade","migrate",OUT]`, `["upgrade","cut-over",OUT]` or
  `["upgrade","abort",OUT]`; `OUT` records `ok`, `busy`, `aborted`, `changed`,
  `refused`, or `indeterminate` as a one-element array.
- Every upgrade event needs a following `["observe",STORES,STATE]`, and
  the history must end in such an observation. `STATE` is `["v1"]` or
  `[PHASE,HANDLER_PIN,MIGRATION_PIN]` with `prepared`, `migrated`, or `v2`.
  Rows retain the v1 store shape before install. Thereafter each job appends
  its attempt count and each v2 receipt appends `2`; v1 receipts stay unchanged.
- Submits and deliveries use §2's shapes, plus `["unavailable"]` in the
  `migrated` phase (neither protocol in force). `["concurrent",[A,B]]` covers
  exactly two successful submit/delivery calls, without nested groups or
  phase transitions. The model checks both orders. Unsupported concurrent or
  generic fault claims cannot pass this checker. A recorder gap anywhere
  (including inside a concurrent group) or a missing required observation is
  indeterminate, not a mutant rejection.
- `["crash","node",OLD_OS_PID,NEW_OS_PID,137]` is used only after the external
  driver correlates the signal receipt with the target, observes its actual wait
  status, and starts a distinct BEAM on the same SQLite file. It takes the A4
  node-crash step (clears the outbox, not the store).
- `["submit-committed-unpublished",T,K,D,DEAD_WORKER,REPLACEMENT_WORKER]`
  records the witnessed `w3_commit_before_reply` kill. The checker uses the
  normal successful submit transition, checks its predicates, and retains the
  *prior* outbox rather than publishing the new receipt. The driver separately
  requires an indeterminate response, independent observation of the receipt,
  and matching worker death/replacement in the same front/BEAM. A malformed
  fault witness projects to a gap, not a semantic rejection. A missing
  immediate store observation after either fault is also indeterminate.

The worker harness reads phase and projected rows in an independent SQLite
transaction: report IDs and digests (not payload bytes), job rows and attempts,
key/receipt rows, and tenant counters. Equality is of this projection, not of
report payloads or the SQLite file's bytes.
The verifier projects matching image pins to the abstract A4 model image and
checks model responses and observations; it does not infer executions from
pins alone. The harness also requires an exact verdict for every positive and
negative control, and successful child exits. The `/1` verifier remains a separate
branch for A3 and receives no new permissive event forms.

The worker fixture checks a witnessed SQLite cut-over acknowledgement loss by recording
the `indeterminate` transition and required state after store restart; it
never claims the transaction rolled back based on that outcome. A separately
witnessed idle worker kill corroborates supervision and outbox preservation, not
a node crash or a general fault event in this schema. The bounded campaign
checks the completeness of the planned histories, operation-specific fault
witnesses, post-restart state, same-key retries, and negative controls outside the
model, in `host/service/tools/a4-crash-evidence.mjs`.
This evidence gate also requires strictly overlapping call intervals from one
monotonic clock, the two distinct front-selected workers, and a final `drained`
milestone corroborated by the zero-pending query and final v2 observation.
An admissible trace that omits such a milestone is not campaign evidence.

### Chunked storage for version 1 histories

A manifest with schema `fenrir.service.history/1-chunked` carries the v1
tenant, scenario and expectation fields, an integer `event_count` and an
integer `chunks`. For a manifest at `history.json`, chunk zero lives at
`history.json.events.0`. Subsequent suffixes are consecutive decimal integers.
Each chunk is a JSON object with a zero-based global event offset `first` and
a nonempty `events` array using the v1 event grammar. An empty history uses
zero chunks. Each file has the existing 64 MiB JSON parser limit, including
any final observation within its chunk.

Pass the manifest to `harness/run-service-history.sh`. The checker carries
the candidate states and property monitors across chunk boundaries. It checks
offsets and the total event count before accepting, and reports the first
inadmissible event using its global index. A missing chunk or inconsistent
offset makes an otherwise admissible history unreadable. The model state and
an individual observation must still fit in memory.
