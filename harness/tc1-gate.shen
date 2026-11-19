\\ TC1 gate evaluator, in Shen: effects and handlers, and remote perform, contract
\\ spec/tc1/EFFECTS.md. Registered as the check tc1-qualification in
\\ .pi/fenrir-workflow.json, with the manifest spec/tc1/tc1-requirements.json, by the
\\ owner's instruction of 2026-11-15; see campaigns/tc1/TC1_GATE_REGISTRATION.md.
\\ The verdict counts as a qualification only while the manifest is owner-accepted
\\ and the workflow configuration names this evaluator; otherwise the report says
\\ authority UNREGISTERED and qualification UNKNOWN.
\\
\\   shen-jit script harness/tc1-gate.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE [NONCE CHECK_ID SOURCE_SHA256 CONFIG_SHA256]
\\
\\ Row evaluation, aggregation and the report are in harness/gate-core.shen, shared
\\ with the TC0-A gate: any required FAIL gives FAIL; else any BLOCKED gives BLOCKED;
\\ else any UNKNOWN gives UNKNOWN; else PASS. An evaluator error, a check that does
\\ not report, or a check it does not know is UNKNOWN.
\\ This file holds the TC1 row checks and the registration rule. The TC0-A rows are
\\ not restated: the TC0-A evaluator is run as one prerequisite row. The rows for the
\\ generated family, its reduction and its replay are in harness/tc1-random-rows.shen;
\\ the three rows for remote perform, and the Erlang half of the toolchain row, are in
\\ harness/tc1-remote-rows.shen.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/gate-core.shen"))
\\ The rows for the generated family.
(load (cn (value fh.*root*) "harness/tc1-random-rows.shen"))
\\ The rows for remote perform.
(load (cn (value fh.*root*) "harness/tc1-remote-rows.shen"))

\\ ---------- the scope this gate requires ----------
\\ The node bound of the exhaustive family and the number of programs of grammar H
\\ (tools/tc1/handler-enumerate.mjs) up to it. The enumerator, the harness's own
\\ derivation from the grammar and this number must all agree; the manifest's
\\ acceptance text states the same two numbers.

(define fh.tc1-bound -> "7")
(define fh.tc1-programs -> "12693")

\\ ---------- TC1 rows ----------

\\ The ids of the required rows of a gate report that did not pass, with their statuses.
(define fh.not-passing
  [] -> []
  [Row | Rows] -> (if (and (= (fh.field "required" Row) true) (not (= (fh.field "status" Row) "PASS")))
                      [(make-string "~A ~A" (fh.field "id" Row) (fh.field "status" Row)) | (fh.not-passing Rows)]
                      (fh.not-passing Rows)))

(define fh.waiver-entries
  Waivers -> (map (/. W ["waiver" W]) Waivers))

\\ The TC0-A gate, run by its own evaluator as a separate process on the same tree.
\\ Its verdict and exit must agree; a report for another HEAD says nothing about this one.
(define fh.tc0-a-gate
  Memo ->
    (let Report (fh.harness "gate.shen" [(fh.subdir "tc0-a-gate") (value fh.*jit*)] 7200)
         Verdict (fh.member "verdict" Report)
         Detail [["required_rows_passing" (fh.member "required_rows_passing" Report)] ["authority" (fh.member "authority" Report)]
                 ["qualification" (fh.member "qualification" Report)] ["claims" (json.stringify (fh.member "claims" Report) [])]]
      (if (or (= Report []) (not (= (fh.member "schema" Report) "tc0-a-gate-run/3")))
          (fh.row "UNKNOWN" ["The TC0-A gate did not report"] [] Memo)
          (if (= Verdict "PASS")
              (if (= (fh.member "head" Report) (fh.member-in "head" Memo))
                  (fh.row "PASS" [] Detail (append (fh.waiver-entries (fh.member "waivers" Report)) Memo))
                  (fh.row "UNKNOWN" ["The TC0-A gate report is for another HEAD, or this run's source was never identified"] Detail Memo))
              (fh.row (if (element? Verdict ["FAIL" "BLOCKED"]) Verdict "UNKNOWN")
                      [(cn "TC0-A gate verdict " (if (string? Verdict) Verdict "missing")) | (fh.not-passing (fh.member "rows" Report))]
                      Detail Memo)))))

