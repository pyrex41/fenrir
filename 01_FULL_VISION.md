# Fenrir language and Gleipnir deterministic execution platform

Version 0.2 • Semantic and execution-plan revision • Proposed architecture and implementation contract

**Working names:** Fenrir is the language and overall project. Gleipnir is its deterministic harness and conformance environment. ShenCheck retains its existing name as reusable campaign, replay, and evidence infrastructure. TC0 remains the identifier of the first language core; its contract revision is now 0.2.

**Revision status:** This is a substantive revision responding to [review.md](review.md), not a naming-only change. Version 0.1 tapes and gate evidence are not automatically compatible. These documents propose requirements; no executable schema, oracle, backend or gate is claimed to be qualified by this revision. The existing specification ZIP is a historical v0.1 bundle and is not the current authority.

## 1 Purpose and reading order

Build Fenrir, a practical native language inspired by Koka whose semantics, runtime, and standard services are specified through executable Shen models. Gleipnir explores legal executions, checks independently observed behavior, minimizes counterexamples, and supplies precise feedback to implementation agents. The intended result combines efficient functional programming and effects with straightforward builds, structured concurrency, useful diagnostics, and reliable deployment.

This is a development specification, not a claim that the platform exists or is proven correct. MUST and MUST NOT denote acceptance requirements; SHOULD permits a documented exception; MAY denotes an option. All performance benefits are hypotheses until measured. No calendar delivery dates are implied.

Read this document for the full product and architecture, [02_TINY_LANGUAGE_CORE.md](02_TINY_LANGUAGE_CORE.md) for the normative first machine, and [03_PHASED_EXECUTION_PLAN.md](03_PHASED_EXECUTION_PLAN.md) for implementation order and gates. If an architectural aspiration conflicts with the core contract, the core contract controls version 0.2 behavior for its declared execution profile. Changes require an explicit versioned amendment and new fixtures.

The initial deliverable is an executable pure-language slice with an independent candidate, strict replay, and a minimized implementation failure. Handlers and structured concurrency follow as separately qualified vertical slices. Full TC0 qualification is a later bootstrap milestone, not a prerequisite for useful evidence. The long-term deliverable is a production language and runtime.

## 2 Product vision

A developer writes direct-style functions using immutable values and explicit environmental effects. The compiler infers or checks effects and compiles efficient native code. A standard runtime owns task lifetimes, deadlines, resources, and service supervision. The same application can run with production handlers, local development handlers, or a controlled simulation environment.

The product promise is that environmental dependencies are visible, substitutable, and testable. Every supported deterministic operation has a specified interpretation. Failures produce retained evidence that another machine can inspect and replay under compatible versions.

Borrow these qualities without attempting to clone the entire source languages:

| Inspiration | Product requirement |
| --- | --- |
| Koka | Effect-aware semantics, immutable data, native compilation, a path to ownership-aware reuse |
| Go | One install, predictable builds, good diagnostics, coherent tools, easy deployment |
| Elixir | Owned tasks, supervision, bounded communication, operational inspection |
| Common Lisp | Interactive evaluation, inspection, rapid iteration, carefully scoped code replacement |
| Shen | Executable semantics, typed model construction, logic relations, portable oracle implementation |

The initial implementation MUST NOT require end users to understand continuations, reference counts, or model checking to write ordinary programs. Advanced mechanisms must remain accessible to library and runtime authors.

## 3 Goals and exclusions

### Required outcomes

1. A small independent Shen reference machine defines permitted behavior.
2. Every nondeterministic choice in the supported profile is explicit and retained.
3. A candidate compiler/runtime is checked against the model through semantic observations.
4. Known implementation defects are detected, minimized, and replayed.
5. Limits, incomplete exploration, unsupported effects, and ambiguous results are reported honestly.
6. Candidate builds and runs cannot modify acceptance authority within the declared isolation boundary; only the external evaluator issues verdicts about independently observed behavior.
7. Existing ShenCheck capabilities are reused after source-grounded validation.
8. Production performance is evaluated separately from simulator throughput.

### Explicit exclusions for the first core

Arbitrary cloud applications, unrestricted C FFI, shared-memory atomics, multicore weak-memory exploration, durable distributed execution, full POSIX, unrestricted multi-shot continuations, hot replacement of suspended frames, and a new production hypervisor are excluded. These can be future profiles, not implicit promises of version 0.2.

