\\ TC0-A gate evaluator, in Shen. Registered as the check tc0-a-qualification in
\\ .pi/fenrir-workflow.json, with the manifest spec/tc0/tc0-a-requirements.json.
\\ It replaced the Python evaluator on 2026-11-13 by the owner's instruction; see
\\ campaigns/tc0/G1_SHEN_EVALUATOR_SWITCH.md.
\\
\\   shen-jit script harness/gate.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE [NONCE CHECK_ID SOURCE_SHA256 CONFIG_SHA256]
\\
\\ Row evaluation, aggregation and the report are in harness/gate-core.shen, shared
\\ with the TC1 gate: any required FAIL gives FAIL; else any BLOCKED gives BLOCKED;
\\ else any UNKNOWN gives UNKNOWN; else PASS. An evaluator error, a check that does
\\ not report, or a check it does not know is UNKNOWN.
\\ The verdict counts as a qualification only while the manifest is owner-accepted
\\ and the workflow configuration names this evaluator; otherwise the report says
\\ authority UNREGISTERED and qualification UNKNOWN.
\\ This file holds the TC0-A row checks and the registration rule.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/gate-core.shen"))

\\ ---------- TC0-A rows ----------

(define fh.not-ported
  What Memo -> (fh.row "UNKNOWN" [(cn What " is not yet moved to the Shen harness")] [] Memo))

(define fh.hand-agreement-and-replay
  Memo ->
    (let Report (fh.harness "hand-cases.shen" [(fh.subdir "hand") "sandbox"] 600)
         Status (fh.member "status" Report)
      (if (= Status "development-fail")
          (fh.row "FAIL" ["Hand cases: model, implementation, hand expectations or strict replay disagree"]
                  [["failures" (json.stringify (fh.member "failures" Report) [])]] Memo)
          (if (and (= Status "development-pass") (= (fh.member "strict_replay_admitted" Report) (fh.member "cases" Report)))
              (fh.row "PASS" [] [["cases" (fh.member "cases" Report)] ["expectations_checked" (fh.member "expectations_checked" Report)]
                                 ["strict_replay_admitted" (fh.member "strict_replay_admitted" Report)]]
                      [["hand" Report] | Memo])
              (fh.row "UNKNOWN" ["The hand-case harness did not report"] [] Memo)))))

\\ Two campaigns. Each must discover, reduce and strictly replay its failure.
(define fh.campaigns
  [] Memo Reasons Detail Status -> (fh.row Status (reverse Reasons) (reverse Detail) Memo)
  [Mutant | Mutants] Memo Reasons Detail Status ->
    (let Dir (fh.subdir (cn "reduction-" Mutant))
         Report (fh.harness "reduction.shen" [Dir "pure-data" Mutant] 900)
         S (fh.member "status" Report)
      (if (= S "development-pass")
          (fh.campaigns Mutants [[(cn "campaign:" Mutant) Report] | Memo] Reasons
            [[Mutant (make-string "case ~A, ~A attempts (~A accepted), nodes ~A->~A, divergence epochs ~A and ~A"
                                  (fh.member "discovered_index" Report) (fh.member "attempts" Report) (fh.member "accepted" Report)
                                  (fh.member "original_nodes" Report) (fh.member "minimized_nodes" Report)
                                  (fh.member "original_divergence_epoch" Report) (fh.member "minimized_divergence_epoch" Report))] | Detail]
            Status)
          (if (= S "development-fail")
              (fh.campaigns Mutants Memo [(make-string "~A: ~A" Mutant (fh.member "reason" Report)) | Reasons] Detail "FAIL")
              (fh.campaigns Mutants Memo
                [(make-string "~A: ~A" Mutant (if (= Report []) "the campaign did not report" (fh.member "reason" Report))) | Reasons]
                Detail (if (= Status "PASS") "UNKNOWN" Status))))))

(define fh.discovery-reduction-replay
  Memo -> (fh.campaigns ["arm-by-position" "reverse-operands"] Memo [] [] "PASS"))

(define fh.exact-arithmetic
  Memo -> (fh.guest-row (fh.guest-batch ["--exact-arithmetic"]) Memo))

(define fh.solo5-guest-agreement
  Memo -> (fh.guest-row (fh.guest-batch ["--exhaustive-nodes" "5"]) Memo))

(define fh.exhaustive-small
  Memo ->
    (let Report (fh.harness "model-vs-candidate.shen" ["5" (fh.subdir "exhaustive") "sandbox"] 1800)
         Status (fh.member "status" Report)
         Agreeing (fh.member "agreeing" Report)
         Programs (fh.member "programs" Report)
      (if (= Report [])
          (fh.row "UNKNOWN" ["The exhaustive harness did not report"] [] Memo)
          (if (not (= (fh.member "scope_complete" Report) true))
              (fh.row "UNKNOWN" ["The enumerated scope was truncated or incomplete"] [] Memo)
              (if (not (= Agreeing Programs))
                  (fh.row "FAIL" [(make-string "~A of ~A programs agree with the model" Agreeing Programs)]
                          [["disagreements" (json.stringify (fh.member "disagreements" Report) [])]] [["exhaustive" Report] | Memo])
                  (fh.row "PASS" [] [["programs" Programs] ["steps" (fh.member "model_steps" Report)]] [["exhaustive" Report] | Memo]))))))

