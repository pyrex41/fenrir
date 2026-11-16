# TC1 gate: two remote rows added, and the gate registered

15 November 2026 • Authority record • Amendments 1, 2 and 3 of 16 November 2026 are at the end

## What changed

| | Before | After |
| --- | --- | --- |
| Manifest | `spec/tc1/tc1-requirements.json`, status `proposed`, 19 required rows | Same path, status `owner-accepted`, 21 required rows |
| Evaluator | `harness/tc1-gate.shen`, reporting `authority: UNREGISTERED`, `qualification: UNKNOWN` | Same file; reports `authority: owner-accepted, registered`, and `qualification` is the verdict |
| Workflow configuration | No TC1 check | Check `tc1-qualification`, kind `qualification`, command `sh harness/run-tc1-gate.sh` |
| Required rows added | | `remote-model`, `remote-run` |
| Changed row | `toolchain-pinned`: Shen/JIT is the flake's | The same, and the Erlang/OTP the supervisor is built and run with is the flake's |
| Claims added | | `remote-perform-model-properties-bounded`, `remote-perform-observed-histories-spt` |
| Contract | `spec/tc1/EFFECTS.md` draft 4 | Draft 5: three owner rulings in §12.10, and the crash between a peer's commit and its reply (§12.3, §12.7) |

Manifest registered, SHA-256 of `spec/tc1/tc1-requirements.json`:

```text
8c3c087b0769eaa8382dc0eaf4b6b4e5c77e89dd907725058a0f42783a4528dd
```

That is the manifest as registered on 15 November 2026. The amendments below
replace it; the last of them gives the hash of the manifest this record is
about now. A
manifest with any other hash is not the one this record is about. The other
nineteen rows, their required flags, ledger references, the earlier six
claims, the claim prerequisites and the aggregation rule are as they were
proposed.

## Basis

In conversation on 15 November 2026 the owner (pyrex41):

1. accepted the first implementation's answer to question 1 of EFFECTS.md
   §12.10: an undeclared connection is rejected when the system is assembled
   from the manifest, and the run-time refusal stays as a backstop;
2. accepted its answer to question 2: request keys are chosen by the program;
3. ruled on question 10: a peer killed between its store commit and its reply
   is to be handled by letting the model accept a replay when the durable
   store shows the request was applied. The store is the durable truth; the
   supervisor's log is not;
4. instructed that the two checks of remote perform be added as rows of the
   TC1 gate, and that the TC1 gate then be registered.

That is recorded here as **owner acceptance by instruction**. It is not a
line-by-line review of the manifest, of `harness/*.shen`, of the model, of the
supervisor or of the contract text, and the manifest status says
`owner-accepted`, not `owner-reviewed`, for that reason. It is the same kind
of acceptance as the TC0-A gate's
([G1_SHEN_EVALUATOR_SWITCH.md](../tc0/G1_SHEN_EVALUATOR_SWITCH.md)). The owner
had not seen the row texts, the claim names or the change to the toolchain row
when giving the instruction; they were written to carry it out.

## What "registered" means, exactly

The evaluator calls its verdict a qualification only while both of these hold
(`fh.registered-as` in `harness/gate-core.shen`, the rule the TC0-A gate uses,
unchanged):

- the manifest's `status` is `owner-accepted`;
- `.pi/fenrir-workflow.json` has a check named `tc1-qualification` whose
  command contains `harness/run-tc1-gate.sh`.

Both hold from this change on. Nothing else was needed to make the report say
`registered`, and nothing else was done to it.

