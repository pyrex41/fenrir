# Accepted-job upgrade contract (stage A4)

Draft 1 • 15 November 2026 • For owner review

Stage A4 of [04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md) §8: "a
versioned upgrade that preserves pending work", under the amendment's §13 default:
**version-pinned**, not hot code swap. It extends the A1 contract
([ACCEPTED_JOB.md](ACCEPTED_JOB.md)), the A2 storage contract ([HANDLER.md](HANDLER.md))
and the A3 host contract ([host/service/CONTRACT.md](../../host/service/CONTRACT.md));
everything they say still holds for a service that never upgrades, and the A1
properties keep their meaning across an upgrade (§6).

This text was written before the model. The authoritative statement is the executable
Shen model [models/service-a4/upgrade.shen](../../models/service-a4/upgrade.shen) with
its properties in
[models/service-a4/upgrade-properties.shen](../../models/service-a4/upgrade-properties.shen);
where they disagree with this text, the model is the contract and the text is wrong.
Evidence labels: the model, *bounded exploration passed*; the real stack, *observed
history accepted; bounded crash campaign*; `qualification: UNKNOWN` throughout. Every
choice this draft makes that the sources leave open is marked *provisional* and listed
in §11.

## 1 What "version-pinned" means here

Three things carry a version, and each is pinned differently.

1. **A run** (one boot of a handler image serving one request, A3) is pinned to the
   version of the image that runs it. A run is never migrated: it finishes on its
   version, or its commit is refused (§4.3) and the client retries, which is A1's
   "a crash loses only volatile state" applied to a run that lost the race with a
   cut-over. Runs are short (one request per boot), so nothing is lost but latency.
2. **The store** is in exactly one schema version at a time, the one the durable
   upgrade state names (§3). A transaction is applied entirely under that version or
   not at all.
