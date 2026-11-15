# TC1 durable effects: effects the host discharges

Draft 1 • 15 November 2026 • For owner review

**Status.** Written before its machines, which were then written from it: a
Shen model ([models/tc1/durable-machine.shen](../../models/tc1/durable-machine.shen)),
an independent JavaScript implementation
([runtime/tc1/durable-machine.mjs](../../runtime/tc1/durable-machine.mjs)) and
the C machine of the Solo5 guest, driven over control protocol
[v2](../solo5/pure-call-control-v2.md). Nothing here is qualified. It is the
third effect class of [04_DIRECTION_AMENDMENT.md](../../04_DIRECTION_AMENDMENT.md)
§4 (ordinary, runtime, durable), the one [EFFECTS.md](EFFECTS.md) §8 named and
left unimplemented, and it is what stage A2 of the application example
(amendment §8) needs: a handler written in Fenrir whose durable operations cross
the Solo5 boundary as protocol requests while "the guest holds no database".
Every choice this text makes that the sources leave open is marked
*provisional* and listed in §12.

Slice **D1** is TC1 (TC0-A plus EFFECTS.md, slices H1 and H2) plus what is
below. Nothing in EFFECTS.md changes for an artifact that declares no durable
effect. Tasks and channels (CONCURRENCY.md) are not part of D1: an artifact of
this slice has none (§11).

## 1 Effect classes

An effect declaration of schema `tc1-durable-demo/1` carries a class:

```text
effect Ask   ordinary { ask : I64 -> I64 }
effect Store durable  { commit : Tx -> Reply }
```

Artifact encoding: `{"name": ..., "class": "ordinary" | "durable", "operations": [...]}`.
Every effect declaration of this schema has the field; older schemas have no
such field and are unchanged.

- An **ordinary** effect is exactly an EFFECTS.md effect: it must be handled
  inside the program, and its performs are not observations.
- A **durable** effect is one the program may leave unhandled. A perform of it
  that no user handler encloses is a **host request**: the program stops, the
  host discharges the operation under its storage contract, and the program
  continues with the host's reply (§4). The host is the handler that "carries a
  storage contract" in amendment §4; Fenrir code never is.
- The runtime effects stay reserved names (`Emit`, `Task`, `Channel`, `Time`,
  `Resource`) and cannot be declared with either class. (*Provisional*: `durable`
  is the only host-discharged class in D1. The amendment's examples —
  transaction, durable job, durable inbox — are all operations of declared
  durable effects, not built-in names. A volatile host effect, for example a
  client reply that does not survive a crash, would be a fourth class; D1 does
  not need one, because a handler's response is its result.)
- Operation types of every effect stay serializable (EFFECTS.md §1). For a
  durable effect this is not a restriction of the slice but of the class: an
  argument and a reply cross a process boundary as bytes (§5).

## 2 Effect sets and the residual row

Typing is EFFECTS.md §3 unchanged, with one rule replaced:

- The entry function's effect set may contain `Emit` and **durable** effects,
  and no ordinary effect. The durable effects in it are the program's
  **residual effects**: those the host must be able to discharge.

The residual row is the image's **capability manifest** (vision §7, amendment
§4). It is read from the artifact, not from a run: the entry's effect set,
with each residual effect's full declaration (operations, argument and result
types, the datatypes they mention). Before running an image the host checks the
manifest against the storage contracts it carries and **refuses to run an
image** that has a residual effect, or an operation of one, or an operation
type, that no contract of the host discharges. A refusal is a deployment
outcome, not a run: no step is taken. A host may carry more contracts than an
image needs; an image cannot obtain a capability its manifest does not name,
because a perform of an effect outside the manifest fails validation (it would
make the entry's set larger than declared).

The entry's argument may be any serializable type in this slice (the request a
handler receives), not only I64 (*provisional*; §10 says what the harness
supplies).

## 3 Selection: user handler first, then the host

`perform(E, op, v)` with E durable selects, as for every effect, the innermost
*active* handler for E (EFFECTS.md §4). If there is one, the perform is an
ordinary handled perform: the clause runs, nothing crosses the boundary, and
nothing is observed (EFFECTS.md §5). Only when **no active handler for E**
exists is the perform a host request. An *inactive* handler (the selected
handler and those between it and the perform while one of its clauses runs) is
not a candidate, so a perform of E inside a clause of a handler for E goes to
the next handler out, and to the host when there is none.

