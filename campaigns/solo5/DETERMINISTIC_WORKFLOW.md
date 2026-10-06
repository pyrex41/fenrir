# Deterministic Solo5 development workflow

Status: PROPOSED, not started or qualified. Planning packet only; no drive, infrastructure, upstream patch, evaluator registration or deployment authorization.

Authority: `01_FULL_VISION.md` §§7–10 and `03_PHASED_EXECUTION_PLAN.md` §8. This packet does not change those plans, language semantics, or controller authority. The TC0 drive stopped at its independent-repair review boundary; do not silently redirect or renew it.

## 1. The target and the two distinct deliverables

**D1 — cooperative deterministic semantic execution:** a pinned Solo5 guest running an explicit, single-threaded reference-profile runtime. The host supplies decisions and all environment inputs. Compatible artifact/input/tape identities reproduce identical semantic observations, including the same first discrepancy. Clocks and readiness come only from modeled state. Infrastructure timing is not semantic time.

D1 assumes the audited guest/runtime follows the protocol and does not execute arbitrary counter/entropy instructions or undeclared native code. Isolation can still protect the host from a defective guest. Isolation does not prove the guest obeys semantic safe points or reports its hidden computation honestly.

**D2 — independently enforced native instruction control:** reproducible budgets and validated treatment of clock/entropy/device instructions even when code never yields. Requires a separately demonstrated emulator or verified metering boundary. Stock Solo5, seccomp, one CPU and a wall watchdog do not supply D2.

Do not market D1 as whole-machine determinism. If arbitrary agent-written native code is a requirement, D2 is a required product gate, not a cosmetic follow-on. Byte-identical guest RAM is not a D1 requirement; raw-address nondeterminism must not influence semantic choices, values or stable identities.

## 2. Measured starting point

Existing files:

- `backends/solo5/{Dockerfile,profile.json,probe.c,README.md}`
- `tools/solo5/{setup.py,spike.py}` and `tests/solo5/test_frames.py`
- Historical evidence under `build/solo5/{setup,spike,spike.logs}.json`

Measured target: Solo5 v0.9.3, commit `38e0c348be231a2a3c59510a5caabf562792679f`, **SPT/Linux/AArch64**, inside Docker. It is not HVT/KVM. Ten cold Pong/Terminal runs matched; tested open/socket attempts received SIGSYS; a protected sentinel stayed unchanged. Stock wall-clock samples varied. Inputs currently arrive once through the command line; output uses console framing. There is no interactive Run/AdvanceTime channel or TC0 guest.

Initial source search identifies required audit sites, not completed audit findings:

- `bindings/spt/bindings.c`: direct Linux monotonic/realtime clock calls.
- `bindings/spt/net.c`: yield/readiness and elapsed-time handling.
- `tenders/spt/spt_core.c`: clock syscall permissions and sandbox setup.
- `bindings/crt_init.h`: CPU ticks during startup.
- `bindings/cpu_aarch64.h`: `cntvct_el0` read.
- HVT/virtio have additional counter/clock implementations; switching targets requires a new audit.

The installed APK inventory is not a reproducible package lock. Evidence must be regenerated against the actual selected environment before extending the claim.

## 3. Dependencies and work lanes

```text
S0 profile/target decision → S1 reproducible baseline
                             ├→ S2 interactive transport → S3 virtual environment
                             ├→ S4 minimal native guest ─────────────┐
                             └→ S6 enforced isolation                │
                          S2 + S3 + S4 → S5 exact replay ─────────────┤
                          S5 + S6 → S7 perturbation/mutation → S9 review

S0 → S8 bounded instruction-control feasibility → separate D2 gate
```

S2/S3/S4 development may use a clearly named **pure-core backend demo** without pretending TC0-A or G1 is qualified. Scheduling/timer transport probes can be synthetic protocol tests; they cannot count as TC0-C conformance. Full P4/G4 qualification retains the normative dependency on qualified P3/G3 interfaces. A new earlier qualification claim needs separate review, not a renamed gate.

