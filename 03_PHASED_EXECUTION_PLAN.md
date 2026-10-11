# Fenrir and Gleipnir phased execution plan

Version 0.3 • Status-aware revision • Dependency ordered implementation program

**Working names:** Fenrir is the language and overall project. Gleipnir is its deterministic harness and conformance environment. ShenCheck retains its existing name. TC0 remains the first core; 0.2 is its revised contract.

**Revision status (11 October 2026, master `8cc4c92`):** This plan adopts [review.md](review.md) and replaces the v0.1 bootstrap dependency chain. The specification ZIP remains a historical v0.1 bundle. The repo now has the schema `/2` TC0-A development slice, S2 campaigns, an S3 repair packet, a registered TC0-A gate and a recorded PASS at `1db7471` under owner-approved waivers. That receipt is historical and source-bound to `1db7471`; no run at the current master has been recorded in this checkout. Re-run the registered gate on the clean current head before treating G1 as current. B, C, the full language, and native execution remain outside that result. Requirements below remain normative; the status notes identify delivered evidence without widening its scope.

**Direction amendment (11 October 2026):** See [§19](#19-direction-amendment-unikernel-target-and-agent-back-pressure). It sets the unikernel production target, effects as the capability manifest, a semantic per-change check for the agent loop, a host-hardening freeze until G1, and a new dependency-epoch rule for unrecoverable inputs. It replaces the first concrete assignment in §18. Gate requirements are unchanged except where this document explicitly adds rows to G4, G6, G7 and G10.

## 1 Mission and operating rules

Implement Fenrir and its Gleipnir harness according to the architecture in [01_FULL_VISION.md](01_FULL_VISION.md), beginning with the normative contract in [02_TINY_LANGUAGE_CORE.md](02_TINY_LANGUAGE_CORE.md). Continue in vertical slices: model, evaluator, candidate implementation, adversarial evidence, then the next feature. This plan includes the bootstrap and the phases after the tiny core so a fresh implementation agent has the complete dependency chain.

Do not rewrite ShenCheck without a source-grounded reason. Do not claim existing documentation proves a gate passes. Do not start with a new hypervisor, a complete surface language, or aggressive reference-count reuse. Make the semantic machine independently useful first.

Each phase ends with a gate. PASS requires current evidence bound to source and toolchain hashes. FAIL, UNKNOWN, BLOCKED and DEFERRED are distinct. Deferred optional work cannot satisfy a required gate. No dates or estimates substitute for acceptance evidence.

Measure progress by closed feedback loops, not by subsystems added or hardening passes completed. Each task packet must select a registered development check that exercises its component and record when it runs (see 01_FULL_VISION.md §13, back pressure). The manifest registers checks; it does not by itself enforce component-to-check routing or execution on every edit. Once a run's scope, protected inputs, sandbox and budget are approved, candidate-only iterations proceed without per-step human approval; humans review authority changes, dependency epochs and stops.

## 2 Dependency order

| Phase | Deliverable | Depends on | Current position |
| --- | --- | --- | --- |
| P0 | Provenance, integration inventory, requirement ledger | None | TC0 development toolchain and ledger exist; the native-host dependency epoch and retained image rebuild remain open. |
| P1 | Qualified TC0-A pure model, evaluator, candidate and strict-replay repair loop | P0 core readiness | Registered gate recorded PASS at `1db7471` under waivers; rerun on current master before treating G1 as current. |
| P2 | Qualified TC0-B dynamic handlers across the same vertical stack | Current G1 evidence | Next implementation phase after a current-head G1 PASS. |
| P3 | Qualified TC0-C concurrency/lifetimes/time, then full TC0 freeze | P2 | Not started. |
| P4 | Deterministic Solo5 execution profile | P3 | Not started; optional thin development slice may follow G1 as described below. |
| P5 | Native compiler and memory correctness baseline | P3; P4 for isolated release evidence | Not started. |
| P6 | Practical typed surface language and tooling | P5 | Not started. |
| P7 | Production concurrency and supervised services | P4, P6 | Not started. |
| P8 | Persistent services and independent history checking | P7 | Not started. |
| P9 | Ownership optimization and specialization | P5; broader suites from P6–P8 | Not started. |
| P10 | Interactive development and production qualification | P6–P9 | Not started. |

P1–P3 each include model, independent candidate, evaluator, applicable mutants, reduction and strict replay. They are not separate model-first/evaluator-second/candidate-last phases. The first useful release is G1; full TC0 is G3.

After G1, a bounded **thin unikernel slice** may run as a development spike, extending the existing native-arithmetic spike rather than replacing it: one pure function plus one output effect, lowered to C, linked against Solo5 hvt with a device manifest derived from that effect, run, strictly replayed and compared with Shen. It establishes the end-to-end shape of the production target early. It is not P4 work, does not satisfy G4, and stops at its budget with retained blockers.

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

Pin ShenCheck, Koka, Solo5, the selected Shen port, C compiler, Rust toolchain where used, and any Jepsen checker artifacts. Record exact commits, license obligations, build commands, file hashes and platform details. Keep upstream source adaptations explicit. Use a Nix flake and lockfile for reproducible dependencies where supported; provide a documented non-Nix build path if platform support requires it. Backend container and guest images should be built from the flake where recipes are defined, so a lost image can be reproduced rather than recovered. The current flake pins the TC0 development toolchain only; native stock/control image recipes and identities are still outstanding. Keep local upstream fixes as named overlays or patch files with review records.

**Dependency epochs.** A pinned input set is an epoch with its own identity. When a retained input cannot be restored exactly, a reviewer opens a new epoch: rebuild from pinned sources, record the new identities and the reason, mark evidence bound to the old epoch historical, and rerun what the next gate needs. Old receipts are never rewritten or reinterpreted to match new artifacts, and earlier failures or uncertainties stay recorded. The repository flake now pins the TC0 development toolchain; this does not open or complete the separate native-host epoch for the missing stock/control images. A native epoch does not by itself authorize live runs, which still require the remaining gates in the native closure packet.

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

Register the slice's semantic development checks with the Pi workflow controller as development-tier commands: validator negative tests, hand-fixture Shen-vs-candidate agreement, and strict replay of retained cases. They give the agent loop semantic back pressure but do not approximate the separate `tc0-a-qualification` evaluator. The current manifest has both tiers registered; measure development-check wall time, with the per-change set targeting about a minute on the process backend.

Until G1 passes, native-host and Solo5 hardening is frozen except for work that removes a named blocker for G1 or for the dependency epoch above. The pure process-backed loop is the critical path.

### Gate G1 — first useful release

The pure model and independent candidate agree on hand fixtures, the declared exhaustive-small scope and sampled campaigns. Canonical bytes and arithmetic match independent expectations. The gate measures named catalog-transition coverage and the stated distinguishing hand fixtures; 112/112 catalog keys does not establish every frame/context combination or state-space coverage. The reference kernel has no environmental effects.

Gleipnir discovers an evaluation-order or arithmetic defect, reduces it, strictly replays the original failure, and supplies an agent patch with fresh passing evidence. Applicable evaluator/pure mutants are killed with expected classifications; the equivalent control passes. Required replay/protocol failures never promote the candidate. Publish a runnable gate entry point and versioned manifest; proposed command text alone is not evidence.

Qualify the A profile/catalog identities only. This release does not claim handlers, concurrency, full TC0 or production semantics. Cross-port portability is claimed only after independently checked fixtures pass on the stated configurations.

**Recorded result and freshness.** The registered `tc0-a-qualification` evaluator returned PASS at `1db7471`, with all 15 required rows and six claims, under the owner-recorded waivers in [`campaigns/tc0/G1_EVALUATOR_REVIEW.md`](campaigns/tc0/G1_EVALUATOR_REVIEW.md). The accepted scope is bounded (including grammar G through 5 AST nodes and three mutants); the repairer used instruction-only isolation, and the evaluator is trusted-local while candidates are sandboxed. This is a G1 result for that source identity, not a waiver-free isolation claim or qualification of B/C/full TC0. The current master is a later commit and has no recorded fresh gate receipt here. Until the registered check passes at the current clean source, current-head G1 is UNKNOWN. A later documentation-only change still changes the exact committed source identity required by the gate.

## 6 P2 Qualify TC0-B handlers vertically

### Work

Add explicitly dynamic handler selection to the Shen model, independent candidate, validator, generators, reducer and evaluator together. Specify lexical clause captures, inactive selected/intervening handlers, outer clause context, single restore on return, and abort cleanup. Freeze no handler rule based only on the first implementation.

Start P2 in a separate bounded run after reviewing the G1 controller receipt and approving the P2 task packet. The first protected-source edit makes affected G1 evidence historical. G2 must rerun the required A rows against the final P2 source alongside the new B rows. G1's program enumeration has one scheduling alternative per state; it supplies no concurrency, fairness, crash, retry or partition evidence. New claims require their own fault model, schedule identity, monitor state and replay evidence.

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

Derive the guest device manifest from the program's residual effect row (01_FULL_VISION.md §7, effects as the capability manifest). Link only handlers for residual effects. Configure the tender to grant only the derived devices. Write the boundary inventory for the image: tender, hypervisor and host kernel assumptions, single privilege level inside the guest, runtime-internal operations and any unsafe code.

Run host perturbation experiments: vary host load, scheduling delays, run directory, process placement and repeated cold boots while keeping the semantic profile fixed. Normalize only fields explicitly outside the semantic contract. Audit instructions/libraries that could bypass mediation. State precisely which cooperative or trusted-code assumptions remain.

### Gate G4

The same compatible artifact and tape produce identical semantic traces across a declared repeat suite, including failure cases. Guest crashes remain isolated and diagnosed. No live network/filesystem input enters replay. Boundary bypass tests fail closed where enforceable; any remaining unmediated native instruction capability limits the claim explicitly.

A program whose residual effects lack a permitted handler is rejected at image build. Each image's device manifest matches its derived effect set, and attempted use of an undeclared device fails closed in tests.

Repeat counts provide empirical evidence, not proof of universal determinism. Publish the supported profile and audit inventory. Do not label the profile machine-level deterministic unless an independent backend establishes that stronger claim.

### Optional instruction-control gate

If the product requires deterministic termination of non-yielding native code, prototype a compatible instruction-counted emulator or validated metering strategy. Gate it on infinite-loop termination, reproducible instruction-limit outcomes, replay of interrupts/devices where present, and integration with semantic observations. Do not claim that Solo5's isolation alone supplies this.

## 9 P5 Generate native code

### Work

Implement a conservative compiler from validated TC0 to an explicit state-machine IR and C/native code targeting `TC0-REF-STEP/0.2`. Preserve semantic node mappings and its published scheduler checkpoints. This is a reference-profile compiler, not the permanent production scheduling design. Separate validation, lowering, code generation, runtime linking and execution. Compare the generated candidate against both Shen and the conservative interpreter.

Use simple safe memory management first. Pin ABI, integer representation, closure layout conventions and error propagation. Generated C is acceptable; hand-written runtime C runs under sanitizers in the per-change tier on the process backend, or that component moves to a language whose compiler rejects the same errors. Record the choice per runtime component. Test tail calls, alias preservation and stack limits. Use available sanitizers, allocator poisoning and guarded allocations in suitable process builds; document which tools cannot run in the guest configuration.

### Gate G5

Generated programs agree with the oracle on all required campaigns. The compiler rejects invalid artifacts, traps arithmetic correctly, preserves left-to-right effects and tail-call stack behavior, and passes memory-error campaigns. Every compiler bug becomes a minimized source-level regression. Candidate optimization is disabled or minimal at this gate.

## 10 P6 Add a usable surface language

### Work

Choose surface syntax after TC0 demonstrates the contract. Investigate extending/reusing Koka versus introducing a small frontend that lowers to the defined IR; record maintenance and semantic compatibility costs. Do not assume Koka's full semantics equal TC0.

Before adding polymorphism/effect rows, review an elaboration/lowering contract: monomorphization, dictionary passing, erasure or a new core version must be an explicit decision. Specify recursive instantiation limits, effect discharge, source/node mapping, code-size implications and independently checked source-to-core examples. A valid target artifact alone does not establish source-semantics preservation.

Add local type inference, polymorphism, algebraic datatypes and effect rows incrementally. Every addition has a reviewed semantics-preserving desugaring or a new model rule. Build a formatter, package manifest/lockfile, diagnostic source mapping, language server essentials and a standard CLI. Separate compiler-internal types from stable public APIs.

Design the surface for agents as primary authors (01_FULL_VISION.md §15): checked module interface files with effect rows, a versioned grammar card, and a skill pack per release with migration guidance and mechanical rewrites. Prefer explicit, regular constructs that the type and effect checker can reject over syntax sugar that mainly helps human reading. Track richer type-level checking (refinements, then dependent types) as a later research option for added back pressure; it is not a P6 requirement.

Before committing to a syntax, a time-boxed throwaway prototype MAY be built after G1: a minimal frontend lowering to the existing TC0-A artifacts, used to test whether agents write correct programs from the grammar card alone. It produces design evidence only, is discarded afterwards, and cannot satisfy G6.

### Gate G6

The elaboration/lowering contract has independent distinguishing fixtures for every admitted surface extension, not only target-validator success. A new developer can install, build, run, test, explore and replay a sample with documented commands. An agent given only the grammar card, interface files and skill pack writes the declared sample suite so that it passes the semantic suites, with the attempt count recorded. Parser round trips and formatter stability hold. Effect diagnostics identify missing handlers and relevant call sites. Dependency resolution is reproducible. All generated surface examples reduce to validated artifacts and pass the semantic suites.

## 11 P7 Build production concurrency

### Work

First qualify a separate compiled/production scheduling contract: task-switch and cancellation boundaries, pure-step coalescing, fairness, observable atomicity, progress, and trace abstraction/refinement. Reference-frame changes must not silently change this language-visible contract. Exact reference-step tapes are not portable production tapes.

Specify asynchronous I/O, elapsed-time deadlines, cancellation shielding if needed, realistic finalizers, bounded channels/mailboxes, supervisor restart policies and overload behavior as new versions/profiles. Keep one documented default policy for application developers. Distinguish production elapsed time from TC0 idle-advance time; fairness cannot make the latter progress while runnable tasks remain.

The elapsed-time contract for unikernel deployment cannot assume a host time service. Specify time as an effect handler that combines several clock sources, reports their disagreement and bounds its error; Gleipnir replaces the same handler with virtual time. Persisted virtual actors (actors addressed by identity and rehydrated from a storage handler on demand) are a candidate later profile on top of supervision; specify them as a separate profile if adopted, not as an extension of TC0 tasks.

Implement a production scheduler separately from the deterministic scheduler, sharing validated state transitions where appropriate but retaining independent checking. Capture causal histories and map them to the abstract model. Add actual parallel stress tests if multiple native threads are introduced. A serial simulator cannot establish weak-memory correctness by itself.

### Gate G7

The compiled/production scheduling and elapsed-time profiles are published and qualified, with reviewed trace abstraction and independent boundary/progress tests. Long-running service tests demonstrate graceful shutdown, bounded queues, cancellation completion, no leaked tasks/resources, and defined restart behavior under fault campaigns. Production histories are admitted by the model. The multi-source time handler's disagreement and error reporting is tested under injected clock faults. Latency, throughput, memory and telemetry overhead are measured with reproducible workloads and hardware details. Timer behavior under CPU load is explicitly tested against the production contract.

## 12 P8 Add persistence and distributed histories

### Work

Add a versioned storage model: write visibility, flush/durability, crash loss, recovery, and allowed corruption faults. Network models distinguish channel semantics from packet loss, partitions, delayed responses and retransmission. Distinguish logical requests from retry attempts and client knowledge from internal state.

For cloud-shaped deployments, evaluate an object-store-primary storage profile: an S3-compatible store as the durable source of truth with a local block cache, modeled as a storage effect with explicit visibility, durability and cache-loss semantics. Use NixOS machine tests, or an equivalent pinned multi-machine harness, to run fleets of images against network rules and fault schedules.

Build a small durable service, first a register or queue, then a lease/fencing or transactional workload. Use Shen domain models plus the existing Jepsen bridge for supported Elle/Knossos histories. Validate at least one history that passes, one known anomaly and one indeterminate case. Preserve each checker's distinct verdict.

### Gate G8

Crash-after-commit-before-response, retry duplication, stale fencing, partition recovery and incomplete histories all have explicit outcomes and fixtures. Independent checkers detect seeded anomalies. Replayed environmental faults are exact within the declared profile. Unmodeled external services are marked opaque rather than implied deterministic.

This is the trigger point for the network/storage library decision in 01_FULL_VISION.md §8: reuse MirageOS libraries through an OCaml backend, or port handler libraries against an existing implementation used as a differential oracle. Compare boundary inventories and determinism audit cost for the chosen workload, and record the decision. It is also the trigger point for evaluating a Unikraft backend if a concrete library or compatibility workload justifies it. Adoption requires the same boundary inventory and conformance gates as Solo5, plus the new OS components' semantics. It does not replace the small reference backend.

## 13 P9 Optimize ownership and execution

### Work

Introduce a typed ownership/effect IR with explicit alias and lifetime information. Evaluate Perceus-inspired reference counting, borrowing, reuse, specialization, closure elimination and unboxing independently. Keep the conservative implementation available as a differential baseline.

For every optimization define preconditions, preserved observations, invalidation conditions and adversarial alias/effect examples. Test resource failure behavior separately from physical allocation performance. Use benchmarks that cover persistent sharing, array algorithms, recursion, effect-heavy tasks and real services.

### Gate G9

Optimized and baseline implementations agree over fresh generated campaigns and the regression corpus. Memory tooling finds no invalid reuse in the supported configurations. Performance changes include distributions, peak memory, compile time and code size. An optimization without a demonstrated benefit can be omitted. No universal speedup or zero-allocation claim is inferred from one benchmark.

## 14 P10 Qualify the product

### Work

Add interactive inspection, source-level suspended-task views, effect-context diagnostics and module replacement for new requests. Defer replacement of active suspended frames until a separate migration model exists. Complete package signing/provenance policy, compatibility/deprecation policy, supported-platform matrix, release documentation and operational guides.

Conduct a review of boundary enforcement, dependency updates, malformed artifacts, FFI profiles, sensitive trace data, resource exhaustion and denial-of-service behavior. Publish the unikernel deployment threat model: what removing the shell and interpreter does and does not prevent, memory-safety and code-reuse exposure, guest privilege levels, tender/hypervisor/host trust, and the patch process for each. Ship the redacting logging handler as the default and test that declared secrets never reach log output. Add supported real I/O libraries and independent integration tests. Retain reproducible old failure bundles across releases or publish explicit migration limits.

### Gate G10

Release qualification includes clean-machine installation, reproducible builds, compatibility fixtures, realistic long-duration services, fault recovery, performance budgets, and no unresolved required UNKNOWN rows. The product documentation states precisely which replay guarantees apply to which execution profiles. A breaking change between two supported releases is migrated by its skill pack across the retained corpus with recorded results. No security property of unikernel deployment is advertised beyond what the published threat model and adversarial tests support.

## 15 Campaign tiers and cost controls

| Tier | Purpose | Promotion policy |
| --- | --- | --- |
| Per-change | Hand fixtures, protocol validation, smoke mutants, retained regressions | Required for every relevant patch |
| Integration | Exhaustive-small models, differential generation, replay perturbation | Required before feature promotion |
| Scheduled deep run | Larger exploration, fault schedules, optimization stress | Results bound to exact revision |
| Release | Full required matrix, real services, platform and performance qualification | Required for declared supported release |

The per-change tier is the agent loop's back pressure and is held to a latency target (about a minute for the current slice on the process backend). Work that cannot meet it moves to the integration tier rather than slowing every iteration.

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

## 18 Current implementation sequence

The 11 October direction amendment (§19) has been implemented in the plan and workflow controller. The former assignment to build S1–S3, pin the TC0 development toolchain and register the evaluator is historical; those artifacts are present on master. Do not start the old `NEXT_SLICE.md` S1 assignment again.

1. **Verify the supported runner and refresh G1 only.** The flake currently targets `x86_64-linux`; the registered gate requires Nix and the pinned Shen output. Select an actual Linux x86-64 runner and record its OS, architecture, Nix/toolchain identities, checkout commit, available resources and finite timeout before starting. macOS is not a qualified execution path; an unavailable supported runner is BLOCKED. On a clean committed source, run only `tc0-a-qualification` through the controller and retain its receipt with source/configuration hashes, executable identities, evidence hashes and cleanup. The standalone gate report is supporting evidence; the controller receipt is the qualification artifact. PASS ends this run for receipt review. Non-PASS stops progression and routes to the reported row. Do not begin P2 in this run.
2. **Review a separate P2 task packet, then implement one minimal handler slice.** Specify the exact dynamic-handler semantics, new profile/catalog versions, allowed paths, protected A baseline, authority changes, relevant development checks and finite budgets. After this review, start a fresh P2 run through the vertical stack in §6. The first protected-source edit invalidates affected current G1 evidence; keep its receipt as a historical regression baseline. Freeze the final P2 source and run a reviewed G2 evaluator that reruns required A rows plus B rows. A G1 PASS alone does not qualify P2.

3. **Close the accepted G1 waiver before broadening trust.** The recorded G1 accepted instruction-only repairer isolation and a trusted-local evaluator with only candidate sandboxing. Keep those limits explicit during P2; before using the gate to support claims beyond its accepted G1 scope, separately review and measure enforced repairer and evaluator isolation, then rerun the affected qualification rows. Do not silently upgrade the waiver to an isolation guarantee.
4. **Keep the native-host dependency epoch separate.** The TC0 flake pins the TC0 tools; it does not restore or replace missing native stock/control images. When native work becomes a named prerequisite, open the epoch, rebuild from pinned sources, record new identities, and retain old receipts as historical. Do not run live native campaigns before their closure packet gates pass.
5. **After G1, optional bounded thin unikernel slice** (§2): one pure function plus one output effect, compiled to C, linked with Solo5 hvt using an effect-derived device manifest, replayed and compared with Shen. It is development evidence only and is not P4/G4 qualification. Keep it behind P2 work unless an explicit bounded task says otherwise.
6. **Continue P3 and later only through their gates:** add tasks/channels/cancellation, conservative resource lifetimes and distinct idle-time rules; demonstrate stale-waiter repair; then qualify full TC0 at G3. Surface-language prototypes, production backends and optimization remain downstream of their listed dependencies.

**Authority-record cleanup is a separate reviewed change, not a new gate prerequisite.** The evaluator header still calls itself unreviewed/unregistered, and the ledger retains pre-registration gap text. Reconcile evaluator source, ledger, manifest, workflow registration and review packet together. The ledger checker validates structure and file references; it cannot establish semantic consistency among those objects. These stale descriptions should be corrected under authority review, but do not block a read-only G1 refresh unless the owner explicitly changes the acceptance contract. Any cleanup changes source/authority identities and requires fresh evidence afterwards.

The immediate milestones are a supported-runner G1 refresh and receipt review, followed by a separately reviewed P2 run and final-source G2 evaluation. Optional native or surface-language spikes are excluded from both runs. Strict replay, a generated failure, its minimized counterexample, and fresh repair evidence are part of the recorded `1db7471` gate result under the stated waiver; do not describe those historical receipts as fresh on a later source identity.

## 19 Direction amendment: unikernel target and agent back pressure

**Source.** Geoffrey Huntley, ["unikernels were hard. key word: were."](https://ghuntley.com/unikernels/), 11 October 2026: a write-up of a conversation with Justin Cormack (MirageOS). Its arguments are opinion and anecdote, not measured evidence. This section records which ideas the plan adopts, where they land, and what it does not adopt.

**Assessment (updated 11 October 2026).** The article's central method, "if you have an oracle, porting is a loop," is Gleipnir's design: Shen is the oracle and candidates are checked against it. The process-backed TC0-A loop now has semantic development checks, generated discovery/reduction, an S3 repair packet and a registered evaluator. Its recorded G1 PASS at `1db7471` has explicit scope and isolation waivers; the current master still needs a fresh gate receipt. The separate native path remains blocked on unrecoverable stock/control images. The amendment keeps acceptance authority strict and makes the inner candidate loop fast and bounded.

| Article idea | Adopted as | Where |
| --- | --- | --- |
| The application is the OS; the general-purpose OS is design debt; no shell means no next hop | Unikernel as intended production target, with an explicit threat model before any security claim | Vision §2, §3, §7; plan P10 |
| Every service is a library | Effect rows as the image's capability manifest; device manifest derived from residual effects | Vision §7; plan P4/G4 |
| If you have an oracle, porting is a loop | Existing implementations as differential oracles for handler libraries; MirageOS reuse vs port decided at P4/P8 | Vision §8, §13; plan P8 |
| Back pressure; compile time is a tax | Semantic per-change check registered with the controller; latency target; heavy work in later tiers | Vision §13; plan §1, P1, §15 |
| C gives too little back pressure | Sanitizers on hand-written runtime C, or a safer language for that component | Vision §13; plan P5 |
| Tool-calling a human is not AGI | No per-iteration human approval inside an approved run; humans keep authority changes | Vision §13; plan §1 |
| Nix overlays; Nix machine tests | Flake-built images, dependency epochs, overlays for upstream fixes; machine tests for fleets | Vision §16; plan P0, P8 |
| `.mli` files as agent context | Checked module interface files with effect rows | Vision §15; plan P6 |
| Grammar lookup table; languages designed for agents | Versioned grammar card, tested by agents writing the sample suite | Vision §15; plan P6/G6 |
| Breaking changes with skill packs | Skill pack per release with migration tested on the retained corpus | Vision §15; plan P6, G10 |
| Multi-source time (NTP, RADclock, TigerBeetle) | Production time handler over several sources with disagreement reporting | Vision §18; plan P7/G7 |
| PII wrapper at the logging boundary | Redacting logging handler by default, policy as a pluggable module | Vision §15; plan P10 |
| S3-primary storage with local cache | Candidate object-store storage profile | Plan P8 |
| Orleans-style virtual actors (Spaceleans) | Candidate later profile on top of supervision | Plan P7 |
| Projects as katas, redone as models improve | Optional throwaway surface prototype after G1 | Plan P6, §18 |

**Not adopted or deferred.**

- Claims that porting is trivial or that in-guest privilege separation is "a prompt away" are not planning assumptions; each port and each privilege profile carries its own oracle, boundary inventory and gate evidence.
- Dependent types are recorded as a later research option for added back pressure, not a P6 requirement.
- Self-hosting the compiler (the T-diagram path) is out of scope until a stable surface language and G6 exist.
- Choosing OCaml as an implementation language is not decided here; it is one option at the §8 library decision.
- Nothing in this amendment changes TC0 0.2 semantics, profile identities, the evidence contract (§16) or the rule that only the registered gate evaluator issues qualification verdicts.