3. **An accepted job** is a durable obligation (amendment §4: "cancelling it is itself a
   durable transition"). Draft 1 takes the **migrated** branch of §13's alternative for
   every job: the `migrate` transition converts every job, pending or terminal, to the
   new schema in the same atomic step as everything else (§4.2). No job stays bound to
   the old version, so after cut-over no old-version worker is needed. The other branch
   (a pending job bound to the version that accepted it, finished by a retained old
   worker) is not modelled (*provisional*, §11).

New requests go to the new version only after a durable **cut-over** (§4.4).

## 2 Version identity, and what v2 changes

A **handler version** is the pair *(artifact SHA-256, contract version)*: the SHA-256
of the elaborated artifact the image runs (DURABLE.md §2: images are bound by artifact
hash), and the **storage-contract version** the image's residual effect row is written
against. The contract version is not a separate annotation in the program (Fenrir has
no such form): it is the contract whose declaration the image's capability manifest
(the residual row with its operation types and the datatypes they mention) matches
exactly. The host carries contract 1 (HANDLER.md §2) and contract 2 (§2.2 below); an
image whose manifest matches neither is refused (§4.1). The image descriptor states the
version it claims, and the host refuses a descriptor whose claim differs from its
manifest's (*provisional*).

| Version | Handler | Storage contract | Model |
| --- | --- | --- | --- |
| 1 | [examples/service/accepted-job.fen](../../examples/service/accepted-job.fen), unchanged | HANDLER.md §2–§3 (`Tx`) | A1's transaction, `svc.submit`, `svc.complete` |
| 2 | [examples/service/accepted-job-v2.fen](../../examples/service/accepted-job-v2.fen) | §2.2 (`Tx2`) | §2.1 |

### 2.1 The v2 store schema and behaviour

The change is chosen small, but so that each upgrade property has something to break:

- **Jobs gain `attempts`**, the number of delivery commits applied to the job. A v2 job
  record is `[Id Report Status Attempts]`. v2 stages a new job as `[N N pending 0]`;
  a v2 delivery that finds the job pending sets the status (`done` or `failed`) **and**
  `Attempts + 1`. Because the `Pending` guard lets exactly one delivery apply, in a
  correct v2 store `Attempts` is 0 exactly when the job is pending and 1 otherwise. This
  is the observable behaviour change for new requests (it is visible in every store
  observation).
- **New receipts carry the contract version.** A request accepted under v2 gets the
  receipt `[receipt T K D R J 2]` (the canonical observation shows it as
  `[t, k, d, r, j, 2]`); a request accepted under v1 has A1's `[receipt T K D R J]`
  (`[t, k, d, r, j]`). **A receipt, once issued, is returned unchanged forever**: the
  key entry of a request accepted under v1 keeps its v1 receipt after migration, and a
  v2 handler that replays it returns it as recorded. The client therefore sees one
  representation per request, the one of the version that accepted it.
- Reports, the key table's keys and digests, and `Next` are unchanged in shape.

The migration function (*provisional* defaults, but derived, not guessed):

```text
mig-job  [J R pending]  = [J R pending 0]
mig-job  [J R St]       = [J R St 1]          St = done | failed: exactly one delivery applied
mig-key  [K D Rc]       = [K D Rc]            receipts are kept exactly as recorded
mig-store [store Reports Jobs Keys Next] = [store Reports (map mig-job Jobs) (map mig-key Keys) Next]
```

### 2.2 The v2 storage contract

As HANDLER.md §2–§3, with these differences only:

```text
Receipt  (Receipt t k d r j) | (Receipt2 t k d r j)        Receipt2 is [receipt T K D R J 2]
Write    (PutReport digest payload) | (StageJob2 attempts) | (RecordKey key digest)
         | (Finish job ok) | (CountAttempt job)
Tx       (Tx2 Cap Guard Writes)
```

- `(StageJob2 a)` adds the job `[N N pending a]`.
- `(RecordKey k d)` adds `[k d [receipt t k d N N 2]]` and the reply is
  `(Committed (Receipt2 t k d N N))`.
- `(Finish j ok)` sets the status of job j; `(CountAttempt j)` adds 1 to its attempts.
  The v2 handler writes both in one commit; deduplication is its `Pending` guard, as in
  v1.
- `(Recorded d r)` carries the receipt as recorded, in either representation.
- The commit's constructor is its **contract version in band**: `Tx` is version 1, `Tx2`
  version 2. A guest cannot produce a commit of a contract its artifact does not
  declare (DURABLE.md §2), so the version of a commit is the version of the image that
  made it.

## 3 The durable upgrade state

The store holds, besides the tenant stores, one **upgrade state** `U`, written only by
the upgrade transitions, never by a request, and never changed by a crash:

| `U` | Schema of every tenant store | Version in force for new runs | Commits accepted |
| --- | --- | --- | --- |
| `[v1]` | 1 | 1 | `Tx` |
| `[prepared Img]` | 1 | 1 | `Tx` |
| `[migrated Img]` | 2 | none: requests are refused as `unavailable` | none |
| `[v2 Img]` | 2 | 2 (the image `Img`) | `Tx2` |

`Img` is the v2 image the upgrade was begun with (its version identity, §2). The schema
a state names is the column above; "readable by exactly the version the durable state
names" (§6) refers to it.

## 4 The upgrade transitions

Each is **one atomic step** on the whole store (all tenant stores and `U`), like A1's
`submit` on one tenant's store. A crash between two steps leaves `U` and the stores as
the last completed step left them.

### 4.1 `begin-upgrade Img`

Enabled in `[v1]`. The host reads `Img`'s capability manifest (DURABLE.md §2) and
checks it against the storage contract it will provide **after** migration (contract 2)
and the migration program's manifest against the migration contract (§5). If both are
discharged: `U` becomes `[prepared Img]`. Otherwise the step is **refused**: nothing
changes and the operator is told `refused`. Requests continue under v1 in `[prepared Img]`.

### 4.2 `migrate`

Enabled in `[prepared Img]`. In one step: every tenant store `S` becomes `mig-store S`
(§2.1), the schema becomes 2 and `U` becomes `[migrated Img]`. All of it or none of it:
there is no state in which some tenant, some job or some key entry is converted and
another is not. This is the strongest of the two options the stage description allows
(one atomic step, or per-tenant atomic steps with an invariant between them); draft 1
takes it because SQLite's single writer makes one transaction over all tenants cheap and
because it needs no mixed-schema invariant (*provisional*).

### 4.3 Fencing

A run's commit carries its contract version (§2.2). The store applies a commit of
version V only when the version in force (§3) is V, checked **inside the commit's own
transaction** against the durable `U`; otherwise it applies nothing and the run gets no
reply (DURABLE.md §4: the host answers once or never). The client is told
`unavailable` (nothing applied, retry). So:

- a v1 run dispatched before `migrate` whose commit arrives after it is refused (the
  stale-writer case), whatever the supervisor believes;
- every request between `migrate` and `cut-over` is refused, submits and deliveries
  alike: no schema-2 store is ever written by v1 code, and no v2 code writes before the
  cut-over that makes v2 the version in force.

The supervisor's own check (it starts only workers whose image version matches `U`) is
a second line, not the guarantee.

### 4.4 `cut-over`

Enabled in `[migrated Img]`: `U` becomes `[v2 Img]`. From then on every new run is a v2
run.

### 4.5 Abort and rollback

- **Before `migrate`**: `abort-upgrade`, enabled in `[prepared Img]`, sets `U` back to
  `[v1]`. Nothing else was changed, so nothing else is undone.
- **Between `migrate` and `cut-over`**: not supported in draft 1. (It would be
  possible: no v2 transaction can have run, and the inverse of `mig-store` is total on
  migrated stores. *Provisional*, §11.) The upgrade can only go forward; a crash there
  is resumed by cutting over.
- **After `cut-over`: rollback is not supported.** A v2 receipt or a job with attempts
  has no v1 representation, and v1 code cannot read the v2 schema. A failed v2 is
  replaced by a later version (v3), which is outside this draft.

## 5 The migration as a Fenrir program

The migration function is written in Fenrir:
[examples/service/migrate-v1-v2.fen](../../examples/service/migrate-v1-v2.fen). Its
residual row is one durable effect, `Migration`, with three operations, one row per
request:

```text
read    : I64 --> Next1        row i of the snapshot (NoMore past the end); reading row 0
                               makes the host take a new snapshot of every job and key row
                               of every tenant (schema 1) and drop anything staged
stage   : Row2 --> Ack         the v2 row the program computed from a v1 row, kept by the
                               host in the migration's session (volatile)
install : I64 --> Migrated     install the staged rows, after reading all n rows
Row1       (Job1 t id report status) | (Key1 t key digest receipt)
Row2       (Job2 t id report status attempts) | (Key2 t key digest receipt)
Migrated   Installed | Changed | Refused
```

The program reads the rows, stages the v2 row of each, computed by a pure function
(`mig-job`, `mig-key` of §2.1), and asks the host to install them. Under D1 a
transaction cannot be held open across host requests (DURABLE.md §8), so `install` is a
**compare-and-swap**: the host applies it, in one transaction, only when `U` is
`[prepared Img]`, n is the number of rows in the snapshot, and the store's current
schema-1 rows are exactly the snapshot; it then replaces every job and key row with the
staged rows in their order, sets the schema to 2 and `U` to `[migrated Img]`, and
replies `Installed`. If a v1 request committed after the snapshot, the reply is
`Changed` and nothing is applied; the program reads again from row 0 (at most three
times, then gives up with `Changed`). `Refused` means `U` is not `[prepared _]` or n is
not the snapshot's size. Reports and `Next` are not rows: their shape does not change and
the install keeps them; the compare covers them through the job and key rows (§11). The
session is the migration run's own and is lost with it: a crash during a migration loses
only volatile state, and the migration is run again.

The first draft of this section had one `snapshot` request returning every row and one
`install` carrying them. That is expressible in D1 and ran in the Shen model and the
JavaScript implementation, but **not in the Solo5 guest**: control protocol v2 limits a
host reply to 512 bytes (pure-call-control-v2.md §6), and a snapshot of more than a few
rows exceeds it (`GuestError Oversize`). One row per request keeps every reply under the
limit; the guest-to-host direction (61,440 bytes) was never the constraint. This is a
transport limit, not a limit of the durable contract.

The refinement harness checks that the program computes `mig-store` (§9). Its
emulated host checks types, row count and the compare; this is not evidence that
an OTP host would catch a wrong program. The proposed host boundary must validate
the staged rows and preservation obligations independently (see
[A4 host port](../../host/service/A4_PORT.md)).

## 6 Properties

Each is a predicate on states (*state*) or explored transitions `x -l-> y` (*edge*),
checked on every reachable state and edge of the upgraded system. "The v1 view" of a
state drops a job's attempts and a receipt's version field; A1's predicates applied to
the v1 view are A1's properties carried across the upgrade. Code names are those of
`upgrade-properties.shen`.

### A1's properties, across the upgrade

- **Authority** `authority.frame` (edge): a request or delivery under tenant T's
  capability changes no other tenant's store; `respond`, `crash`, `begin-upgrade`,
  `abort-upgrade` and `cut-over` change no store. `migrate` is the one transition that
  acts on every tenant (an operator capability over the whole store); what it may do is
  constrained by the pending, receipt and version properties below.
- **Atomicity** `atomicity.records` (state): A1's invariant on the v1 view of every store.
- **Response discipline** `response.durable` (state) and
  `response.commit-before-respond` (edge): A1's, on the v1 view, for receipts of either
  representation.
- **Retry safety** `retry.replay` (edge): a submit whose key is recorded leaves every
  store unchanged and answers the recorded receipt (same digest) or `conflict` (other
  digest), **or** `unavailable` (refused, nothing applied). `retry.delivery` (edge): a
  second delivery of a job, with either outcome, changes nothing.
- **Recovery** `recovery.crash-frame` (edge): a crash changes no store, no trace **and
  not `U`**. `recovery.obligations` (edge): A1's, on the v1 view.
- **Progress** (conditional): A1's assumptions F1 (every pending job is eventually
  delivered) and F2 (a delivery is not itself interrupted), and **F3**: an upgrade in
  `[migrated Img]` is eventually cut over (the operator, or the orchestrator resuming
  after a crash, completes it). `progress.dischargeable` (state): for every acceptance a
  client was told and both outcomes, the state reached by cutting over if `U` is
  `[migrated _]` and then delivering the job has the job terminal.
  `progress.terminal-stable` and `progress.delivery-terminates` (edge): A1's, on the v1
  view; the second only for a delivery that was not refused.

