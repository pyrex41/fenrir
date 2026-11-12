# Reconciling open branches with the direction amendment

12 November 2026 • Review notes, step D0 of [04_DIRECTION_AMENDMENT.md](../04_DIRECTION_AMENDMENT.md) §10

Base: master `4898e7b`. These notes recommend; the owner merges. Nothing here
is a gate verdict, and no qualification campaign was run.

## Summary

| PR | Head | Content | Fit with the amendment | Recommendation |
| --- | --- | --- | --- | --- |
| #5 Review cleanup | `a247568` | Attic move, gate timeout fix, provisional PASS label, committed receipt | Direct fit | Merge first |
| #6 Gate HEAD drift | `c52f668` | Three-line fix to the gate's source-drift check | Independent of direction | Merge after #5, with owner authority review |
| #8 AArch64/Rocq lane | `0114607` | Compiler to AArch64 bytes for unary checked-I64 arithmetic, Rocq proofs, QEMU comparison | The seed of the native proof foundation | Merge as a development lane, with the follow-ups below |
| #7 P2 handler packet | `73cdf2f` | Draft task packet for TC0-B handlers | Process fits; semantic target is superseded | Do not merge as written; re-target to the TC1 effect contract |

Suggested order: #5, #6, #8, then a revised #7.

## What was checked here

- **Merge order.** In a scratch worktree, #5 merged into master, then #6, #7
  and #8 each merged onto that result without conflicts; #5 + #6 + #8 together
  also merge cleanly.
