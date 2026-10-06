# Native arithmetic development host (Go)

This **unqualified development profile** independently compares the bounded C
Solo5 candidate against the existing Shen arithmetic/expression model. It is not
TC0 qualification, native-counter/startup closure, or an isolation certification.
The host does not import oracle transitions into the candidate. Node is used only
for existing closed artifact validation and data lowering; Go invokes Shen and
Docker directly. The superseded native `build.py`/`session.py` adapters and their
Python tests were retired after fresh Go normal/mutant evidence. Unrelated
historical Python tools and retained receipts are unchanged.

## Pinned local toolchain

From the repository root:

```sh
GO=/nix/store/v0l8ihkyjdqqx97g0b8lkllicmalj0lq-go-1.27.1/bin/go
export GOTOOLCHAIN=local GOCACHE="$PWD/build/go-cache"
# Set FENRIR_SHEN_SOURCE to your local checkout of the pinned Shen commit.
export FENRIR_SHEN_EXECUTABLE="${FENRIR_SHEN_SOURCE:?Set the local Shen checkout}/_build/bin/shen-scheme"
(cd tools/solo5/native-arithmetic && "$GO" test -race -v ./...)
(cd tools/solo5/native-arithmetic && "$GO" build -race -o ../../../build/solo5/native-host .)
```

The exact executable is the Nix Go 1.27.1 darwin/arm64 toolchain. It does not change
machinewide Go. The live Shen test skips without an explicit executable; a skip
is not model-agreement evidence. This module uses only the Go standard library.

## Build and compare

All outputs must be fresh and below `build/solo5`; create their parent first.
Existing immutable tender/image dependencies must already be available.

```sh
node tools/solo5/native-arithmetic/lower.mjs \
  fixtures/tc0/left-trap-program.json build/solo5/unit-input.json \
  build/solo5/left-trap-data.h
build/solo5/native-host build --root . \
  --data build/solo5/left-trap-data.h \
  --output-dir build/solo5/fresh-native-build \
  --transport-build build/solo5/control-build-5b98ecf8/build.json --fuel 200
build/solo5/native-host session --root . \
  --build-report build/solo5/fresh-native-build/build.json \
  --artifact fixtures/tc0/left-trap-program.json \
  --input build/solo5/unit-input.json \
  --shen-executable "$FENRIR_SHEN_EXECUTABLE" \
  --output build/solo5/fresh-native-session.json
```

`unit-input.json` is canonical `["unit"]`. Use `--mode mutant` and a fresh output
for the retained operand-order defect. A development divergence is a reportable
observation, not a command failure; inspect `execution`, `conformance`, and
`first_error`. Admission/cleanup failures return nonzero and do not publish a
successful session bundle.

Fresh builds emit development build receipt v2 with required `compile_command`
bound to the fixed isolated recipe and canonical fuel. `command` remains advisory
CLI argv. Current admission requires v2; historical v1 receipts are not rewritten
or reinterpreted. See `spec/solo5/native-arithmetic-demo/build-receipt-v2.md`.
This command consistency is not independent binary-to-fuel attestation.

Build admission binds the complete current Go/C/protocol/validator source set,
data header, dependency receipt, immutable image provenance and guest bytes.
The host compiles twice in network-none, nonroot, readonly-root containers with
readonly inputs, all capabilities dropped, no-new-privileges, 128 MiB/32 PID
limits, and the unchanged `/work:rw,nosuid,size=32m,mode=1777` build tmpfs policy.
Container inspection confirms policy; owned process groups and named containers
are synchronously cleaned and absence-checked. Neither a Go process group nor
this controller is itself an OS sandbox.

Each live session freshly invokes Shen. Header rederivation is checked before
guest execution. Strict canonical FGCTL records are compared before each Run;
comparison stops at the first mismatch. Completion requires terminal agreement,
Ack, EOF, successful exit and the exact expected record/response counts.
Source/model/Node/Shen/boot/host executable identities are hashed before and
after. Historical bundles remain evidence for their original source identities;
source changes require fresh builds/sessions.

## Strict cold replay