### Upgrade properties

- **Pending work preserved.**
  - `pending.preserved` (edge): every job pending in x is in y with the same tenant, id
    and report, pending or (only by a delivery of that job) terminal. In particular
    `migrate` drops no pending job.
  - `pending.deliverable` (state): every pending job, whether or not a client was told,
    becomes terminal by cutting over if `U` is `[migrated _]` and then one delivery, with
    either outcome. So no pending job is ever unreachable to the version in force.
  - "None is delivered under a version that cannot interpret it" is stated through
    `version.readable` below: a v1 delivery applied to a schema-2 job leaves a terminal
    job with no attempt counted, which no correct v2 store contains.
- **Receipts stable.**
  - `receipts.immutable` (edge): every key entry `[K D Rc]` of x is in y, unchanged
    (across every request, delivery, crash and upgrade step, `migrate` included).
  - `receipts.retry-stable` (edge, monitor): if an acceptance `[accepted Rc]` was ever
    issued for T and K (even if a crash lost it before a client saw it), a submit T K D,
    under whichever version is in force, leaves every store unchanged and answers exactly
    `[accepted Rc]` (the same representation) when D is Rc's digest, `[conflict T K]`
    otherwise, or `unavailable`; if a conflict was issued for T, K and D, it answers
    `[conflict T K]` or `unavailable`. Never a second mutation, never `conflict` for the
    recorded payload.