The language need not deploy as a unikernel in production. Solo5 is initially an execution and validation backend. A Linux process backend and a production scheduler can implement the same semantic contracts.

## 4 The key idea

The reference machine is a deterministic transition function parameterized by an explicit decision:

```text
enabled(State) -> ordered finite set of Decision
step(State, Decision) -> State × ordered list of Observation
check(Model, History, Bounds) -> structured Verdict
```

Determinism means that the same initial state and valid decision sequence produce the same semantic observations. It does not mean that only one schedule is legal. Exploration deliberately tries different schedules, inputs, and faults.

The model defines the contract. The harness explores and checks it. The production runtime implements a declared language/runtime profile. These responsibilities MUST remain distinguishable even if packaged together.

Reference-machine steps and language-visible scheduling boundaries are separate concepts. `TC0-REF-STEP/0.2` initially makes every published machine step a Gleipnir scheduling and cancellation boundary, for precise oracle debugging and exact replay. It is not the permanent scheduling contract of compiled Fenrir. A future compiled profile MUST separately specify switch/cancellation boundaries, time progress, fairness, observable atomicity, and trace refinement before claiming conformance. Changing reference frames requires a new reference-profile identity; production semantics must not silently inherit such changes.

## 5 Architecture and trust boundaries

| Component | Responsibility | Trust position |
| --- | --- | --- |
| Shen semantic kernel | Values, evaluation, effects, task transitions, observations | Small reviewed oracle |
| Property and history checkers | Invariants, bounded response, application consistency | Independently validated evaluators |
| ShenCheck campaign adapter | Choice tapes, exploration, corpus, minimization, evidence | Trusted test infrastructure |
| Controlled environment | Time, communication, storage/fault models in later profiles | Versioned environment specification |
| Execution adapter | Load candidate, mediate requests, enforce protocol and limits | Trusted host boundary |
| Candidate compiler/runtime | Implement the language and runtime contract | System under test |
| Implementation agent | Produce patches from tasks and counterexamples | Cannot change acceptance authority |

The oracle SHOULD run outside the candidate guest. A guest crash must not destroy the checker. Candidate reports are evidence inputs, never verdict authority. External outputs, lifecycle behavior, protocol completion, and independently decoded artifacts must corroborate candidate assertions.

The initial trusted computing base includes the host OS, compiler/toolchain used to build the oracle and harness, Shen port, Solo5 components, runner, serializer, and checker. This project does not initially prove that entire base correct. Pin versions, test the evaluator, and use independent implementations to reduce common-mode mistakes.

### Threat model and independently observed facts

Distinguish accidental implementation bugs, untrusted candidate/build code, and deliberately fabricated reports. Gleipnir validates observable behavior at controlled boundaries; a perfectly fabricated admissible trace does not reveal hidden computation by itself. Every profile publishes which facts it observes or enforces independently: process/guest lifecycle, framing/EOF, decoded outputs, mediated effects, termination handshake, and any instruction or memory controls. Hidden native state is not claimed to be inspected unless a validated mechanism supplies that observation.

Candidate builds and execution MUST use isolated environments with read-only evaluator inputs, separate writable build/output directories, no evaluator credentials, explicit network/device policy, and source/artifact verification. The evaluator hashes protected inputs before and after execution and rejects unauthorized drift. A writable-path list is an agent workflow rule, not sandbox enforcement. P0 records the supported sandbox and tests attempted writes, credential exposure, and forbidden external access; unsupported enforcement blocks the corresponding security claim.

## 6 Three forms of specification

### Language specification

Defines values, evaluation order, lexical scope, errors, effects, handler behavior, and termination. Reviewed explicit rules and their qualified executable Shen model provide authority for the selected core/profile; an unqualified interpreter does not establish semantics merely by arriving first. Native code may use different data representations as long as observations conform.

### Runtime specification

Defines runnable tasks, blocking, channel operations, cancellation, scope completion, timers, and resource lifetime. The scheduler selects among legal transitions. It cannot invent new semantics.

### Application specification

Defines domain state and permitted histories: registers, queues, leases, transactions, idempotent requests, or application-specific state machines. The full system can preserve multiple possible states when observations are ambiguous. Exceeding a state-set limit returns unknown, not a fabricated pass.

