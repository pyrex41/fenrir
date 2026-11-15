\\ TC1 gate evaluator, in Shen: effects and handlers, contract spec/tc1/EFFECTS.md.
\\ PROPOSED. Its manifest, spec/tc1/tc1-requirements.json, is not owner-accepted and
\\ this evaluator is not registered in .pi/fenrir-workflow.json, so its report says
\\ authority UNREGISTERED and qualification UNKNOWN whatever the rows say.
\\
\\   shen-jit script harness/tc1-gate.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE [NONCE CHECK_ID SOURCE_SHA256 CONFIG_SHA256]
\\
\\ Row evaluation, aggregation and the report are in harness/gate-core.shen, shared
\\ with the TC0-A gate: any required FAIL gives FAIL; else any BLOCKED gives BLOCKED;
\\ else any UNKNOWN gives UNKNOWN; else PASS. An evaluator error, a check that does
\\ not report, or a check it does not know is UNKNOWN.
\\ This file holds the TC1 row checks and the registration rule. The TC0-A rows are
\\ not restated: the TC0-A evaluator is run as one prerequisite row.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/gate-core.shen"))

\\ ---------- the scope this gate requires ----------
\\ The node bound of the exhaustive family and the number of programs of grammar H
\\ (tools/tc1/handler-enumerate.mjs) up to it. The enumerator, the harness's own
\\ derivation from the grammar and this number must all agree; the manifest's
\\ acceptance text states the same two numbers.

(define fh.tc1-bound -> "7")
(define fh.tc1-programs -> "12693")

\\ The number of programs of grammar G (tools/tc1/task-enumerate.mjs, slice C1) the
\\ task exploration must cover. The harness derives the same number from the grammar;
\\ the manifest's acceptance text states it.
(define fh.tc1-task-programs -> "3600")

\\ Every n-th program of the 5-node grammar joins the Solo5 control check's batch.
(define fh.solo5-control-stride -> "25")

\\ The validator the differential row compares the current one against: the artifact
\\ validator as it was before the TC1-D1 edit (the parent of commit 8d13bca, "validator:
\\ schema tc1-durable-demo/1"), and the digest of that file. The row reads it from git; a
\\ file with another digest is not the validator it pins. The scope the comparison must
\\ cover is the tool's own corpora with the program counts below.
(define fh.validator-old-rev -> "8b3d0c1a777e9f31fb43fc0face7e609dc6570be")
(define fh.validator-old-sha256 -> "d7600203052bc56a77595b42600acca2fff5a3ca5ffbdf9b5a662f3478d532df")
(define fh.validator-verdicts -> "137469")
(define fh.validator-accepted -> "24153")
(define fh.validator-corpora
  -> [["tc0-call-hand" "8"] ["tc0-data-hand" "15"] ["tc0-call-generated" "32"] ["tc0-data-generated" "24"]
      ["tc0-data-exhaustive-5" "5695"] ["tc1-handler-hand" "20"] ["tc1-handler-exhaustive-7" "12693"]
      ["tc1-handler-generated" "2048"] ["tc1-task-hand" "18"] ["tc1-task-exhaustive" "3600"]])

\\ The generated family G (tools/tc1/handler-generate.mjs): the number of programs a
\\ complete batch holds, which is also the family's size.
(define fh.tc1-generated-programs -> "2048")

\\ The defects with a discovery-reduction-replay campaign, each with its own row.
(define fh.tc1-campaign-defects -> ["forgotten_resume" "double_resume" "outermost_handler" "shallow_resume"])

\\ The handler transition catalog and the digest of the file this gate measures against.
\\ An edited catalog is not measured against until this pin (and the manifest's
\\ catalog_sha256) is changed with it.
(define fh.tc1-catalog -> "spec/tc1/handler-catalog.json")
(define fh.tc1-catalog-sha256 -> "018dee318b47c91ca6fa8b7a8d291a5ab27867a9ffdf0e676bd7329e89276a19")

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
\\ Its verdict is this row's status; a report for another HEAD says nothing about this one.
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

\\ Agreement only: each defect has its own row, read from the report kept in Memo.
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
                  (fh.row "PASS" [] [["programs" Programs] ["steps" (fh.member "model_steps" Report)]
                                     ["outcomes" (json.stringify (fh.member "outcomes" Report) [])]]
                          [["tc1-exhaustive" Report] | Memo]))))))

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

