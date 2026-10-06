# Fenrir and Gleipnir phased execution plan

Version 0.2 • Vertical-slice revision • Dependency ordered implementation program

**Working names:** Fenrir is the language and overall project. Gleipnir is its deterministic harness and conformance environment. ShenCheck retains its existing name. TC0 remains the first core; 0.2 is its revised contract.

**Revision status:** This plan adopts [review.md](review.md) and replaces the v0.1 bootstrap dependency chain. Gates below are requirements, not completed work or existing commands. The specification ZIP remains a historical v0.1 bundle. Old evidence does not satisfy revised gates without explicit compatibility review and reruns.

## 1 Mission and operating rules

Implement Fenrir and its Gleipnir harness according to the architecture in [01_FULL_VISION.md](01_FULL_VISION.md), beginning with the normative contract in [02_TINY_LANGUAGE_CORE.md](02_TINY_LANGUAGE_CORE.md). Continue in vertical slices: model, evaluator, candidate implementation, adversarial evidence, then the next feature. This plan includes the bootstrap and the phases after the tiny core so a fresh implementation agent has the complete dependency chain.

Do not rewrite ShenCheck without a source-grounded reason. Do not claim existing documentation proves a gate passes. Do not start with a new hypervisor, a complete surface language, or aggressive reference-count reuse. Make the semantic machine independently useful first.

Each phase ends with a gate. PASS requires current evidence bound to source and toolchain hashes. FAIL, UNKNOWN, BLOCKED and DEFERRED are distinct. Deferred optional work cannot satisfy a required gate. No dates or estimates substitute for acceptance evidence.

## 2 Dependency order

| Phase | Deliverable | Depends on |
| --- | --- | --- |
| P0 | Provenance, integration inventory, requirement ledger | None |
| P1 | Qualified TC0-A pure model, evaluator, candidate and strict-replay repair loop | P0 core readiness |
| P2 | Qualified TC0-B dynamic handlers across the same vertical stack | P1 |
| P3 | Qualified TC0-C concurrency/lifetimes/time, then full TC0 freeze | P2 |
| P4 | Deterministic Solo5 execution profile | P3 |
| P5 | Native compiler and memory correctness baseline | P3; P4 for isolated release evidence |
| P6 | Practical typed surface language and tooling | P5 |
| P7 | Production concurrency and supervised services | P4, P6 |
| P8 | Persistent services and independent history checking | P7 |
| P9 | Ownership optimization and specialization | P5; broader suites from P6–P8 |
| P10 | Interactive development and production qualification | P6–P9 |

P1–P3 each include model, independent candidate, evaluator, applicable mutants, reduction and strict replay. They are not separate model-first/evaluator-second/candidate-last phases. The first useful release is G1; full TC0 is G3.

P4 and early P5 work can proceed independently after P3 interfaces freeze. P0 performs a bounded Solo5 spike only; backend blockers do not prevent process-backed P1 work unless they affect its actual prerequisites. P9 experiments may begin earlier, but cannot replace the conservative compiler baseline. Optional emulation and Unikraft tracks have explicit triggers below.

## 3 Repository and ownership strategy

Begin by reading the actual repository instructions and current requirements matrix. ShenCheck's inspected AGENTS.md points implementation work to docs/AI_BUILD_WORKFLOW.md; the current file must be read in the target checkout. Respect its evidence and review requirements. This document does not authorize deployment, infrastructure mutation, or modification of unrelated adapters.

Suggested organization, subject to the actual repository layout:

```text
spec/tc0/                 versioned contract, schema and rule catalog
models/tc0/               Shen semantic machine and property definitions
fixtures/tc0/             hand-derived programs, traces and mutant cases
crates/...tc0-adapter/    ShenCheck integration and protocol validation
runtime/tc0/              conservative candidate implementation
compiler/tc0/             validation, lowering and native generation
backends/solo5/           guest bindings and tender integration
backends/process/         development execution adapter
campaigns/tc0/            smoke, exhaustive-small and nightly campaigns
evidence/                 manifests or content-addressed references
```

Keep generic campaign/history capabilities in ShenCheck. The language model, compiler and runtime may live in a separate repository if that improves ownership; use a versioned adapter package across the boundary. Do not hardwire a particular application or transport into the model kernel.

Separate semantic-authority changes from candidate implementation changes. The implementation agent's writable path set excludes qualified model rules, goldens and gate definitions. A separate review path can approve a contract change and its migration.