The `replay` subcommand accepts the same build/artifact/input/Shen/mode flags
as `session`, plus `--original retained-session.json` and a fresh `--output`.
It validates the original source/executable/model and launch input identities,
then sends only the recorded choices: no fresh-choice or randomness fallback.
Complete, budget and captured semantic-divergence boundaries are supported.
Missing/extra/reordered/incompatible choices reject; uncaptured crash/watchdog
sessions are Incomplete rather than an exact replay claim. A reproduced defect
is `replay: Exact` with `conformance: Diverged`, never Admitted.

## Bounded selected-case campaign (development only)

`campaign` synchronously owns lowering, two-build compilation, fresh Shen/native
sessions and optional cold replay. It uses the existing admission/session/replay
code, never a Python or shell campaign wrapper. SIGINT/SIGTERM cancel active
native sessions through the joined context path; preflight/model/build subprocess
work remains watchdog-bounded before the next cancellation check. A partial
summary is retained on cancellation/error after output creation. Cleanup errors
are conservatively unresolved and stop the selection; there is no retry.

A closed `fenrir.solo5.selected-campaign-plan/1` JSON plan contains:

- `declared_hands: 13`, `declared_generated: 16` (full intended corpus, not credit);
- `prior_executions`, `prior_two_build_compilations`: explicit prior attempt
  accounting, supplied by the operator, not an independent persistent ledger;
- `cases`: unique safe `name`, `family` (`hand`/`generated`), `artifact`, `input`,
  `fuel` (0..200), unique `modes` (`normal`/`mutant`), and boolean `replay`.

The selected plan must fit the shared 100 execution/40 two-build limits including
prior accounting and replays. Attempts are conservatively counted before
admission/oracle/compilation, so a stopped reservation is not hidden. Data paths
are sealed below the repository; plans and fresh outputs are below `build/solo5`.

```sh
# This retained example selects 2 hands and 1 generated artifact, not all 29.
# Use a freshly reviewed plan with updated prior accounting for subsequent runs.
HOST=build/solo5/native-host-3282e34c/host-h5
PLAN=build/solo5/native-host-3282e34c/selected-campaign-plan-1.json
"$HOST" campaign --root . --plan "$PLAN" \
  --transport-build build/solo5/control-build-5b98ecf8/build.json \
  --shen-executable "$FENRIR_SHEN_EXECUTABLE" \
  --output-dir build/solo5/fresh-selected-campaign
"$HOST" campaign-inspect --root . \
  --summary build/solo5/fresh-selected-campaign/summary.json
```

Saved inspection verifies bounded summary shape, selected observation identities
and retained evidence hashes **without rerunning guests**. It does not admit
historical evidence under changed current sources or confer authority. Every
summary intentionally remains `status: INCOMPLETE`, `qualification: UNKNOWN`,
even when all selected executions succeed: full hand-derived outcome/emission/
rule verification, full corpus, repetition/perturbation obligations and the H1/H2
matrix remain separate gaps. Exit0 means selected work returned without an
infrastructure error, not full campaign acceptance. First errors and cleanup
state are explicit. A crash/watchdog is never converted to admitted completion.

Measured source-bound example `selected-campaign-1`: 3 two-build attempts,
8 execution attempts, source identities unchanged and cleanup confirmed;
last-step Completed/Admitted, budget-edge BudgetExhausted/Admitted, generated
case00 normal Completed/Admitted and mutant StoppedAtDivergence/Diverged.
All four cold replays are Exact with their distinct conformance verdicts.
This is 2/13 selected hands and 1/16 selected generated artifacts, not full breadth.

## Retained development evidence and remaining obligations

See `REPAIR_HANDOFF.md` for the executable evidence index and candidate-only
review boundary. This sprint measured 13 native hand artifacts and completing,
budget and divergent cold replays. A finite 16-case generated family discovered
a mutant discrepancy on its first evaluated case (15 cases remain unevaluated).
Three validated/native-rechecked reduction proposals retained a 9 -> 6 -> 3-node
failure and rejected a valid one-node proposal that lost the failure. Original
and smaller generated defects replay Exact/Diverged; no global-minimality claim.

Genuinely independent repair and deeper new Go guest lifecycle negative campaigns
remain unexecuted. Existing hand/model/catalog/evaluator authority was not changed.
Stack-canary, stock tender defaults and native startup counters are unchanged;
qualification and their closure remain **UNKNOWN**.
