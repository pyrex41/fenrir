# S3 independent repair 1 — record

Status: **DEVELOPMENT-PASS** from the frozen evaluator, with the independence caveats
below. Qualification remains UNKNOWN; this is not a G1 verdict.

## Arrangement (approved by the project owner for this run)

- Repairer: a fresh local subagent (same model family as the packet author), started
  with only the workspace path, `S3_TASK.md`, and a Shen executable path. The prompt
  did not describe the defect.
- Workspace: a copy of the clean-room export at `dc2b400`, placed outside the
  repository. The subagent was told not to read outside it, use git, use the network,
  or edit anything except `runtime/tc0/pure-call-machine.mjs`.
- That isolation was **instruction-only**. Nothing technically stopped the subagent
  from reading the repository, so its independence is asserted, not enforced. Its own
  report names only workspace files.

## Patch (the only change; line 43)

```diff
-else if(f.kind==='Match'){const arm=f.arms[this.constructorIndex(c.value[1],c.value[2])];if(!arm)throw ...
+else if(f.kind==='Match'){const arm=f.arms.find(a=>a[0]===c.value[2]);if(!arm)throw ...
```

Repaired candidate SHA-256 `f22c8fd46ffcb7239a5beca529dd9d73ecba039aba25d3ca2f5b6439fe761078`.
The repairer's explanation: arms were chosen by the constructor's declared
position, whereas `match_rules` allow any arm order and the Shen model looks arms up
by constructor name. In the minimized failure, `Sq(6,4)` entered the `Rect` arm and
dispatched node 55 instead of 67 at epoch 29. The value was the same; the trace
was not.

## Evaluation

`python3 -I tools/check-tc0-s3-repair.py --packet build/s3/packet --workspace <copy> --shen-executable build/toolchain/shen-scheme`
(evaluator SHA-256 `89495284…5000`; Shen = flake-pinned shen-scheme v0.26; bundle `e9ccd4da…718a`;
defective original `f5235713…5298`; manifest `2124c919…395a`):

| Step | Result | Boundary |
| --- | --- | --- |
| protected-inputs | PASS | manifest comparison |
| candidate-changed | PASS | |
| original-replay (defective original stops at epochs 88 and 29) | PASS | trusted defective original |
| repaired-replay (both failures Exact, Admitted) | PASS | sandbox |
| hand-case-agreement (24) | PASS | sandbox |
| regressions (workspace suite) | PASS | network namespace and empty environment only |
| held-out-generated-pure-call (32) | PASS | sandbox |
| held-out-generated-pure-data (24) | PASS | sandbox |
| held-out-exhaustive-5 (5,051 programs) | PASS | sandbox |
| mutation-control-defective-4 (632 programs reject the original) | PASS | trusted defective original |

## Caveats

- Independence is instruction-only, and the repairer shares a model family with the
  packet author.
- The defect is small and local. This demonstrates the loop end to end; it is not a
  measure of repair difficulty.
- Packet defect found by the repairer: `S3_TASK.md` advertised the exhaustive checker,
  which the export withholds. The template no longer lists it; the run above used the
  older template.
