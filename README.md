# Fenrir / Gleipnir

Fenrir is the planned language; Gleipnir is its exploration and conformance
harness. **Current stage: research prototypes and a development harness. There
is no usable full language and no production compiler.**

Nothing described here is a qualification except the historical TC0-A record
below. Every other check reports `development-pass` with authority
`UNREGISTERED` or `qualification: UNKNOWN`.

## Where this is

- The direction is set by [04_DIRECTION_AMENDMENT.md](04_DIRECTION_AMENDMENT.md)
  (owner rulings of 12 November 2026). Its §10 is the live build order, steps
  B0 to B6. [03_PHASED_EXECUTION_PLAN.md](03_PHASED_EXECUTION_PLAN.md) keeps the
  gate definitions and the TC0 requirements.
- Work after the TC0-A gate lives on the development branch
  `claude/keen-ptolemy-w9d7ve`, not on `master`. Check `git log master..` on
  that branch for the difference; this file does not record a commit.
- **B0 has not been done.** B0 is the owner's merge of the open pull requests
  ([campaigns/RECONCILIATION_2026-11.md](campaigns/RECONCILIATION_2026-11.md)).
  The AArch64 pull request's content is present on the development branch via a
  merge; the pull requests themselves are untouched.
- [harness/README.md](harness/README.md) is the detailed account of what each
  check does and what it measured. Numbers are kept there, not here.

## Build steps (amendment §10)

Evidence words are those of amendment §9: *model property proved*,
*implementation refinement proved*, *bounded exploration passed*,
*observed history accepted*. Bounded exploration is not proof. Every row is
development grade.

| Step | What exists | Evidence | Run | Not covered |
| --- | --- | --- | --- | --- |
| B1 Solo5 lane | TC0-A pure-call machine as a guest of the stock `spt` tender; host-selected steps over a control channel ([protocol v1](spec/solo5/pure-call-control-v1.md)); tapes and strict replay | Bounded exploration passed, against the Shen model | `sh harness/run-solo5-pure-call.sh`, `sh harness/run-solo5-control.sh` | `hvt`/KVM (no `/dev/kvm` here); entry inputs other than unit, bool, int; IDs above 2^64 |
| B2 TC1 effects | Draft contract [spec/tc1/EFFECTS.md](spec/tc1/EFFECTS.md); handlers H1 (tail-resumptive) and H2 (one-shot) in the Shen model, a JavaScript machine and the C guest; generation, reduction and strict replay; catalog of 29 transitions ([handler-catalog.json](spec/tc1/handler-catalog.json)) | Bounded exploration passed | `sh harness/run-tc1-handlers.sh`, `sh harness/run-solo5-pure-call.sh tc1`, `sh harness/run-tc1-gate.sh` | Multi-shot resumption; exploration beyond grammar H; two value-only defects have no reduction campaign |
| B3 Frontend | Reader, elaboration and typing in Shen; typing rules as sequent rules with a small fixed checker ([TYPING.md](spec/tc1/TYPING.md), `typing/`); handler, durable and task schemas; differential against the JavaScript validator; surface syntax [SURFACE.md](spec/tc1/SURFACE.md) | Bounded exploration passed (derivable under a rule set; soundness of the rule set not proved) | `sh typing/run.sh`, `sh frontend/test.sh` | Soundness proof of the rules; surface choices in SURFACE §8 are open |
| B4 Tasks and channels | Slice C1 ([CONCURRENCY.md](spec/tc1/CONCURRENCY.md), draft): model, JavaScript machine, Solo5 guest over [protocol v3](spec/solo5/pure-call-control-v3.md), commuting-obligation check on an exhaustive-small scope, loop closure, catalog of 53 transitions | Bounded exploration passed | `sh harness/run-tc1-tasks.sh`, `sh harness/run-solo5-tasks.sh`, `sh harness/run-tc1-task-explore.sh`, `sh harness/run-tc1-task-loop.sh` | The commuting argument as a universal claim; combined durable and task questions (CONCURRENCY §13) |
| D1 Durable effects | [DURABLE.md](spec/tc1/DURABLE.md) (draft): host-discharged effects in the Shen model, JavaScript machine and guest over [protocol v2](spec/solo5/pure-call-control-v2.md) | Bounded exploration passed | `sh harness/run-tc1-durable.sh`, `sh harness/run-solo5-durable.sh` | Capabilities are forgeable (DURABLE §9) |
| B5 Service example | A0 Rocq model in [verification/service/](verification/service/README.md); A1 contract as a Shen model ([ACCEPTED_JOB.md](spec/service/ACCEPTED_JOB.md)); A2 handler in Fenrir ([HANDLER.md](spec/service/HANDLER.md), `examples/service/`); A3 real stack on Erlang/OTP, SQLite and a Solo5 worker ([host/service/](host/service/README.md)); A4 versioned upgrade that keeps pending work ([UPGRADE.md](spec/service/UPGRADE.md)) | A0: model property proved (model only). A1, A2, A4 model: bounded exploration passed. A2 is checked against A1 by exploration, not proved. A3, A4 stack: observed history accepted over bounded crash campaigns | `sh harness/run-service-explore.sh`, `sh harness/run-service-fenrir.sh`, `sh host/service/check.sh`, `sh harness/run-service-upgrade.sh` | Power loss, fsync honesty, SQLite and OTP themselves, performance ([CONTRACT.md](host/service/CONTRACT.md) §6). The campaign does not detect the `sync_off` host mutant. Shen-to-Rocq correspondence is by reading |
| B6 Proved native code | AArch64 lane: Rocq 9.3 proofs for three closed profiles (checked unary, expr, call), exact-image theorems, QEMU comparisons, Shen differential ([verification/aarch64/](verification/aarch64/README.md), [PLAN.md](verification/aarch64/PLAN.md)) | Implementation refinement proved, against a handwritten instruction model. Agreement with the Shen model is by test only | `sh verification/aarch64/check.sh` | Closures, data, Solo5 on AArch64; correspondence with Arm's own semantics; loading and whole-image execution |
| Universal claim through Búri | First attempt: checked `add` ([verification/universal/](verification/universal/README.md)) | **Open.** Búri's certificates cannot state the property, and its calculus has no rule for `cond`, `and`, `or` | `sh verification/universal/check.sh` | No model property is proved for TC0-A this way |

