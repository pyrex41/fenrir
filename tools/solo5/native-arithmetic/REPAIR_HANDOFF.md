# Native arithmetic candidate-only repair handoff

Development evidence only. **Qualification, native startup/counter closure, and
independent repair remain UNKNOWN / NOT EXECUTED.** No self-repair substitutes for
independently reviewed repair; do not register this demo as a qualified evaluator.

## Retained counterexample

Evidence root: `build/solo5/native-arithmetic-2032a056/generated-1/`.

- `manifest.json`: finite 16-case typed arithmetic/emit enumeration (100-node and
  200-step bounds). Only the first case was executed before discovery stopped;
  the remaining 15 are unevaluated, not coverage credit.
- `case_00.artifact.json`: generated 9-node `add` with a left emit-let yielding
  `-7`, followed by a right emit-let yielding `3`.
- `case_00-build/{build.json,guest.spt}`: original two-build-equal guest and full
  candidate/data/dependency source hashes. Do not overwrite/rebuild in place.
- `case_00-control.json`: fresh independent Shen / native normal agreement.
- `case_00-mutant.json`: first mismatch at epoch 1, record index 3; expected
  Dispatch node `3` (left operand), observed Dispatch node `7` (right operand).
  Host sent Init and only the first Run; it stopped before the second Run.
- `case_00-mutant-replay.json`: cold recorded-choice replay **Exact**, language
  conformance still **Diverged**, original bundle SHA bound.
- `discovery-summary.json`: executable aggregation with source/evidence hashes,
  accepted/rejected reduction attempts and explicit boundedness limitations.

## Bounded reduction

`reduction/manifest.json` contains three proposals; each was admitted by the
unchanged validator, built twice in isolation, and freshly run against Shen in
both normal and mutant modes:

1. `attempt_1`: unwrap left emit-let, 9 -> 6 nodes; normal agrees, mutant diverges.
2. `attempt_2`: unwrap right emit-let, 6 -> 3 nodes; normal agrees, mutant diverges.
3. `attempt_3`: replace root by its left literal, 1 node; both modes agree, so this
   valid proposal is rejected because it loses the distinguishing failure.

Retained smaller artifact:

```text
[prim 2 add [int 6 -7] [int 10 3]]
```

At epoch 1 the smaller expected Dispatch is node `6`, observed node `10`.
`reduction/attempt_2-replay.json` is **Exact/Diverged**. No global-minimality claim;
three proposals were exhausted, no global search was performed. Original guest,
artifacts, source/options identities and evidence remain unchanged.

## Candidate boundary for independent review

Inspect `backends/solo5/native-arithmetic/machine.c`: `reverse_operands` changes
collection child selection and value reordering. The accepted control uses
`normal`; the deliberately introduced defect uses `mutant`. The binary contains
both options; the protocol and retained records bind the selected mode.

An independent reviewer may propose a candidate-only correction with fresh
source identity. Do not rewrite the Shen models, existing validator/catalog,
hand expectations or retained original tapes to accommodate it. Do not turn the
existing normal option into an independent-repair claim. Evaluate any reviewed
repair freshly with controls, original/smaller counterexamples and regressions;
original exact failure replay stays a separate historical obligation.

## Reproduction

Use the pinned Go host build instructions in `README.md`. Original replay must
use the exact retained host executable at
`build/solo5/native-arithmetic-2032a056/native-host`; changing that executable or
any recorded source invalidates replay admission rather than falling back.

```sh
BASE=build/solo5/native-arithmetic-2032a056/generated-1
build/solo5/native-arithmetic-2032a056/native-host replay --root . \
  --original "$BASE/case_00-mutant.json" \
  --build-report "$BASE/case_00-build/build.json" \
  --artifact "$BASE/case_00.artifact.json" \
  --input "$BASE/case_00.input.json" \
  --shen-executable "${FENRIR_SHEN_EXECUTABLE:?Set the local pinned Shen executable}" \
  --mode mutant --output "$BASE/fresh-review-replay.json"
```

Output must be fresh. Missing/extra/reordered choices, incompatible model/input/
source identity, and uncaptured crash/watchdog boundaries reject; no randomness
fallback is permitted. Semantic divergence replay binds the captured boundary,
not Docker CLI's host-dependent SIGKILL exit representation.

## Consolidated measured scope and remaining gaps

- 13 native hand artifacts: exact 2^53 arithmetic, wide multiplication overflow,
  min negation / min divided by -1, max addition overflow, signed truncating
  division, resolved distinct-binder shadowing, Bool input / selected branch,
  emit order, left trap suppressing later emit, Bool not, last-step completion,
  and explicit budget exhaustion. All samples agree with fresh Shen; hand
  outcomes/emissions and literal rule sequences are checked separately.
- Completing and budget cold replays: Exact/Admitted. Original hand-selected and
  generated mutant replays: Exact/Diverged.
- Go race tests including real Shen, strict codec/tape and source/policy tests;
  88 Node TC0/lowering regressions and 31 unchanged historical Solo5 tests pass.
  Legacy Python tests exercise old tooling only; the new Go host invokes no
  Python. Controller development checks remain distinct from these tests.
- Sandbox inspections and owned group/container cleanup are confirmed. Stock
  defaults, tender/descriptor/seccomp policy, noexec build tmpfs and native-tick
  startup canary remain unchanged. Pure candidate stepping uses no clocks, but
  that does not close startup/counter or native-machine determinism obligations.
- Actual new Go-host malformed/truncated/EOF/watchdog guest lifecycle campaigns
  are not measured; codec negatives and historical transport probes do not
  substitute for them. Whole-language frames, calls/closures, native stacks,
  qualified isolation and genuinely independent repair are outside this slice.