\\ The generated family: agreement, the handler behaviours its traces exercised and the
\\ defects it kills, all decided by the harness; this row checks the scope.
(define fh.tc1-generated
  Memo ->
    (let Report (fh.harness "tc1-generated.shen" [(fh.tc1-generated-programs) (fh.subdir "tc1-generated") "sandbox"] 1800)
         Programs (fh.member "programs" Report)
         Agreeing (fh.member "agreeing" Report)
         Status (fh.member "status" Report)
      (if (= Report [])
          (fh.row "UNKNOWN" ["The generated handler harness did not report"] [] Memo)
          (if (or (not (= (fh.member "scope_complete" Report) true)) (not (= Programs (fh.tc1-generated-programs))))
              (fh.row "UNKNOWN" [(make-string "The generated family was truncated or incomplete: ~A programs, ~A required" Programs (fh.tc1-generated-programs))] [] Memo)
              (if (not (= Agreeing Programs))
                  (fh.row "FAIL" [(make-string "~A of ~A generated programs agree with the model" Agreeing Programs)]
                          [["disagreements" (json.stringify (fh.member "disagreements" Report) [])]] Memo)
                  (if (= Status "development-pass")
                      (fh.row "PASS" [] [["programs" Programs] ["steps" (fh.member "model_steps" Report)]
                                         ["outcomes" (json.stringify (fh.member "outcomes" Report) [])]
                                         ["features" (json.stringify (fh.member "features" Report) [])]
                                         ["defects" (json.stringify (fh.member "defects" Report) [])]]
                              [["tc1-generated" Report] | Memo])
                      (fh.row "FAIL" ["A listed handler behaviour was never exercised, or an injected defect survived every generated program"]
                              [["features_unexercised" (json.stringify (fh.member "features_unexercised" Report) [])]
                               ["defects_undetected" (json.stringify (fh.member "defects_undetected" Report) [])]] Memo)))))))

\\ One discovery-reduction-replay campaign. Its retained cases must be the committed ones,
\\ which the strict-replay row replays.
(define fh.tc1-reduction
  Defect Memo ->
    (let Report (fh.harness "tc1-reduction.shen" [(fh.subdir (cn "tc1-reduction-" Defect)) Defect "sandbox"] 1800)
         Status (fh.member "status" Report)
         Detail [["case" (make-string "~A (index ~A), ~A attempts (~A accepted), nodes ~A->~A, divergence epochs ~A and ~A"
                                       (fh.member "discovered_program" Report) (fh.member "discovered_index" Report)
                                       (fh.member "attempts" Report) (fh.member "accepted" Report)
                                       (fh.member "original_nodes" Report) (fh.member "minimized_nodes" Report)
                                       (fh.member "original_divergence_epoch" Report) (fh.member "minimized_divergence_epoch" Report))]
                 ["discrepancy" (fh.member "discrepancy" Report)]]
      (if (= Status "development-pass")
          (if (= (fh.member "matches_retained" Report) true)
              (fh.row "PASS" [] Detail [[(cn "tc1-campaign:" Defect) Report] | Memo])
              (fh.row "UNKNOWN" [(cn "The campaign's original or minimized failure differs from the committed retained case for " Defect)] Detail Memo))
          (if (= Status "development-fail")
              (fh.row "FAIL" [(cn "Campaign failed: " (fh.member "reason" Report))] [] Memo)
              (fh.row "UNKNOWN" [(if (= Report []) "The reduction campaign did not report" (cn "Campaign error: " (fh.member "reason" Report)))] [] Memo)))))

(define fh.tc1-missing
  [] _ -> []
  [X | Xs] Ys -> (if (element? X Ys) (fh.tc1-missing Xs Ys) [X | (fh.tc1-missing Xs Ys)]))