## TC0-A and the gates

- **TC0-A (pure slice, G1).** The registered gate is `harness/gate.shen`
  (`tc0-a-qualification` in [.pi/fenrir-workflow.json](.pi/fenrir-workflow.json),
  runner `sh harness/run-gate.sh`). The registered evaluator was a Python
  program until 13 November 2026 and is Shen now
  ([record](campaigns/tc0/G1_SHEN_EVALUATOR_SWITCH.md)). The only recorded
  qualification PASS, at `1db7471` under owner waivers
  ([review](campaigns/tc0/G1_EVALUATOR_REVIEW.md)), was issued by the Python
  evaluator and is historical. For the Shen gate there are only direct runs of
  `harness/run-gate.sh`; **no controller receipt has been produced, so TC0-A /
  G1 qualification is UNKNOWN on the current source.** A controller run on a
  supported Linux x86-64 runner is still owed.
- **TC1 gate** ([harness/tc1-gate.shen](harness/tc1-gate.shen),
  `spec/tc1/tc1-requirements.json`) and **service gate**
  ([harness/service-gate.shen](harness/service-gate.shen),
  `spec/service/service-requirements.json`) are proposed. They are not
  registered in the workflow manifest; their reports say development-pass,
  authority UNREGISTERED, qualification UNKNOWN. Registering a gate is the
  owner's decision.
- Verdicts stay PASS, FAIL, UNKNOWN, BLOCKED, DEFERRED, distinct from the four
  evidence words above.

## Standing limits

- The "independent" implementations (Shen model, JavaScript machine, C guest,
  fixtures, harness) come from **one author lineage**. Agreement shows
  consistency, not independence of judgement.