Path restrictions are workflow controls, not isolation. Build and run candidates in separate sandboxed writable directories with read-only evaluator inputs, no evaluator credentials, explicit network/device policy and independently verified source/binary hashes. Hash protected inputs before and after execution. Test attempted evaluator writes, external access and credential discovery with benign probes. Record platform-specific enforcement and stop claims not supported by it. Candidate code cannot issue the authoritative gate verdict.

## 4 P0 Establish the baseline

### Work

Pin ShenCheck, Koka, Solo5, the selected Shen port, C compiler, Rust toolchain where used, and any Jepsen checker artifacts. Record exact commits, license obligations, build commands, file hashes and platform details. Keep upstream source adaptations explicit. Use a Nix flake and lockfile for reproducible dependencies where supported; provide a documented non-Nix build path if platform support requires it.

Inspect ShenCheck choices, replay, model sets, corpus/minimizer, cooperative protocol, Antithesis shim, Jepsen bridge and current tests. Classify each as reusable unchanged, requires adapter, requires repair, or unrelated. Inspect Koka's runtime assumptions before deciding whether code can be reused on Solo5. Inspect Solo5 clocks, bindings, tender, toolchain and target support.

Create a ledger with requirement ID, contract/slice/profile, owner component, test, evidence path, and current status. Establish the enforced evaluator boundary and clean-room task packet. Create a semantic decision log for scope-failure timing, handler contexts, conservative capture support, reference-step transitions and future production profiles. Distinguishing examples and reviewed rules precede implementation; implementation arrival order is not authority.

### Bounded feasibility spikes

1. **Exact arithmetic:** Validate the selected Shen representation against independently established integer results around 2^53 and I64 limits, wide multiplication intermediates, minimum negation/division, truncation signs and unsigned IDs. Two ports agreeing does not establish exactness. Preserve a separate arithmetic fixture evaluator.
2. **Solo5:** On a demonstrated target, build/boot a minimal guest, exchange one framed host/guest message, inspect clock/entropy paths, and record dependencies and required patches. Set a work budget in advance; stop with retained blockers when exhausted. Do not expand this spike into scheduler/tender implementation.
3. **Isolation:** Demonstrate read-only evaluator inputs, credential exclusion and the declared access policy for process-backed builds/runs. Any weaker local development mode is labeled and cannot promote protected qualification.

Pin later external checkers before using their evidence; unavailable optional backend/checker dependencies are explicit and need not block the pure slice.

### Gate G0

Report G0 core readiness separately from backend readiness. Core PASS requires the selected Shen/process toolchain baseline and required tests, exact-arithmetic evidence, enforced evaluator boundary, requirement ledger and pinned source inventory. Missing required core evidence is UNKNOWN/BLOCKED, never PASS. Backend/checker blockers are retained with only affected work stopped; they cannot count as successful backend evidence.

No whole-system determinism claim is inherited from SDK random replay. Select a supported single-CPU guest target from demonstrated compatibility, not guesses. The bounded Solo5 report contains either measured results or an explicit blocker; return to P1 once core prerequisites pass.

## 5 P1 Qualify TC0-A and the first repair loop

### Work

Publish the closed A artifact/event/tape schemas, canonical byte vectors, exact arithmetic rules and pure frame/transition catalog before qualifying the oracle. Include the checked `{code_id, captures, capture_support}` closure descriptor and `TC0-A-CLOSURE-EMPTY-SUPPORT` now, with empty support arrays preserved through higher-order calls. Keep these as small checked artifacts beside the implementation, not another broad prose revision. Implement the Shen model and an independently structured native-process candidate together. Host wrappers handle transport, not semantic authority. The candidate must not reuse the Shen transition implementation.

Integrate structured recorded choices, including singleton Run choices, strict header/domain/site/footer validation, trace checking, property verdicts and retained bundles now. Add a small typed reducer for expressions and values; regenerate and recheck every proposed reduction. Preserve original and minimized cases and distinguish smallest-found from globally minimal.

Use scripted peers to test malformed/truncated streams, duplicate sequence IDs, wrong artifact hashes, oracle failure, missing/extra tapes, early terminal contradictions and unknown-to-pass promotion. Add reversed-evaluation-order and arithmetic mutants plus one equivalent control. Implement small exhaustive finite input/configuration exploration and explicit truncation reporting. Search identity includes the A machine, property-monitor state and remaining bounds from the start; P2 extends rather than introduces that product. Saved-history checking must not require candidate execution.