The first core tests language/runtime correctness. Later application models exercise the whole stack without changing the language's meaning.

## 7 Solo5 as the first isolated backend

Solo5's thin guest API and separation between bindings and tender make it a promising integration point. Upstream architecture documentation explicitly associates eliminating interrupts with more deterministic behavior and easier replay. This is architectural suitability, not evidence that stock Solo5 is a deterministic harness.

A proposed deterministic profile MUST provide:

- One logical execution thread per guest for the first version.
- Fixed initial memory layout policy and a bounded guest memory allocation.
- No ambient network or writable host filesystem access.
- Guest-visible clocks supplied by virtual state rather than host time.
- Explicit environmental inputs and deterministic readiness responses.
- Stable semantic IDs independent of guest addresses.
- Deterministic task scheduling at specified semantic boundaries.
- A bounded request/response transport with framing, sequence checks, and strict replay.
- Controlled startup inputs, CPU feature profile, locale-independent encoding, and pinned images.

Both guest bindings and host tender require inspection. Intercepting a host call is insufficient if a clock reads a CPU counter inside the guest. Direct timestamp instructions, hardware entropy, hidden library calls, asynchronous callbacks, and address-dependent behavior must be removed, mediated, or classified as unsupported. A successful ordinary run is not evidence of closure over these sources.

Solo5's existing API is not to be assumed to include our event protocol, semantic snapshots, deterministic instruction budgets, or replay exploration. Those are project work. Prefer a small extension or dedicated test adapter after a compatibility spike; do not publish an upstream compatibility claim without verification.

## 8 Unikraft and instruction emulation

Unikraft is a later backend candidate when existing OS libraries or application compatibility materially reduce implementation effort. Its selected scheduler, timers, drivers, libraries, and device interfaces all become part of the behavior under test. A small image alone does not establish determinism.

An instruction-counted emulator is a complementary backend for native code that loops without yielding, machine-level replay, and reverse debugging. QEMU documents record/replay using instruction counting and logged nondeterministic inputs. A compatible pinned machine/device configuration must be demonstrated. Record/replay does not by itself explore alternative executions or support arbitrary schedule mutation.

Decision rule: use Solo5 for the small runtime and isolation; add emulation when independent instruction control is required; adopt Unikraft only for a documented compatibility use case. Do not block the semantic core on constructing a novel hypervisor.

## 9 Determinism and conformance claims

| Claim | Required evidence |
| --- | --- |
| Checker replay | Same saved semantic history yields the same checker result under pinned versions |
| Scenario replay | Same materialized workload and choices are reissued |
| Exact semantic replay | Same compatible candidate and decisions yield identical normalized semantic trace |
| Native machine replay | Machine state and nondeterministic inputs replay under a separately validated backend |
| Bounded exhaustive result | Every reachable transition in the stated finite model was explored with no truncation |
| Production conformance evidence | Selected production executions are admitted by the abstract model |

No row implies all other rows. Semantic replay does not require equal addresses or allocation order. Exact replay MUST reject a missing, extra, reordered, or incompatible choice; it MUST NOT fall back to fresh randomness and continue claiming exactness.

For native implementation I, abstraction function alpha, and model M, the central requirement is that alpha(trace(I)) is admitted by M. Internal implementation steps may stutter without producing a semantic event. The abstraction function is versioned and reviewed; it cannot erase outcomes relevant to a property.

Finite testing supplies bounded evidence. General refinement requires a separate proof. A model with finitely bounded inputs but unbounded execution is not a finite exhaustive campaign.

## 10 Bounds and resource semantics

Every campaign manifest specifies program size, input domain, semantic steps, task count, channel capacities, timers, trace size, model-state count, and wall-clock watchdog. Native profiles add memory, stack, and instruction-control settings.

Distinguish three outcomes:

1. A modeled resource limit: a defined program-visible trap or result.
2. Search truncation: exploration incomplete and verdict unknown for the uncompleted claim.
3. Infrastructure watchdog: execution stopped without establishing a semantic outcome.

Semantic fuel cannot stop arbitrary broken native code unless a trusted execution mechanism enforces progress. Candidate-inserted counters alone are not an independent enforcement boundary. Watchdogs protect infrastructure; they do not turn real elapsed seconds into semantic time.

