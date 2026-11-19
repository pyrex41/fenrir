\\ Rows of the TC1 gate for the generated handler family: agreement on the
\\ family, the family in the Solo5 guest, the negative control, reduction of a failure
\\ per injected defect, and replay of the reduced failures. Load after gate-core.shen.
\\ Loaded by tc1-gate.shen, and by tc1-random-control.shen to run the control alone.
\\ The checks themselves are tc1-random.shen, tc1-reduce.shen and tc1-replay.shen,
\\ each run as its own process.

(load (cn (value fh.*root*) "harness/tc1-random-guest.shen"))

\\ ---------- the scope the gate requires ----------
\\ Twenty fixed seeds (fh.g-seed 0 .. 19 of tc1-generate.shen), a thousand programs
\\ each. The manifest's acceptance text states the same numbers.

(define fh.tc1-random-seeds -> 20)
(define fh.tc1-random-per-seed -> 1000)

\\ The control's scope: one seed, with each defect in turn and once with none.
(define fh.tc1-control-per-seed -> 1000)

\\ ---------- the family: validator, model against implementation, distribution ----------

(define fh.tc1-random-reasons
  Report Expected ->
    (append (if (= (fh.member "programs" Report) Expected) [] [(make-string "~A programs compared, ~A required" (fh.member "programs" Report) Expected)])
            (if (= (fh.member "rejected_by_validator" Report) "0") [] [(cn (fh.member "rejected_by_validator" Report) " generated programs rejected by the validator")])
            (if (= (fh.member "node_count_differs" Report) []) [] ["The validator and the generator count different nodes"])
            (if (= (fh.member "disagreeing" Report) "0") [] [(cn (fh.member "disagreeing" Report) " programs on which the model and the implementation disagree")])
            (if (= (fh.member "behaviours_absent" Report) []) [] [(cn "No program in the family is " (fh.join (fh.member "behaviours_absent" Report) ", "))])))

\\ Defect is [] for the family itself, or the injected defect of a negative control.
\\ A report with a defect switched on is never a pass.
(define fh.tc1-random-with
  Defect Seeds PerSeed Tag Memo ->
    (let Directory (fh.subdir Tag)
         Report (fh.harness "tc1-random.shen" (append [Directory (str Seeds) (str PerSeed) "sandbox"] (if (= Defect []) [] [(cn "defect=" Defect)])) 3600)
         Status (fh.member "status" Report)
         Expected (str (* Seeds PerSeed))
      (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.tc1-random/1")))
          (fh.row "UNKNOWN" ["The generated-family harness did not report"] [] Memo)
          (if (= Status "development-fail")
              (fh.row "FAIL" (fh.tc1-random-reasons Report Expected)
                      [["injected_defect" (fh.member "injected_defect" Report)] ["disagreements" (json.stringify (fh.member "disagreements" Report) [])]
                       ["rejections" (json.stringify (fh.member "rejections" Report) [])]] Memo)
              (if (and (= Status "development-pass") (= (fh.member "programs" Report) Expected) (= (fh.member "agreeing" Report) Expected)
                       (= (fh.member "rejected_by_validator" Report) "0") (= (fh.member "injected_defect" Report) "none"))
                  (fh.row "PASS" []
                          [["programs" Expected] ["steps" (fh.member "model_steps" Report)] ["seeds" (str Seeds)]
                           ["outcomes" (json.stringify (fh.member "outcomes" Report) [])]
                           ["behaviours" (json.stringify (fh.member "behaviours" Report) [])]
                           ["nodes" (json.stringify (fh.member "nodes" Report) [])]
                           ["max_handler_nesting_depth" (fh.member "max_handler_nesting_depth" Report)]
                           ["step_kinds_covered" (make-string "~A/~A" (fh.member "step_kinds_covered" Report) (fh.member "step_kinds" Report))]
                           ["rules_exercised" (make-string "~A/~A" (fh.member "rules_exercised" Report) (fh.member "rules" Report))]]
                          [["tc1-random" Report] ["tc1-random-directory" (cn Directory "/")] | Memo])
                  (fh.row "UNKNOWN" ["The generated-family report is not a pass at the required scope"] [] Memo))))))

(define fh.tc1-random
  Memo -> (fh.tc1-random-with [] (fh.tc1-random-seeds) (fh.tc1-random-per-seed) "tc1-random" Memo))

\\ ---------- the family in the Solo5 guest ----------
\\ The programs are the files this run's family row wrote, so both rows are about the
\\ same programs. One guest image per seed.

(define fh.tc1-guest-random
  Memo ->
    (let Directory (fh.member-in "tc1-random-directory" Memo)
         Family (fh.member-in "tc1-random" Memo)
      (if (= Directory [])
          (fh.row "UNKNOWN" ["Needs this run's generated family, accepted by the validator and agreed by the implementation"] [] Memo)
          (let Guest (fh.rg-family Directory (fh.tc1-random-seeds) (fh.tc1-random-per-seed) (tc0.i64.small (fh.member "step_bound" Family)))
               Status (fh.member "status" Guest)
               Detail [["batches" (fh.member "batches" Guest)] ["programs" (fh.member "programs" Guest)] ["steps" (fh.member "guest_steps" Guest)]
                       ["programs_differing" (fh.member "programs_differing" Guest)]]
            (if (= Status "blocked")
                (fh.guest-row blocked Memo)
                (if (= Status "fail")
                    (fh.row "FAIL" [(cn (fh.member "programs_differing" Guest) " generated programs differ between the model and the Solo5 guest, or a guest defect went undetected in a batch")] Detail Memo)
                    (if (and (= Status "pass") (= (fh.member "programs" Guest) (fh.member "programs" Family)) (= (fh.member "model_steps" Guest) (fh.member "model_steps" Family)))
                        (fh.row "PASS" [] Detail Memo)
                        (fh.row "UNKNOWN" ["A guest batch did not report, or the batches are not this run's family"] Detail Memo))))))))