- **No mixed-version atomicity violation.**
  - `version.readable` (state): every tenant store is a well-formed store of the schema
    `U` names (§3): schema 1, every job `[J R St]` and every receipt five fields; schema
    2, every job `[J R St A]` with A = 0 when St is pending and A = 1 otherwise, and every
    receipt five fields (accepted under v1) or six with version 2. Checked on every
    state, so on every state a crash can leave.
  - `version.transitions` (edge): `U` changes only along `[v1] → [prepared Img] →
    [migrated Img] → [v2 Img]` and `[prepared Img] → [v1]`, each by its own label; no
    request, delivery, response or crash changes it.
- **Capability manifest.** `manifest.admitted` (state): `U` never names an image whose
  manifest the host does not discharge under contract 2. The alphabet offers
  `begin-upgrade bad`, an image whose residual row names a storage contract the host does
  not provide; it must be refused.

## 7 The model

State `[up4 U [sys Stores Outbox Trace]]`: A1's system state (the stores in the schema
`U` names) and the durable upgrade state. The outbox holds A1's responses and the
**in-flight runs** `[run V Label]`: a run dispatched to version V, not yet committed.

| Label | Effect |
| --- | --- |
| `[submit T K D]`, `[complete T J Ok]` | a run of the version in force, dispatched and committed in one step (A1's steps when that version is 1; §2.1's transaction when it is 2); `unavailable` in `[migrated _]` |
| `[dispatch L]` | L a submit or complete: a run of the version in force starts and waits, `[run V L]` in the outbox; not offered in `[migrated _]` |
| `[land I]` | the I-th in-flight run commits: applied when V is in force, else refused (§4.3) and answered `unavailable`; the run leaves the outbox either way |
| `[respond E]`, `[crash]` | A1's; a crash also drops every in-flight run |
| `[begin-upgrade good]`, `[begin-upgrade bad]`, `[abort-upgrade]`, `[migrate]`, `[cut-over]` | §4 |