- Open specification choices wait for the owner: [EFFECTS.md §11 and the
  draft-text notes in §6](spec/tc1/EFFECTS.md), SURFACE §8, CONCURRENCY §13,
  the ACCEPTED_JOB §6 and HANDLER §6 choices, DURABLE §12, UPGRADE §11, and the
  host [CONTRACT.md](host/service/CONTRACT.md), which is draft 1 for owner
  review.
- Solo5 runs are x86-64 `spt` only, a seccomp-sandboxed process, not a virtual
  machine; there is no KVM here.
- The model's integers are decimal strings because Shen/JIT integers are 62
  bits (`models/tc0/i64.shen`).
- The harness and model share one Shen process; a Shen/JIT bug could affect
  both.

## Running things

The toolchain is pinned in [flake.nix](flake.nix) (x86-64 Linux). Do not
hard-code store paths; ask Nix:

```sh
nix build --no-link --print-out-paths .#shen-jit   # Shen/JIT 0.7: set FENRIR_SHEN_JIT to this
nix build --no-link --print-out-paths .#solo5      # Solo5 at the pinned commit: set FENRIR_SOLO5 to this
nix build .#fenrir-a3-tools                        # OTP 28, SQLite (host/service/check.sh does this itself)
nix build .#aarch64-verification                   # Rocq 9.3, AArch64 binutils, qemu-user
```

`harness/jit.sh` and `harness/solo5.sh` do the first two for you when `nix` is
on the path and the variables are unset; without Solo5 the Solo5 rows are
BLOCKED. Fast tests: `npm test` (workflow controller only) and
`node --test 'tests/**/*.test.mjs'`. Heavier checks are listed in
[harness/README.md](harness/README.md); several take minutes and gigabytes.

## Earlier TC0-A work (kept for reference)

TC0-A is the checked-`I64` pure slice: calls, closures, tuples, datatypes,
`match`, bytes, `eq`, traps, `emit` (schema `tc0-a-pure-call-demo/2`). Its
artifacts are [spec/tc0/](spec/tc0/), [models/tc0/](models/tc0/),
[runtime/tc0/](runtime/tc0/), [tools/tc0/](tools/tc0/) and
[fixtures/tc0/](fixtures/tc0/); [campaigns/tc0/](campaigns/tc0/) holds the
repair packet, the reviews and the independent repair
([independent-repair-1](campaigns/tc0/s3/independent-repair-1.md): instruction-only
isolation, same model family as the packet author). The numbers it reported
(24 hand fixtures, a 5-node exhaustive grammar, catalog coverage, exact
arithmetic) are in [harness/README.md](harness/README.md) under the Shen
checks that replaced the Python ones. Earlier text in this file named
`tools/check-tc0-*.py` commands and shen-scheme v0.26; those tools were
replaced by `harness/` and the pinned Shen/JIT.

**Native host (Go orchestration, Docker, earlier profile): state as of
2026-10-08, not rechecked.** The host in
[tools/solo5/native-arithmetic/](tools/solo5/native-arithmetic/README.md) and the
closure packet [campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md](campaigns/solo5/NATIVE_HOST_CLOSURE_PASS.md)
were left blocked then: the exact retained Docker images were gone, and the
packet's other prerequisites (ownership review, attempt accounting, a proposed
envelope not yet in effect) were open. The stock-tender Solo5 lane above needs
neither Docker nor those images and does not close that packet. Native startup
and counter closure stay UNKNOWN.

## Plans and records

- [Full vision](01_FULL_VISION.md), [tiny core v0.2](02_TINY_LANGUAGE_CORE.md),
  [execution plan](03_PHASED_EXECUTION_PLAN.md),
  [direction amendment](04_DIRECTION_AMENDMENT.md)
- [Original review](review.md), [workflow research](workflow_research.md)
- [Reconciliation of open branches](campaigns/RECONCILIATION_2026-11.md)
- [Pi workflow extension](.pi/extensions/fenrir-workflow/README.md)
- [Hand-off for a new session](PI_CLM_HANDOFF.md)

Task packets propose work; they do not authorize execution or prove
completion. The specification ZIP is a historical v0.1 snapshot, not current
authority. Private captures live under ignored `build/`.