\\ Killed means: completed with a trace different from the model's. Crashes are never kills.
(define fh.mutant
  Name Memo ->
    (let Counts (fh.member Name (fh.member-in "exhaustive" Memo))
         Killed (fh.member "killed" Counts)
      (if (= Counts [])
          (fh.row "UNKNOWN" ["No exhaustive report in this run"] [] Memo)
          (if (= Killed "0")
              (fh.row "FAIL" [(make-string "Mutant ~A survived every program (~A crashes are not kills)" Name (fh.member "crashed" Counts))] [] Memo)
              (fh.row "PASS" [] [["killed" Killed] ["survived" (fh.member "survived" Counts)] ["crashed" (fh.member "crashed" Counts)]] Memo)))))

\\ Coverage is measured over the traces this run established as agreeing.
(define fh.catalog-coverage
  Memo ->
    (if (or (= (fh.member-in "hand" Memo) []) (= (fh.member-in "exhaustive" Memo) [])
            (not (= (fh.member "agreeing" (fh.member-in "exhaustive" Memo)) (fh.member "programs" (fh.member-in "exhaustive" Memo)))))
        (fh.row "UNKNOWN" ["Needs this run's agreeing hand and exhaustive results"] [] Memo)
        (let Report (fh.harness "coverage.shen" [(cn (value fh.*out*) "hand/hand.jsonl") (cn (value fh.*out*) "exhaustive/candidate-5.jsonl")] 900)
             Status (fh.member "status" Report)
          (if (= Status "outside-catalog")
              (fh.row "FAIL" ["Steps outside the catalog"] [["unknown_observed" (json.stringify (fh.member "unknown_observed" Report) [])]] Memo)
              (if (= Status "incomplete")
                  (fh.row "UNKNOWN" ["Catalog transitions uncovered"] [["missing" (json.stringify (fh.member "missing" Report) [])]] Memo)
                  (if (= Status "complete")
                      (fh.row "PASS" [] [["covered" (make-string "~A/~A" (fh.member "covered" Report) (fh.member "catalog_keys" Report))]] Memo)
                      (fh.row "UNKNOWN" ["The coverage harness did not report"] [] Memo)))))))

(define fh.candidate-boundary
  Memo ->
    (let R (fh.exec "node" [(cn (value fh.*root*) "tools/tc0/check-sandbox.mjs") (cn (value fh.*out*) "sandbox.json")] 300)
      (if (= (hd R) 2)
          (fh.row "BLOCKED" [(fh.trim (hd (tl (tl R))))] [] Memo)
          (if (= (hd R) 0)
              (fh.row "PASS" [] [] Memo)
              (fh.row "FAIL" ["A boundary probe was not denied in the sandbox, or the probe run failed"] [] Memo)))))

(define fh.requirement-ledger
  Memo ->
    (let R (fh.exec "node" [(cn (value fh.*root*) "tools/tc0/check-requirement-ledger.mjs")] 120)
      (if (= (hd R) 0)
          (fh.row "PASS" [] [] Memo)
          (fh.row "FAIL" ["The ledger checker reports problems"] [["output" (fh.trim (hd (tl R)))]] Memo))))

\\ A fresh repair packet from this run's failure, the retained patch applied, then the
\\ repair evaluation. A patch that no longer applies is stale evidence: UNKNOWN.
(define fh.failed-steps
  [] -> ""
  [S | Ss] -> (if (= (fh.field "status" S) "PASS") (fh.failed-steps Ss) (cn (fh.field "step" S) (cn " " (fh.failed-steps Ss)))))