(define fh.tc1-handlers
  Memo ->
    (let Report (fh.harness "tc1-handlers.shen" [(fh.subdir "tc1-handlers") "sandbox"] 600)
         Status (fh.member "status" Report)
      (if (= Status "development-pass")
          (fh.row "PASS" [] [["cases" (fh.member "cases" Report)] ["expectations_checked" (fh.member "expectations_checked" Report)]
                             ["defects" (json.stringify (fh.member "defects" Report) [])]] [["tc1-hand" Report] | Memo])
          (if (= Status "development-fail")
              (fh.row "FAIL" ["TC1 handler slice: disagreement, a failed expectation, or an undetected or crashing defect"]
                      [["failures" (json.stringify (fh.member "failures" Report) [])]] Memo)
              (fh.row "UNKNOWN" ["The TC1 handler harness did not report"] [] Memo)))))

\\ Each defect has its own row, read from the report kept in Memo. Agreement alone
\\ cannot make this row pass when the exhaustive harness reports failure.
(define fh.tc1-exhaustive
  Memo ->
    (let Report (fh.harness "tc1-exhaustive.shen" [(fh.tc1-bound) (fh.subdir "tc1-exhaustive") "sandbox"] 1800)
         Agreeing (fh.member "agreeing" Report)
         Programs (fh.member "programs" Report)
      (if (= Report [])
          (fh.row "UNKNOWN" ["The exhaustive handler harness did not report"] [] Memo)
          (if (or (not (= (fh.member "scope_complete" Report) true)) (not (= Programs (fh.tc1-programs))))
              (fh.row "UNKNOWN" [(make-string "The enumerated scope was truncated or incomplete: ~A programs, ~A required" Programs (fh.tc1-programs))] [] Memo)
              (if (not (= Agreeing Programs))
                  (fh.row "FAIL" [(make-string "~A of ~A programs agree with the model" Agreeing Programs)]
                          [["disagreements" (json.stringify (fh.member "disagreements" Report) [])]] [["tc1-exhaustive" Report] | Memo])
                   (if (= (fh.member "status" Report) "development-pass")
                       (fh.row "PASS" [] [["programs" Programs] ["steps" (fh.member "model_steps" Report)]
                                          ["outcomes" (json.stringify (fh.member "outcomes" Report) [])]]
                               [["tc1-exhaustive" Report] | Memo])
                       (fh.row "FAIL" ["The exhaustive handler harness reported failure despite agreement"]
                               [] [["tc1-exhaustive" Report] | Memo])))))))

\\ Killed means: completed with a trace different from the model's. Crashes are never kills.
(define fh.tc1-defect
  Name Memo ->
    (let Counts (fh.member Name (fh.member "defects" (fh.member-in "tc1-exhaustive" Memo)))
         Killed (fh.member "killed" Counts)
      (if (= Counts [])
          (fh.row "UNKNOWN" ["No exhaustive handler report in this run, or it does not report this defect"] [] Memo)
          (if (= Killed "0")
              (fh.row "FAIL" [(make-string "Defect ~A survived every program (~A crashes are not kills)" Name (fh.member "crashed" Counts))] [] Memo)
              (fh.row "PASS" [] [["killed" Killed] ["survived" (fh.member "survived" Counts)] ["crashed" (fh.member "crashed" Counts)]] Memo)))))

\\ The exhaustive family in the Solo5 guest. The guest comparison itself does not know
\\ what a complete family is, so this row checks the batch: its handler family must hold
\\ the required number of programs and the comparison must have covered the whole batch.
(define fh.tc1-guest-exhaustive
  Memo ->
    (let Directory (fh.guest-build ["--tc1-exhaustive-nodes" (fh.tc1-bound)])
      (if (= Directory blocked)
          (fh.guest-row blocked Memo)
          (let Batch (json.parse (read-file-as-string (cn Directory "/batch.json")) [])
               Family (fh.member (cn "tc1-exhaustive-" (fh.tc1-bound)) (fh.member "families" Batch))
               Report (fh.harness "solo5-pure-call.shen" [Directory] 1800)
            (if (and (= Family (fh.tc1-programs)) (or (= Report []) (= (fh.member "programs" Report) (fh.member "count" Batch))))
                (fh.guest-row Report Memo)
                (fh.row "UNKNOWN" [(make-string "The guest batch or its comparison is incomplete: ~A handler programs built, ~A required; ~A of ~A programs compared"
                                                Family (fh.tc1-programs) (fh.member "programs" Report) (fh.member "count" Batch))] [] Memo))))))

