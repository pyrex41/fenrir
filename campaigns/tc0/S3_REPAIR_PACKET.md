# S3 candidate-only repair packet (TC0-A pure-call demo, schema /2)

Status: prepared, dry-run, and one independent repair evaluated DEVELOPMENT-PASS (see [`s3/independent-repair-1.md`](s3/independent-repair-1.md), including its independence caveats). This is a task
packet and evaluator, not acceptance authority. Qualification remains UNKNOWN.

## What the packet contains

`node tools/tc0/s3-prepare.mjs S2_REPORT OUT_DIR` builds, from a committed HEAD and a
retained pure-data `arm-by-position` reduction report:

- `packet/defective-pure-call-machine.mjs`: the preserved defective original. It is
  the reference candidate with the arm-by-position mutant made unconditional and
  every trace of the option removed (`tools/tc0/s3-defect.mjs`). Match selects
  the arm at the constructor's declared position instead of by constructor name.
- `packet/failure-bundle.json`: the S2 original (64 nodes) and minimized (17 nodes)
  failures, their Shen-observed traces, and the defective original's first divergence
  (epochs 88 and 29, each right after a `MatchReturn` step).
- `packet/workspace-manifest.json`: SHA-256 of every workspace file, the single
  allowed path `runtime/tc0/pure-call-machine.mjs` and the ignored `build/` prefix.
- `workspace/`: a `git archive` export of HEAD with no history, the defective
  candidate in place, `S3_TASK.md` and the bundle. Evaluator-side material is
  withheld: README, campaigns, `.pi`, the mutation, generation and reduction tooling
  for this defect, the held-out exhaustive scope, the S3 tools, and the requirement
  ledger, which cites them. Three exact
  rewrites drop the mutant's name from shared tooling. Preparation fails if any
  workspace file still names the defect.

## Evaluator

`python3 -I tools/check-tc0-s3-repair.py --packet P --workspace W --shen-executable SHEN --output build/...json`
runs these steps in order:

1. Protected inputs: only the allowed path may differ from the manifest.
2. The candidate differs from the defective original.
3. Exact-original replay: the defective original reproduces each retained failure
   and stops at its recorded first divergence.
4. The repaired candidate replays each retained failure Exact and Admitted.
5. Fresh Shen agreement on the hand cases.
6. The workspace regression suite.
7. Held-out scopes against fresh Shen: the generated pure-call (32) and pure-data
   (24) families, and every exhaustive-small program up to 5 nodes (5,695 since
   grammar G gained a third bytes literal; 5,051 when repair 1 was evaluated).
8. Mutation control: the held-out exhaustive scope at 4 nodes must reject the
   defective original.

Steps 3 and 7–8 run in a trusted export of the start revision with the candidate
file substituted, never with workspace tooling. Every step that executes the
repaired candidate (4, 5 and 7) runs it inside `tools/tc0/sandbox.mjs`: no network,
no inherited environment, reads limited to the candidate tree and inputs, and no
writes or processes. The regression suite (6) runs with network and environment
isolation only; each step's report row names its boundary.

## Dry runs (evaluator self-checks, not repairs)

| Workspace | Verdict | Failing steps |
| --- | --- | --- |
| Untouched (defective) | FAIL | candidate-changed |
| Reference candidate restored | DEVELOPMENT-PASS | none |
| Minimal one-line fix (select arm by name) | DEVELOPMENT-PASS | none |
| Overfit fix (by name only for two-arm matches) | FAIL | repaired-replay, held-out-generated-pure-data, held-out-exhaustive-5 |
| Minimal fix plus an edited model file and an added tool | FAIL | protected-inputs (names both files) |

The overfit patch passes the hand cases and regressions. When grammar G had only a
two-constructor datatype, it also passed the whole exhaustive scope; G now includes
a three-constructor enum matched in all six arm orders, so the exhaustive scope
rejects it as well.

Both passing patches were written by the packet author with knowledge of the defect.
They show the evaluator can pass a correct candidate, and they are **not** evidence
of an independent repair.

## Independent repair

An independent repair needs an approved arrangement: an agent or person who receives
only `workspace/`, has not seen this packet's evaluator side or the defect
description, and returns a patch to the allowed path. The evaluator then runs
unchanged on the returned workspace. Repair 1 (a local subagent with instruction-only
isolation, approved by the project owner) is recorded in
[`s3/independent-repair-1.md`](s3/independent-repair-1.md). A repair under enforced
isolation, such as a separate container that receives only the workspace, is still
open.