Physical allocation limits and logical language limits are distinct. Compiler optimizations may change physical allocation. They MUST NOT alter a specified language-visible quota by accident. Version 0.2 defines no language-visible physical heap quota; later resource APIs require a representation-independent charging model or an explicitly implementation-specific contract.

## 11 Property interface and guidance

Provide stable property IDs, source locations, typed details, and a catalog before a campaign begins. The standard vocabulary is invariant, forbidden event, reachability target, bounded response, and history contract. Report trigger counts and observation coverage.

An invariant with no relevant observations is not silently credited as exercised. A reachability target with no witness is not proof of impossibility unless exhaustive search establishes it. Bounded response specifies its trigger, cancellation/discharge rules, profile-specific time or step deadline, and fairness assumptions.

Exploration state is the product of machine state, property-monitor state, and remaining bounds. Outstanding obligations, history summaries, coverage/trigger state relevant to acceptance, and fairness monitors cannot be discarded merely because runtime states match. Gate aggregation is a separate versioned evaluator rule; prefix safety evidence cannot satisfy a required completion or progress claim.

Structured choices expose domains such as runnable task IDs or eligible delivery IDs instead of opaque random integers. Guidance may prioritize inputs but cannot change legal transitions. Guided exploration and minimization must retain the resulting decisions rather than rely on a seed alone.

Use Antithesis-compatible assertion export where semantics align. Keep native temporal properties distinct from similarly named SDK assertions. An SDK compatibility layer is not an Antithesis execution-environment replacement.

## 12 Histories and Jepsen integration

Keep operation invocation, completion, logical operation ID, attempt ID, actor, arguments, result, and outcome certainty. Timeout after commit remains indeterminate from the client's perspective. A known failure without an applied effect differs from an unknown result.

Use existing ShenCheck exports and independent Elle/Knossos checks for supported workloads. Validate mappings against actual fixtures. An internal simulator can observe state unavailable to a client; retain that diagnostic truth separately rather than silently giving a client-history checker privileged information.

Do not force a total physical order on truly concurrent production operations. Controller sequence orders recorded observations, while the checker respects the history's admissible precedence and ambiguity.

## 13 Agent implementation workflow

The implementation agent receives a requirement, relevant model rules, interfaces, permitted files, bounded examples, and an acceptance command. It produces source changes and an explanation. The evaluator builds those changes independently and records source and binary hashes.

On failure the agent receives a minimal program/input, semantic tape, expected and observed event, violated rule ID, first divergence, and reproduction command. Evaluation uses retained public regressions plus fresh generated campaigns. The agent cannot change oracle code, golden expectations, property catalogs, or gate configuration in its implementation patch.

A suspected specification defect becomes a separate proposal with a distinguishing example. Acceptance authority reviews that change, versions the specification, and reruns historical cases. Infrastructure failure, unknown, and skipped checks cannot promote a candidate.

This is counterexample-driven development. It resembles counterexample-guided synthesis but is not automatically a complete synthesis procedure: the language, search domain, and candidate space may be unbounded.

## 14 Compiler and memory management strategy

Start with an explicit monomorphic core AST, a straightforward reference interpreter, and a conservative native implementation developed together by slice. An independently tested artifact validator guards the execution boundary; formal verification is not an initial claim. The first production-oriented backend should use the existing Koka/C experience where reusable; compatibility is a spike, not an assumption.

Later add row-polymorphic effects, type inference, richer data, and ownership-aware IR. Perceus-inspired reuse must preserve alias observations, error behavior, and effect order. No initial requirement mandates eliminating GC. A simple safe allocator or tracing collector may be preferable while semantics stabilize.

Differential tests compare reference evaluation, conservative compilation, and optimized compilation. Sanitizers and allocator instrumentation detect physical errors beyond the abstract machine's observations. Benchmark runtime overhead, memory, build time, and tail latency separately. No optimization is accepted solely because generated code appears efficient.

## 15 Production usability

The mature distribution needs package resolution and lockfiles; hermetic toolchains; formatter and language server; readable effect/type errors; supported platforms; standard networking, storage, serialization, and telemetry; stable cancellation/resource conventions; source-level debugging; compatibility policy; and security maintenance.

Interactive development should first support evaluating code and routing new work to a new module version. Replacing live suspended continuations is a separate semantic feature. Production record capture is opt-in with sensitive-data policy and bounded overhead; arbitrary production executions are not promised to replay unless all required nondeterminism was captured.