(define fh.tc1-strict-replay
  Memo ->
    (let Report (fh.harness "tc1-strict-replay.shen" [(fh.subdir "tc1-strict-replay") "sandbox"] 900)
         Status (fh.member "status" Report)
         Missing (fh.tc1-missing (fh.tc1-campaign-defects) (fh.member "retained_defects" Report))
         Detail [["hand_admitted" (make-string "~A/~A" (fh.member "hand_admitted" Report) (fh.member "hand_cases" Report))]
                 ["retained" (make-string "~A cases; ~A admitted without the defect, ~A diverged at the retained epoch with it"
                                         (fh.member "retained_cases" Report) (fh.member "retained_fixed_admitted" Report)
                                         (fh.member "retained_diverged_at_epoch" Report))]]
      (if (= Status "development-fail")
          (fh.row "FAIL" ["A hand fixture disagreed, a tape was not admitted, or a retained failure did not diverge at its epoch"]
                  [["hand_failures" (json.stringify (fh.member "hand_failures" Report) [])]
                   ["not_admitted" (json.stringify (append (fh.member "hand_not_admitted" Report) (fh.member "retained_fixed_not_admitted" Report)) [])]
                   ["not_diverged" (json.stringify (fh.member "retained_not_diverged" Report) [])]] Memo)
          (if (not (= Status "development-pass"))
              (fh.row "UNKNOWN" ["The strict replay harness did not report"] [] Memo)
              (if (not (empty? Missing))
                  (fh.row "UNKNOWN" [(cn "No retained original and minimized failure for " (fh.join Missing ", "))] Detail Memo)
                  (if (not (= (fh.member "catalog_hash" Report) (fh.tc1-catalog-sha256)))
                      (fh.row "UNKNOWN" ["The tapes bind another handler catalog than the one this gate pins"] Detail Memo)
                      (fh.row "PASS" [] Detail Memo)))))))

\\ Coverage is measured over the traces this run established as agreeing.
(define fh.tc1-catalog-coverage
  Memo ->
    (if (or (= (fh.member-in "tc1-hand" Memo) []) (= (fh.member-in "tc1-exhaustive" Memo) []) (= (fh.member-in "tc1-generated" Memo) [])
            (not (= (fh.member "agreeing" (fh.member-in "tc1-exhaustive" Memo)) (fh.member "programs" (fh.member-in "tc1-exhaustive" Memo)))))
        (fh.row "UNKNOWN" ["Needs this run's agreeing hand, exhaustive and generated handler results"] [] Memo)
        (let Report (fh.harness "tc1-coverage.shen" [(cn (value fh.*root*) (fh.tc1-catalog)) (fh.tc1-catalog-sha256)
                                                     (cn (value fh.*out*) "tc1-handlers/handlers.jsonl")
                                                     (cn (value fh.*out*) "tc1-exhaustive") (cn (value fh.*out*) "tc1-generated")] 1800)
             Status (fh.member "status" Report)
          (if (= Status "outside-catalog")
              (fh.row "FAIL" ["Handler steps with no catalog transition, or contradicting their transition's depth change"]
                      [["outside_catalog" (json.stringify (fh.member "outside_catalog" Report) [])]
                       ["depth_violations" (json.stringify (fh.member "depth_violations" Report) [])]] Memo)
              (if (= Status "catalog-mismatch")
                  (fh.row "UNKNOWN" [(make-string "The catalog's digest ~A is not the pinned ~A" (fh.member "catalog_sha256" Report) (fh.tc1-catalog-sha256))] [] Memo)
                  (if (= Status "incomplete")
                      (fh.row "UNKNOWN" ["Catalog transitions uncovered"] [["missing" (json.stringify (fh.member "missing" Report) [])]] Memo)
                      (if (= Status "complete")
                          (fh.row "PASS" [] [["covered" (make-string "~A/~A" (fh.member "covered" Report) (fh.member "transitions" Report))]
                                             ["catalog" (make-string "~A ~A" (fh.member "catalog_version" Report) (fh.member "catalog_sha256" Report))]] Memo)
                          (fh.row "UNKNOWN" ["The handler coverage harness did not report"] [] Memo))))))))

\\ ---------- optional rows: slice C1 (tasks and channels) and the Solo5 control channel ----------

\\ A decimal count the harness reports as a string, above zero. Anything else is not.
(define fh.positive-count?
  X -> (and (string? X) (> (tc0.i64.small X) 0)))

(define fh.tc1-tasks
  Memo ->
    (let Report (fh.harness "tc1-tasks.shen" [(fh.subdir "tc1-tasks") "sandbox"] 600)
         Status (fh.member "status" Report)
      (if (= Status "development-pass")
          (fh.row "PASS" [] [["cases" (fh.member "cases" Report)] ["runs" (fh.member "runs" Report)]
                             ["expectations_checked" (fh.member "expectations_checked" Report)]
                             ["defects" (json.stringify (fh.member "defects" Report) [])]
                             ["defects_crashing" (json.stringify (fh.member "defects_crashing" Report) [])]] Memo)
          (if (= Status "development-fail")
              (fh.row "FAIL" ["TC1 task slice: disagreement, a failed expectation, a non-production schedule, or an undetected defect"]
                      [["failures" (json.stringify (fh.member "failures" Report) [])]
                       ["defects_undetected" (json.stringify (fh.member "defects_undetected" Report) [])]] Memo)
              (fh.row "UNKNOWN" ["The TC1 task harness did not report"] [] Memo)))))

