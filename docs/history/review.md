# Fenrir and Gleipnir plan review

## Overall assessment

The plans are strong, especially in their treatment of replay, trust boundaries, incomplete results, and independent evidence. The central approach—an executable semantic contract, an independently implemented candidate, and counterexample-driven development—is sound.

**Recommendation: proceed with P0 and semantic prototyping, but do not freeze TC0 yet.** Several unresolved details determine observable behavior, not merely implementation representation. Freezing before resolving them would risk making implementation choices accidentally authoritative.

### Review scope

Reviewed completely:

- `01_FULL_VISION.md`
- `02_TINY_LANGUAGE_CORE.md`
- `03_PHASED_EXECUTION_PLAN.md`

`DETERMINISTIC_LANGUAGE_SPECIFICATIONS.zip` contains byte-identical copies of these three documents; it adds no separate specification.

This is a document review. Upstream capabilities and feasibility spikes were not independently verified or executed. Line references below refer to the documents as reviewed and may shift after edits.

## 1. Strengths to preserve

### Clear separation of claims

`01_FULL_VISION.md:128` distinguishes checker replay, scenario replay, semantic replay, machine replay, exhaustive exploration, and production conformance.

This avoids treating reproducible randomness as deterministic execution, or successful replay as proof of correctness. Preserve this distinction in the CLI and evidence format.

### Honest treatment of limits

The documents consistently distinguish modeled resource exhaustion, incomplete exploration, infrastructure watchdogs, candidate crashes, and valid but undesirable program outcomes.

The prohibition against promoting UNKNOWN to PASS should become a centrally tested evaluator invariant, not just a workflow convention.

### Sensible implementation strategy

A process adapter before Solo5, a conservative interpreter before a compiler, and safe memory management before reuse optimization are good decisions.

Instruction emulation and Unikraft should remain optional rather than prerequisites for validating language semantics.

### Oracle protection

Separate authority changes from implementation changes, retain original counterexamples, use fresh campaigns, and require an equivalent mutation control. These are valuable safeguards.

### Production claims remain appropriately qualified

The plans acknowledge that serial simulation does not establish weak-memory correctness, production capture requires complete nondeterminism capture, and real finalization differs from abstract release.

## 2. Issues to resolve before freezing TC0

### 2.1 Child-failure propagation has an observable timing ambiguity

**References:** `02_TINY_LANGUAGE_CORE.md:115–119`

Child failure does not asynchronously trap the parent, but a child trap causes the scope to request cancellation of unfinished children. The specification does not clearly define when cancellation happens:

1. Immediately when the child terminates.
2. When the parent next runs.
3. Only after the scope body finishes and enters its join phase.

These choices produce different traces. Consider this pseudocode:

```text
scope:
    spawn(child_that_traps)
    spawn(child_that_emits_repeatedly)
    parent_computes_forever
```

Depending on the interpretation, the emitting sibling is cancelled or continues indefinitely.

Another distinguishing case is:

```text
scope:
    t = spawn(child_that_traps)
    result = await(t)
    handle_failed_outcome(result)
```

Does the scope still produce `ChildFailed` after the parent observes and handles the failure? The wording suggests yes, but this should be explicit.

**Required decisions:**

- Which transition latches scope failure.
- Which transition requests sibling cancellation.
- Whether the body continues.
- Whether awaiting failure acknowledges it or leaves scope failure unchanged.
- Precedence between body trap, body cancellation, and child failure.
- How children behave after the scope closes to new spawns.

Add distinguishing fixtures for each decision.

### 2.2 Resource lifetime and task ownership need an explicit region calculus

**References:** `02_TINY_LANGUAGE_CORE.md:39`, `:113–119`, `:147–149`

The intended guarantees are clear, but their enforcement rules are incomplete. Consider:

```text
scope:
    resource("r", r):
        spawn(() => use(r))
    emit("after-resource", unit)
```

The child belongs to the enclosing task scope. The resource body can finish before that scope joins its children.

The contract must specify whether this program:

- Is rejected because the resource does not outlive the child.
- Creates an implicit nested task scope inside the resource.
- Delays release until borrowing children finish.

These choices affect validation, scheduling, traces, and expressiveness.

The type grammar exposes `region`, but does not define region binders, ordering, closure-capture constraints, or typing judgments for lifetime-creating constructs.

**Recommendation:** Publish a small formal region system covering:

- Region creation and nesting.
- Handle accessibility.
- Closure captures.
- Handler captures inherited by children.
- Resource borrowing versus ownership.
- Returning values from scopes.
- Spawn lifetime obligations.

Use accepted/rejected program pairs, particularly when resource and task-scope lifetimes differ.

### 2.3 Effect-handler context is insufficiently precise

**References:** `02_TINY_LANGUAGE_CORE.md:70–76`