A1's steps under `[v1]` with no dispatch and no upgrade label are exactly A1's graph.
The exploration alphabet is A1's (every submit, every delivery of an id in use or the
next unused one, every response in the outbox, crash), the dispatches of the same
submits and deliveries, every in-flight run's landing, and the upgrade labels enabled in
the state. Budgets: submits, deliveries, responses, crashes, dispatches and upgrade
steps; a landing takes no budget (it consumes the run a dispatch made).

Canonical observation (counterexamples, hand traces): a state is
`[Upgrade, Tenants, Outbox, Trace]` with `Upgrade` `["v1"]`, `["prepared", img]`,
`["migrated", img]` or `["v2", img]`; a tenant is A1's `[reports, jobs, keys, next]` with
v2 jobs `[id, report, status, attempts]` and v2 receipts `[t, k, d, r, j, 2]`; the outbox
lists A1's events (accepted before conflict, by fields; a v1 receipt before a v2 receipt
with the same five fields) and then the runs `["run", v, label]` in dispatch order; labels
as A1's plus `["dispatch", label]`, `["land", i]`, `["begin-upgrade", img]`,
`["abort-upgrade"]`, `["migrate"]`, `["cut-over"]`; a response is an event, `null`,
`"unavailable"` or `"refused"`.

## 8 Mutants

Kept outside the model (harness/service-upgrade-mutants.shen), each one change:

| Mutant | Change | Aimed at |
| --- | --- | --- |
| `migration-drops-pending` | `migrate` keeps only terminal jobs | pending |
| `migration-not-atomic` | `migrate` is split into one internal step per tenant; `U` changes only after the last, and v1 keeps serving between them | version (mixed-schema store) |
| `cutover-before-migration` | `cut-over` is enabled in `[prepared _]` and does not migrate | version |
| `stale-v1-commit` | the store does not fence: a landing v1 run is applied with v1's statements to whatever schema the store has | version, receipts |
| `keys-not-migrated` | `migrate` builds an empty key table | receipts, retry |
| `receipt-rewritten` | `migrate` rewrites every v1 receipt to the v2 representation | receipts |
| `deliver-to-v1` | after cut-over, deliveries still run v1's statements (a v2 job finished with no attempt counted) | version (interpretation) |
| `no-manifest-check` | `begin-upgrade` admits any image | manifest |
| `volatile-upgrade-state` | `U` is held in memory: a crash puts it back to `[v1]` | recovery, version |
| `equivalent-control` | migration and v2 delivery written differently with the same meaning | must not be flagged; same graph |

## 9 Fenrir handlers and the refinement check

From the repository root with Shen/JIT available, run
`sh harness/run-service-upgrade.sh` for the A4 model and its mutant campaign.
`sh harness/run-service-upgrade-fenrir.sh` runs the Fenrir refinement, its mutant
campaign, the sandboxed JS comparison, and the Solo5 sample (requires a Linux
spt host). Each accepts `replay-retained` for its own counterexample set.
The Solo5 sample check uses one cold-boot replay per tape; its `quick` mode
does not repeat the standalone hostile-host or independent rerecording checks.
None of these commands qualify the OTP host or test power loss.

