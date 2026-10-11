# S3 candidate-only repair packet (TC0-A pure-call demo, schema /2)

Status: prepared and dry-run; **independent repair NOT EXECUTED**. This is a task
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
  for this defect, the held-out exhaustive scope and the S3 tools. Three exact
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
   (24) families, and all 5,051 exhaustive-small programs up to 5 nodes.
8. Mutation control: the held-out exhaustive scope at 4 nodes must reject the
   defective original.

Steps 3 and 7–8 run in a trusted export of the start revision with the candidate
file substituted, never with workspace tooling.

## Dry runs (evaluator self-checks, not repairs)

| Workspace | Verdict | Failing steps |
| --- | --- | --- |
| Untouched (defective) | FAIL | candidate-changed |
| Reference candidate restored | DEVELOPMENT-PASS | none |
| Minimal one-line fix (select arm by name) | DEVELOPMENT-PASS | none |
| Overfit fix (by name only for two-arm matches) | FAIL | repaired-replay, held-out-generated-pure-data |
| Minimal fix plus an edited model file and an added tool | FAIL | protected-inputs (names both files) |

The overfit patch passes the hand cases, regressions and the whole exhaustive scope,
because grammar G has only a two-constructor datatype. Only the retained failures
and the generated three-constructor family catch it. That is a recorded gap in G.

Both passing patches were written by the packet author with knowledge of the defect.
They show the evaluator can pass a correct candidate, and they are **not** evidence
of an independent repair.

## Remaining step: independent repair

An independent repair needs a separately approved arrangement: an agent or person
who receives only `workspace/` (or a fresh clone of it), has not seen this packet's
evaluator side or the defect description, and returns a patch to the allowed path.
The evaluator is then run unchanged on the returned workspace. Until that happens,
the independent-repair claim stays **UNKNOWN**. No nested model session was started
while preparing this packet.