Keep the pure-core repair/evaluator work on its own lane. Do not build B/C, a compiler, an optimizer or a new hypervisor merely to get the first backend demonstration.

## S0 — freeze scope and inspect the actual target

Deliverables: proposed `campaigns/solo5/manifest.json`, environment inventory and requirement ledger. Review before they become acceptance authority.

1. Inspect current Docker/server architecture, upstream instructions, toolchains and process/container cleanup. Confirm the historical target still builds and boots.
2. Select SPT/AArch64 as the initial development target unless measured compatibility forces a change. Record image, source, compiler/linker, bindings, tender, kernel, CPU features and sandbox identities.
3. Enumerate every guest input/time source: startup arguments, memory initialization, auxiliary metadata, allocator/address dependencies, clocks, CPU counters, entropy, device readiness, console, exit, exceptions and libraries.
4. Decide whether the required endpoint is D1 only or D1 plus D2. Record unsupported instructions/foreign libraries and the exact cooperative trust assumptions.
5. Review initial protocol/environment bounds. Proposed starting caps: 200 semantic steps, 200 AST nodes, 16 MiB guest memory, 64 KiB frame, 8 MiB transport output and 30-second wall watchdog per guest. These are tunable development settings, not universal guarantees or language traps.

Exit: one supported target, explicit claim boundaries and dependency inventory. Missing target/toolchain/isolation prerequisites are BLOCKED for affected work, not PASS. No upstream changes yet.

## S1 — reproducible build and lifecycle baseline

Concrete boundaries: extend `tools/solo5/setup.py` only after inspection; add build identity helpers and tests under `tools/solo5/` and `tests/solo5/`. Retain stock `probe.c` as a historical feasibility fixture rather than silently changing its identity.

- Pin packages/toolchain or preserve content-addressed build inputs with a documented reproducibility limitation. Never install moving dependencies during evidence runs.
- Build in an isolated scratch tree without evaluator credentials or writable oracle/checkout mounts. Candidate build commands are also untrusted.
- Record guest binary, bindings archive, tender binary, patch set and complete command hashes, before and after execution.
- Own every process group/container explicitly; retain bounded diagnostics and remove owned execution resources in `finally`. Failed cleanup blocks continuation.
- Establish fixed initial-memory policy and bounded allocator/stack. Zero required state; use stable IDs, never pointers, in semantic outputs.

Acceptance: two clean builds have identical guest bytes under the declared reproducible scope, or a retained byte-level diagnosis limits the build claim. Cold startup, malformed input, guest crash and watchdog cleanup all have distinct classifications. A crash cannot become a semantic trap merely because a wrapper maps its exit status.

## S2 — a real interactive host/guest channel

Proposed new boundaries: `backends/solo5/interactive-probe.c`, `backends/solo5/protocol.{h,c}`, `tools/solo5/interactive.py`, `spec/solo5/protocol-demo.json`, and transport tests.

Perform a bounded feasibility slice before selecting the transport:

- Inspect the pinned SPT tender/bindings for a minimal dedicated bidirectional channel. Use explicit inherited descriptors or a small tender extension only if the sandbox can constrain the exact descriptor set and operations.
- Do not assume stock console provides input. Do not use live networking, TAP, a writable block device or repeated command-line launches to masquerade as an interactive scheduler.
- If a new syscall/device path is necessary, isolate its small upstream patch and review the expanded boundary before using it. Keep modifications in a project-owned overlay, not an unexplained vendor edit.

Define versioned Hello/Init, request, response and terminal records. Bind run ID, direction/sequence, epoch, request kind, semantic site, enabled-domain hash, selected decision and payload lengths. TC0-specific fields must come from the existing or separately reviewed catalog, never an ad-hoc competing scheduler.

Separate diagnostic output from semantic frames. Validate framing, schema, bounds and lifecycle independently of candidate claims. EOF is not successful termination.

Hand-derived transport fixture: Hello → Init → boundary request0 → response0 → request1 → response1 → Terminal/ack → clean exit. Delaying a response must not execute the next semantic transition or alter its payload.

