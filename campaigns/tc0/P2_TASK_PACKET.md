# P2 task packet: TC0-B dynamic handlers (draft for owner review)

Status: **draft, not approved.** This packet proposes work; it does not authorize a run,
freeze a contract or issue a verdict. It follows `03_PHASED_EXECUTION_PLAN.md` §6 and §18
item 2, and the M2 entry of `campaigns/tc0/TEAM_EXECUTION.md`. Section references (§n) are to `02_TINY_LANGUAGE_CORE.md`
unless stated.

## 0 Preconditions

P2 starts only after all of these hold:

1. A current-source G1 PASS through the controller on the merged master, with its receipt
   reviewed (M1). The `1db7471` result is historical.
2. This packet approved, with the open questions in §9 answered or explicitly deferred.
3. The candidate shape settled. Branch `claude/s3-enforced-rerun` removes the mutant options
   from `runtime/tc0/pure-call-machine.mjs` and formats it. P2 edits the candidate heavily,
   so that refactor should land (with a recorded round-2 repair) before P2 begins. If it
   cannot, P2 starts on the current candidate and the refactor is rebased afterwards.

The first protected-source edit in P2 makes the affected G1 evidence historical. G2 reruns
every required A row on the final P2 source (03 §6).

## 1 Scope

### 1.1 Increment B1: one handler level per effect

Language added to the closed artifact (schema `tc0-b-handler-demo/1`):

- **Effect declarations** (§2, §5): a named user effect with a finite list of operations,
  each `op: A -> B` at monomorphic types.
- **`handle(effect,[op(x) => e]...,body)`** (§4): exactly one clause per declared operation
  (§5 TC0-EFFECT).
- **`perform(effect,op,e)`** (§4): one argument expression `e : A`, result `B`.
- **Effect sets** on functions and lambdas, and the TC0-EFFECT-CHECK typing (§5): perform
  adds its effect; handle discharges the handled effect from the body and adds the clause
  effects; entry closes all user effects. Reserved effects (Task, Channel, Time, Resource,
  Emit) cannot be handled (§3 Built-in signatures).

Semantics in B1 (§4 reference-step table, §5):

- **Handle entry:** one step installs the handler and enters the body. **Normal exit:** one
  step removes the handler and propagates the body Value unchanged.
- **Ready perform:** one step resolves the innermost active matching handler in the current
  task, saves the suspended segment through it, and enters the clause. The clause runs in the
  lexical environment of the handle node plus the operation argument, under the selected
  handler's outer dynamic handler stack. The selected handler is inactive during the clause.
- **Clause return:** one step restores the saved segment and supplies the clause Value at the
  suspended perform. The handler stays active in the resumed body. There is no user-visible
  resume continuation (§5).
- **Clause trap:** aborts rather than resumes. B1 has no scopes or resources, so abort
  cleanup is the unwind of the clause's frames, then of the suspended segment, then of outer
  frames (§5), one delimiter or frame per Unwind step (§4). The step count of segment discard
  is open question Q3.
