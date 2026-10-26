# Team execution through G3 — coordinator checkpoint

## Authorized sequence

The owner supplied the M0–M4 execution plan on 2026-10-11. This checkpoint carries its next executable boundary across sessions. The coordinator may publish milestone PRs; the owner controls merge and acceptance of qualification authority. At most six active agents including the coordinator; isolated writer worktrees and exclusive file leases. Model/candidate lanes receive the frozen public contract without each other's transition implementation. Shared filesystem and model family remain independence limitations.

1. **M0:** checkpoint the six reconciled documents, independently review evaluator header/ledger registration cleanup, publish PR and wait for owner merge.
2. **M1:** after merge, demonstrate the official digest-pinned Nix Linux/amd64 runner on existing Docker; run G1 only through the controller on the exact merged commit, retain receipt and stop for review. Require 4 CPUs, 6 GiB RAM, 15 GiB available disk, read-only source, separate build/cache, no home/credentials/socket/host process namespace. Namespace or Nix failure is BLOCKED; no unsandboxed fallback or automatic new host.
3. **M2:** after current-source G1 PASS and receipt review, freeze separately reviewed B contract (`tc0-b-handler-demo/1`, `tc0-b-handler-catalog/1`, `tc0-b-handler-tape/1`, `TC0-REF-STEP/0.2`). Implement representation/first slice, nested handlers, generated counterexample/reduction/exact replay and candidate-only repair, then reviewed final-source A+B G2 evaluation. Record explicit G2 waiver acceptance.
4. **M3:** after G2, freeze each C increment's encodings; implement tasks/scopes/cancellation, channels/stale-waiter repair, resources/inherited handler ownership, then idle-only virtual time. Run A/B/C regressions after integration. Preserve child failure after descendant cleanup/join, same-transition sibling cancellation, and continued parent body.
5. **M4:** freeze source/manifest; independently review and qualify G3 with required mutants, equivalent and classification controls, lifetime-invalid rejection, generated discovery/repair, strict replay and bounded exploration. Compare required fixtures on two exact-arithmetic Shen ports before portability claims. Publish evidence PR; full TC0 freeze requires owner scope-specific waiver acceptance and current-source PASS.

Each package has a two-hour ceiling and at most six repairs, without renewal. One heavy campaign at a time. Defaults: B 32 cases/200 nodes and steps/100 reductions; C smoke 4 tasks/2 capacity-at-most-two channels/2 resources per task/32-byte values/200 nodes and steps; exhaustive-small 2 tasks/1 capacity-one channel/1 resource per task/6 nodes/30 steps, integers -2…2 and sleeps 0…2. Exploration caps 50,000 states/200,000 edges. Ordinary invocation watchdog 30 seconds; discovery/reduction 300 seconds. Streams 4 MiB each, trace 8 MiB, retained milestone bundle 256 MiB. Required exhaustive cap hit remains UNKNOWN.

## M0 evidence and next gate

- Starting source: `8cc4c92`; original six modified documents preserved in the original checkout.
- Documentation checkpoint: `ec46b3e`, on `codex/fenrir-m0-checkpoint` in the sibling `fenrir-m0` worktree.
- Cleanup changes only the evaluator docstring and three ledger descriptions; no requirement, status, acceptance rule, manifest, transition or executable logic changes.
- Focused ledger tests: 2/2 PASS; structural checker: no problems and qualification UNKNOWN (as designed). `git diff --check`: PASS.
- Read-only Kingsbury and Torvalds reviews run concurrently, with no writer leases assigned. Both reviews completed; both identify the existing standalone source-drift weakness below. Coordinator repeated validation: 30/30 ledger/controller tests PASS, no skips.
- M1 preflight: Docker reports `linux/aarch64`; host `df -h .` reports 6.5 GiB available, below the required 15 GiB. **Runner BLOCKED.** No image pull, container, qualification run or cleanup mutation was started. Docker inventory is shared and was not pruned.
- Current-source G1: UNKNOWN. G1 PASS at `1db7471` remains historical. G2/G3: NOT-EXECUTED.

## Review findings retained

Kingsbury review found the authority-path prose overstated registration; it now says the TC0 Python checkers invoked by the gate. It also identified an existing standalone evaluator weakness: `source_identity()` overwrites `gate.head` before the final comparison, so that comparison cannot detect a HEAD change. The registration predicate checks the path and reviewed status but does not independently check the controller's complete authority configuration. M0 changes no executable logic. Standalone reports are supporting evidence only; M1 admission requires the controller's source/configuration drift checks and receipt. A standalone evaluator hardening change needs a separate reviewed authority patch.

Next: owner merges M0; resolve disk availability to at least 15 GiB, verify it live, then establish the pinned amd64 runner and execute M1 on the exact merged commit. Do not start B/C implementation before their qualification/review dependencies. Native compilation, production scheduling, deployment, host epochs, Solo5, surface syntax and optimization remain outside this campaign.