\\ Coverage is measured over the traces this run established as agreeing.
(define fh.tc1-step-coverage
  Memo ->
    (if (or (= (fh.member-in "tc1-hand" Memo) []) (= (fh.member-in "tc1-exhaustive" Memo) [])
            (not (= (fh.member "agreeing" (fh.member-in "tc1-exhaustive" Memo)) (fh.member "programs" (fh.member-in "tc1-exhaustive" Memo)))))
        (fh.row "UNKNOWN" ["Needs this run's agreeing hand and exhaustive handler results"] [] Memo)
        (let Report (fh.harness "tc1-coverage.shen" [(cn (value fh.*out*) "tc1-handlers/handlers.jsonl") (cn (value fh.*out*) "tc1-exhaustive")] 900)
             Status (fh.member "status" Report)
          (if (= Status "outside-table")
              (fh.row "FAIL" ["Steps classified outside the table of EFFECTS.md section 6"] [["unknown_observed" (json.stringify (fh.member "unknown_observed" Report) [])]] Memo)
              (if (= Status "incomplete")
                  (fh.row "UNKNOWN" ["Handler step kinds uncovered"] [["missing" (json.stringify (fh.member "missing" Report) [])]] Memo)
                  (if (= Status "complete")
                      (fh.row "PASS" [] [["covered" (make-string "~A/~A" (fh.member "covered" Report) (fh.member "kinds" Report))]] Memo)
                      (fh.row "UNKNOWN" ["The handler coverage harness did not report"] [] Memo)))))))

(define fh.check
  "source-identity" Memo -> (fh.source-identity Memo)
  "toolchain-pinned" Memo -> (fh.tc1-toolchain-pinned Memo)
  "unit-suite" Memo -> (fh.unit-suite "tests/tc0/*.test.mjs tests/tc1/*.test.mjs" Memo)
  "tc0-a-gate" Memo -> (fh.tc0-a-gate Memo)
  "tc1-handlers" Memo -> (fh.tc1-handlers Memo)
  "tc1-exhaustive" Memo -> (fh.tc1-exhaustive Memo)
  "tc1-defect:forgotten_resume" Memo -> (fh.tc1-defect "forgotten_resume" Memo)
  "tc1-defect:double_resume" Memo -> (fh.tc1-defect "double_resume" Memo)
  "tc1-defect:outermost_handler" Memo -> (fh.tc1-defect "outermost_handler" Memo)
  "tc1-defect:dynamic_clause_environment" Memo -> (fh.tc1-defect "dynamic_clause_environment" Memo)
  "tc1-defect:resume_returns_argument" Memo -> (fh.tc1-defect "resume_returns_argument" Memo)
  "tc1-defect:shallow_resume" Memo -> (fh.tc1-defect "shallow_resume" Memo)
  "tc1-guest-hand" Memo -> (fh.guest-row (fh.guest-batch ["--tc1"]) Memo)
  "tc1-guest-exhaustive" Memo -> (fh.tc1-guest-exhaustive Memo)
  "tc1-step-coverage" Memo -> (fh.tc1-step-coverage Memo)
  "tc1-random" Memo -> (fh.tc1-random Memo)
  "tc1-guest-random" Memo -> (fh.tc1-guest-random Memo)
  "tc1-random-control" Memo -> (fh.tc1-random-control Memo)
  "tc1-reduction" Memo -> (fh.tc1-reduction Memo)
  "tc1-reduced-replay" Memo -> (fh.tc1-reduced-replay Memo)
  "tc1-remote-model" Memo -> (fh.tc1-remote-model Memo)
  "tc1-remote-run" Memo -> (fh.tc1-remote-run Memo)
  "tc1-remote-peer" Memo -> (fh.tc1-remote-peer Memo)
  Name Memo -> (fh.row "UNKNOWN" [(cn "The evaluator has no check named " Name)] [] Memo))

\\ Registered: the manifest is owner-accepted and the workflow has a tc1-qualification
\\ check that runs this gate. The rule is the TC0-A gate's (fh.registered-as).
(define fh.registered?
  Manifest -> (fh.registered-as "tc1-qualification" "harness/run-tc1-gate.sh" Manifest))

(fh.gate-main "spec/tc1/tc1-requirements.json" "tc1-requirement-manifest/1" "tc1-gate-run/1" "harness/tc1-gate.shen" "TC1 gate (Shen)")