## 16 Evidence and reproducibility

A failure bundle contains the manifest, source or content-addressed source references, compiler/runtime/oracle/backend hashes, validated core program, inputs, environment state, choices, trace, property catalog, verdicts, minimization provenance, and reproduction instructions. Retain both original and minimized cases.

Canonical encoding, schema version, hashing algorithm, and normalization rules are explicit. Snapshot state includes runtime state, event queues, virtual clocks, environment state, tape cursor, and checker obligations. Guest RAM alone is not a complete snapshot. Version 0.2 uses restart-and-replay; snapshots are a later optimization validated against that baseline.

Secrets and production data are excluded by default. Redaction changes an artifact and may break exact replay; label the resulting limitation rather than claiming byte identity.

## 17 Risks and mitigations

| Risk | Required response |
| --- | --- |
| Oracle and implementation share the same error | Independently structured oracle, mutation tests, hand-derived fixtures, external checkers |
| Hidden nondeterminism | Boundary audit, repeated runs, adversarial host perturbation, explicit supported profile |
| State explosion | Honest bounds, symmetry/POR only after soundness validation, layered campaigns |
| Simulator differs from production | Trace refinement, production-backend campaigns, separate real concurrency tests |
| Agent overfits tests | Fresh generators, held-out campaigns, mutant evaluation, protected acceptance rules |
| Runtime grows before semantics settle | Vertical slices and phase gates |
| Kernel work dominates language work | Start with a process adapter, then Solo5, keep emulator optional until needed |

## 18 Definition of project success

The first success is an independent pure candidate for a qualified TC0-A slice: Gleipnir finds, minimizes and strictly replays an evaluation-order or arithmetic defect, an agent repairs it, and fresh evidence confirms the repair. The next bootstrap successes qualify handlers (TC0-B), structured concurrency and conservative lifetimes (TC0-C), then full TC0. Mutant requirements expand with each implemented component rather than delaying the first candidate until the whole core exists.

TC0 uses idle-advance virtual time. Production deadlines require a separate elapsed-time contract; scheduler fairness alone cannot make idle-only time progress. A later success is a supervised service whose real fault histories are independently checked. Production success additionally requires usability, performance, compatibility, and operational gates in the execution plan.

## 19 Source grounding and limitations

These references were inspected during the design discussion on 2 October 2026. Branch URLs can change; Phase 0 MUST pin exact commits and retain file hashes before implementation. Repository statements are not independently executed test results.

- [Koka repository](https://github.com/koka-lang/koka) and [language book](https://koka-lang.github.io/koka/doc/book.html): effects, native implementation, Perceus, tooling and development context.
- [Solo5 architecture](https://github.com/Solo5/solo5/blob/main/docs/architecture.md) and [API](https://github.com/Solo5/solo5/blob/main/include/solo5.h): thin execution interface, tenders, clocks and I/O.
- [Unikraft](https://github.com/unikraft/unikraft): modular library-OS alternative.
- [QEMU replay documentation](https://www.qemu.org/docs/master/system/replay.html): instruction-counted record/replay, devices and snapshots; supported configurations require validation.
- [Antithesis SDK](https://antithesis.com/docs/reference/sdk/), [properties](https://antithesis.com/docs/reference/sdk/define_test_properties/), [structured randomness](https://antithesis.com/docs/reference/sdk/generate_randomness/): instrumentation and guidance ideas.
- [Jepsen](https://github.com/jepsen-io/jepsen): workloads, faults and history checking.
- [ShenCheck](https://github.com/pyrex41/shencheck), [choices](https://github.com/pyrex41/shencheck/blob/main/crates/shencheck-core/src/choice.rs), [model sets](https://github.com/pyrex41/shencheck/blob/main/crates/shencheck-core/src/model.rs), [replay](https://github.com/pyrex41/shencheck/blob/main/crates/shencheck-runner/src/replay.rs), [Antithesis integration](https://github.com/pyrex41/shencheck/blob/main/docs/ANTITHESIS.md), [Jepsen integration](https://github.com/pyrex41/shencheck/blob/main/docs/JEPSEN.md): inspected reuse candidates. Existing SDK-randomness replay does not control OS scheduling or I/O. The new language-specific machine and deterministic Solo5 backend remain proposed work.