Give an agent a generated failure against a protected oracle, retain its task packet and revisions, independently build its patch, and rerun retained plus fresh cases. A scenario tape may be reissued against the repaired candidate, but exact-original replay remains bound to the original candidate identity.

### Gate G1 — first useful release

The pure model and independent candidate agree on hand fixtures, the declared exhaustive-small scope and sampled campaigns. Canonical bytes and arithmetic match independent expectations. Every A constructor/frame has explicit transitions and distinguishing fixtures. The reference kernel has no environmental effects.

Gleipnir discovers an evaluation-order or arithmetic defect, reduces it, strictly replays the original failure, and supplies an agent patch with fresh passing evidence. Applicable evaluator/pure mutants are killed with expected classifications; the equivalent control passes. Required replay/protocol failures never promote the candidate. Publish a runnable gate entry point and versioned manifest; proposed command text alone is not evidence.

Qualify the A profile/catalog identities only. This release does not claim handlers, concurrency, full TC0 or production semantics. Cross-port portability is claimed only after independently checked fixtures pass on the stated configurations.

## 6 P2 Qualify TC0-B handlers vertically

### Work

Add explicitly dynamic handler selection to the Shen model, independent candidate, validator, generators, reducer and evaluator together. Specify lexical clause captures, inactive selected/intervening handlers, outer clause context, single restore on return, and abort cleanup. Freeze no handler rule based only on the first implementation.

Extend strict replay and one-step fixtures. Kill skipped-handler and double-resume mutations. Test a closure defined under H1 but called under H2, same-effect outward forwarding, and an outer E operation crossing an inner F handler. Include traps and continuation restoration. Timer/channel suspension fixtures and `TC0-BC-INHERITED-HANDLER-OWNERSHIP` are declared dependencies on C and are not silently credited in B. Copied handler ownership anchors must rebind to the child's task-local scope; parent scope/cleanup authority is never inherited.

Explore the product of machine state, property-monitor state and remaining bounds. Add monitor obligations/history summaries, relevant coverage and fairness state to search identity. Demonstrate that identical runtime states with different obligations do not merge. Any quotient needs an explicit reviewed equivalence argument and comparison against unreduced small exploration.

### Gate G2

A regressions remain passing. B model/candidate traces agree over required hand/generated campaigns; every B frame/rule is specified and reviewed. Handler mutants have retained strictly replayable failures, the equivalent control still passes, and reducer outputs remain type/effect valid. Pure handler traps restore or unwind exactly as specified. C-dependent suspension/cleanup cases remain explicitly unqualified until G3.

Publish the B schema/catalog and runnable source-bound gate manifest. No full TC0 freeze or backend claim is made here.

## 7 P3 Qualify TC0-C, then freeze full TC0

### Work

Begin with two tasks, one channel, cancellation and an abstract resource. Specify and implement scope-failure latching in the child's terminal transition, immediate sibling requests, continuing parent body, joins, and primary-outcome precedence. Use the conservative lifetime rule: captures must outlive the owning task scope; require an explicit nested scope inside a resource body rather than implicit delayed release.

Extend model, independent candidate, checker, generators, reducer and strict replay through channels, resources, cancellation, idle-advance time and the full scope/handler interactions. Add wait graphs, epoch/machine-site identities and footer/checkpoint handling for budget boundaries. Keep production elapsed-time scheduling outside this profile.

Implement the named fixtures `TC0-BC-INHERITED-HANDLER-OWNERSHIP` and `TC0-C-FAILURE-AFTER-DESCENDANT-JOIN`. The latter schedules sibling B while trapping A joins its descendants and checks that B's cancellation request occurs only after A's terminal transition. Preserve this terminal-time propagation choice rather than reopening it.

Introduce applicable runtime/time mutants and one equivalent control. Reduce tasks/operations only when type/effect/region valid; reduced tapes must be regenerated and reproduce the same classified discrepancy. Expand exhaustive-small exploration, reporting exact state/edge counts, monitor product-state identity and all cap hits. Test both completing campaigns and deliberate truncation.

### Gate G3 — full TC0 qualification

A–C hand fixtures, exhaustive-small campaigns and declared sampling campaigns pass against the independent candidate. The stale-waiter defect is found, minimized, strictly replayed, repaired and rechecked with fresh evidence. Handler suspension/abort cases deferred from B now pass. Lifetime-invalid programs are rejected, including resource capture into a longer-lived scope.