\\ The commuting obligation on the whole of grammar G. Only a complete, untruncated scope
\\ of exactly the required programs can pass; a partial one is UNKNOWN, never PASS.
(define fh.tc1-task-explore
  Memo ->
    (let Report (fh.harness "tc1-task-explore.shen" [(fh.subdir "tc1-task-explore") "sandbox"] 1800)
         Programs (fh.member "programs" Report)
         Compared (fh.member "witnesses_compared" Report)
         Detail [["programs" (if (string? Programs) Programs "")] ["witnesses_compared" (if (string? Compared) Compared "")]
                 ["witnesses_agreeing" (let A (fh.member "witnesses_agreeing" Report) (if (string? A) A ""))]]
      (if (= Report [])
          (fh.row "UNKNOWN" ["The TC1 task exploration did not report (or exceeded its time limit)"] [] Memo)
          (if (or (not (= (fh.member "scope_complete" Report) true)) (not (= Programs (fh.tc1-task-programs)))
                  (not (= (fh.member "bounds_hit" Report) "0")))
              (fh.row "UNKNOWN" [(make-string "The exploration was truncated or incomplete: scope_complete ~A, ~A programs (~A required), bounds hit ~A"
                                              (fh.member "scope_complete" Report) Programs (fh.tc1-task-programs) (fh.member "bounds_hit" Report))]
                      Detail Memo)
              (if (and (= (fh.member "status" Report) "development-pass")
                       (= (fh.member "obligation_holds" Report) true)
                       (fh.positive-count? (fh.member "programs_failing_the_check" (fh.member "broken_send_not_a_point" Report)))
                       (fh.positive-count? (fh.member "programs_failing_the_check" (fh.member "broken_eager_cancel" Report)))
                       (fh.positive-count? Compared)
                       (= (fh.member "witnesses_agreeing" Report) Compared))
                  (fh.row "PASS" [] [["programs" Programs]
                                     ["obligation_holds" "true"]
                                     ["broken_send_not_a_point_fails_on" (fh.member "programs_failing_the_check" (fh.member "broken_send_not_a_point" Report))]
                                     ["broken_eager_cancel_fails_on" (fh.member "programs_failing_the_check" (fh.member "broken_eager_cancel" Report))]
                                     ["witnesses_compared" Compared]] Memo)
                  (fh.row "FAIL" ["The commuting obligation does not hold on every program, a broken variant passed the check everywhere, or a witness disagrees with the model"]
                          (append Detail [["obligation_holds" (make-string "~A" (fh.member "obligation_holds" Report))]
                                          ["unequal_examples" (json.stringify (fh.member "unequal_examples" Report) [])]
                                          ["witness_disagreements" (json.stringify (fh.member "witness_disagreements" Report) [])]]) Memo))))))

\\ The host-controlled Solo5 guest, driven step by step by Shen (harness/solo5-control.shen),
\\ as harness/run-solo5-control.sh does. No Solo5, or a guest build that fails: BLOCKED.
\\ The harness not completing in time, or not reporting: UNKNOWN.
(define fh.solo5-control
  Memo ->
    (let Built (fh.exec "node" [(cn (value fh.*root*) "tools/solo5/control-pure-call-build.mjs") "--stride" (fh.solo5-control-stride)] 1800)
      (if (= (hd Built) -1)
          (fh.row "UNKNOWN" ["The Solo5 control batch build did not complete within its time limit"] [] Memo)
      (if (not (= (hd Built) 0))
          (fh.row "BLOCKED" ["The Solo5 control batch or guests could not be built (is Solo5 available at the pinned commit?)"] [] Memo)
          (let Batch (fh.last-line-of (hd (tl Built)))
               Run (fh.subdir "solo5-control")
               R (fh.exec (value fh.*jit*) ["script" (cn (value fh.*root*) "harness/solo5-control.shen") (value fh.*lib*) (value fh.*root*) Batch Run] 1800)
               Report (fh.last-report (hd (tl R)))
               Status (fh.member "status" Report)
            (if (element? (hd R) [126 127])
                (fh.row "BLOCKED" ["Shen/JIT could not be started for the Solo5 control harness"] [] Memo)
                (if (= Status "development-pass")
                    (fh.row "PASS" [] [["programs" (fh.member "programs" Report)] ["stride" (fh.solo5-control-stride)]
                                       ["total_boots" (fh.member "total_boots" Report)]] Memo)
                    (if (= Status "development-fail")
                        (fh.row "FAIL" ["The Solo5 control check failed: a divergence between the guest and the model, a tape that did not replay exactly, or an unexpected hostile-peer result"] [] Memo)
                        (fh.row "UNKNOWN" ["The Solo5 control harness did not report (or exceeded its time limit)"] [] Memo)))))))))

