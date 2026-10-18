# S3 round 2: packet

Evaluator-side packet for the second repair round, built by `tools/tc0/s3-prepare.mjs` at
start revision `4cb6954` from a fresh pure-data arm-by-position S2 report (discovered at
case 12; reduced 64 → 17 nodes; first divergences at epochs 88 and 29).

- `defective-pure-call-machine.mjs`: the preserved defective original.
- `failure-bundle.json`: the two retained failures with Shen reference traces.
- `workspace-manifest.json` (schema `tc0-s3-workspace/2`): protected-file hashes, the allowed
  path, and `withheld_failing_tests`: `tests/tc0/pure-call-coverage.test.mjs` and
  `tests/tc0/pure-data.test.mjs` failed on the defective candidate, so the repairer does not
  get them; the evaluator runs them as held-out regressions.

Repairers receive only the workspace archive (SHA-256 `62a050316e16dee69d38ef0bbe225e99f9a6fb16d91f29774e8c22a48d3c1951`), never this repository.

Evaluator dry runs at `4cb6954`: the untouched workspace FAILs (`candidate-changed`); a
self-authored reference fix gets DEVELOPMENT-PASS on all 11 steps. Neither is a repair.

Status: no round-2 repair has been run. Running a sandboxed CLI repairer from the authoring
session was refused by its permission policy, so the repair is pending an external run.