The complete applicable mutant catalog is killed with expected classifications and retained reproducers; equivalent controls pass. A premature terminal report inconsistent with model state is rejected. A nonresponding candidate is HarnessTimeout, never valid semantic completion. Tests do not claim detection of every perfectly fabricated admissible trace or inspection of hidden private tasks.

Freeze full TC0 only after closed schemas, concrete frame rules, checker/monitor/gate encoders, independent semantic review and no unresolved ambiguity. Run independently checked fixtures on two Shen ports before portability claims. This qualifies `TC0-REF-STEP/0.2` and `TC0-IDLE-TIME/0.2`, not a permanent compiled/production scheduling contract.

## 8 P4 Add deterministic Solo5 execution

### Work

Port only the minimum candidate/runtime support required. Establish boot parameters, allocator, bounded memory, console/debug channel and a dedicated framed semantic protocol. Audit all guest-visible time and input paths. Replace clock/readiness behavior with virtual responses. Disable unused devices. Use a single logical CPU and no uncontrolled asynchronous callbacks.

Document the protocol request fields, response fields, validation limits, startup handshake, profile hashes, termination handshake, and error behavior. Replay rejects drift. Start by restarting from initial state; do not depend on unimplemented VM snapshots.

Run host perturbation experiments: vary host load, scheduling delays, run directory, process placement and repeated cold boots while keeping the semantic profile fixed. Normalize only fields explicitly outside the semantic contract. Audit instructions/libraries that could bypass mediation. State precisely which cooperative or trusted-code assumptions remain.

### Gate G4

The same compatible artifact and tape produce identical semantic traces across a declared repeat suite, including failure cases. Guest crashes remain isolated and diagnosed. No live network/filesystem input enters replay. Boundary bypass tests fail closed where enforceable; any remaining unmediated native instruction capability limits the claim explicitly.

Repeat counts provide empirical evidence, not proof of universal determinism. Publish the supported profile and audit inventory. Do not label the profile machine-level deterministic unless an independent backend establishes that stronger claim.

### Optional instruction-control gate

If the product requires deterministic termination of non-yielding native code, prototype a compatible instruction-counted emulator or validated metering strategy. Gate it on infinite-loop termination, reproducible instruction-limit outcomes, replay of interrupts/devices where present, and integration with semantic observations. Do not claim that Solo5's isolation alone supplies this.

## 9 P5 Generate native code

### Work

Implement a conservative compiler from validated TC0 to an explicit state-machine IR and C/native code targeting `TC0-REF-STEP/0.2`. Preserve semantic node mappings and its published scheduler checkpoints. This is a reference-profile compiler, not the permanent production scheduling design. Separate validation, lowering, code generation, runtime linking and execution. Compare the generated candidate against both Shen and the conservative interpreter.

Use simple safe memory management first. Pin ABI, integer representation, closure layout conventions and error propagation. Test tail calls, alias preservation and stack limits. Use available sanitizers, allocator poisoning and guarded allocations in suitable process builds; document which tools cannot run in the guest configuration.

### Gate G5

Generated programs agree with the oracle on all required campaigns. The compiler rejects invalid artifacts, traps arithmetic correctly, preserves left-to-right effects and tail-call stack behavior, and passes memory-error campaigns. Every compiler bug becomes a minimized source-level regression. Candidate optimization is disabled or minimal at this gate.

## 10 P6 Add a usable surface language

### Work

Choose surface syntax after TC0 demonstrates the contract. Investigate extending/reusing Koka versus introducing a small frontend that lowers to the defined IR; record maintenance and semantic compatibility costs. Do not assume Koka's full semantics equal TC0.

Before adding polymorphism/effect rows, review an elaboration/lowering contract: monomorphization, dictionary passing, erasure or a new core version must be an explicit decision. Specify recursive instantiation limits, effect discharge, source/node mapping, code-size implications and independently checked source-to-core examples. A valid target artifact alone does not establish source-semantics preservation.

Add local type inference, polymorphism, algebraic datatypes and effect rows incrementally. Every addition has a reviewed semantics-preserving desugaring or a new model rule. Build a formatter, package manifest/lockfile, diagnostic source mapping, language server essentials and a standard CLI. Separate compiler-internal types from stable public APIs.

### Gate G6

The elaboration/lowering contract has independent distinguishing fixtures for every admitted surface extension, not only target-validator success. A new developer can install, build, run, test, explore and replay a sample with documented commands. Parser round trips and formatter stability hold. Effect diagnostics identify missing handlers and relevant call sites. Dependency resolution is reproducible. All generated surface examples reduce to validated artifacts and pass the semantic suites.