(define fh.last-line-of
  Text -> (let Lines (fh.lines Text)
            (if (empty? Lines) "" (fh.trim (hd (reverse Lines))))))

\\ ---------- optional rows: durable effects (slice D1), the validator edit, the typing rules ----------

\\ The TC1-D1 hand fixtures under their host replies (harness/tc1-durable.shen, as
\\ harness/run-tc1-durable.sh runs it): the model and the sandboxed implementation agree,
\\ every handwritten expectation holds and each expectation kind can fail, and the injected
\\ durable defects are detected. Only the harness's own development-pass is PASS.
(define fh.tc1-durable
  Memo ->
    (let Report (fh.harness "tc1-durable.shen" [(fh.subdir "tc1-durable") "sandbox"] 600)
         Status (fh.member "status" Report)
      (if (= Status "development-pass")
          (fh.row "PASS" [] [["cases" (fh.member "cases" Report)] ["expectations_checked" (fh.member "expectations_checked" Report)]
                             ["executions" (json.stringify (fh.member "executions" Report) [])]
                             ["defects" (json.stringify (fh.member "defects" Report) [])]
                             ["defects_crashing" (json.stringify (fh.member "defects_crashing" Report) [])]] Memo)
          (if (= Status "development-fail")
              (fh.row "FAIL" ["TC1-D1 fixtures: disagreement, a failed expectation, an expectation kind that cannot fail, or an undetected defect"]
                      [["failures" (json.stringify (fh.member "failures" Report) [])]
                       ["defects_undetected" (json.stringify (fh.member "defects_undetected" Report) [])]
                       ["expectation_kinds_unable_to_fail" (json.stringify (fh.member "expectation_kinds_unable_to_fail" Report) [])]] Memo)
              (fh.row "UNKNOWN" ["The TC1-D1 durable harness did not report (or exceeded its time limit)"] [] Memo)))))

\\ The host-controlled Solo5 guest over control protocol v2 (harness/solo5-durable.shen), as
\\ harness/run-solo5-durable.sh runs it. No Solo5, or a guest build that fails: BLOCKED.
\\ Shen/JIT that cannot start: BLOCKED. A time limit or no report: UNKNOWN.
(define fh.solo5-durable
  Memo ->
    (let Built (fh.exec "node" [(cn (value fh.*root*) "tools/solo5/control-durable-build.mjs")] 1800)
      (if (= (hd Built) -1)
          (fh.row "UNKNOWN" ["The Solo5 durable batch build did not complete within its time limit"] [] Memo)
      (if (not (= (hd Built) 0))
          (fh.row "BLOCKED" ["The Solo5 durable batch or guest could not be built (is Solo5 available at the pinned commit?)"] [] Memo)
          (let Batch (fh.last-line-of (hd (tl Built)))
               Run (fh.subdir "solo5-durable")
               R (fh.exec (value fh.*jit*) ["script" (cn (value fh.*root*) "harness/solo5-durable.shen") (value fh.*lib*) (value fh.*root*) Batch Run] 1800)
               Report (fh.last-report (hd (tl R)))
               Status (fh.member "status" Report)
            (if (element? (hd R) [126 127])
                (fh.row "BLOCKED" ["Shen/JIT could not be started for the Solo5 durable harness"] [] Memo)
                (if (and (= Status "development-pass")
                         (= (fh.member "programs_agreeing_with_model" Report) (fh.member "programs" Report)))
                    (fh.row "PASS" [] [["protocol" (fh.member "protocol" Report)] ["programs" (fh.member "programs" Report)]
                                       ["steps_agreed" (fh.member "steps_agreed" Report)] ["total_boots" (fh.member "total_boots" Report)]] Memo)
                    (if (element? Status ["development-pass" "development-fail"])
                        (fh.row "FAIL" ["The Solo5 durable check failed: a divergence between the guest and the model, a tape that did not replay exactly, or an unexpected hostile-host or vector result"]
                                [["failures" (json.stringify (fh.member "failures" Report) [])]] Memo)
                        (fh.row "UNKNOWN" ["The Solo5 durable harness did not report (or exceeded its time limit)"] [] Memo)))))))))

