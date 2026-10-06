# Fenrir / Gleipnir

**Current stage: working research prototypes and a developing test harness—not a
usable or qualified programming language yet.** Fenrir is the planned language;
Gleipnir is the development, exploration and conformance harness.

## How far along are we?

We have moved beyond plans: there are executable Shen models, independently
structured development candidates, checked artifacts, hand fixtures, generated
counterexamples, reduction and strict replay. A small arithmetic candidate has
also run natively inside Solo5 with an external Shen comparison.

However, **the first language qualification milestone (G1 / TC0-A) is not yet
complete**. Most recent work has hardened the native development host, rather
than added user-facing language features. Passing host tests are useful progress,
but are not evidence that the whole language is implemented or qualified.

A percentage would be misleading: a small demonstrated arithmetic/closure slice
is very different from the compiler, runtime and tools needed for the full vision.
Think of this as **early executable bootstrap work, before the first qualified
language release**.

| Area | What exists | What is not established |
| --- | --- | --- |
| Specification | v0.2 architecture, core contract and phased plan | Full frozen, executable acceptance authority |
| Pure-language development | Shen arithmetic, expression, closure and pure-call models; independent development candidates; validators and distinguishing fixtures | Complete, qualified TC0-A constructor/frame coverage and integration |
| Counterexample loop | Generated operand-order failures, bounded reduction and source-bound strict replay | Genuinely independent candidate repair followed by fresh independent acceptance |
| Native arithmetic spike | Small C/Solo5 candidate; historical model comparisons, hand cases, generated failure and cold replay | Full language backend, machine-level determinism, native startup/counter closure |
| Native host | Go orchestration, bounded readers/output, source inventories, owned process/container cleanup, session/replay and selected campaigns | Current-source live validation of recent repairs; full hostile-peer/corpus/perturbation obligations |
| Qualification | Explicit verdict separation and bounded development workflow | A configured TC0-A qualification evaluator and a qualified G1 release |
| Later language/product phases | Requirements and dependency order | Qualified handlers, concurrency/lifetimes/time, production compiler/runtime, practical surface language, package tooling and deployment |

The current pure candidates are development machines, not a production Fenrir
compiler or end-user language distribution. See [`runtime/tc0/`](runtime/tc0/),
[`models/tc0/`](models/tc0/) and [`tools/tc0/`](tools/tc0/) for the executable work.

## Latest native-host progress

The recent Go host pass added executable checks for:

- Exact consistency between Node lowering data and its generated C data header.
- Docker-reported command/entrypoint/path/arguments against intended launch argv.
- Recorded replay command policy, mode, image and guest-path consistency.
- Partial campaign attempt counts bounded by the selected plan.
- Versioned **build receipt v2**, binding the actual compilation command to the
  unchanged fixed recipe and canonical fuel, without reinterpreting old receipts.

The pass retained fail-before vectors: 19 header/data contradictions, 14 launch
metadata contradictions, seven recorded-command contradictions, two partial-count
contradictions and seven compilation-command contradictions. Additional vectors
check swapped replay identities, unsafe representation tokens and preflight order.
These are **adapter/unit development evidence**, not live security certification.
Daemon launch checks occur after launch; receipt consistency is not independent
binary-to-fuel attestation.

Latest local measurements from that pass:

- Pinned Nix **Go 1.27.1** full host race suite: PASS (12.428s), including all 13
  retained real Node hand lowerings.
- Node TC0/lowering regressions: 88 PASS in the same pass, before later Go-only
  repairs.
- Approved workflow development checks: PASS; these test the controller, not
  language conformance.
- Live Shen transport test: skipped in that test invocation, therefore unmeasured.
- **No new native compilation, guest, replay or peer attempts in this pass.**

Historical native evidence includes 13 arithmetic hands and a finite 16-case
generated family whose first evaluated case exposed the operand-order mutant.
Retained reductions found a 9 → 6 → 3-node failure; a valid one-node proposal lost
the failure. This is not full generated coverage or a global-minimality proof.
Later selected campaigns add bounded observations, not full-corpus qualification.
See the [native host README](tools/solo5/native-arithmetic/README.md) and
[repair handoff](tools/solo5/native-arithmetic/REPAIR_HANDOFF.md).

## Current blocker and next steps

**The latest native closure pass is blocked before its live bootstrap.** The local
Docker daemon is responding again, but both exact retained stock/control images
are absent. The local archive search did not locate an image backup. No pull,
rebuild, replacement image or guest execution was performed during restore review.

An exact restore needs the original Docker/OCI archive or a registry recovery
source containing those immutable identities. A rebuild would require a separately
reviewed dependency epoch, not rewriting historical receipts to match new images.

Other outstanding gates before live work:

1. Finish ownership-specific current resource review while preserving the old
   failed run's missing-ownership uncertainty. New cleanup success does not erase
   a historical failure.
2. Reconcile inherited attempt accounting with retained evidence. The recorded
   hardening totals are 26 guest attempts / 17 two-build attempts / 7 peer scenarios;
   final reconciliation remains incomplete.
3. Explicitly review the proposed cumulative 160/72/40 envelope. It is **not yet
   effective**; existing v1 limits remain 100 executions / 40 two-build attempts,
   with the prior peer scope capped at 24.
4. Complete remaining saved-report/footer consistency checks and live prerequisites.
5. Only after those gates, perform one fresh arithmetic bootstrap, stopping without
   retry on cleanup ambiguity; then measure the bounded hostile-peer and corpus scope.

The larger project milestone is still a **qualified pure TC0-A repair loop**:
complete model/candidate/evaluator coverage, retain discovery/reduction/exact-original
replay, obtain an independent repair and validate it freshly. Broader native-host
work does not substitute for that milestone.

Overall language qualification and native startup/counter closure remain
**UNKNOWN**; independent candidate repair remains **NOT EXECUTED**.

## Plans and task packets

- [Full vision](01_FULL_VISION.md)
- [Tiny core v0.2](02_TINY_LANGUAGE_CORE.md)
- [Vertical-slice execution plan and gates](03_PHASED_EXECUTION_PLAN.md)
- [Original review](review.md)
- [Workflow research](workflow_research.md)
- [Pure calls/closures next-slice packet](campaigns/tc0/NEXT_SLICE.md)
- [Native host closure packet](campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md)
- [Development build receipt v2](spec/solo5/native-arithmetic-demo/build-receipt-v2.md)

Task packets propose work; they do not authorize execution or prove completion.
The specification ZIP is a historical v0.1 snapshot, not current authority.

## Running development checks

The project-local [Pi workflow extension](.pi/extensions/fenrir-workflow/README.md)
drives bounded development work alongside `pi-clm` continuous context. Review the
manifest, available prerequisites and finite scope before starting; do not resume
a blocked pass merely because some tests pass. Its default manifest intentionally
has no TC0 qualification evaluator and cannot fabricate qualification PASS.

```sh
# Controller tests only; Node 22.19+, no downloaded dependencies/model calls.
npm test

# TC0 and native-lowering Node regressions.
node --test tests/tc0/*.test.mjs tests/solo5/native-arithmetic-lowering.test.mjs
```

For Go host tests, pinned toolchain instructions and optional explicit Shen/Node
integration vectors, use the [native host README](tools/solo5/native-arithmetic/README.md).
Live commands additionally require the exact images and reviewed isolation/cleanup
prerequisites; ordinary unit tests do not supply them.

Private development captures live under ignored `build/` and workflow journals.
They are local source-bound evidence, not automatically available from a clean
checkout or published qualification receipts.