*Provisional:* a user handler **may** enclose a durable effect. It is a
reinterpretation, typically a test double (an in-program store), and claims no
storage contract; the effect is then not residual on that path, and if no path
leaves it residual it is not in the entry's set and not in the manifest. The
alternative, forbidding `handle` of a durable effect, is one validator rule;
it would make "a durable effect is discharged only under a storage contract"
true by construction, at the cost of testing a handler in-program.

## 4 Host requests

When a perform of a durable effect E selects no handler, with argument v
(already collected, EFFECTS.md §2: `perform` is strict in its argument):

1. **Request.** The machine takes one step. It records the observation
   `HostRequest{seq, effect E, operation op, value v}` and stops in phase
   `HostWait`. Nothing else changes: no frame is pushed or popped, the
   environment is the perform site's, and the whole continuation — every frame,
   handlers included — is the suspended segment. `seq` is the number of host
   requests the run has made before this one: 0, 1, 2, … with no gap or reuse.
2. **Wait.** In `HostWait` the machine can take no step on its own. The host
   holds the continuation as a **one-shot resumption**: it answers exactly once,
   with a reply r, or never (the run then has no outcome; §7).
3. **Reply.** The host's reply is checked at the boundary against op's result
   type B (§5). If it is a value of type B, the machine takes one step: it
   records `HostReply{seq, value r}` and continues in phase Value with r as the
   value of the perform, at the perform site, with the same frames. The perform
   behaves from here on as if a tail-resumptive clause had returned r. A reply
   that is not a value of type B is a **host-contract violation** (§5); the
   machine takes no step.