(define fh.validator-corpora-match?
  [] Corpora -> true
  [[Name Programs] | Rest] Corpora ->
    (and (= (fh.show (fh.member "programs" (fh.member Name Corpora))) Programs) (fh.validator-corpora-match? Rest Corpora)))

\\ A decoded JSON value as text: a number is read as [number N], a string stays itself.
(define fh.show
  [number N] -> (make-string "~A" N)
  V -> (if (string? V) V (make-string "~A" V)))

\\ The differential check of the artifact validator edits (tools/tc1/validator-differential.mjs):
\\ every program of every older corpus, and mutations aimed at the edit, get the same verdict
\\ from the validator before the TC1-D1 edit and from the current one. The earlier copy is
\\ read from git at the pinned revision and must have the pinned digest. The current
\\ validator also carries the later effect-name fix (b4f4af2); on these corpora it changes no
\\ verdict, which the identical count shows. PASS only when every verdict is identical and the
\\ counts are the pinned ones; a difference or other counts is FAIL; no report, or no earlier
\\ copy, is UNKNOWN.
(define fh.validator-differential
  Memo ->
    (let Old (cn (fh.subdir "validator-differential") "/old-validator.mjs")
         Got (fh.exec "sh" ["-c" (make-string "git show ~A:tools/tc0/pure-call-artifact.mjs > ~A" (fh.validator-old-rev) Old)] 120)
      (if (or (not (= (hd Got) 0)) (not (= (fh.sha256 Old) (fh.validator-old-sha256))))
          (fh.row "UNKNOWN" ["The validator as it was before the TC1-D1 edit could not be read from git, or is not the file the evaluator pins"] [] Memo)
          (let R (fh.exec "node" [(cn (value fh.*root*) "tools/tc1/validator-differential.mjs") Old] 900)
               Report (fh.last-report (hd (tl R)))
               Detail [["verdicts" (fh.show (fh.member "verdicts" Report))] ["identical" (fh.show (fh.member "identical" Report))]]
            (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.validator-differential/1")))
                (fh.row "UNKNOWN" ["The validator differential did not report (or exceeded its time limit)"] [] Memo)
                (if (and (= (fh.member "status" Report) "identical")
                         (= (hd R) 0)
                         (= (fh.member "differences" Report) [])
                         (= (fh.show (fh.member "verdicts" Report)) (fh.validator-verdicts))
                         (= (fh.show (fh.member "identical" Report)) (fh.validator-verdicts))
                         (= (fh.show (fh.member "accepted_as_is" Report)) (fh.validator-accepted))
                         (fh.validator-corpora-match? (fh.validator-corpora) (fh.member "corpora" Report)))
                    (fh.row "PASS" [] (append Detail [["accepted_as_is" (fh.validator-accepted)] ["old_validator" (fh.validator-old-rev)]]) Memo)
                    (fh.row "FAIL" ["Some verdict differs between the validator before the TC1-D1 edit and the current one, or the corpora are not the pinned ones"]
                            (append Detail [["status" (fh.show (fh.member "status" Report))]
                                            ["differences" (json.stringify (fh.member "differences" Report) [])]]) Memo)))))))

\\ The families of the typing differential whose acceptance disagrees. The probe family is
\\ judged against the contract text instead; its departures are listed separately.
(define fh.typing-disagreeing
  [] -> []
  [F | Fs] -> (if (or (= (fh.member "family" F) "probes") (= (fh.member "agreeing" F) (fh.member "programs" F)))
                  (fh.typing-disagreeing Fs)
                  [(fh.member "family" F) | (fh.typing-disagreeing Fs)]))