- **Dynamic selection:** a closure captures lexical variables, not the handler in scope at its
  definition. A closure defined under H1 and called under H2 uses H2 (§5; §15 "Closure defined
  under H1, called under H2").
- **Validation:** UnhandledEffect in a validated run is a candidate defect, not a trap (§3).
  The validator must make it unreachable for entry-closed artifacts.

B1 permits several handlers in one program, sequentially or for different effects, but has
no fixture that relies on the inactive-intervening-handler rule. "Same effect nested inside
same effect" and "outer E across inner F" are B2.

### 1.2 Increment B2: nesting

- Same-effect forwarding: a perform inside a clause for effect E selects the next outer E
  handler (§5 "performing the same effect forwards outward").
- Outer E across inner F: during an E clause selected through an inner F handler, F is
  inactive and is restored on resume (§15 "Outer E across inner F").
- Inactive intervening handlers: every handler between the perform and the selected handler is
  inactive during the clause (§5).
- Traps inside nested clauses with multiple saved segments.

### 1.3 Explicitly out of P2

- Clause sleep, blocking, cancellation and timers (§1: "B suspension tests requiring timers run
  when C is available"). Listed as C-dependent, not credited in B.
- `TC0-HANDLER-OWNERSHIP` and `TC0-BC-INHERITED-HANDLER-OWNERSHIP` (§5, §15): these need spawn
  and tasks; deferred to C.
- Scopes, resources and the clause-created ownership rules that attach to them (§5).
- Multi-shot or user-visible continuations, handler polymorphism and effect polymorphism (§1
  excludes unrestricted continuations).

### 1.4 Where 02 is ambiguous (decisions for the owner, not the implementers)

These must be answered in the frozen catalog before either lane starts. See §9 for the list.

- **Q1 Perform operand collection.** §4 says tuple/construct/prim/apply/send collect operands
  and "call collects its argument", and the step table has "Ready perform". It does not list
  perform among the collecting forms. Proposal: perform collects its one argument like call
  (Dispatch → Eval argument → CollectReturn → Ready perform).
- **Q2 Tail positions under handle.** TC0-TAIL says handler cleanup frames remain for active
  handlers. It does not say whether a call in tail position of a handle body, or of a clause
  body, is a tail call. Proposal: the handle body is non-tail (the handler delimiter must
  run normal exit), and a clause body is non-tail (the clause-return frame must restore the
  segment). A tail call *inside* either body still reuses that body's return destination.
- **Q3 Segment discard on clause trap.** §4's Unwind row discards "one ordinary frame/handler
  delimiter" per step. It is not stated whether a suspended segment is discarded frame by
  frame (after the clause frames) or as one machine-site step. This changes step counts in
  every trap-in-clause trace.
- **Q4 Clause lexical environment.** "Its definition's lexical variable environment": the
  environment captured when the handle node is entered. Values are immutable, so the only
  question is which bindings are visible. Proposal: exactly the bindings in scope at the
  handle node, plus the clause binder.
- **Q5 Operation types.** §5 says operations are `A -> B` without restricting A or B. Can A or
  B be Arrow (closure) types, and must they be serializable? This affects the generator and
  the equality/serializability rules.
- **Q6 Observable events.** A defines `emit` events (Invoke/Emit/Commit). §5 defines no events
  for perform, clause entry or clause return. Proposal: none; they are visible only in step
  records and sites. A user effect that wants observation calls `emit` in its clause.
- **Q7 Site identity.** For the clause-return frame and the normal-exit step, is the site node
  the perform node, the handle node or the clause body? §13 needs this fixed for replay.
- **Q8 State representation.** §6 lists both `handlers` and `suspended_segments` in Task, while
  §4's Unwind row treats the handler as a delimiter in the continuation. The catalog must fix
  one representation for the state hash and checkpoints. Both machines may represent it
  internally however they like, but the hashed observation must be the same.
- **Q9 Effect-set canonical form.** Effect sets in artifacts need a canonical order (proposal:
  sorted by unsigned UTF-8 bytes, duplicates rejected).

## 2 Contracts frozen before implementation

Each is reviewed, versioned and hashed before the model or candidate lanes start. A change
after freeze is a versioned amendment with distinguishing fixtures (§1).

| Identity | File (proposed) | Must contain |
| --- | --- | --- |
| `tc0-b-handler-demo/1` (artifact schema) | `spec/tc0/handler-demo.json`, `schema_version` | Closed artifact, function and source-map fields; effect declaration shape; `handle`/`perform` AST shapes with arity; effect-set field on functions and lambdas; acceptance of A schemas `/1` and `/2` unchanged; the unsupported list (C tags rejected, not skipped). |
| `tc0-b-handler-catalog/1` (frame/transition catalog) | same file, `version` | Every control and frame shape (handler delimiter, clause-return frame, suspended segment); dispatch, ready, unwind and root rules for B; tail positions (Q2); site rules (Q7); step record fields; event shapes (Q6); trap routing through clauses (Q3); the transition key list used for coverage, enumerated in the catalog itself (see §3.4). |
| `tc0-b-handler-tape/1` (replay tape) | `tools/tc0/` replay schema, documented in the catalog | Header binding catalog hash, profile, artifact/input, oracle, candidate, adapter and toolchain identities; singleton Run choices with epoch, site and domain hash (§13); footer kinds; a state hash that includes handler stack and suspended segments (Q8). |
| Step profile | catalog `profile` / `target_profile` | A uses `pure-call-demo-step/1` targeting `TC0-REF-STEP/0.2`. B either keeps a demo profile (`handler-demo-step/1`) targeting `TC0-REF-STEP/0.2`, or claims `TC0-REF-STEP/0.2` directly (Q10). |
| B requirement manifest | `spec/tc0/tc0-b-requirements.json` | Required/optional rows, acceptance rules, claim mapping (§8 of this packet), versioned like the A manifest. |
| Ledger rows | `spec/tc0/requirement-ledger-b.json` | TC0-EFFECT, TC0-EFFECT-CHECK, §15 B fixtures, §16 handler mutants, each with evidence or gap; C-dependent rows marked deferred to C. |

## 3 Lanes and independence

### 3.1 Lanes

| Lane | Produces | Receives |
| --- | --- | --- |
| Contract (owner review) | §2 artifacts and answers to §1.4 | 02, A catalog, this packet |
| Fixtures | Hand cases with hand-derived traces | Frozen contract only |
| Model | Shen B machine | Frozen contract and fixtures, **not** candidate source |
| Candidate | JS B machine | Frozen contract and fixtures, **not** model source |
| Harness | Validator, generator, reducer, replay, mutants, evaluator rows | Frozen contract, both machines as black boxes |

### 3.2 Rules

1. **Fixtures before machines.** Hand-derived traces for every §15 B fixture (B1: H1/H2
   closure, clause return, clause trap, sequential handlers; B2: same-effect forwarding, outer E
   across inner F, nested trap) are written and committed before either machine runs. The
   fixture lane derives them by hand from the catalog. This addresses the review finding that
   only one A trace was hand-derived.
2. **Lane exports, not instructions.** Each machine lane works in an exported tree (git archive
   at the contract commit) with the other lane's paths removed, as `tools/tc0/s3-prepare.mjs`
   does for repairers. A shared filesystem or shared history is not lane isolation.
3. **Different authors where possible.** The model and candidate lanes should not share an
   author lineage. If both are written by the same model family, the record says so, and the
   G2 claim is scoped to single-lineage differential agreement as G1 is (see the README's
   "Limits of the TC0-A PASS").
4. **The frozen public contract** is: the catalog JSON, the artifact schema, the tape schema,
   02 §§1–5 and §13–17 as amended for B, and the fixtures. It excludes both machines, the
   mutants module and the evaluator.
5. **Coverage keys come from the catalog.** The B coverage tool reads its transition keys from
   `spec/tc0/handler-demo.json`, rather than restating them in JavaScript as the A tool does.

### 3.3 Spec defects

A lane that believes the contract is wrong files a proposal; it never edits the catalog,
fixtures or model to match its implementation (03 §17).

## 4 Paths and authority

### 4.1 Allowed paths per lane (proposed; see Q11)

| Lane | Allowed |
| --- | --- |
| Contract | `spec/tc0/handler-demo.json`, `spec/tc0/tc0-b-requirements.json`, `spec/tc0/requirement-ledger-b.json`, 02 amendments as a separate reviewed change |
| Fixtures | `fixtures/tc0/handler-hand-cases.mjs` |
| Model | `models/tc0/pure-call-machine.shen` (extended) or a new `models/tc0/handler-machine.shen`, plus `models/tc0/pure-call-oracle.shen` entry points |
| Candidate | `runtime/tc0/pure-call-machine.mjs` (extended) or a new `runtime/tc0/handler-machine.mjs` |
| Harness | `tools/tc0/pure-call-artifact.mjs` (validator), generator/reducer/replay/coverage/mutant modules under `tools/tc0/`, B checkers, `tests/tc0/` |

### 4.2 Protected A baseline

- A schemas `/1` and `/2` keep their exact semantics. Every A hand case, the exact-arithmetic
  ledger, the exhaustive-small scope at 5 nodes and the three A mutant rows rerun unchanged
  as required G2 rows.
- If the machines are extended in place (Q11), A evidence on the new source is fresh evidence
  for the extended machine, not a continuation of the old receipt.

### 4.3 Changes that need owner review

- Freezing or amending any §2 contract.
- Registering or changing the B gate, its manifest, its `authorityPaths` or claims.
- Any change to the A catalog, A fixtures, A model or the A gate.
- Accepting any waiver (isolation, scope, lane independence).

## 5 Development checks

Registered with the workflow controller as `kind: development`. They give the lanes semantic
back pressure; none is a qualification verdict.

| Check | Content | Latency target |
| --- | --- | --- |
| `tc0-candidate-tests` (extended) | Validator negatives, machine unit tests, replay, mutants, for A and B | ≤ 30 s |
| `tc0-pure-call-oracle` (extended) | Fresh Shen-vs-candidate agreement on A and B hand cases, then strict replay | ≤ 60 s |
| `tc0-b-coverage` | Catalog-derived B transition coverage over hand cases | ≤ 30 s |
| `tc0-b-exhaustive-smoke` | Exhaustive B grammar at a small bound (measured; target ≤ 3 nodes beyond A's leaves) | ≤ 120 s |

Heavy campaigns (generated families, full exhaustive bound, reduction) run in a separate tier,
one at a time, under the budgets in §8.

## 6 Mutants

Each mutant is an evaluator-side source transform in `tools/tc0/pure-call-mutants.mjs` (the
pattern on `claude/s3-enforced-rerun`), never an option in the candidate. Per §16, a kill
requires **the expected discrepancy classification and a retained reduced reproducer with
exact replay**. A trace difference alone, a crash or a budget exhaustion is not a kill. This
closes the §16 gap the 17 October review found in the A rows.

| Mutant | Increment | Transform | Expected classification | Killing fixture |
| --- | --- | --- | --- | --- |
| `lexical-handler` (skipped handler, §16) | B1 | Closures capture the handler in scope at definition | `wrong-handler-selected`: first divergence at the step after Ready perform; different clause node entered | H1/H2 closure |
| `handler-kept-on-exit` | B1 | Normal exit propagates the Value without removing the handler | `stale-handler-selected`: a later perform under an outer handler enters the inner clause | Sequential handlers, same effect |
| `forgotten-resume` | B1 | Clause return becomes the handle's result; the saved segment is discarded | `missing-resumed-segment`: first divergence at clause return; body continuation steps absent | Clause return then body emit |
| `double-resume` (§16) | B1 | Clause return restores the segment and re-pushes it, so the continuation runs twice | `duplicated-resumed-segment`: repeated emissions or repeated steps after resume | Clause return then body emit |
| `handler-leak-on-unwind` | B1 | Unwind skips the handler-delimiter discard step | `unwind-step-mismatch`: depth and step count differ during trap unwind | Clause trap; body trap under handle |
| `outermost-handler` | B2 | Selects the outermost matching handler instead of the innermost | `wrong-handler-selected` | Same-effect nesting |
| `intervening-active` | B2 | Selected and intervening handlers stay active during the clause | `wrong-handler-selected` on a forwarded perform; possibly non-termination (classified, not counted as a kill unless the expected selection divergence is observed first) | Same-effect forwarding; outer E across inner F |

**Equivalent-mutant control (required, §16).** `clause-lookup-by-sorted-name`: clause
selection searches the clause list sorted by operation name instead of declared order. Exactly
one clause per operation exists, so it is semantically equivalent. It must produce byte-identical
traces on every hand case, generated family and exhaustive program. Any difference is an
evaluator false positive and fails G2.

The A rows' kill rule should be tightened to the same standard as part of G2 (classification
plus retained reproducer for reverse-operands, bad-overflow and arm-by-position).

## 7 Discovery, reduction, replay and repair

- **Generator.** A finite, deterministic B family that uses handle, perform, clause return and
  clause trap in every case, plus a B exhaustive-small grammar G_B (measured bound; at most two
  handlers and one effect with two operations to start). Generator-derived predictions of the
  mutant outcome are checked, as in A.
- **Invalid family.** Named single mutations: missing or duplicate clause, clause type
  mismatch, perform of an undeclared operation, unhandled effect at entry, handler for a
  reserved effect, effect-set mismatch on a lambda. Each records the exact rejection class, and
  invalid artifacts never execute.
- **Reduction.** Typed rules that keep validity and the effect discipline, for example
  `handle-to-body` when the body performs nothing, `drop-unused-clause-effect`,
  `perform-to-argument` only where types allow, and `inline-clause`. Every proposal is
  revalidated and confirmed against fresh Shen and candidate observations, and accepted only
  when it keeps the expected classification.
- **Replay.** Exact original and minimized replay on `tc0-b-handler-tape/1`, with the
  divergence epoch retained.
- **S3 repair for B.** One B defect (proposed: `forgotten-resume`) goes through the S3 packet
  with failing-test withholding and held-out regressions. Repairer isolation must be enforced,
  or the waiver is recorded explicitly by the owner.

## 8 G2 exit criteria and budgets

### 8.1 Required rows (proposed)

1. Clean committed HEAD; pinned toolchain.
2. Unit suite (A and B), no skips.
3. A hand cases: fresh Shen agreement and strict replay (all 24).
4. A exact-arithmetic ledger; A exhaustive-small at 5 nodes; A mutants with classification and
   retained reproducer.
5. B hand cases: agreement with the hand-derived traces **and** fresh Shen/candidate agreement,
   then strict replay.
6. B invalid family: exact rejection classes; no execution.
7. B exhaustive-small G_B at its declared bound: full agreement, cap hits reported as UNKNOWN.
8. B catalog coverage from the catalog JSON: every B key covered or listed with a reason.
9. Each B mutant (B1 rows, and B2 rows if B2 is in scope): expected classification observed,
   reduced reproducer retained, exact replay of original and minimized.
10. Equivalent control: zero differences.
11. Generated B discovery, reduction and exact replay for one B mutant.
12. Fresh S3 evaluation of the B repair; repair-isolation record.
13. Candidate sandbox probes; B requirement ledger check.

C-dependent fixtures are listed in the ledger as deferred to C. They are not optional rows
and do not count toward PASS.

### 8.2 Claims

The six A claims, rescoped to A+B, plus `dynamic-handler-selection` (rows 5, 7, 8) and
`handler-mutants-classified` (rows 9, 10). A claim is credited only when all its rows and the
prerequisites pass.

### 8.3 Budgets (codex defaults)

- B campaigns: 32 cases, 200 AST nodes, 200 reference steps, 100 reduction attempts.
- Package ceiling: two hours per package, at most six repairs, no renewal.
- One heavy campaign at a time.
- Watchdogs: 30 s ordinary invocation, 300 s discovery/reduction.
- Output caps: 4 MiB per stream, 8 MiB per trace, 256 MiB retained milestone bundle.
- A required exhaustive scope that hits its cap is UNKNOWN, not PASS.

## 9 Non-goals and owner decisions

### 9.1 Non-goals

C features (tasks, scopes, channels, cancellation, resources, virtual time), clause suspension,
inherited handler ownership, native or Solo5 execution, surface syntax, compiled scheduling
profiles, performance work, and any full-TC0 or backend claim (03 §6 Gate G2).

### 9.2 Decisions needed

- **Q1–Q9** in §1.4 (semantic gaps in 02 §4–§5).
- **Q10 Profile.** Should B tapes keep a demo step profile targeting `TC0-REF-STEP/0.2`, or claim
  `TC0-REF-STEP/0.2` directly?
- **Q11 Extend or add.** Should the A machines be extended in place (one machine, A schemas
  still accepted), or should B get new files that import nothing from the A machines? In-place
  extension keeps one candidate; new files keep the A baseline byte-identical.
- **Q12 Increments.** Should G2 require B2 (nesting), or should B1 get its own gate (G2a)
  first?
- **Q13 Lane authorship.** Who writes the fixtures, and which model or person writes each
  machine lane? This decides whether G2 can claim more than single-lineage agreement.
- **Q14 Harness language.** 03 §18 says to retire Python runners and add no new semantic
  harness logic in Node, but the A harness is Node and Python. Which language does B harness
  logic go in?
- **Q15 Repair isolation.** Will the B repair require enforced isolation, or will a recorded
  waiver be accepted again?