Acceptance negatives: split/coalesced frames, duplicate sequence, wrong run/epoch, unknown field/kind, oversized length, premature EOF, terminal-before-completion, suffix after terminal and crash while waiting. Each fails closed with a retained classification. No seed fallback or implicit fresh decision.

Stop after one bounded transport feasibility slice if the selected target cannot support the channel safely; retain the blocker and review alternatives.

## S3 — virtual clocks, environment and readiness

Proposed boundaries: project-owned Solo5 bindings/tender overlay, `backends/solo5/virtual-env.{h,c}`, `spec/solo5/environment-demo.json`, and `tools/solo5/check-environment.py`.

- Replace guest clock API paths with explicit virtual state; provide a fixed recorded wall-clock origin if the profile exposes wall time. Prefer forbidding an API that has no needed semantics.
- Close startup counter reads as well as normal calls. Audit linked code/disassembly and allowed Linux syscalls. Deny stock clock syscalls once the supported runtime no longer needs them.
- Readiness comes from recorded inputs or the model, not `poll` timeouts or host arrival order. Transport availability is not a semantic event.
- The **language host/model** owns AdvanceTime eligibility. Never advance virtual time because the runner waited in real time; runnable language tasks prevent idle-time advancement.
- No default host randomness. A required entropy service must use explicit recorded bytes with versioned depletion/error semantics; otherwise reject it.
- Disabled devices remain disabled. Ambient host files, network traffic, timezone, locale and directory names cannot become replay inputs.

Hand-derived environment probe: initialize virtual time0; repeated read returns0; real host delay still yields0; explicit recorded advance10 gives10; repeat reads give10. A backward advance or missing response is rejected. Synthetic readiness fixtures must reproduce the recorded readiness set and order. These are environment tests, not qualified language timer semantics.

Acceptance: supported APIs and startup paths stop depending on host clocks; relevant forbidden-syscall probes are denied; counter/entropy instruction probes have explicitly observed dispositions. On SPT, CPU-register reads may remain available despite seccomp: report them as a **D1 trust limitation / D2 gap**, not sandbox closure. Static disassembly alone does not establish safety for arbitrary dynamic code.

## S4 — minimal native semantic guest, before a general compiler

Proposed boundaries: `backends/solo5/tc0-demo/` with a small C explicit-state interpreter, guest loader and checked ABI; guest-side fixtures/tests. Extend host artifact validation, not oracle transitions.

- Start with the existing closed pure-call artifact identity, or define a distinct backend demo identity with explicit omissions. Do not quietly reuse a broader schema for a smaller guest implementation.
- Independently implement explicit Eval/Value/Ready/Return/terminal controls and data continuations. No import or generated copy of Shen transition logic.
- Define exact I64 arithmetic without C signed-overflow undefined behavior, including min-negation/division and values beyond2^53. Avoid host floating-point conversion of semantic integers.
- Define stable function/node/binding IDs, closure layout/capture support, tail destination reuse, bounded buffers and deterministic iteration. Check source-map/catalog coverage.
- Begin with validation on the host and a closed bounded guest loader. Bind the loader and input format to the profile; untrusted bytes must not bypass the host validation boundary.
- Run process-build sanitizers/poisoning where supported, then separately run the actual Solo5 guest. Process tests do not establish guest behavior.

Acceptance: hand-derived arithmetic/emit/trap/call/closure cases agree with fresh independent Shen observations at every published semantic step. Include left trap suppressing right emit, same-result/reversed-emit mutant, tail/non-tail distinctions and completion on the final fuel step. State a smaller supported subset if necessary. Candidate-emitted traces alone are not proof of arbitrary hidden computation.

## S5 — source-bound restart-and-replay

Proposed boundaries: `tools/solo5/{record,replay}.py`, reviewed backend tape/observation schemas and replay perturbation tests. Reuse existing semantic tape concepts without falsely declaring a new backend compatible with existing host tapes.