As A2: a Fenrir machine is the A4 model with every run (`submit`, `complete`,
`dispatch` then `land`) executed by running the handler program of the run's version on
the Shen TC1-D1 model, its `Store.commit` answered by the store under the storage
contract of that version (HANDLER.md §3 for `Tx`, §2.2 for `Tx2`) with the fencing of
§4.3, and `migrate` executed by running the migration program with its requests
answered on the current stores (*provisional*: both answered within the `migrate` step).
The claim, checked by bounded exploration, is that this machine has exactly the A4
model's graph: same states, edges and responses. Separately, for every reachable
`[prepared _]` state and every submit that changes it, the migration program run with
the snapshot of the first state and the install against the second gets `Changed`,
changes nothing, reads again and installs the migration of the second state (the
compare-and-swap of §5). The distinct (program, request, replies) runs are then run in
the JavaScript TC1-D1 implementation and, on a declared sample, in the Solo5 guest,
step for step against the model.

## 10 Proposed real-stack mapping (host/service)

This section is a design, not evidence that the current A3 host implements A4.

- The SQLite file has a `meta` table with the schema version (`schema`:
  `fenrir.host.service-store/1` or `/2`) and the upgrade state (`upgrade`, with the image
  identity). The adapter refuses to open a store whose schema it does not know.
- Every commit's transaction reads `meta` after `BEGIN IMMEDIATE` and refuses (`stale`,
  told to the client as `unavailable`) a commit whose version is not in force: fencing
  in the store.
- `install` is one `BEGIN IMMEDIATE … COMMIT` that compares, adds the v2 columns, replaces
  the job and key rows, and writes `meta`.
- The image descriptor carries the handler version; the supervisor starts only workers
  whose version is the one in force and replaces them at cut-over.
- An upgrade orchestration API on the node: `begin_upgrade`, `migrate` (runs the
  migration guest), `cut_over`, `abort_upgrade`, `upgrade_state`.
- History schema `fenrir.service.history/2` adds the upgrade events, `unavailable`,
  dispatched runs and v2 receipts; schema `/1` histories stay valid and are checked as
  before ([HISTORY_FORMAT.md](HISTORY_FORMAT.md)).

The model's tenant label represents a tenant already authenticated by the host. It
does not stand for an authority carried in the guest's request. The A4 host must
preserve A3's token-to-scope binding, the separate trusted delivery path and the
host's check of the response tenant before publication. A version or image selected
by the guest cannot confer authority. The operator-only migration capability is
separate from tenant credentials and from the handler's store capability; a handler
must never acquire cross-tenant snapshot, staging or install access.

## 11 For the owner to confirm

1. Every job is migrated (§1, item 3); version-pinned jobs finished by a retained v1
   worker are not modelled.
2. Version identity = (artifact SHA-256, storage-contract version), the contract version
   being the contract the manifest matches, and the commit constructor (`Tx`/`Tx2`)
   carrying it in band (§2, §2.2). Alternative: an explicit version field in every
   commit, or a language-level module version.
3. The v2 change: `attempts` on jobs with derived defaults (0 pending, 1 terminal), and
   version 2 in new receipts while old receipts keep their representation (§2.1).
4. One atomic `migrate` over all tenants (§4.2), not per-tenant steps.
5. Requests refused (`unavailable`) between `migrate` and `cut-over` (§3), rather than
   served by v2 at once (which would merge the two steps).
6. Fencing inside the commit's transaction, against the durable state (§4.3); a refused
   commit gets no reply and the client is told `unavailable`.
7. No rollback between `migrate` and `cut-over` (possible, not done), none after
   `cut-over` (§4.5).
8. Progress assumption F3: a migrated upgrade is eventually cut over (§6).
9. The migration's requests answered within the `migrate` step in the refinement
   check; interleaving covered by the separate compare-and-swap check (§9).
10. The install's compare covers job and key rows; reports and `Next` are compared
    through them (§5). A v1 commit always changes a job or key row, except a delivery
    of an unknown or finished job, which changes nothing at all.
11. The migration program retries at most three times on `Changed` (§5).
12. `begin-upgrade` checks the migration program's manifest too, against a host
    contract named `Migration` (§4.1, §5).

## 12 What this does not cover

Hot swap of running frames (no in-flight run is ever migrated); schema histories longer
than v1 → v2 (v1 → v2 → v3); rollback after cut-over; rollback between migrate and
cut-over; version-pinned jobs (§1); several upgrades in one exploration beyond the step
budget; power loss and fsync honesty in the real stack (as A3); everything A1–A3 list as
not covered.
