# TC0-A gate: switch to the Shen evaluator

13 November 2026 • Authority record

## What changed

| | Before | After |
| --- | --- | --- |
| Evaluator | `tools/check-tc0-a-gate.py` (Python) | `harness/gate.shen` (Shen, on Shen/JIT 0.7) |
| Registered command | `python3 -I tools/check-tc0-a-gate.py` | `sh harness/run-gate.sh` |
| Manifest | `spec/tc0/tc0-a-requirements.json`, status `owner-reviewed` | Same path, status `owner-accepted`, evaluator `harness/gate.shen` |
| Checks | Six Python checkers and JavaScript report readers | Shen programs under `harness/` |
| Model | `pure-call-machine.shen` with host-integer `arithmetic.shen`, driven as a separate process | `pure-call-machine.shen` with `i64.shen` (I64 values and IDs as decimal strings), run in the harness process |
| Oracle host | shen-scheme 0.26 | Shen/JIT 0.7, flake output `shen-jit` |

Rows, required flags, ledger references, claims, claim prerequisites and the
aggregation rule are the registered gate's, unchanged, with one optional row
added (`solo5-guest-agreement`). The acceptance text of five rows was rewritten
to say what the Shen check does; read it in the manifest.

## Basis

The owner instructed the switch in the working session of 12 to 13 November
2026: first that the harness be Shen rather than Python or JavaScript, then,
with the proposed Shen gate passing and this list of consequences in front of
them, "Do it". That is recorded here as **owner acceptance by instruction**.
It is not a line-by-line review of `harness/*.shen`, and the manifest status
says `owner-accepted`, not `owner-reviewed`, for that reason. The earlier
review, [G1_EVALUATOR_REVIEW.md](G1_EVALUATOR_REVIEW.md), is about the Python
evaluator and is now historical.

## What the Shen evaluator was checked against before the switch

Run on committed trees with both evaluators' checks present:

- Exhaustive scope to 5 nodes: 5,695 of 5,695 agree; outcomes 4,350 Ok, 595
  DivZero, 517 Bounds, 233 Overflow; mutants killed on 3,940, 233 and 975
  programs. These are the Python checker's published counts.
- Discovery and reduction, three campaigns: discovery index, attempts,
  accepted proposals, node counts and both divergence epochs equal the Python
  tool's published results in every campaign.
- Catalog coverage: 112 of 112, as published.
- Hand cases: 24 cases, 42 expectations; each expectation kind was confirmed
  to fail when its expected value is corrupted.
- Repair evaluation on the retained patch: DEVELOPMENT-PASS, ten of ten steps;
  the mutation control rejects the defective original on 20 of 719 programs.
- The proposed gate, unregistered: verdict PASS, 15 of 15 required rows.

The Python gate was not run side by side on the same commit: its toolchain row
needs the nix-built shen-scheme link and its repair row was broken for several
commits by the new harness files (they named the injected defect and tripped
the packet's leak check; fixed before the switch).

## What is different in substance

1. **Exact arithmetic.** The independent side is the Solo5 guest's C
   arithmetic, not Python integers and not the JavaScript implementation. The
   boundary set is 33 values (8,745 programs). The former ledger's program with
   IDs above 2^64 is not covered: the guest lowering refuses such IDs. The
   former two-port comparison is gone; the optional second-port row is always
   DEFERRED.
2. **Model and harness share a process.** A Shen/JIT defect could affect both.
   The JavaScript implementation and the C guest are the independent sides.
3. **Integer representation.** I64 values and all IDs are decimal strings in
   the model. `arithmetic.shen` (host integers) remains only for the
   arithmetic-demo expression machine.
4. **Strict replay** uses the same JavaScript tape code, driven through
   `tools/tc0/replay-reference.mjs` with the model's trace as reference. The
   tape header's oracle identity is now the harness's, not a list of Python
   and Shen source hashes.
5. **Reports.** One `gate.json` per run plus each harness program's working
   files, under `build/harness/gate/`. The Python checkers' per-check report
   schemas no longer exist, and the JavaScript tools that read them were
   removed with them.
6. **HEAD drift.** The final check reads HEAD directly (the fix proposed in
   PR #6).

## Carried over unchanged

- The repair-isolation waiver (`s3/repair-isolation-acceptance.json`):
  instruction-only isolation, owner waiver of 2026-10-11, reported in every
  gate report.
- Scope limits of TC0-A: bounded grammar to 5 nodes, three mutants, single
  author lineage across model, implementation and harness.
- The evaluator runs trusted-local; only the implementation is sandboxed.

## Consequences

- Every receipt issued by the Python evaluator is historical, including the
  PASS at `1db7471`. None of them describes this evaluator.
- No qualification receipt exists for the Shen evaluator yet. A run through
  the workflow controller on a supported runner is the first one.
- Removed: `tools/check-tc0-*.py` (nine files, including three for superseded
  lineages), the JavaScript runners that only read their reports, the stdin
  oracle driver and the shaken-oracle builder.