The workflow entry declares as evaluator authority, and so protects from
edits by a workflow run: `harness`, `spec/tc1`, `spec/tc0`, `models/tc1`,
`models/tc0`, `fixtures/tc1`, `fixtures/tc0`, `tools/tc1`, `tools/tc0`,
`runtime/tc1`, `runtime/tc0`, `tools/solo5/freerun-pure-call.mjs`,
`tools/solo5/freerun.mjs`, `tools/solo5/pure-call`,
`tools/solo5/remote-build.mjs`, `backends/solo5/pure-call`,
`backends/solo5/remote`, `supervisor`, `tests/tc1`, `tests/tc0`,
`campaigns/tc0/s3`, `campaigns/tc1`, `flake.nix`, `flake.lock`. That is
everything the TC0-A check declares (the TC0-A gate is a row of this one) and
the remote-perform system. Solo5 itself is outside the repository
(`build/vendor/solo5` or `FENRIR_SOLO5`) and is identified in the report by
its commit and the tender's hash, as for the TC0-A guest rows.

## Gaps against the TC0-A precedent, and what was not done

- **No qualification receipt.** A receipt is issued by the workflow controller
  when it runs the check on a supported runner. None has been issued for this
  gate. The runs behind the numbers below were direct runs of
  `sh harness/run-tc1-gate.sh` on a committed tree. The TC0-A Shen gate is in
  the same position.
- **Not a required check of the workflow.** `requiredChecks` in
  `.pi/fenrir-workflow.json` still lists `tc0-a-qualification` only, and
  `requiredClaims` the six TC0-A claims. The workflow controller's completion
  condition is written for the TC0-A slice; adding TC1 to it would change what
  that workflow means, which was not asked for. So a workflow run can execute
  `tc1-qualification` and record its receipt, but does not need it to
  complete.
- **No ledger row for remote perform.** The two rows cite `TC0-B-HANDLERS`
  (user effects and handlers), the nearest row of
  `spec/tc0/requirement-ledger-a.json`. The ledger was not changed.
- **No review.** See Basis.

## What the gate shows

On a committed tree, with the flake's Shen/JIT and Erlang/OTP and Solo5 built
at the pinned commit, verdict PASS means all of the following were observed in
that run, on that commit.

- **Slices H1 and H2** (tail-resumptive handlers, explicit one-shot
  resumption), as before: the Shen model, the JavaScript implementation and
  the C machine in a Solo5 `spt` guest agree step for step on twenty hand
  fixtures, on all 12,693 programs of grammar H up to 7 nodes and on 20,000
  generated programs; six injected defects are each detected, shrunk and
  replayed; the TC0-A gate passes on the same commit.
- **Remote perform, model** (`remote-model`). *Model-level bounded
  exploration.* The whole reachable state graph of six small systems
  (633,517 states, 3,013,418 transitions) satisfies the eight properties of
  EFFECTS.md §12.8; nine model mutants are each killed on the property they
  are aimed at; nine hand schedules pass; a negative control fails as
  required.
- **Remote perform on `spt`** (`remote-run`). *Observed histories on `spt`
  accepted by the model.* The Erlang/OTP supervisor with a caller image and a
  peer image, under 13 hand schedules, 40 seeded schedules and 3 free-running
  runs: every recorded event log is one the model allows, with the properties
  holding on the replay and the images' consoles and the peer's store file as
  the model says; five defect switches of the real system are each caught; a
  negative control fails as required.

## What it does not show

- **No `hvt`.** Every guest ran under the `spt` tender, a seccomp-sandboxed
  process, not a virtual machine. There was no KVM where this was done.
- **No proof.** Nothing here is a theorem: not the typing rules, not the
  one-shot check, not the properties of remote perform. The model rows are
  exhaustive within stated bounds on small systems; the run row is a few dozen
  histories of one two-member system.
- **No controller receipt on a supported runner.** See above.
- **Shrunk programs are small, not minimal.** The reduction rows shrink a
  failing generated program to a small failing one. Nothing says it is the
  smallest.
- **The transport is block-device mailboxes.** Messages between the supervisor
  and an image go through files used as Solo5 block devices, polled by the
  image. No network device, no tap, no distribution across hosts.