“Nearest lexical/dynamic handler” leaves open a fundamental language choice:

```text
f = function_that_performs_E_defined_under_handler_H1
call_f_under_handler_H2
```

Does `f` use the handler active where it was defined or where it is called?

A second ambiguity arises across intervening handlers:

```text
handle E:
    handle F:
        perform E
```

Is the inner `F` handler available while the `E` clause executes? “Under the handler’s enclosing effect context” suggests not, but this needs an explicit rule.

This interacts with suspended clauses, resources in suspended computations, cancellation, and handler snapshots inherited by children.

**Recommendation:** Define the handler stack and continuation split:

- Which frames are suspended.
- Which handlers remain active during clause execution.
- Which environment binds clause variables.
- How normal return reinstates the suspended computation.
- How trap/cancellation unwinds both contexts.
- Exactly what a child copies.

Provide hand-derived step traces.

### 2.4 Built-in result types and signatures are missing

**References:** `02_TINY_LANGUAGE_CORE.md:27–35`, `:45–59`, `:115`, `:135–141`

The language uses `Ok(T)`, `Cancelled`, `Failed(TrapCode)`, `Sent`, `Closed`, `Item(T)`, and `End`, but does not define these built-in datatype families or their representation in a monomorphic language.

Other details to specify:

- Exact primitive names and signatures.
- Function return/effect annotations.
- Lambda return/effect annotations or permitted checking/inference rules.
- Whether `await` is repeatable.
- Whether a task may await a sibling.
- Whether multiple tasks may await the same child.
- The type and representation of `TrapCode`.
- Index bases for tuple projection and byte indexing.
- Label and byte-literal constraints.

**Recommendation:** Add a normative built-in signature table and declaration schema before implementing the full validator.

### 2.5 Exact-step semantics must be a published contract

**References:** `02_TINY_LANGUAGE_CORE.md:66`, `:101`, `:155–159`

Scheduling occurs at every reference step, including pure evaluation. CEK-frame choices therefore determine observable schedules, cancellation opportunities, and budget consumption.

Applying an operation in the same step as its last operand returns, rather than in a separate step, can determine whether cancellation occurs before or after commit.

The required frame catalog is appropriate, but these choices are not merely representation details under exact-step replay.

**Recommendation:** Publish normative transitions for:

- Expression dispatch.
- Operand evaluation.
- Continuation return.
- Primitive application.
- Operation registration and commit.
- Task creation and completion.
- Scope joining.
- Cancellation delivery.
- Resource release.
- Budget charging.

Freeze this catalog alongside TC0.

### 2.6 Replay-site identity is underspecified for scheduler decisions

**Reference:** `02_TINY_LANGUAGE_CORE.md:165–167`

A choice contains a site `(task/node/occurrence)`, but a scheduler decision selects among several runnable tasks. Before selection there is no obvious single task/node site. `AdvanceTime` is also not naturally associated with a task or AST node.

**Recommendation:** Separate:

- **Decision-point identity:** a machine-level location, such as scheduler epoch.
- **Selected-transition identity:** task, node, operation occurrence, or time transition.

Define singleton decision recording, `AdvanceTime` tape consumption, occurrence-counter increments, domain encoding/hashing, budget-exhaustion replay boundaries, and trace normalization.

### 2.7 Canonical JSON is not yet uniquely specified

**Reference:** `02_TINY_LANGUAGE_CORE.md:19`

“Escape control characters” allows multiple byte spellings unless one is mandated. For example, `"\n"` and `"\u000a"` represent the same string and both escape the control character.

Since artifact identity hashes canonical bytes, the serializer must choose one spelling.

Also specify:

- Hex digit case in escapes and byte literals.
- Whether `/` may be escaped.
- BOM handling.
- Acceptance of noncanonical input that can be canonicalized.
- Decimal representations for IDs, capacities, indices, and counters.
- Whether source maps contribute to semantic artifact identity.

**Recommendation:** Provide golden byte vectors and define input acceptance separately from canonical output. Consider separate transport-artifact and semantic-program hashes if source-map-only changes should not invalidate semantic identity.

## 3. Evaluator and trust-boundary concerns

### 3.1 Fake termination requires a precise threat model

**References:** `01_FULL_VISION.md:68–82`, `03_PHASED_EXECUTION_PLAN.md:108–110`

A terminal event can be rejected when the model still expects live children. However, a checker observing only a fabricated but valid trace cannot prove that an adversarial candidate genuinely performed internal computation.

This does not invalidate trace conformance; it limits the claim.

**Recommendation:** Distinguish:

1. Trusted implementations with accidental bugs.
2. Untrusted generated code inside a controlled boundary.
3. Deliberately adversarial candidates fabricating observations.

For each, identify independently observed facts: process/guest lifecycle, framing and EOF, actual output, mediated effects, residual execution, and machine inspection where supported.