There is exactly one reply step per request step, immediately after it: no
step of the program happens between a request and its reply, and a second
reply to the same request is impossible (the machine is no longer in
`HostWait`, and a reply names its request's `seq`; §6).

The host never resumes a segment twice and cannot discontinue it: D1 has no
host-initiated abort (*provisional*). A host that cannot discharge an operation
says so in the reply, which is why a durable operation's result type is
normally a datatype with a failure constructor (`Unavailable`, `Refused`, …)
rather than a bare value. Whether a host should also be able to *discontinue*
the resumption (and so unwind the program) is listed in §12.

## 5 Replies at the boundary

A reply is a serializable value in the artifact's value encoding
(`["unit"]`, `["bool",b]`, `["int","n"]`, `["bytes","hex"]`,
`["tuple",v...]`, `["data",Type,Constructor,v...]`). It is well typed for B when,
recursively:

- B is `Unit`, `Bool`, `I64` (a canonical decimal in range), `Bytes`
  (lowercase hex, even length) or `TrapCode` (one of its constructors) and r is
  that kind of value;
- B is `(Tuple B1 ... Bn)` and r is a tuple of n components, each well typed;
- B is a declared datatype and r names that datatype and one of its
  constructors with exactly that constructor's field count, each field well
  typed for the declared field type.

An ill-typed reply is the **host's** contract violation, not the program's: it
is not a trap, the program's handlers and unwinding do not run, and the run
ends with execution `HostViolation` and no outcome. The reason (the path to the
first ill-typed component) is diagnostic only. Compiled code must refuse such a
reply in the same place, before any of the program's code sees it; in the Solo5
guest that is the guest refusing the host's frame (v2 §4, `BadReply`).

## 6 Observations

The observations of a run are, in order: its `Emit` events and its host
requests, interleaved as they happened; the host's replies, each right after its
request; and the outcome. Unlike a perform of a handled effect (EFFECTS.md §5),
**a host request is an observation**: the host sees it. A compiler must
preserve, exactly: the sequence of host requests and their arguments; the
position of every emit relative to every host request; and that the program
continues only with the reply. It may not merge, split, duplicate, drop,
reorder or speculate host requests, nor move an emit across one. The replies are
inputs: a run is a function of (program, entry input, the host's replies in
order), and of nothing else.

Within one request–reply pair nothing of the program is observable, so a
compiler is free to do anything that is not observable between them (there is
nothing: the program does not run).

## 7 Reference steps and runs

Properties of the reference machines; not obligations on compiled code.

| Step | Site | After | Depth | Events |
| --- | --- | --- | --- | --- |
| Ready `perform` of a durable effect with no active handler | the perform node, rule `Ready` | `HostWait` | unchanged | `HostRequest` |
| `HostReply` | the perform node, rule `HostReply` | `Value` | unchanged | `HostReply` |

Every other step is EFFECTS.md §6 unchanged; a durable perform that selects a
user handler takes exactly the handled steps.

Event shapes, with fields in this order:
`{"kind":"HostRequest","task":"0","node":N,"seq":S,"effect":E,"operation":op,"value":v}`
and `{"kind":"HostReply","task":"0","node":N,"seq":S,"value":r}`, `S` a
canonical unsigned decimal string.

A run is driven by a host, given either as the list of its replies in order or
as a function from a request (`seq`, effect, operation, value) to a reply. It
ends with one of these executions:

| Execution | Meaning |
| --- | --- |
| `Completed` | terminal, with an outcome (Ok value or Trap), as in TC1 |
| `BudgetExhausted` | the step bound was reached first |
| `AwaitingHost` | the machine is in `HostWait` and the host gave no reply (a reply list ran out) |
| `HostViolation` | the host's reply to the last request was ill-typed (§5) |

`AwaitingHost` and `HostViolation` have no outcome and are never a pass of a
program check; `HostViolation` is a pass only of a check whose expectation is
that very violation.

## 8 Transactions: one commit, as data

The service handler of stage A2 must write business state, a durable job and
the request-deduplication entry *atomically* (amendment §8). The library
interfaces `atomic`, `once` and `jobs.stage` could be designed in two ways:

- **(a) a host round trip per operation:** `atomic` opens a host transaction,
  each read and write inside its body is a host request, and the end of the body
  commits; or
- **(b) one commit, as data:** the body of `atomic` *computes* the transaction:
  the whole serializable write set with its preconditions; `atomic` then
  performs **one** durable operation, `Store.commit(tx)`, and the host installs
  the transaction in one step or not at all.

**D1 chooses (b)** (*provisional*), for these reasons:

1. *Atomicity becomes one obligation of the host, at one point.* Under (b) the
   storage contract says one thing: a commit request is applied to one tenant's
   store as a pure function, entirely or not at all, and its reply says which.
   That is exactly A0's and A1's storage assumption ("a transaction is a pure
   function on one tenant's store, installed atomically"; A1's `submit` is one
   step), so the A1 model is literally the host of the refinement check.
2. *(a) holds a transaction across scheduling points.* Every host request is a
   point where the guest is suspended and the host can do anything else
   (amendment §14 makes a durable operation a scheduling point). Under (a) the
   transaction stays open across several of them, which §14 forbids ("a
   transaction or exclusive borrow may not be held across a scheduling point
   other than its own operations") unless the contract adds isolation and
   rollback on guest crash, a lost reply in the middle of a transaction, and a
   timeout for a guest that never commits. None of that is needed under (b).
3. *It fits SQLite on the host side.* One `BEGIN IMMEDIATE … COMMIT` per
   request, never a transaction open while the guest computes; "busy" and an
   indeterminate commit become reply values of one request (amendment §8, A3).
4. *It is a typing rule, not a runtime protocol.* The body of `atomic` is a
   function whose effect set is **empty** (it may not even `emit`): it cannot
   perform `Store` or anything else, so "no host round trip inside a
   transaction" is checked by the existing effect typing (EFFECTS.md §3). A
   program that tries is rejected statically.

What (b) costs: a decision that needs to *read* the store first cannot be made
inside the transaction. The library therefore gives the transaction
**preconditions** evaluated by the host inside the commit: `once` is the
request-key check (absent: apply; present: do nothing and return the recorded
answer), and a job delivery's guard is "this job is still pending". A program
that wants a general read-then-write must express the read's assumption as a
precondition of the commit and handle the "precondition failed" reply
(optimistic concurrency). D1 needs no general read; A2's handler needs none.

`once` is therefore not a separate durable operation: it is the key-table check
inside the same commit, and `jobs.stage` is a write in the same write set. The
service library and its storage contract (the datatypes, and what the host's
commit does to a tenant's store) are in
[spec/service/HANDLER.md](../service/HANDLER.md).

## 9 Capabilities

Amendment §4 asks for a tenant or storage capability to be "a value with an
indexed type". TC1 has no indexed or abstract types, so in D1 a capability is an
ordinary serializable value (in A2, `(Tenant t)`) that the program receives in
its input and passes back in each commit; the host acts on the store it
designates. A program **can forge one** (*provisional*, and the weakest point of
this draft): nothing in D1's typing stops a handler from writing `(Tenant 1)`.
In A2 such a program is caught dynamically by the authority property (A1
`authority.frame`), not rejected. What closes this is either an abstract
capability type the program cannot construct (then the mutant is rejected
statically), or a host that checks each commit's capability against the one the
request was granted (then it is refused at run time); both are listed in §12.

## 10 Entry input

A run's entry input is a serializable value of the entry's argument type,
validated with the artifact. The harness programs of this slice take it from
the case (`input` field of a fixture, the request of a service step); the Solo5
guest has it lowered into its image with the program (v2 §3), so one image
entry is one (artifact, input) pair. Older schemas keep input `["int","0"]`.

## 11 What D1 leaves out

- Tasks and channels with durable effects: what a durable request means for a
  task that is cancelled while waiting (amendment §14, open point) is not
  decided; a D1 artifact has no task forms.
- A host-initiated discontinue (§4), timeouts, and an indeterminate reply as a
  language notion (it is a reply value of the storage contract).
- Volatile host effects (§1).
- Multi-shot resumption of a host request (never: the host holds one-shot
  resumptions only).
- Closures in requests or replies (operation types are serializable).

## 12 For the owner to confirm

1. The spelling of the class: `class: "durable"` in the artifact, and only two
   classes (`ordinary`, `durable`) are declarable (§1).
2. Residual effects are exactly the durable effects in the entry's set, and the
   manifest is their full declarations; a host refuses an image it cannot
   discharge (§2).
3. A user handler may enclose a durable effect, as a reinterpretation (§3).
   Alternative: forbid it.
4. Selection is "innermost active user handler, else the host" (§3).
5. A host request is one step to `HostWait` and one `HostReply` step, both at
   the perform node; depth unchanged (§4, §7).
6. Request sequence numbers start at 0 and count requests of the run (§4).
7. An ill-typed reply is the execution `HostViolation`, not a trap, and nothing
   of the program runs (§5).
8. No host-initiated discontinue in D1; failures are reply values (§4).
9. Host requests are observations; replies are inputs (§6).
10. Transactions as data: `atomic` performs one `Store.commit(tx)`; its body
    has an empty effect set; `once` and job guards are preconditions inside the
    commit (§8).
11. Capabilities are forgeable values in D1 (§9): accept for the draft, or
    require an abstract capability type or a host-side capability check before
    A3.
12. The entry may take any serializable argument when the artifact declares a
    durable effect (§2, §10).
13. No tasks in D1 artifacts (§11).

## 13 What is checked

**Typing.** §1–§2 and §10 are stated as rules in
[TYPING.md](TYPING.md) §6.1 (the Program rule's residual entry row, the class
as a structural check), and both artifact validators judge every durable
artifact: the JavaScript one, and the Shen one (structure, derivation search,
fixed checker). `sh typing/run.sh` finds both accept all 16 hand fixtures with
their inputs, the frontend's durable programs and `examples/service/accepted-job.fen`
with its mutants, and agree on every program `tests/tc1/durable-artifact.test.mjs`
validates, on 244 single-point mutants and on 17 boundary probes whose verdicts
were written from this text first. The claim is "derivable under rule set R,
soundness not yet proved".


See [harness/README.md](../../harness/README.md) ("TC1-D1: durable effects" and
"Service example A2"). In short: hand fixtures with expectations written from
this text before any machine ran; the Shen model, the sandboxed JavaScript
implementation and the Solo5 guest (over control protocol v2) step for step;
injected defects in the JavaScript implementation; validator tests; and the
A2 refinement check of the Fenrir service handler against the A1 model. All of
it is *bounded exploration passed*, development grade, `qualification:
UNKNOWN`.