## 11 P7 Build production concurrency

### Work

First qualify a separate compiled/production scheduling contract: task-switch and cancellation boundaries, pure-step coalescing, fairness, observable atomicity, progress, and trace abstraction/refinement. Reference-frame changes must not silently change this language-visible contract. Exact reference-step tapes are not portable production tapes.

Specify asynchronous I/O, elapsed-time deadlines, cancellation shielding if needed, realistic finalizers, bounded channels/mailboxes, supervisor restart policies and overload behavior as new versions/profiles. Keep one documented default policy for application developers. Distinguish production elapsed time from TC0 idle-advance time; fairness cannot make the latter progress while runnable tasks remain.

Implement a production scheduler separately from the deterministic scheduler, sharing validated state transitions where appropriate but retaining independent checking. Capture causal histories and map them to the abstract model. Add actual parallel stress tests if multiple native threads are introduced. A serial simulator cannot establish weak-memory correctness by itself.

### Gate G7

The compiled/production scheduling and elapsed-time profiles are published and qualified, with reviewed trace abstraction and independent boundary/progress tests. Long-running service tests demonstrate graceful shutdown, bounded queues, cancellation completion, no leaked tasks/resources, and defined restart behavior under fault campaigns. Production histories are admitted by the model. Latency, throughput, memory and telemetry overhead are measured with reproducible workloads and hardware details. Timer behavior under CPU load is explicitly tested against the production contract.

## 12 P8 Add persistence and distributed histories

### Work

Add a versioned storage model: write visibility, flush/durability, crash loss, recovery, and allowed corruption faults. Network models distinguish channel semantics from packet loss, partitions, delayed responses and retransmission. Distinguish logical requests from retry attempts and client knowledge from internal state.

Build a small durable service, first a register or queue, then a lease/fencing or transactional workload. Use Shen domain models plus the existing Jepsen bridge for supported Elle/Knossos histories. Validate at least one history that passes, one known anomaly and one indeterminate case. Preserve each checker's distinct verdict.

### Gate G8

Crash-after-commit-before-response, retry duplication, stale fencing, partition recovery and incomplete histories all have explicit outcomes and fixtures. Independent checkers detect seeded anomalies. Replayed environmental faults are exact within the declared profile. Unmodeled external services are marked opaque rather than implied deterministic.

This is the trigger point for evaluating a Unikraft backend if a concrete library or compatibility workload justifies it. Adoption requires the same boundary inventory and conformance gates as Solo5, plus the new OS components' semantics. It does not replace the small reference backend.

## 13 P9 Optimize ownership and execution

### Work

Introduce a typed ownership/effect IR with explicit alias and lifetime information. Evaluate Perceus-inspired reference counting, borrowing, reuse, specialization, closure elimination and unboxing independently. Keep the conservative implementation available as a differential baseline.

For every optimization define preconditions, preserved observations, invalidation conditions and adversarial alias/effect examples. Test resource failure behavior separately from physical allocation performance. Use benchmarks that cover persistent sharing, array algorithms, recursion, effect-heavy tasks and real services.

### Gate G9

Optimized and baseline implementations agree over fresh generated campaigns and the regression corpus. Memory tooling finds no invalid reuse in the supported configurations. Performance changes include distributions, peak memory, compile time and code size. An optimization without a demonstrated benefit can be omitted. No universal speedup or zero-allocation claim is inferred from one benchmark.

## 14 P10 Qualify the product

### Work

Add interactive inspection, source-level suspended-task views, effect-context diagnostics and module replacement for new requests. Defer replacement of active suspended frames until a separate migration model exists. Complete package signing/provenance policy, compatibility/deprecation policy, supported-platform matrix, release documentation and operational guides.

Conduct a review of boundary enforcement, dependency updates, malformed artifacts, FFI profiles, sensitive trace data, resource exhaustion and denial-of-service behavior. Add supported real I/O libraries and independent integration tests. Retain reproducible old failure bundles across releases or publish explicit migration limits.

### Gate G10

Release qualification includes clean-machine installation, reproducible builds, compatibility fixtures, realistic long-duration services, fault recovery, performance budgets, and no unresolved required UNKNOWN rows. The product documentation states precisely which replay guarantees apply to which execution profiles.

## 15 Campaign tiers and cost controls