- **Tests on the merged tree.** `node --test tests/tc0/*.test.mjs`: 104 pass
  with #5 (135 on master before the attic move). `node --test
  tests/aarch64/*.test.mjs`: 4 pass.
- **PR #8 proof.** `verification/aarch64/Core.v` compiles with Coq 8.18.0 and
  `Print Assumptions expression_binary_correct` reports "Closed under the
  global context".
- **Not run:** the TC0-A gate, any Shen comparison, PR #8's full
  `tools/aarch64/check.mjs` (needs AArch64 binutils and QEMU: its twelve image
  theorems, `coqchk` replay, 564 QEMU comparisons and binary mutants are taken
  from the PR's own report, not reproduced), and the Solo5 Python tests.

## PR #5 — review cleanup

Moves the superseded arithmetic-only candidate, the closure-machine lineage,
the expression-level generator/reducer/replay and the v0.1 ZIP to `attic/`
with `git mv`; fixes the gate so a unit-suite timeout reports UNKNOWN instead
of an unreachable branch reporting "1 failing test"; relabels the TC0-A PASS as
provisional single-author differential agreement; commits the `fa9ed18`
receipt.

This is the amendment's "keep evidence attached to the versions it covers" and
"replace prototype implementations where that helps", already done. Its
"Limits of the TC0-A PASS" section is the honest baseline TC1 starts from.

Two things to carry forward when it merges:

- The receipt it commits is for `fa9ed18`. Merging changes the source identity
  again, so current-head G1 stays UNKNOWN until the supported-runner refresh
  (plan §18 item 1).
- It defers extracting mutant switches from the candidate until the
  enforced-isolation S3 rerun. Under the amendment the candidate becomes one of
  three lanes for TC1; do that extraction before TC1 work starts on it, not
  during.

## PR #6 — gate HEAD drift

`source_identity()` overwrote `gate.head` before the final comparison, so the
gate compared HEAD with itself and could not see a commit made during an
evaluation. The fix reads HEAD directly and compares it with the recorded
value. The diff is three lines and touches nothing else.

Correct as far as reading goes. It changes the registered evaluator, so it
needs the owner's authority review, and the full gate was not re-run on it.
It is unaffected by the direction change.

## PR #8 — AArch64 checked-I64 compiler and Rocq proofs

**What it establishes.** For the closed profile
`fenrir-aarch64-checked-unary/1` (one pure `I64 → I64` function whose body is
the parameter under a chain of `add`/`sub` by a literal in 0..4095 and `neg`),
the emitted words implement the checked source semantics for every signed-I64
input, in a handwritten instruction model. Intermediate overflow is preserved:
`(x + 1) - 1` traps at maximum I64. Reading `Core.v`:

- the overflow-flag formulas for ADDS, SUBS and NEGS are stated from sign
  conditions and proved equal to the mathematical out-of-range predicate
  (`flag_correct`) rather than defined as it;
- `decode` is proved to invert `word` on admitted operations (`decode_word`),
  and the immediate range bound matches 4095 × 1024;
- `compiler_correct` holds for any initial flag and status values and any
  surplus fuel.

Under the amendment's vocabulary (§9) this is *implementation refinement
proved*, scoped to that profile and that instruction model. The PR's own README
states the same limits.

**Fit.** It is the right foundation for step D6. Three follow-ups make it part
of the new architecture instead of a parallel island:

1. **One source language.** `Core.v` defines its own `expr`, `eval_expr` and
   `checked`. When the TC1 Rocq core exists (D2), restate
   `expression_binary_correct` against the core's evaluation of the projected
   fragment and delete the private copy. Until then the README should say the
   source semantics is local to the lane.
2. **One projection obligation.** The unverified step from artifact JSON to the
   Rocq AST (ARM-02, in `tools/aarch64/compile.mjs`) is the same obligation as
   the core's artifact projection (amendment §3). Solve it once in the core.
3. **Ownership names.** `PLAN.md`'s "Integration ownership" section assigns
   roles to Buri, Vor and Thornet as separate projects. If Buri is the
   prototype being consolidated, that section should be rewritten to match
   amendment §11; if not, it needs a sentence saying what those projects are.

Smaller points:

- The theorem models registers as mathematical integers and the program
  counter as a remaining-instruction list. That is stated. ARM-03 (Sail/Islaris
  correspondence) and ARM-04 (addresses, ABI, loading) remain the real
  distance to hardware.
- The two-register result convention (`x1` = status) is a custom ABI. Pin it as
  a named convention before a second profile depends on it.
- The CI workflow installs tools with `apt-get`; versions are recorded but not
  pinned. Move Coq/Rocq into the flake when the owner picks a version
  (amendment §12 item 9).
- The README change in this PR touches the status section that #5 also
  rewrites; they merge cleanly in the order above.

## PR #7 — P2 task packet for TC0-B handlers

The packet is careful about process: fixtures hand-derived before either
machine runs, lane exports instead of instructions, catalog-derived coverage
keys, a kill rule that demands the expected discrepancy class and a retained
reproducer, and an equivalent-mutant control. All of that transfers unchanged
and should.

Its semantic target does not. It freezes `tc0-b-handler-demo/1` against
contract 0.2 §5: no resumption value, monomorphic finite effect sets. The
amendment (§4) replaces that with a TC1 effect contract in which the 0.2 rule
is the tail-resumptive profile of one-shot resumption. Building and qualifying
the 0.2 version first would produce a gate, catalog and tape format for
semantics we already intend to change.

Recommended revision:

| Packet item | Under the amendment |
| --- | --- |
| Preconditions (current G1 PASS, candidate refactor landed) | Keep |
| B1 (handle/perform, clause return, clause trap, sequential handlers) | Keep as the first TC1 effect slice, named as the tail-resumptive profile |
| B2 (nesting, forwarding) | Keep as the second slice |
| Q1 perform collects its argument; Q2 tail positions; Q4 clause environment; Q9 canonical effect-set order | Answer in the TC1 effect contract; the packet's proposals are reasonable defaults |
| Q3 segment discard per frame or per step; Q7 site identity; Q8 handler stack or segments in the state hash | These are reference-profile questions. Answer them for the reference machine only; they are not compiler obligations (amendment §6) |
| Q5 operation argument/result types | Decide with the resumption rule: a resumption is not serializable and not equality-compatible; whether operations may carry arrows depends on capture support |
| Q6 observable events | Decide with the observation boundary: performed operations are observable effects in §6's list, so "none" needs revisiting |
| Lanes | Add the Rocq lane: the slice's typing and evaluation rules in the core, with a soundness statement for the slice |
| Mutants | Keep all seven. `double-resume` and `forgotten-resume` become the direct tests of the one-shot rule |
| Q11 extend or add files; Q12 separate gate; Q13 authorship; Q14 harness language; Q15 repair isolation | Still owner decisions, unchanged |

The packet should be rewritten after the owner accepts or rejects amendment
§4, not before.

## The external prototype

Not reviewed: it is not in this repository and was not available in this
session. Amendment §11 gives the porting rules. Its first concrete check is
arithmetic (amendment §5): any imported optimizer or lowering lemma stated for
wrapping `Word32` does not hold for checked `I64` as is.