- **The supervisor's log is its own account.** The run row checks it against
  the model, the consoles and the store file; it cannot check that the
  supervisor did nothing else. A crash is placed between steps, or at one
  place inside a step (after a peer's commit, before its reply) with the
  image's cooperation; no kill is placed at any other instant.
- **Two free-running runs depend on the wall clock**, with timeouts of 300 ms.
  On a heavily loaded machine the row can fail for that reason alone.
- **One author lineage.** The contract, the models, the implementations, the
  defects and the checks were written together. The checker of the remote
  model reads history variables the model's own steps maintain.
- Liveness, confidentiality, dynamic topology, a failing supervisor, a peer
  written in TC1, typing of remote effects: EFFECTS.md §12.9. Programs above 7
  nodes exhaustively, closures in handler programs, strict replay of handler
  runs: the manifest's `not_covered`.

## Checked before registration

On a scratch clone of the working tree with one snapshot commit:

- `sh harness/run-tc1-gate.sh`: verdict PASS, 21 of 21 required rows, the optional
  coverage row PASS too, all eight claims credited, the TC0-A gate's
  repair-isolation waiver reported; the report says
  `authority: owner-accepted, registered` and `qualification: PASS`. About
  nine minutes.
- `sh harness/run-gate.sh` (TC0-A, manifest untouched): verdict PASS, 15 of
  15 required rows.
- With Erlang made unavailable (`FENRIR_ERLANG` set to a directory that does
  not exist): `toolchain-pinned` and `remote-run` are BLOCKED, the verdict and the
  qualification are BLOCKED, the exit status is 2, and the two remote claims
  and the claims that need the toolchain row are not credited.

These were direct runs, not controller runs. The snapshot they ran on is the
tree of this change.

## How to revoke

Either of these makes every later report of this gate say
`authority: UNREGISTERED` and `qualification: UNKNOWN`, and makes the
controller's record credit no verdict and no claims:

- set `"status"` in `spec/tc1/tc1-requirements.json` to anything other than
  `owner-accepted` (`proposed` is what it was);
- remove the check `tc1-qualification` from `.pi/fenrir-workflow.json`.

Both files are evaluator authority, so a workflow run cannot do this; it is a
change made and committed by a person. Nothing else depends on the
registration: the TC0-A gate does not read the TC1 manifest, and the workflow's
required checks do not include this one. The two remote rows can be removed
from the manifest separately; that changes the manifest's hash, and this
record then no longer describes it.

## Amendment 1, 2026-11-16

Everything above is the record as written on 15 November 2026 and is left as
it was, except the two sentences that point here. Where it gives numbers for
the two remote rows, or the manifest's hash, this amendment replaces them.

### Basis

In conversation on 16 November 2026 the owner (pyrex41) ruled on five of the
open questions of EFFECTS.md §12.10 and instructed that the contract, the
model, the implementation and the gate be brought into line with the rulings:

- question 3: the supervisor may duplicate messages; the clause stays;
- question 4: the outcome `peer_down` is renamed `not_delivered`, and it is
  also allowed when the supervisor drops a request before hand-over while the
  peer is up;
- question 5: on a restart of the supervisor every request issued before the
  restart counts as handed over; only `timed_out` or `reply` is possible for
  it;
- question 6: a restarted caller starts its program from the beginning and
  keeps its durable store;
- question 8: a key reused with a different argument is refused, inside
  `reply`, as the service model's `Conflict`; the peer records a digest of
  the argument with the reply record.

Like the registration, this is **acceptance by instruction given in
conversation, not line review**. The owner had not seen the changed row texts,
the new counts, the property and defect names, the encoding of a conflict, or
what this change decided a supervisor restart keeps and loses; they were
written to carry the rulings out. Questions 7 and 9 were left open and were
not touched.

### What changed

| | Registered on 15 November 2026 | After this amendment |
| --- | --- | --- |
| Contract | `spec/tc1/EFFECTS.md` draft 5 | Draft 6: five more rulings in §12.10; `not_delivered` (§12.4, §12.5); the supervisor's restart (§12.7); `conflict` inside `reply` (§12.2, §12.3) |
| Row `remote-model`, required scope | 6 systems, 9 model mutants, 9 hand schedules | 8 systems, 11 model mutants, 14 hand schedules |
| Row `remote-run`, required scope | 13 hand schedules, 40 seeded, 3 free-running; 5 defect switches | 19 hand schedules, 40 seeded, 4 free-running; 7 defect switches |
| Row `remote-run`, what an accepted run is | Steps, properties, consoles and store as the model says | The same, and the run had one relay process more than the supervisor restarts it recorded; the store is compared record by record with the argument of each |
| Properties of EFFECTS.md §12.8 | 8 | 9: `key-bound-to-argument` is new; `peer-down-not-handed` and `peer-down-sealed` are now `not-delivered-not-handed` and `not-delivered-sealed`, and the first no longer requires the peer to be down and does require that the request was not issued before a supervisor restart |
| Budgets of a schedule | crashes, duplicates | crashes, duplicates, supervisor restarts |
| Wire format between supervisor and images | Version 1 | Version 2: a status in a reply outcome, `conflict` as a third result of acting, the argument in a store record. The code of `not_delivered` is the one `peer_down` had |
| The caller image's program | Key 7 (one retry), key 8 | The same, then key 7 again with another argument |
| Manifest text | | The acceptance texts of the two rows, `contract`, `review` and `not_covered` |

Not changed: the number of rows (21 required, 1 optional), their ids, checks,
required flags and ledger references; the other nineteen rows' acceptance
texts; the eight claims, their rows and prerequisites; the claims' evidence
classes; the aggregation rule; the evaluator's rule for `registered`; the
workflow configuration. No check was loosened: every condition the two rows
had is still required, on more systems, schedules and defects.

Manifest now, SHA-256 of `spec/tc1/tc1-requirements.json`:

```text
899fdedd01a044ed61a44be98ec39a94cb8c1e4609dc6ef1dba735c457c83c93
```

### What the two rows show now

- **`remote-model`.** *Model-level bounded exploration.* The whole reachable
  state graph of eight small systems (834,783 states, 3,931,593 transitions),
  one of them with a supervisor restart in its budget and one performing a key
  with two arguments, satisfies the nine properties; eleven model mutants are
  each killed on the property they are aimed at; fourteen hand schedules pass;
  a negative control fails as required.
- **`remote-run`.** *Observed histories on `spt` accepted by the model.* 19
  hand schedules, 40 seeded schedules (each with one crash, one duplicate and
  one supervisor restart in its budget) and 4 free-running runs; seven defect
  switches of the real system are each caught, among them a restarted
  supervisor that reports `not_delivered` for a request the peer has applied,
  and a peer image that replays its record for a key reused with another
  argument; a negative control fails as required.

### What they still do not show, and what is new among it

Everything under "What it does not show" above stands. In addition:

- **The supervisor's restart is a restart of one Erlang process.** The relay
  process is killed and started again between two steps of a scheduled run,
  while the guests keep running. What the contract says survives is held in
  the memory of another process of the same Erlang VM, not on disk. A restart
  inside a step, a restart in the free-running mode, and the loss of the VM or
  the host are not exercised.
- **The digest of an argument is the argument.** Arguments are I64. Nothing
  here says anything about a peer that compares real digests.
- **A conflict is a pair of integers.** No datatype crosses the image
  boundary yet; the sum type the contract describes is not implemented.
- **Three free-running runs depend on the wall clock**, not two.

### Checked before this amendment

On a scratch clone of the working tree with one snapshot commit, by direct
runs, not controller runs:

- `sh harness/run-tc1-gate.sh`: verdict PASS, 21 of 21 required rows; the
  report says `authority: owner-accepted, registered` and
  `qualification: PASS`.
- `sh harness/run-gate.sh` (TC0-A, manifest untouched): verdict PASS, 15 of 15
  required rows.

There is still no qualification receipt from the workflow controller.

## Amendment 2, 2026-11-16

Everything above is left as it was, except the two sentences near the top
that point to the amendments, which now say there are two. Where Amendment 1
gives numbers for the two remote rows, or the manifest's hash, this amendment
replaces them. The hash under "Manifest now" in Amendment 1 is that of the
manifest between the two amendments.

### Basis

Later on 16 November 2026, in conversation, the owner (pyrex41) ruled on the
two questions of EFFECTS.md §12.10 that Amendment 1 left open, and instructed
that the contract, the validator, the frontend, the model, the implementation
and the gate be brought into line, that the pins be updated and that this
amendment be appended with the new manifest hash:

- question 9: a remote operation belongs to a fourth effect class, `remote`,
  beside ordinary, runtime and durable, and is declared in the source. Effect
  declarations carry their class in the artifact; the type checker requires
  the caller to deal with all three outcomes; the image's connection list is
  derived from the declarations; the caller image of the real system is built
  from a source file through the frontend;
- question 7: a peer with no durable store is allowed only for operations
  declared read-only; any operation that changes state requires a store. A
  read-only operation needs no request key and no idempotency record, and its
  `reply` has a weaker guarantee, to be stated precisely.

As before, this is **acceptance by instruction given in conversation, not line
review**. The owner had not seen the changed row texts, the new counts, the
property, mutant and defect names, the concrete syntax, the artifact schema,
the wire format, or what this change decided where the rulings left a choice.
Those choices are listed in EFFECTS.md §12.10 under questions 7 and 9, and six
of them are raised there as new open questions (11 to 16): among them that a
`handle` of a remote effect is rejected, that each read-only perform is its
own request, and that nothing checks a peer's code against the read-only
marker. They were written to carry the rulings out and are for the owner to
confirm or change.

### What changed

| | After Amendment 1 | After this amendment |
| --- | --- | --- |
| Contract | `spec/tc1/EFFECTS.md` draft 6 | Draft 7: rulings on questions 7 and 9 in §12.10; the remote class (§1, §3, §8, §12.2); read-only operations (§12.3, §12.4); derived declarations and three refusals at assembly (§12.6) |
| Artifact schemas | `tc1-handler-demo/1` and `/2`; a validator option admitted an unhandled effect for the caller image | `/1` and `/2` unchanged and closed to the new fields; `/3` (slice TC1-R1) for programs that declare a remote effect; the option is removed |
| The caller image's program | A hand-assembled fixture (`fixtures/tc1/remote-caller.mjs`), admitted through that option | The source file `examples/remote/ledger-caller.fen`, elaborated by the frontend; the fixture is deleted. The same three keyed performs, then a read-only one with one retry |
| What an image declares of itself | A hand-written line with the caller's connections | A line per image, derived by the build from the program's remote-effect declarations and its binding of effect to member: the caller's connections and operations, the peer's operations and whether it has a store |
| Row `remote-model`, required scope | 8 systems, 11 model mutants, 14 hand schedules | 10 systems, 13 model mutants, 19 hand schedules |
| Row `remote-run`, required scope | 19 hand schedules, 40 seeded, 4 free-running; 7 defect switches | 24 hand schedules, 40 seeded, 4 free-running; 8 defect switches |
| Row `remote-run`, when it is BLOCKED | No Erlang/OTP, or images that cannot be built | The same; the images are not built either when the frontend does not elaborate the source |
| Properties of EFFECTS.md §12.8 | 9 | 11: `read-only-changes-nothing` and `read-reply-from-state` are new; the nine are unchanged |
| Wire format between supervisor and images | Version 2 | Version 3: a mode (keyed or read-only) in a request, `read` as a fourth result of acting |
| Workflow configuration, check `tc1-qualification` | Evaluator authority as listed under "What registered means" | The same, and `frontend` and `examples/remote`, which the remote-run row now depends on. The development check `tc0-candidate-tests` also runs `tests/tc1/remote-artifact.test.mjs` |
| Manifest text | | The acceptance texts of the two rows, `contract`, `review` and `not_covered` |

Not changed: the number of rows (21 required, 1 optional), their ids, checks,
required flags and ledger references; the other nineteen rows' acceptance
texts; the eight claims, their rows and prerequisites; the claims' evidence
classes; the aggregation rule; the evaluator's rule for `registered`; the
workflow's required checks and claims. No check was loosened: every condition
the two rows had is still required, on more systems, schedules and defects,
and the eight model systems, eleven mutants, fourteen and nineteen hand
schedules and seven defects of Amendment 1 are all still among them. The
numbers of the first eight model systems are what they were (834,783 states,
3,931,593 transitions). The unit-suite row runs one more test file.

The rows for slices H1 and H2 are untouched, and so are their inputs: schemas
`/1` and `/2`, grammar H, the generated family and the hand fixtures.

Manifest now, SHA-256 of `spec/tc1/tc1-requirements.json`:

```text
cfe73a575d05fca2de270cc1de3526a24ff03f86482e2509c21e85e8d42e0614
```

### What the two rows show now

- **`remote-model`.** *Model-level bounded exploration.* The whole reachable
  state graph of ten small systems (1,029,806 states, 4,850,067 transitions),
  one of them performing a read-only operation beside a keyed one and one with
  a peer that has no durable store, satisfies the eleven properties; thirteen
  model mutants are each killed on the property they are aimed at, among them
  a read-only operation that writes; nineteen hand schedules pass; a negative
  control fails as required.
- **`remote-run`.** *Observed histories on `spt` accepted by the model.* The
  caller image is built from the source file through the frontend. 24 hand
  schedules, 40 seeded schedules and 4 free-running runs; two of the hand
  schedules are refusals at assembly, of a connection the manifest lacks and
  of a storeless peer image that serves a keyed operation; one retries a read
  across a restart of the peer; eight defect switches of the real system are
  each caught, among them a peer image whose read-only operation writes; a
  negative control fails as required.

### What they still do not show, and what is new among it

Everything under "What it does not show" and in Amendment 1 stands. In
addition:

- **The typing of the remote class is tested, not proved.** The validator and
  the frontend reject the wrong programs of their test suites. Nothing says
  the rule is sound, and a program may still drop an outcome unexamined.
- **The frontend is exercised by this gate on one program.** Its own tests
  (`sh frontend/test.sh`) are development evidence and not a row. The gate
  would notice a frontend that elaborates the caller program wrongly only as
  far as the model, running the same artifact, then disagrees with the image.
- **The peer is not a program of the language.** What it serves is derived
  from the caller's declarations, and that its read-only operation changes
  nothing is observed on the histories run, not checked on its code.
- **No accepted run has a peer without a store.** The model explores one; the
  real system only refuses one that serves a keyed operation.
- **Two of the three assembly checks rest on what images declare.** Nothing
  ties an image file to the build that derived its line.
- **The read-only guarantee is checked in one reading.** "Between issue and
  reply" is checked as a bound on a counter that never decreases.
- **The ninth model system has no retry.** With a retry of its read it
  exceeded the checker's state limit; the retry of a read is explored only
  where the peer's state never changes, and by hand schedules.
- **The operation's name is not on the wire.** One keyed and one read-only
  operation per peer; an I64 or unit argument.

### Checked before this amendment

On a scratch clone of the working tree with one snapshot commit, by direct
runs, not controller runs:

- `sh harness/run-tc1-gate.sh`: verdict PASS, 21 of 21 required rows; the
  report says `authority: owner-accepted, registered` and
  `qualification: PASS`.
- `sh harness/run-gate.sh` (TC0-A, manifest untouched): verdict PASS, 15 of 15
  required rows.

There is still no qualification receipt from the workflow controller.

## Amendment 3, 2026-11-16

16 November 2026, later again the same day • Amends the record above; nothing
above is rewritten, and Amendments 1 and 2 stand as the record of what the
manifest was after each. Where Amendment 2 gives the number of hand schedules
of the row `remote-run`, or the manifest's hash, this amendment replaces
them. The hash under "Manifest now" in Amendment 2 is that of the manifest
between Amendments 2 and 3.

### Basis

Later again on 16 November 2026, in conversation, the owner (pyrex41) ruled
on four of the six questions that draft 7 of EFFECTS.md raised in §12.10, and
instructed that the contract, the frontend, the validator, the build, the
supervisor and the gate be brought into line, that the pins be updated and
that this amendment be appended with the new manifest hash:

- question 11: a remote outcome may not be ignored. The result of a remote
  perform must be scrutinised by a `match`, and may not be discarded, stored,
  returned or passed on; the simplest sound rule is to be chosen, stated
  exactly, and enforced in both the frontend and the validator;
- question 12: each read-only perform is its own request. Confirmed;
- question 14: the binding of a remote effect to the member that serves it
  moves out of the build script into the system manifest, the file that lists
  the members and the declared connections; the build reads it there, the
  supervisor's assembly check uses the same manifest, and an effect with no
  binding, bound to a member not in the manifest, or bound to a member with
  no declared connection from the caller is refused at assembly, each with
  its own message;
- question 16: a `handle` of a remote effect is rejected. Confirmed.

Questions 13 and 15 were not ruled on and are open; the owner said they are
taken up in a following step. Nothing here touches them.

As before, this is **acceptance by instruction given in conversation, not line
review**. The owner had not seen the changed row text, the rule as written,
the manifest's format, the names of the refusals, or what this change decided
where the rulings left a choice. Those choices are listed in EFFECTS.md
§12.10 under questions 11 and 14. Three of them are worth naming here because
they are stricter than the rulings require: a `let` between a remote perform
and its match is rejected; the type of an outcome can no longer be written in
a program at all, which draft 7 allowed; and a caller image built for another
member than the manifest binds is an error of the manifest, not a refusal.
They were written to carry the rulings out and are for the owner to confirm
or change.

### What changed

| | After Amendment 2 | After this amendment |
| --- | --- | --- |
| Contract | `spec/tc1/EFFECTS.md` draft 7 | Draft 8: rulings on questions 11, 12, 14 and 16 in §12.10; the must-use rule (§3); the system manifest, its bindings and five refusals at assembly (§12.6) |
| Typing of a remote perform | Type `Remote B`, taken apart only by an exhaustive match; an outcome could be bound, passed, returned, compared or dropped | Accepted only as the scrutinee of a `match`; the type `Remote B` is written nowhere. Enforced by the frontend and, for any artifact, by the validator |
| Artifact schemas | `/1`, `/2`, `/3` | The same three. `/3` admits fewer artifacts: the two conditions above. `/1` and `/2` are untouched |
| The caller image's program | `examples/remote/ledger-caller.fen` | The same file; four comment lines reworded, no line added or removed. Its artifact is the same bytes (SHA-256 `28e97289cad10cb1483d2bf8053d79ce35281083119979f03fe709dc5cc7bf35`), and so are the caller and peer images |
| Where the binding of `Ledger` to the member `peer` is | A constant of `tools/solo5/remote-build.mjs` | The system manifest `examples/remote/ledger-system.json`, which also names the caller's source and the connection. The build holds no binding; the supervisor is given the manifest's bindings |
| Refusals at assembly | 3: a connection the manifest lacks, `no-store`, `unserved` | 5: `unbound` and `unknown-member` are new; the first of the three is now derived from the manifest's binding instead of the image's line, and `unserved` is judged against the bound member. None was removed or weakened |
| Row `remote-run`, required scope | 24 hand schedules, 40 seeded, 4 free-running; 8 defect switches | 26 hand schedules, 40 seeded, 4 free-running; 8 defect switches. The two new hand schedules are the refusals `unbound` and `unknown-member` |
| Row `remote-model` | 10 systems, 13 model mutants, 19 hand schedules | Unchanged, text and numbers |
| Workflow configuration | | Unchanged. The system manifest is under `examples/remote`, which was already evaluator authority of the check `tc1-qualification` |
| Manifest text | | The acceptance text of the row `remote-run`, `contract`, `review` and `not_covered` |

Not changed: the number of rows (21 required, 1 optional), their ids, checks,
required flags and ledger references; the other twenty rows' acceptance
texts; the eight claims, their rows and prerequisites; the claims' evidence
classes; the aggregation rule; the evaluator; the rule for `registered`; the
workflow's checks, required checks and claims; the model; the wire format;
the images' sources; the properties, mutants, seeds, free-running runs and
defect switches. No check was loosened: every condition the row `remote-run`
had is still required, the 24 hand schedules of Amendment 2 are all still
among the 26 with the same steps and expectations, and every run that is not
about a binding is given the binding the build read from the manifest, which
is the one the constant had.

The rows for slices H1 and H2 are untouched, and so are their inputs.

Manifest now, SHA-256 of `spec/tc1/tc1-requirements.json`:

```text
5b691b824f0fbd076bc230ddbe6bade03613276f1ed0e3787640b4d9630c4433
```

### What the row shows now

- **`remote-run`.** *Observed histories on `spt` accepted by the model.* As in
  Amendment 2, with 26 hand schedules. Four of them are refusals at assembly
  with nothing started: a remote effect the manifest binds to no member; one
  bound to a name that is no member; one bound to a member the manifest
  declares no connection to (the schedule Amendment 2 describes as "a
  connection the manifest lacks"); and a storeless peer image that serves a
  keyed operation.

### What it still does not show, and what is new among it

Everything under "What it does not show" and in Amendments 1 and 2 stands,
with one line of Amendment 2 overtaken: a program can no longer drop an
outcome unexamined. In addition:

- **The must-use rule is tested, not proved.** It is two syntactic
  conditions. The validator's cases are in the unit-suite row
  (`tests/tc1/remote-artifact.test.mjs`); the frontend's are in
  `sh frontend/test.sh`, which is not a row. Nothing says an arm of the match
  does anything with the outcome: an arm may return unit.
- **The gate exercises the rule on one accepted program**, the caller, which
  already had the required shape. No rejected program is a row.
- **The supervisor's treatment of a malformed manifest is not checked.** A
  duplicate binding, a binding for an effect the image does not use, a
  binding for a member that is not a caller, and an image built for another
  member each end a run in an error; each was tried by hand once.
- **One system shape.** The build makes one caller named `caller` and one
  peer named `peer`. No system with two bindings, two peers or two callers is
  built or run.
- **The binding the image was built with is still in the image.** The caller
  sends its requests to the member compiled into it; the supervisor checks
  that this is the member the manifest binds, by what the image declares.
  Nothing ties an image file to the manifest it was built from beyond that
  line.
- **Questions 13 and 15 of EFFECTS.md §12.10 are open:** who vouches for
  read-only, and who owns the signature of an effect that two callers
  declare.

### Checked before this amendment

On a scratch clone of the working tree with one snapshot commit, by direct
runs, not controller runs:

- `sh harness/run-tc1-gate.sh`: verdict PASS, 21 of 21 required rows; the
  report says `authority: owner-accepted, registered` and
  `qualification: PASS`.
- `sh harness/run-gate.sh` (TC0-A, manifest untouched): verdict PASS, 15 of 15
  required rows.

There is still no qualification receipt from the workflow controller.