\\ ---------- negative control ----------
\\ The family row's own check, on a smaller scope, with each injected defect switched on
\\ in the implementation: it must be FAIL each time, and PASS on the same scope with none.

(define fh.tc1-control-statuses
  [] -> []
  [Defect | Defects] ->
    [[Defect (hd (fh.tc1-random-with Defect 1 (fh.tc1-control-per-seed) (cn "tc1-random-control-" Defect) []))]
     | (fh.tc1-control-statuses Defects)])

\\ The six injected defects, by report key. The gate holds the list itself (tc1-defects.shen,
\\ which the harness programs use, also defines a per-run fh.verdict and cannot be loaded
\\ beside the gate's), so a control that leaves one out cannot pass.
(define fh.tc1-control-defects
  -> ["forgotten_resume" "double_resume" "outermost_handler" "dynamic_clause_environment" "resume_returns_argument" "shallow_resume"])

(define fh.tc1-control-wrong
  [] -> []
  [[Defect "FAIL"] | Rest] -> (fh.tc1-control-wrong Rest)
  [[Defect Status] | Rest] -> [(make-string "With defect ~A switched on the family check is ~A, not FAIL" Defect Status) | (fh.tc1-control-wrong Rest)])

(define fh.tc1-random-control
  Memo ->
    (let Clean (hd (fh.tc1-random-with [] 1 (fh.tc1-control-per-seed) "tc1-random-control-none" []))
         Statuses (fh.tc1-control-statuses (fh.tc1-control-defects))
         Wrong (append (if (= Clean "PASS") [] [(cn "With no defect the family check on the control's scope is " Clean)])
                       (fh.tc1-control-wrong Statuses))
      (fh.row (if (empty? Wrong) "PASS" (if (or (element? "UNKNOWN" (map (/. S (hd (tl S))) Statuses)) (= Clean "UNKNOWN")) "UNKNOWN" "FAIL"))
              Wrong [["none" Clean] | Statuses] Memo)))

\\ ---------- reduction and replay ----------

(define fh.tc1-reduction-detail
  [] -> []
  [[Defect Summary] | Rest] ->
    [[Defect (make-string "~A: ~A -> ~A nodes" (fh.member "original" Summary) (fh.member "original_nodes" Summary) (fh.member "shrunk_nodes" Summary))]
     | (fh.tc1-reduction-detail Rest)])

(define fh.tc1-reduction
  Memo ->
    (let Report (fh.harness "tc1-reduce.shen" [(fh.subdir "tc1-reduce") "sandbox"] 3600)
         Status (fh.member "status" Report)
         Detail (fh.tc1-reduction-detail (tl (fh.member "defects" Report)))
      (if (= Status "development-pass")
          (fh.row "PASS" [] [["programs_scanned" (fh.member "programs_scanned" Report)] | Detail] [["tc1-reduced" (fh.member "reduced" Report)] | Memo])
          (if (= Status "development-fail")
              (fh.row "FAIL" (append (map (/. D (cn "No generated program shows a failure of " D)) (fh.member "defects_without_a_failure" Report))
                                     (if (= (fh.member "unexpected_disagreements" Report) []) [] ["The model and the undefective implementation disagree on a generated program"])
                                     ["A defect has no original, a shrunk program does not fail, or a shrunk program is larger than its original"])
                      [["unexpected_disagreements" (json.stringify (fh.member "unexpected_disagreements" Report) [])] | Detail] Memo)
              (fh.row "UNKNOWN" ["The reduction harness did not report"] [] Memo)))))

(define fh.tc1-reduced-replay
  Memo ->
    (let File (fh.member-in "tc1-reduced" Memo)
      (if (= File [])
          (fh.row "UNKNOWN" ["Needs this run's reduced failures"] [] Memo)
          (let Report (fh.harness "tc1-replay.shen" [(fh.subdir "tc1-replay") File "sandbox"] 1800)
               Status (fh.member "status" Report)
            (if (= Status "development-pass")
                (fh.row "PASS" [] [["records" (fh.member "records" Report)] ["programs_replayed" (fh.member "programs_replayed" Report)]] Memo)
                (if (= Status "development-fail")
                    (fh.row "FAIL" [(cn "Not replayed: " (fh.join (append (fh.member "defects_without_a_record" Report) (fh.member "defects_not_replayed" Report)) ", "))]
                            [["defects" (json.stringify (fh.member "defects" Report) [])]] Memo)
                    (fh.row "UNKNOWN" ["The replay harness did not report"] [] Memo)))))))