(define fh.independent-repair-fresh
  Memo ->
    (if (= (fh.member-in "campaign:arm-by-position" Memo) [])
        (fh.row "UNKNOWN" ["Needs this run's arm-by-position reduction campaign"] [] Memo)
        (let S3 (cn (value fh.*out*) "s3")
             Prepared (fh.exec "node" [(cn (value fh.*root*) "tools/tc0/s3-prepare.mjs")
                                       (cn (value fh.*out*) "reduction-arm-by-position/failure-report.json") S3] 600)
          (if (not (= (hd Prepared) 0))
              (fh.row "UNKNOWN" [(cn "Packet preparation failed: " (fh.trim (hd (tl (tl Prepared)))))] [] Memo)
              (let Repair (cn S3 "/repair")
                   Copied (fh.exec "cp" ["-r" (cn S3 "/workspace") Repair] 300)
                   Patched (fh.exec "patch" ["-p1" "--forward" "--batch" "-d" Repair "-i"
                                             (cn (value fh.*root*) "campaigns/tc0/s3/independent-repair-1.patch")] 120)
                (if (or (not (= (hd Copied) 0)) (not (= (hd Patched) 0)))
                    (fh.row "UNKNOWN" ["Retained independent patch no longer applies to this source; repair evidence is stale"] [] Memo)
                    (let Cleaned (fh.exec "find" [Repair "-name" "*.orig" "-delete"] 60)
                         Report (fh.harness "repair-evaluation.shen" [(fh.subdir "s3-evaluation") (value fh.*jit*) (cn S3 "/packet") Repair] 3600)
                         Verdict (fh.member "verdict" Report)
                      (if (= Verdict "DEVELOPMENT-PASS")
                          (fh.row "PASS" [] [["steps" (str (length (fh.member "steps" Report)))]] Memo)
                          (if (= Verdict "FAIL")
                              (fh.row "FAIL" [(cn "Repair evaluation: " (fh.failed-steps (fh.member "steps" Report)))] [] Memo)
                              (fh.row "UNKNOWN" ["The repair evaluation did not report"] [] Memo))))))))))

(define fh.repair-isolation
  Path Memo ->
    (let Text (trap-error (read-file-as-string (cn (value fh.*root*) Path)) (/. E ""))
         A (if (= Text "") [] (trap-error (json.parse Text []) (/. E [])))
         Patch (fh.member "patch" A)
         By (fh.member "accepted_by" A)
      (if (= A [])
          (fh.row "UNKNOWN" [(cn "No isolation record at " Path)] [] Memo)
          (if (or (not (string? Patch)) (not (= (fh.sha256 (cn (value fh.*root*) Patch)) (fh.member "patch_sha256" A))))
              (fh.row "UNKNOWN" [(cn Path " does not match the retained patch")] [] Memo)
              (if (or (not (string? By)) (= By ""))
                  (fh.row "UNKNOWN" [(cn Path " names no reviewer")] [] Memo)
                  (if (= (fh.member "isolation" A) "enforced")
                      (fh.row "PASS" [] [["isolation" "enforced"] ["accepted_by" By]] Memo)
                      (if (and (= (fh.member "isolation" A) "instruction-only") (= (fh.member "decision" A) "owner-waiver"))
                          (let Waiver (make-string "Repair isolation: instruction-only accepted by ~A on ~A; revisit: ~A" By (fh.member "accepted_on" A) (fh.member "revisit" A))
                            (fh.row "PASS" [] [["isolation" "instruction-only"] ["waiver" Waiver]] [["waiver" Waiver] | Memo]))
                          (fh.row "UNKNOWN" [(cn Path " records neither enforced isolation nor an owner waiver")] [] Memo))))))))

(define fh.check
  "source-identity" Memo -> (fh.source-identity Memo)
  "toolchain-pinned" Memo -> (fh.toolchain-pinned Memo)
  "unit-suite" Memo -> (fh.unit-suite "tests/tc0/*.test.mjs" Memo)
  "hand-agreement-and-replay" Memo -> (fh.hand-agreement-and-replay Memo)
  "exact-arithmetic" Memo -> (fh.exact-arithmetic Memo)
  "exhaustive-small" Memo -> (fh.exhaustive-small Memo)
  "mutant:reverse_operands" Memo -> (fh.mutant "reverse_operands" Memo)
  "mutant:wrap_overflow" Memo -> (fh.mutant "wrap_overflow" Memo)
  "mutant:arm_by_position" Memo -> (fh.mutant "arm_by_position" Memo)
  "catalog-coverage" Memo -> (fh.catalog-coverage Memo)
  "discovery-reduction-replay" Memo -> (fh.discovery-reduction-replay Memo)
  "candidate-boundary" Memo -> (fh.candidate-boundary Memo)
  "requirement-ledger" Memo -> (fh.requirement-ledger Memo)
  "independent-repair-fresh" Memo -> (fh.independent-repair-fresh Memo)
  "repair-isolation:campaigns/tc0/s3/repair-isolation-acceptance.json" Memo -> (fh.repair-isolation "campaigns/tc0/s3/repair-isolation-acceptance.json" Memo)
  "exact-arithmetic-shaken" Memo -> (fh.row "DEFERRED" ["Optional second port: the harness runs on Shen/JIT only"] [] Memo)
  "solo5-guest-agreement" Memo -> (fh.solo5-guest-agreement Memo)
  Name Memo -> (fh.row "UNKNOWN" [(cn "The evaluator has no check named " Name)] [] Memo))

\\ Registered configuration: gate-core also checks the legacy qualification platform.
(define fh.registered?
  Manifest -> (fh.registered-as "tc0-a-qualification" "harness/run-gate.sh" Manifest))

(fh.gate-main "spec/tc0/tc0-a-requirements.json" "tc0-a-requirement-manifest/1" "tc0-a-gate-run/3" "harness/gate.shen" "TC0-A gate (Shen)")
