# TC0-A gate evaluator — authority review packet

Status: **proposal, unreviewed.** Nothing here is registered with the workflow
controller, and no qualification verdict exists. `tc0-a-qualification` stays
unconfigured in `.pi/fenrir-workflow.json` until a reviewer accepts this packet
(03 §16; `campaigns/tc0/NEXT_SLICE.md` S6).

## What is proposed

- **Manifest:** [`spec/tc0/tc0-a-requirements.json`](../../spec/tc0/tc0-a-requirements.json),
  16 rows (15 required, 1 optional). Each row names the ledger requirements it
  serves, the check that produces fresh evidence and its acceptance rule.
- **Evaluator:** [`tools/check-tc0-a-gate.py`](../../tools/check-tc0-a-gate.py). It runs
  every row freshly into `build/tc0/gate/<head>-<time>/` and aggregates per
  TC0-GATE. Its output is a `proposed_verdict` with
  `authority: UNREVIEWED-PROPOSAL`, and it always reports `qualification: UNKNOWN`.
  Exit codes: 0 PASS, 1 FAIL, 2 BLOCKED, 3 UNKNOWN.

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

## What a reviewer must decide

1. **Aggregation precedence.** TC0-GATE names FAIL, UNKNOWN and BLOCKED but no order
   between BLOCKED and UNKNOWN. The proposal uses FAIL > BLOCKED > UNKNOWN > PASS and
   always lists every row's reasons.
2. **Mutant survivors.** A mutant killed on no program is treated as FAIL (detection
   failure). Crashes are never kills.
3. **Repair independence.** Two required rows cover the G1 repair. The first re-runs
   the retained independent patch through a freshly built S3 packet. The second
   requires a reviewed attestation of *enforced* repairer isolation, and none exists.
   Repair 1 used instruction-only isolation, so the second row is UNKNOWN by design.
   The reviewer decides whether instruction-only isolation can ever satisfy it, or
   whether an enforced re-run is required.
4. **Scope sufficiency.** The rows cover hand fixtures, the exact-arithmetic boundary
   product, the exhaustive-small grammar (≤ 5 nodes), catalog transition coverage,
   generated discovery and reduction, the candidate sandbox and the ledger. Are
   these scopes enough for G1, or must some be widened, for example to larger
   exhaustive bounds or more mutants?
5. **Protected inputs.** Registration should list the model, catalog, fixtures,
   manifest, evaluator and S3 tooling as `authorityPaths`, so candidate repairs
   cannot change them.
6. **Evaluator isolation.** The evaluator runs trusted-local. Candidate executions are
   sandboxed, but the evaluator process itself, the regression suite and Shen are
   not isolated from the host.
7. **Six controller claims.** `NEXT_SLICE.md` lists "all required A/G0 rows and six
   controller claims" for G1. This manifest covers the A/G0 rows only. The controller
   claims need their own rows once they are spelled out.

## Not claimed

No TC0-A qualification, no G1 release, no isolation guarantee beyond the measured
probes, and no global minimality or exhaustive exploration beyond the stated bounds.