| Tier | Purpose | Promotion policy |
| --- | --- | --- |
| Per-change | Hand fixtures, protocol validation, smoke mutants, retained regressions | Required for every relevant patch |
| Integration | Exhaustive-small models, differential generation, replay perturbation | Required before feature promotion |
| Scheduled deep run | Larger exploration, fault schedules, optimization stress | Results bound to exact revision |
| Release | Full required matrix, real services, platform and performance qualification | Required for declared supported release |

Choose initial concrete budgets during P0/P1 from measured throughput and refine them in P2/P3. Preserve seeds and tapes for discovery, but use strict tapes for exact replay. Increasing a budget is useful only when it addresses an identified gap. Search reduction techniques such as partial-order reduction require an independence relation and comparison against unreduced exhaustive cases before they can support completeness claims.

## 16 Evidence contract

Each gate packet contains requirement IDs, source/toolchain hashes, commands, inputs, environment/profile versions, test counts, bounds, outcomes, failures, and known limitations. Required files include manifest.json, verdicts.json, program.json, choices.jsonl, trace.jsonl and replay instructions; minimized failures also retain reduction provenance and the original case identifier.

Every gate has a runnable evaluator entry point and a versioned manifest listing required/optional rows, accepted execution outcomes, conformance/property scope, coverage, replay and exploration requirements. These are implementation deliverables, not commands already present in this repository. Aggregation follows TC0-GATE: PASS only when all required rows meet their scopes; retain FAIL, UNKNOWN, BLOCKED and optional DEFERRED reasons independently. An intentionally crashing peer may satisfy an evaluator-classification row, never a candidate-completion row.

Evidence binds slice, reference/catalog and scheduling/time profile, property-monitor and gate versions, sandbox policy, protected-input verification and original/minimized footer checkpoints. Exact replay binds the original candidate; cross-patch scenario replay and fresh repaired-candidate evidence are separate claims.

A source modification invalidates affected prior evidence until rerun. A green CI badge without the corresponding source identity is insufficient. Skipped tests and optional external-checker dependencies appear explicitly. Failed infrastructure is reported as such and never counted as a killed semantic mutant unless the expected observation was independently established.

## 17 Acceptance task template for an implementation agent

```text
Goal: Implement [component] for TC0 [revision/slice/profile/catalog hash].
Read: exact model rules, interface schema, relevant repository instructions.
Allowed changes: [candidate paths].
Protected inputs: [oracle, goldens, catalogs, gates, monitor schemas].
Execution boundary: [sandbox, read-only inputs, network policy, credential exclusion].
Start revision: [exact commit].
Acceptance: [bounded commands and campaign manifests].
On failure: retain first divergence, original and minimized case, and replay.
On suspected spec defect: propose a separate change; do not alter the oracle.
Completion: patch, design explanation, current evidence, remaining limitations.
Never report PASS for timeout, unknown, skipped, or truncated required work.
```

## 18 First concrete implementation assignment

1. Complete G0 core readiness and retain the bounded arithmetic, isolation and Solo5 reports.
2. Define TC0-A encoding, arithmetic, pure transitions, event/tape schemas and hand fixtures.
3. Build the Shen model and independent minimal process candidate together with strict replay and a small reducer.
4. Discover an evaluation-order/arithmetic defect, minimize it, exactly replay the original, obtain an agent patch and independently gather fresh passing evidence (G1).
5. Add dynamic handlers and explicit context rules through the same vertical stack (G2).
6. Add tasks/channels/cancellation, conservative resource lifetimes and distinct idle-time rules; demonstrate the stale-waiter repair and qualify full TC0 (G3).

The next executable demonstration packet contains: (1) a canonical TC0-A program, (2) its hand-derived expected trace, (3) agreement between the Shen evaluator and independent candidate, (4) an injected arithmetic/evaluation-order defect, (5) Gleipnir discovery and reduction, (6) exact replay of the original failure, and (7) a repair passing fresh evaluation. Schemas, concrete frames and byte vectors are checked implementation artifacts; do not delay this packet for B/C ownership fixtures or another large specification revision.

Strict replay is part of step 3, not deferred integration work. The first demonstration must show an actual generated implementation failure, a small deterministic counterexample, original-failure replay, an agent patch, and current passing evidence. A diagram or manually selected happy path is insufficient. Authority comes from reviewed explicit rules and the qualified evaluator, never whichever implementation arrives first. Keep backend work bounded until these slices establish useful evidence.