Do not imply that semantic trace checking alone establishes absence of hidden internal activity.

### 3.2 Agent path restrictions are insufficient isolation by themselves

**References:** `01_FULL_VISION.md:177–185`, `03_PHASED_EXECUTION_PLAN.md:33–54`

Allowed-path policies prevent ordinary accidental edits. They do not prevent candidate build scripts or test binaries from modifying evaluator inputs, reading secrets, or influencing the environment.

**Recommendation:** Add an execution policy:

- Read-only oracle, fixtures, and gate definitions.
- Candidate builds without evaluator credentials.
- Explicit network policy.
- Separate build and evaluation directories.
- Hash verification before and after execution.
- Allowlisted commands or sandboxed build scripts.

Clarify whether hostile build behavior is in scope.

### 3.3 Verdicts need a campaign aggregation rule

**Reference:** `02_TINY_LANGUAGE_CORE.md:171–186`

Independent verdict axes are a good foundation, but conversion into a gate result remains unspecified.

Examples include safety over an incomplete prefix, permitted deadlock, required reachability marked `NotReached`, exact replay of a violation, and campaigns mixing completed runs with timeouts.

**Recommendation:** Define gate aggregation separately from per-run verdicts. Include property scope, coverage, required/optional status, and cap-hit information.

Preserve useful prefix evidence without allowing it to satisfy a stronger completion claim.

### 3.4 Exploration state must include property-monitor state

**Reference:** `03_PHASED_EXECUTION_PLAN.md:88`

Future-relevant state includes outstanding obligations, trigger counts, relevant history summaries, remaining bounds, and fairness-monitor state—not just runtime state.

Identical runtime states can have different property obligations because their histories differ.

**Recommendation:** Explore the product:

```text
machine state × property-monitor state × remaining bounds
```

Distinguish exploration-state identity from evidence-trace identity.

## 4. Feasibility and execution-plan issues

### 4.1 TC0 is not actually tiny

**References:** `02_TINY_LANGUAGE_CORE.md:9–11`, `03_PHASED_EXECUTION_PLAN.md:70–112`

TC0 combines typed closures, recursive datatypes, effects, inherited handlers, structured tasks, channels, cancellation races, regions, resources, virtual time, exact replay, exhaustive exploration, and reduction.

G1 requires the whole semantic machine before G2; G2 requires all mandatory mutants before the first candidate in P3. This delays useful feedback.

**Recommendation:** Retain full TC0 as the target but introduce subprofile gates:

| Slice | Contents | First useful evidence |
| --- | --- | --- |
| TC0-A | Encoding, validation, pure evaluation, arithmetic, tail calls | Differential pure-program checks |
| TC0-B | User effects and handlers | Handler-stack and forwarding mutants |
| TC0-C | Tasks, scopes, channels, cancellation, resources | Stale-waiter repair demonstration |
| TC0-D | Full time, bounds, replay, exploration integration | Complete TC0 qualification |

Run model, evaluator, and candidate vertically through each slice. These are proposed planning subdivisions, not existing specified profiles.

### 4.2 G2 needs a mutant bootstrap strategy

**Reference:** `03_PHASED_EXECUTION_PLAN.md:90–96`

Mandatory mutants target runtime behavior, host time, replay, and verdict promotion. They do not all belong to the same component, and the full candidate arrives in P3.

**Recommendation:** Categorize mutants by target:

- Scripted protocol peers.
- Replay/evaluator implementations.
- Independent miniature candidates.
- Full runtime.
- Compiler.
- Backend.

Require each class when its target exists. Keep semantic-authority mutation experiments isolated from production oracle revisions.

### 4.3 Exact arithmetic across Shen ports is an early risk

**References:** `02_TINY_LANGUAGE_CORE.md:35`, `:217–223`

Exact I64 behavior requires careful treatment of numeric representations and wider arithmetic intermediates. Decimal-string transport does not guarantee internal precision.

**Recommendation:** Add a P0 spike for:

- Values around `2^53`.
- I64 minimum and maximum.
- Negation of I64 minimum.
- Multiplication requiring wider intermediates.
- Division signs and truncation.
- Large unsigned identity counters.

Require exact representation or explicit arithmetic implementation rather than assuming port agreement implies correctness.

### 4.4 Polymorphism and effect rows need a lowering strategy

**References:** `03_PHASED_EXECUTION_PLAN.md:146–156`

P6 introduces polymorphism and effect rows over a monomorphic TC0 with finite effect sets. The bridge could use monomorphization, dictionary passing, erasure, or a new core version.

Each choice affects specialization, code size, recursive instantiation, diagnostics, and node identity.

**Recommendation:** Add a P6 elaboration/lowering design gate. Valid target artifacts do not by themselves establish preservation of source-language meaning.

### 4.5 Production timers must explicitly differ from TC0 timers

