# TC1 gate: two remote rows added, and the gate registered

15 November 2026 • Authority record • Amendment 1 of 16 November 2026 is at the end

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

That is the manifest as registered on 15 November 2026. Amendment 1 below
replaces it, and gives the hash of the manifest this record is about now. A
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