Header binds artifact/input/source map, oracle/catalog/profile, candidate/guest binary, bindings/tender/compiler, loader/protocol, sandbox policy, CPU/initial-memory profile, environment inputs, initial state and all bounds. Record every decision including singletons, epochs, sites/occurrences, enabled domains and environment responses.

The host independently checks framing, observed outputs, process/container lifecycle and terminal handshake; mediated effects carry host observations. Compare candidate observations with fresh independent model traces. No normalizer may erase/reorder semantic emissions or outcome differences.

- Restart from initial state for every replay. Do not require VM snapshot support.
- Preserve completed, first-divergence and semantic-budget-boundary footers.
- Watchdog/crash/truncation gives incomplete replay unless a separately validated backend captures a reproducible boundary.
- Preserve original and minimized artifacts with independently regenerated tapes; retain the original mutant binary and its identity.
- Changing the patch/binary/options is scenario replay, not exact-original replay.

Acceptance: cold exact replay for admitted completion, same first divergence and final-step/budget distinctions. Missing/extra/reordered choice, wrong epoch/site/domain, altered environment response, stale binary/toolchain and changed bounds fail closed. A known divergent original must replay Exact **and remain Diverged**.

## S6 — enforced execution/evaluator boundary

Proposed boundaries: `tools/solo5/boundary.py`, isolation probes and policy manifest; changes to tender syscall permissions require review. Do not alter protected Pi evaluator inputs as an incidental backend patch.

- Separate candidate build/run inputs from evaluator credentials, model/goldens/tapes and writable evidence publication.
- Test read-only protected inputs, no ambient network/devices, no Docker socket, restricted descriptors, memory/output caps and scratch confinement.
- Probe forbidden file open/write, socket/connect, unexpected syscall/descriptor, path escape, access to evaluator secrets, malformed transport and subprocess behavior. A benign sentinel is sufficient; do not expose real credentials to a probe.
- Audit deliberate clock/counter bypasses separately from filesystem/network isolation.
- Publish the actual trusted computing base: host kernel/container engine, compiler, tender/bindings, runner, model and checking code. SPT is not an independent guest kernel boundary.

Acceptance: enforcement is observed for every required policy row; sentinel/hash verification is before/after; owned cleanup succeeds on every failure mode. Missing enforcement limits or blocks the corresponding claim. A task packet's allowed-path list is not isolation.

## S7 — host perturbation, mutation and retained failures

Proposed boundaries: `tools/solo5/campaign.py`, `campaigns/solo5/repeat-matrix.json` and immutable evidence directories.

Start with10 cold boots per representative fixture; then review a100-run integration matrix across declared perturbations: injected transport delays, host load, fresh run directories, process placement where supported and changed boot allocation conditions within the supported profile. Stronger cross-host claims need separate measured platforms; do not assume architecture portability.

Keep semantic inputs fixed. Different output names, timestamps and diagnostic logs remain outside semantic comparisons; explain every excluded field. Persist sources, commands, actual counts, cap hits and source/toolchain stability.

Required controls/mutants:

- Equivalent control accepted; operand-order and incorrect-arithmetic mutants detected with expected discrepancy.
- Stock clock/readiness accidentally reintroduced: detect ambient dependence or deny it.
- Wrong protocol sequence, ignored domain mismatch, missing decision and fabricated early terminal: rejected with expected classification.
- Guest crash/non-yielding loop/output flood: contained and correctly classified; not a semantic mutant kill.

Acceptance: same compatible tape gives identical semantic prefixes/footers across the declared suite; detected failures have a reproducer and, where meaningful, a smaller case. Report empirical repeat scope, never a universal determinism proof. Generated discovery/reduction is distinct from a manually selected backend fixture.

## S8 — instruction-control track (bounded feasibility, then separate gate)

Run this track early if D2 is required. Start with target compatibility evidence, not a large emulator implementation.

Candidate approaches to evaluate:

1. Pinned instruction-counted system emulator with a demonstrated bootable Solo5 machine/device target, restricted devices and controlled counters/entropy. **Do not assume the current SPT process image runs directly under QEMU system replay.** A virtio target or a Linux guest running SPT introduces a different audited TCB/profile.
2. Independently validated binary metering/control-flow enforcement with restrictions sufficient to prevent counter evasion, indirect-entry bypass and self-modifying/dynamic code. Candidate-inserted counters alone are insufficient.

SPT syscall filtering cannot intercept arbitrary CPU instructions. HVT/KVM is not automatically deterministic; a target change requires clock, device and interrupt re-audit. Do not default to building a hypervisor.

Feasibility acceptance: minimal boot, demonstrated supported replay configuration, reproducible instruction-boundary stop of an infinite loop, explicit handling of counter/entropy instructions and diagnosed unsupported operations. If incompatible, retain BLOCKED evidence and choose a different target through review.

D2 gate: independently enforced non-yielding termination, reproducible count-limit/checkpoint outcomes, replayed device/interrupt behavior, precise instruction-accounting rules and integration with D1 semantic observations. A deterministic native instruction limit is a backend outcome, not automatically a language trap. Machine replay does not imply language conformance or alternative-schedule exploration.

## S9 — independent review and qualification packet

Freeze and independently review requirement manifest, monitor/protocol versions, allowed normalization, trust boundary and evidence. Preserve separate verdicts for transport, environment mediation, isolation, semantic replay, native instruction control and full TC0 conformance.

Publish supported profile, pinned build instructions, source inventory, requirement verdicts, choices/trace/footer, original/minimized failures, observed cleanup and reproduction commands. Register a runnable evaluator only after explicit authority review; no agent-authored claim or development-test receipt promotes qualification.

For D1, any unmediated native-instruction capability is prominently disclosed and unsupported untrusted code excluded. For D2, no missing enforcement row can be hidden beneath D1 results. Full G4 remains subject to the normative language prerequisites.

## 4. Execution sizing and stop rules

Organize as multiple separately authorized finite campaigns, not one unattended enormous drive:

1. S0/S1 and bounded S2 transport feasibility.
2. S2 transport negatives plus S3 environment mediation.
3. S4 minimal guest and S5 restart/replay integration.
4. S6 boundary hardening and S7 perturbation/mutation.
5. S8 D2 feasibility/implementation when required, with its own target review.
6. S9 independent authority review and qualification.

Each campaign selects one dependency-ready vertical slice, names allowed files, records hand-derived expectations, measures synchronous checks, checkpoints and stops at its budget/review boundary. Reduce initial scope if throughput does not fit; never erase caps. Timeline estimates should follow measured transport/native-port throughput rather than invented certainty.

Stop on unavailable prerequisites, protocol ambiguity requiring model changes, unsupported target, source/protected-input drift, unresolved cleanup or unapproved authority/infrastructure change. No automatic renewal, push/deploy, background candidate jobs, privileged host setup or nested paid repair sessions.

## 5. First executable assignment after authorization

**Slice:** S0/S1 baseline revalidation plus S2 interactive transport feasibility; no TC0 semantic port yet.

**Allowed project files:** new inventory/transport-probe helpers under `tools/solo5/`, a distinct `backends/solo5/interactive-probe.c`, tests under `tests/solo5/`, and development evidence under a fresh `build/solo5/` directory. Preserve existing stock evidence. Propose any tender/bindings overlay and descriptor policy expansion for review before applying it.

**Inputs:** pinned upstream checkout, existing profile/build helpers, this packet and normative §8. Inspect local instructions before touching external source. Missing Docker/toolchain/safe transport access stops the affected slice.

**Hand expectations:** two decision boundaries require two distinct host responses; guest emits no second boundary transition while blocked for the first response; delayed host delivery changes no semantic payload; mismatched sequence is rejected; guest crash/EOF has no successful terminal handshake; all owned execution resources are removed.

**Exit artifact:** target/source/toolchain inventory, proposed transport design with measured feasibility, exact commands/bounds, positive/negative framed exchanges and cleanup evidence. Keep deterministic-backend qualification UNKNOWN. Review next slice rather than expanding into an incomplete runtime or emulator.