**References:** `02_TINY_LANGUAGE_CORE.md:107–109`, `03_PHASED_EXECUTION_PLAN.md:160–168`

TC0 advances time only when no task is runnable. A perpetually runnable task can prevent sleepers from waking indefinitely. Production timers normally require another contract.

**Recommendation:** Name the distinct profiles:

- TC0 idle-advance virtual time.
- Production elapsed-time deadlines.
- Any later simulation profile modeling production timer progress.

Fair scheduling alone does not make virtual time advance while runnable tasks remain.

### 4.6 Solo5 needs an early bounded spike, not an early dependency

**References:** `03_PHASED_EXECUTION_PLAN.md:60–64`, `:114–132`

Host architecture support, transport integration, runtime dependencies, and tender changes could substantially affect effort.

**Recommendation:** During P0 only:

1. Build a minimal guest on the selected target.
2. Boot it.
3. Exchange one framed host/guest message.
4. Identify clock and entropy paths.
5. Record the smallest required dependency and patch set.

Then return to process-backed semantic work.

## 5. Additional acceptance fixtures

### Scope and failure

- Child traps while parent body remains runnable.
- Child traps while parent awaits another child.
- Parent explicitly awaits and observes child failure.
- Body trap races with child trap.
- Cancellation arrives while scope is already joining.

### Lifetime and handlers

- Spawn captures a resource whose lexical body ends first.
- Copied handler captures an ancestor resource.
- Outer handler clause runs across an inner different-effect handler.
- Cancellation occurs while a handler clause sleeps.
- Clause trap releases resources on both relevant continuation paths.

### Channels and cancellation

- Close races with blocked sender cancellation.
- Receive commits before cancellation and before result consumption.
- Multiple waiters stabilize in one transition.
- Repeated close produces exactly the specified observations.

### Validation and encoding

- Recursive datatype with no finite constructible value.
- Datatype containing a nonserializable field.
- Duplicate keys after JSON escape decoding.
- Equivalent strings with different escape spellings.
- Maximum I64 values on each supported Shen port.

### Replay and budgets

- Scheduler choice among tasks at different AST nodes.
- `AdvanceTime` replay-site validation.
- Singleton-domain tape handling.
- Budget ends immediately before task termination.
- Budget ends after commit but before the receiving task resumes.

## 6. Recommended document revisions

### `01_FULL_VISION.md`

Retain the architecture. Add candidate/agent threat models, independently observable behavior, and bootstrap subprofiles.

Clarify “a verified artifact validator” at line 189. If formal verification is not required, use “independently tested artifact validator.”

### `02_TINY_LANGUAGE_CORE.md`

Before freeze:

1. Resolve scope-failure timing.
2. Define region and lifetime judgments.
3. Define handler-context transitions.
4. Publish built-in signatures and result types.
5. Publish exact-step rules.
6. Complete canonical encoding.
7. Define replay decision-point identity.
8. Define quotas and terminal campaign behavior.
9. Add distinguishing fixtures.

### `03_PHASED_EXECUTION_PLAN.md`

Retain the long-term phases, but:

- Iterate P1–P3 by subprofile.
- Add arithmetic and Solo5 feasibility spikes to P0.
- Categorize mutants by component.
- Define gate aggregation.
- Give gates explicit evaluator entry points and versioned campaign manifests.
- Add a lowering-design gate before broader surface-language features.

## 7. Prioritized review and implementation plan

| Priority | Action | Completion evidence |
| --- | --- | --- |
| 1 | Write a semantic decision log for scope failure, resource/task lifetime, and handlers | Explicit decisions and hand-derived distinguishing traces |
| 2 | Create the canonical schema and byte-vector corpus | Independent encoders produce identical bytes; malformed inputs are rejected |
| 3 | Publish pure-machine transitions and built-in signatures | Every constructor/frame has a rule and fixture |
| 4 | Run exact-arithmetic and backend feasibility spikes | Pinned commands, outputs, limitations, and supported targets |
| 5 | Build the pure reference and independent minimal candidate together | Differential agreement on hand fixtures and declared generated campaigns |
| 6 | Kill one arithmetic/evaluation-order mutant with strict replay | Retained original/minimized case, expected classification, exact reproducer |
| 7 | Extend vertically to cancellation/channel/resource behavior | Stale-waiter bug found, minimized, repaired, and replayed |
| 8 | Freeze full TC0 only after semantic ambiguities are resolved | Complete schema, transition catalog, fixtures, mutant coverage, and current gate evidence |

## Bottom line

Approve the project direction and P0. Hold TC0 freeze and full implementation acceptance until lifetime, handler, scope-failure, exact-step, and replay contracts are explicit.

The main risk is not an obviously wrong architecture. It is freezing an ambitious “tiny” core while observable semantics remain implicit.