\\ typing/run.shen, as typing/run.sh runs it (about 2.5 minutes): Shen-side validation against
\\ the JavaScript validator on every program family, the checker on forged derivations, and
\\ the model on every accepted program. PASS only on development-pass with no family whose
\\ acceptance disagrees, no probe on which the Shen side departs from the contract, and no
\\ derivation search out of budget. A search out of budget, no report or a time limit is
\\ UNKNOWN. The claim is derivable under rule set R, not sound.
(define fh.typing-differential
  Memo ->
    (let Out (fh.subdir "typing")
         R (fh.exec (value fh.*jit*) ["script" (cn (value fh.*root*) "typing/run.shen") (value fh.*lib*) (value fh.*root*) Out] 1800)
         Report (fh.last-report (hd (tl R)))
         Status (fh.member "status" Report)
         Unknown (fh.member "search_unknown" Report)
         Disagreeing (fh.typing-disagreeing (fh.member "families" Report))
         ShenDeparts (fh.member "shen_departs_from_contract" (fh.member "probes" Report))
      (if (not (element? Status ["development-pass" "development-fail"]))
          (fh.row "UNKNOWN" ["The typing differential did not report (or exceeded its time limit)"] [] Memo)
          (if (not (empty? Disagreeing))
              (fh.row "FAIL" ["The Shen validation and the JavaScript validator disagree on the acceptance of some programs"]
                      [["families_disagreeing" (fh.join Disagreeing ", ")]] Memo)
              (if (not (= Unknown "0"))
                  (fh.row "UNKNOWN" [(make-string "A derivation search ran out of budget (~A searches)" (fh.show Unknown))] [] Memo)
                  (if (and (= Status "development-pass") (= ShenDeparts []))
                      (fh.row "PASS" [] [["frontend_programs" (json.stringify (fh.member "frontend_programs" Report) [])]
                                         ["forged_derivations" (json.stringify (fh.member "forged_derivations" Report) [])]
                                         ["search_budget_inferences" (fh.member "search_budget_inferences" Report)]] Memo)
                      (fh.row "FAIL" ["The typing differential failed: a program Shen accepts got stuck, a forged derivation was accepted, a probe departs from the contract, or a family's expectation did not hold"]
                              [["model_runs_of_accepted_programs" (json.stringify (fh.member "model_runs_of_accepted_programs" Report) [])]
                               ["forged_derivations" (json.stringify (fh.member "forged_derivations" Report) [])]
                               ["shen_departs_from_contract" (json.stringify ShenDeparts [])]] Memo)))))))

(define fh.check
  "source-identity" Memo -> (fh.source-identity Memo)
  "toolchain-pinned" Memo -> (fh.toolchain-pinned Memo)
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
  "tc1-generated" Memo -> (fh.tc1-generated Memo)
  "tc1-reduction:forgotten_resume" Memo -> (fh.tc1-reduction "forgotten_resume" Memo)
  "tc1-reduction:double_resume" Memo -> (fh.tc1-reduction "double_resume" Memo)
  "tc1-reduction:outermost_handler" Memo -> (fh.tc1-reduction "outermost_handler" Memo)
  "tc1-reduction:shallow_resume" Memo -> (fh.tc1-reduction "shallow_resume" Memo)
  "tc1-strict-replay" Memo -> (fh.tc1-strict-replay Memo)
  "tc1-guest-hand" Memo -> (fh.guest-row (fh.guest-batch ["--tc1"]) Memo)
  "tc1-guest-exhaustive" Memo -> (fh.tc1-guest-exhaustive Memo)
  "tc1-catalog-coverage" Memo -> (fh.tc1-catalog-coverage Memo)
  "tc1-tasks" Memo -> (fh.tc1-tasks Memo)
  "tc1-task-explore" Memo -> (fh.tc1-task-explore Memo)
  "solo5-control" Memo -> (fh.solo5-control Memo)
  "tc1-durable" Memo -> (fh.tc1-durable Memo)
  "solo5-durable" Memo -> (fh.solo5-durable Memo)
  "validator-differential" Memo -> (fh.validator-differential Memo)
  "typing-differential" Memo -> (fh.typing-differential Memo)
  Name Memo -> (fh.row "UNKNOWN" [(cn "The evaluator has no check named " Name)] [] Memo))

\\ Registered: the manifest is owner-accepted and the workflow has a tc1-qualification
\\ check that runs this gate. Neither holds today.
(define fh.registered?
  Manifest -> (fh.registered-as "tc1-qualification" "harness/run-tc1-gate.sh" Manifest))

(fh.gate-main "spec/tc1/tc1-requirements.json" "tc1-requirement-manifest/1" "tc1-gate-run/1" "harness/tc1-gate.shen" "TC1 gate (Shen, proposed)")
