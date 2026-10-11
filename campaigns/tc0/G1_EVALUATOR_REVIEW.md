# TC0-A gate evaluator — authority review packet

Status: **owner-reviewed and registered (2026-10-11).** The project owner answered the
review questions below; the gate and manifest are registered as `tc0-a-qualification`
in `.pi/fenrir-workflow.json`. Its verdicts count as TC0-A qualification verdicts
only under the recorded decisions and waivers. They are development-grade: the
evaluator itself runs trusted-local (decision 6).

## What is proposed

- **Manifest:** [`spec/tc0/tc0-a-requirements.json`](../../spec/tc0/tc0-a-requirements.json),
  16 rows (15 required, 1 optional). Each row names the ledger requirements it
  serves, the check that produces fresh evidence and its acceptance rule.
- **Evaluator:** [`tools/check-tc0-a-gate.py`](../../tools/check-tc0-a-gate.py). It runs
  every row freshly into `build/tc0/gate/<head>-<time>/` and aggregates per
  TC0-GATE. Its `qualification` field equals the verdict only while the manifest is
  owner-reviewed and the check is registered; otherwise it stays UNKNOWN.
  Exit codes: 0 PASS, 1 FAIL, 2 UNKNOWN/BLOCKED (the controller's contract). Under the
  controller it prints exactly one `fenrir.check.v1` report.

## Latest run

Run `6c825e756997` (`build/tc0/gate/6c825e756997-20261011T073648Z/`, 5.9 minutes, flake-pinned Shen):
**proposed verdict UNKNOWN**. Fourteen of fifteen required rows pass on fresh evidence; the
remaining one has no attestation of enforced repairer isolation.

| Row | | Result | Evidence |
| --- | --- | --- | --- |
| Clean committed HEAD | required | PASS |  |
| Shen is the flake-pinned build | required | PASS |  |
| TC0 unit suite | required | PASS | 135 tests |
| Hand cases: fresh Shen agreement + strict replay | required | PASS | 24 cases |
| Exact-arithmetic ledger (host Shen) | required | PASS | 2908 cases |
| Exhaustive-small scope, candidate sandboxed | required | PASS | 5695 programs |
| Reverse-operands mutant killed | required | PASS | killed 3940, survived 1755, crashed 0 |
| Bad-overflow mutant killed | required | PASS | killed 233, survived 5462, crashed 0 |
| Arm-by-position mutant killed | required | PASS | killed 975, survived 4720, crashed 0 |
| Catalog transition coverage | required | PASS | 112/112 |
| Generated discovery, reduction, exact replay | required | PASS | arm 64→17, reverse 64→15 nodes |
| Candidate sandbox probes | required | PASS |  |
| Requirement ledger check | required | PASS |  |
| Retained independent patch through a fresh S3 packet | required | PASS | S3 evaluator DEVELOPMENT-PASS, 10/10 steps |
| Enforced repairer isolation attested | required | UNKNOWN | No attestation at campaigns/tc0/s3/enforced-isolation-attestation.json |
| Exact arithmetic on the shaken shen-cl port (optional) | optional | PASS | 2908 cases |

Negative control: the same gate on a throwaway local commit that swapped
`bytes_concat` operands gave **FAIL**. The unit suite failed 7 tests and the hand
cases disagreed with Shen. That run also showed the exhaustive scope missed the
swap, because grammar G had only the bytes literals `""` and `ff`. G now has a third
literal, `01`; on the defective candidate the enlarged scope finds 2 disagreeing
programs at 4 nodes.

## Decisions (2026-10-11)

1. **Aggregation precedence:** FAIL > BLOCKED > UNKNOWN > PASS, kept. The owner had no
   preference.
2. **Mutant survivors:** a mutant killed on no program is FAIL, because the evaluator
   is blind to that defect class. The owner was unsure, so the packet author decided.
   Crashes are never kills.
3. **Repair independence:** the owner took the faster route. Instruction-only isolation
   is accepted for now as a recorded waiver
   ([`s3/repair-isolation-acceptance.json`](s3/repair-isolation-acceptance.json)),
   bound to the retained patch's SHA-256. Every gate report lists the waiver. Revisit
   with an enforced re-run before relying on the gate beyond G1.
4. **Scope sufficiency:** the current scopes are accepted for now: hand fixtures,
   the exact-arithmetic boundary product, grammar G up to 5 nodes, catalog coverage,
   the generated families and three mutants.
5. **Protected inputs** (decided by the packet author): the registered check's
   `authorityPaths` cover the gate, `spec/tc0` (manifest, ledger, catalog),
   `models/tc0`, `fixtures/tc0`, `tools/tc0`, every TC0 Python checker, `tests/tc0`,
   `campaigns/tc0/s3` and the toolchain flake and lock. The repairable candidate,
   `runtime/tc0/pure-call-machine.mjs`, is deliberately outside that set.
6. **Evaluator isolation:** accepted as trusted-local for now. Candidate executions
   are sandboxed; the evaluator, the regression suite and Shen are not.
7. **Controller claims** (decided by the packet author): the manifest maps each of
   the six required claims to rows. A claim is credited only when all its rows and
   the prerequisites (source identity, candidate boundary, ledger) PASS.
   - `canonical-program`: unit suite, hand cases
   - `hand-derived-trace`: hand cases, catalog coverage
   - `model-candidate-agreement`: pinned toolchain, hand cases, exact arithmetic,
     exhaustive scope
   - `defect-discovered-and-reduced`: discovery/reduction/replay, three mutant rows
   - `exact-original-failure-replay`: discovery/reduction/replay, fresh S3 repair run
     (its exact-original replay step)
   - `fresh-repair-evaluation`: fresh S3 repair run, repair-isolation record

## Not claimed

No TC0-A qualification, no G1 release, no isolation guarantee beyond the measured
probes, and no global minimality or exhaustive exploration beyond the stated bounds.
