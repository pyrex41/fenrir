# Track 4: tasks, handler tapes, and remaining integration

Base: `integration/arm64-baseline` at `da1ec74`. Donor:
`origin/claude/keen-ptolemy-w9d7ve` at `a924c5c`. These are selective ports,
not a merge and not qualification evidence.

## What is in this slice

- C1 (`tc1-task-demo/1`): artifact validator, Shen reference machine, JavaScript
  candidate, handwritten fixtures, and explicit-schedule comparison. C1 extends
  H2 only. It neither adds task forms to R1/P1/D1 nor admits their effects into
  C1. The Shen task decoder is confined to the C1 harness; shared harness and
  service sources are unchanged.
- Grammar G scheduler exploration: compare the reference and production
  observation sets, followed by JavaScript comparison on one witness per
  reference observation class. The broken scheduling variants still have to
  fail, and scope truncation and exhausted bounds cannot pass.
- H1/H2 strict tape record/replay, the 29-transition pinned development
  catalog, handler-aware reducer proposals, and the eight original/minimized
  retained counterexamples. The replay API checks a fresh execution against
  the same reference and expected header, including choice occurrence,
  epochs, full trace, and footer. The harness checks each catalog hash against
  its pin; request/result summaries are written by the harness, the full tapes
  are recorded and replayed in memory. The existing PR10 replay and coverage
  rows run their original checks; this is not their replacement.

## Reproduced on this branch

`node --test tests/tc0/*.test.mjs tests/tc1/*.test.mjs`: 248 passed, 1 skipped,
no failures (including existing PR10 manifest, remote and serving tests).

The following ran with local Shen/JIT 0.7 (kernel 43.6) on macOS, with
`--trusted-local` explicitly selected. Reports say
`implementation_sandboxed: false` and `qualification: UNKNOWN`. Default
wrappers require the Linux network-namespace sandbox; no fallback is automatic.

| Wrapper (under `harness/`) | Result |
| --- | --- |
| `run-tc1-tasks.sh` | 18 cases, 151 schedules (54 production), 619 expectations, 7,167 model steps; all nine defects detected. Two `waiter_not_woken` runs crashed and were not counted as kills. |
| `run-tc1-task-explore.sh` | All 3,600 G programs, no bounds hit; 15,808 matching observation classes, 15,808 matching JS witnesses, 777,583 compared steps. Removing the switch after `send` breaks equality on 493 programs; eager cancellation breaks it on 373. The JS `stale_waiter` survives the witness sample but is detected by the hand suite. |
| `run-tc1-task-explore.sh` with `limit 10`, then with `limit 10 states 1` | Both `development-fail` (exit 1), incomplete scope; the latter records 50 bound hits. |
| `run-tc1-strict-replay.sh` | 20 hand cases and all 8 fixed retained cases admitted; all 8 defective retained cases replayed at the expected first divergence, across 4 mutants. Catalog pin matched; unit tests reject altered headers, choices, traces and footers. |

No sandboxed Linux run, guest run, fixed C1 typing differential, full PR10 gate
run, or service campaign was performed in this worktree.

## Follow-ups, in dependency order

1. **C1 typing and frontend.** Coordinate `65f80f3` and `60bfb1e` with the
   typing branch; port C1 structure, search and fixed checker rules on top of
   the existing TC0/H1/H2/D1 lane, plus the differential's boundary probes and
   budget-is-UNKNOWN fix (`ae1f681`). Port the C1 parts of frontend commit
   `01b98fc` with its negative files, round trips and explicit schedules,
   preserving R1/P1 elaboration, D1 typed inputs and all schema conflicts.
   The combined C1 × D1 contract is a separate owner decision (`b032cac`);
   resolve host-wait, cancellation, reply order/ownership, deadlock, scope
   failure and copying handlers before adding any combined schema.
2. **C1 execution evidence.** Port `fd507ae` as its own change:
   `tc1-task-loop.shen`, scheduler-aware generation/reduction/replay tools,
   the task catalog, original and minimized corpus, and replay-tamper tests.
   In a coordinated guest change, port `07ee460`'s v3 task control, vectors,
   lowering, `tasks.c` and comparison harness without altering existing v1/v2
   or PR10 remote behavior. Keep cold-boot replay, invalid choice/frame
   refusals, the four guest defects, and free-run refusal. Re-run the task,
   explorer and handler runners with the sandbox on supported Linux;
   exercise v3 on the pinned tender.
3. **Handler catalog coverage.** Port the measurement part of `61a6618` to a
   separate runner rather than replacing `harness/tc1-coverage.shen`.
   Measure the pinned catalog against same-run agreeing hand, exhaustive and
   generated traces, refuse an unknown transition or wrong depth delta, and
   test tampered pins. Preserve all six PR10 generated-family negatives and
   its same-run reductions/replay; the imported four-mutant corpus is
   complementary. If porting the donor discovery campaign (`1aad978`), use
   separate runner names and do not overwrite PR10's generator.
4. **A4 must stack after the authority service changes.** Do not cherry-pick
   the A4 merge or replace `host/service/` or the service checker with donor
   snapshots. After the authority branch lands, start with the contract,
   independent model and declared predictions (`8ccdc93`, `e008975`); then
   port `047cd7a`'s model exploration and v2-handler/migration refinement.
   Keep the v2 handler and migration artifact identities independently
   pinned; retain the A1 graph projection with upgrades disabled, model and
   Fenrir mutants and their retained shortest cases, both equivalent Fenrir
   controls, CAS tests and exact Solo5 sample scope. Next reconcile `4c4454c`
   as a patch over the current store, manifest, worker and evidence layers:
   durable version state, transactional version fence, staged migration/CAS,
   worker image re-selection, and `/2` upgrade histories without changing
   `/1` interpretation. Carry forward PR10's trailing-output rejection
   (`8838916`), complete campaign scope, observed fault effects, recorder
   gaps, tender corroboration and missing-node refusal (`2cc8d0e`, `43eea72`,
   `001db56`, `da1ec74`), plus any authority changes landed after this base.
   Retain A4 crash/load/stale/CAS/manifest campaigns, 13 checker fixtures,
   host mutants/controls, and the explicitly undetected `sync_off` control.
   Re-pin quick/full expectations from runs on the reconciled stack, not the
   donor's counts. Do not adopt `fd2a7e3` wholesale: retain the scope and
   fail-closed corrections in `26a4a9a` and `a8b1f3d` when reviewing the
   separate service gate.
5. **Gate authority.** Any optional rows from `01eecef`, `361a9d5`, `29b339e`
   or `fd2a7e3` need separate owner review. Preserve PR10's registered
   manifest, workflow check, remote/peer rows, scope pins and nested
   report/exit agreement. This patch changes none of them.
