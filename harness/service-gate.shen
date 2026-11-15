\\ Service gate evaluator, in Shen: the accepted-job contract (application example A1,
\\ spec/service/ACCEPTED_JOB.md) and the handler written in Fenrir (stage A2,
\\ spec/service/HANDLER.md). Not part of slice TC1: the TC1 gate does not read it.
\\ PROPOSED. Its manifest, spec/service/service-requirements.json, is not owner-accepted
\\ and this evaluator is not registered in .pi/fenrir-workflow.json, so its report says
\\ authority UNREGISTERED and qualification UNKNOWN whatever the rows say.
\\
\\   shen-jit script harness/service-gate.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE [NONCE CHECK_ID SOURCE_SHA256 CONFIG_SHA256]
\\
\\ Row evaluation, aggregation and the report are in harness/gate-core.shen, shared with
\\ the TC0-A and TC1 gates: any required FAIL gives FAIL; else any BLOCKED gives BLOCKED;
\\ else any UNKNOWN gives UNKNOWN; else PASS. An evaluator error, a check that does not
\\ report, or a check it does not know is UNKNOWN. A truncated exploration is never a pass.
\\ Each row reads the report of a harness program (harness/service-explore.shen,
\\ harness/service-fenrir.shen, harness/solo5-durable.shen) run as its own process; the
\\ rows decide from the fields those reports carry and add no checks of their own beyond
\\ the scope pins below.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/gate-core.shen"))

\\ ---------- the scope this gate requires ----------
\\ A1's default scope: tenants, keys, digests; budgets submits, deliveries, responses,
\\ crashes; the product-state cap. A report for another scope is UNKNOWN.
(define sg.scope -> ["2" "2" "2" "3" "2" "2" "1" "2000000"])

\\ The number of product states of the A1 model at that scope, and the number of
\\ distinct runtime edges the model and the JavaScript implementation must share.
(define sg.model-states -> "251374")
(define sg.runtime-edges -> "629165")

\\ The mutants each exploration must report, and the one the frontend rejects statically.
(define sg.a1-machines
  -> ["volatile-mailbox" "respond-before-commit" "non-atomic-write" "retry-reapplies" "key-reuse-accepted"
      "cross-tenant-counter" "undeduplicated-delivery" "volatile-status" "failure-not-terminal" "equivalent-control"])
(define sg.a2-machines
  -> ["respond-before-commit" "two-commits" "no-key-check" "wrong-tenant" "conflict-undetected"
      "undeduplicated-delivery" "equivalent-control"])
(define sg.a2-static -> ["commit-inside-atomic"])

\\ The retained counterexamples (spec/service/counterexamples and counterexamples-a2).
(define sg.a1-retained -> "22")
(define sg.a2-retained -> "13")

\\ ---------- helpers ----------

\\ A decoded JSON value as text: a number is read as [number N], a string stays itself.
(define sg.show
  [number N] -> (make-string "~A" N)
  V -> (if (string? V) V (make-string "~A" V)))

(define sg.positive?
  V -> (let S (sg.show V) (and (string? S) (not (= S "[]")) (> (tc0.i64.small S) 0))))

(define sg.scope-matches?
  Report ->
    (let P (fh.member "params" Report)
         B (fh.member "budgets" Report)
      (= (map (/. V (sg.show V))
              [(fh.member "tenants" P) (fh.member "keys" P) (fh.member "digests" P)
               (fh.member "submits" B) (fh.member "deliveries" B) (fh.member "responses" B) (fh.member "crashes" B)
               (fh.member "state_cap" Report)])
         (sg.scope))))

\\ An exploration that finished within its cap: complete and not truncated, both stated.
(define sg.untruncated?
  E -> (and (= (fh.member "complete" E) true) (= (fh.member "truncated" E) false)))

(define sg.subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (sg.subset? Xs Ys)))

(define sg.same-set?
  Xs Ys -> (and (= (length Xs) (length Ys)) (sg.subset? Xs Ys) (sg.subset? Ys Xs)))

(define sg.names
  Rows Key -> (map (/. R (fh.member Key R)) Rows))

(define sg.all?
  _ [] -> true
  F [X | Xs] -> (and (F X) (sg.all? F Xs)))

(define sg.every-untruncated?
  Machines -> (sg.all? (/. M (sg.untruncated? (fh.member "exploration" M))) Machines))

\\ A mutant is caught when the run passed its prediction check and at least one property
\\ failed on it; the equivalent control is unflagged when no property failed.
(define sg.machine-ok?
  M -> (if (= (fh.member "mutant" M) "equivalent-control")
           (and (= (fh.member "pass" M) true) (empty? (fh.member "caught_by" M))
                (empty? (fh.member "violations" (fh.member "exploration" M))))
           (and (= (fh.member "pass" M) true) (cons? (fh.member "caught_by" M))
                (cons? (fh.member "violations" (fh.member "exploration" M))))))

(define sg.machines-failing
  [] -> []
  [M | Ms] -> (if (sg.machine-ok? M) (sg.machines-failing Ms) [(fh.member "mutant" M) | (sg.machines-failing Ms)]))

(define sg.last-line-of
  Text -> (let Lines (fh.lines Text)
            (if (empty? Lines) "" (fh.trim (hd (reverse Lines))))))

\\ ---------- A1: the accepted-job contract ----------

\\ The bounded exploration of the model, its mutants and the equivalent control
\\ (harness/service-explore.shen at the pinned scope, JavaScript side sandboxed).
\\ Truncated or another scope: UNKNOWN. A violation on the model, a mutant caught by
\\ nothing, or a flagged control: FAIL. The report is kept in Memo for the differential row.
(define sg.a1-explore
  Memo ->
    (let Out (fh.subdir "service-explore")
         R (fh.exec (value fh.*jit*)
                    (append ["script" (cn (value fh.*root*) "harness/service-explore.shen") (value fh.*lib*) (value fh.*root*) Out "explore"]
                            (append (sg.scope) ["sandbox"]))
                    1800)
         Report (fh.last-report (hd (tl R)))
         Model (fh.member "model" Report)
         Mutants (fh.member "mutants" Report)
      (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.service-explore/1")))
          (fh.row "UNKNOWN" ["The A1 exploration did not report (or exceeded its time limit)"] [] Memo)
          (if (not (sg.scope-matches? Report))
              (fh.row "UNKNOWN" ["The A1 exploration ran at another scope than the one this gate pins"] [] [["a1-report" Report] | Memo])
              (if (not (and (sg.untruncated? Model) (sg.every-untruncated? Mutants)))
                  (fh.row "UNKNOWN" ["An exploration was truncated or incomplete (state cap reached)"] [] [["a1-report" Report] | Memo])
                  (if (not (and (= (sg.show (fh.member "product_states" Model)) (sg.model-states))
                                (sg.same-set? (sg.names Mutants "mutant") (sg.a1-machines))))
                      (fh.row "UNKNOWN" ["The model's state count or the set of mutants is not the one this gate pins"] [] [["a1-report" Report] | Memo])
                      (if (and (= (fh.member "status" Report) "development-pass")
                               (= (fh.member "all_agree" (fh.member "hand_traces" Report)) true)
                               (empty? (fh.member "violations" Model))
                               (empty? (sg.machines-failing Mutants))
                               (empty? (fh.member "properties_never_failing_on_a_mutant" Report))
                               (empty? (fh.member "checks_never_failing_on_a_mutant" Report)))
                          (fh.row "PASS" [] [["product_states" (sg.show (fh.member "product_states" Model))]
                                             ["edges" (sg.show (fh.member "edges" Model))]
                                             ["mutants_caught" (sg.show (- (length Mutants) 1))]
                                             ["equivalent_control_unflagged" "true"]]
                                  [["a1-report" Report] | Memo])
                          (fh.row "FAIL" ["A1: a hand trace disagrees, the model violates a property, a mutant is caught by no property, the equivalent control is flagged, or a property or check fails on no mutant"]
                                  [["model_violations" (json.stringify (fh.member "violations" Model) [])]
                                   ["machines_failing" (json.stringify (sg.machines-failing Mutants) [])]
                                   ["properties_never_failing_on_a_mutant" (json.stringify (fh.member "properties_never_failing_on_a_mutant" Report) [])]]
                                  [["a1-report" Report] | Memo]))))))))

\\ The JavaScript implementation against the model, edge for edge, from the same run.
(define sg.a1-differential
  Memo ->
    (let Report (fh.member-in "a1-report" Memo)
         D (fh.member "differential" Report)
         Summary (fh.member "implementation_summary" D)
      (if (or (= Report []) (= D []))
          (fh.row "UNKNOWN" ["No A1 exploration report in this run, or it carries no differential"] [] Memo)
          (if (not (and (= (fh.member "implementation_ran" D) true) (= (fh.member "implementation_sandboxed" D) true)
                        (= (fh.member "truncated" Summary) false)))
              (fh.row "UNKNOWN" ["The JavaScript side did not run sandboxed to completion, or its exploration was truncated"] [] Memo)
              (if (not (= (sg.show (fh.member "matched" D)) (sg.runtime-edges)))
                  (if (and (= (fh.member "agree" D) true) (sg.positive? (fh.member "matched" D)))
                      (fh.row "UNKNOWN" [(make-string "The differential covered ~A runtime edges, not the pinned ~A" (sg.show (fh.member "matched" D)) (sg.runtime-edges))] [] Memo)
                      (fh.row "FAIL" ["The JavaScript implementation and the model differ on some runtime edge"]
                              [["matched" (sg.show (fh.member "matched" D))] ["implementation_only" (sg.show (fh.member "implementation_only" D))]
                               ["model_only" (sg.show (fh.member "model_only" D))]] Memo))
                  (if (and (= (fh.member "agree" D) true)
                           (= (sg.show (fh.member "implementation_only" D)) "0") (= (sg.show (fh.member "model_only" D)) "0")
                           (= (sg.show (fh.member "implementation_duplicates" D)) "0")
                           (= (sg.show (fh.member "implementation_edge_lines" D)) (sg.show (fh.member "matched" D)))
                           (= (sg.show (fh.member "model_runtime_edges" D)) (sg.show (fh.member "matched" D))))
                      (fh.row "PASS" [] [["matched_runtime_edges" (sg.show (fh.member "matched" D))] ["schedules" (sg.show (fh.member "schedules" Summary))]] Memo)
                      (fh.row "FAIL" ["The JavaScript implementation and the model differ on some runtime edge, or an edge appears on one side only"]
                              [["matched" (sg.show (fh.member "matched" D))] ["implementation_only" (sg.show (fh.member "implementation_only" D))]
                               ["model_only" (sg.show (fh.member "model_only" D))]
                               ["implementation_duplicates" (sg.show (fh.member "implementation_duplicates" D))]] Memo)))))))

\\ ---------- A2: the handler in Fenrir ----------

(define sg.strip-fen
  ".fen" -> ""
  "" -> ""
  (@s C Cs) -> (cn C (sg.strip-fen Cs)))

(define sg.listing
  Dir Suffix ->
    (let R (fh.exec "ls" [Dir] 60)
      (if (= (hd R) 0)
          (sg.keep-suffix (fh.lines (hd (tl R))) Suffix)
          [])))

(define sg.ends?
  Suffix S -> (sg.ends-loop Suffix S))

(define sg.ends-loop
  Suffix S -> true where (= Suffix S)
  _ "" -> false
  Suffix (@s _ Cs) -> (sg.ends-loop Suffix Cs))

(define sg.keep-suffix
  [] _ -> []
  [L | Ls] Suffix -> (if (sg.ends? Suffix L) [L | (sg.keep-suffix Ls Suffix)] (sg.keep-suffix Ls Suffix)))

\\ Elaborate one handler with the frontend. Result: ok, rejected (the message is kept as
\\ NAME.rejected, as harness/run-service-fenrir.sh does) or failed.
(define sg.elaborate
  Jit Source Artifacts Name ->
    (let R (fh.exec "env" [(cn "FENRIR_SHEN_JIT=" Jit) "sh" (cn (value fh.*root*) "frontend/fenrir.sh") "emit" Source (cn Artifacts (cn "/" (cn Name ".json")))] 900)
      (if (= (hd R) 0)
          ok
          (if (= (hd R) 1)
              (do (write-to-file (cn Artifacts (cn "/" (cn Name ".rejected"))) (hd (tl (tl R)))) rejected)
              failed))))

(define sg.elaborate-all
  _ _ [] -> ok
  Jit Artifacts [[Source Name] | Rest] ->
    (let Outcome (sg.elaborate Jit Source Artifacts Name)
      (if (= Outcome failed) failed (sg.elaborate-all Jit Artifacts Rest))))

(define sg.handler-sources
  -> (let Dir (cn (value fh.*root*) "examples/service/mutants")
          Files (sg.listing Dir ".fen")
       [[(cn (value fh.*root*) "examples/service/accepted-job.fen") "accepted-job"]
        | (map (/. F [(cn Dir (cn "/" F)) (sg.strip-fen F)]) Files)]))

\\ Elaborate the handler and its mutants, then run the refinement check (harness/service-fenrir.shen
\\ at the pinned scope): the A1 model, the handler explored against it step for step, each handler
\\ mutant, and the sandboxed JavaScript TC1-D1 implementation on the handler's distinct runs.
\\ Truncated or another scope: UNKNOWN. The report and the directories are kept in Memo for the
\\ rows that read other parts of it.
(define sg.a2-refinement
  Memo ->
    (let Out (fh.subdir "service-fenrir")
         Artifacts (fh.subdir "service-fenrir/artifacts")
         Jit (fh.trim (hd (tl (fh.exec "dirname" [(value fh.*lib*)] 30))))
         Elaborated (sg.elaborate-all Jit Artifacts (sg.handler-sources))
      (if (= Elaborated failed)
          (fh.row "UNKNOWN" ["The frontend failed (not a rejection) on the handler or one of its mutants"] [] Memo)
          (let R (fh.exec (value fh.*jit*)
                          (append ["script" (cn (value fh.*root*) "harness/service-fenrir.shen") (value fh.*lib*) (value fh.*root*) Out "check" Artifacts]
                                  (append (sg.scope) ["sandbox"]))
                          1800)
               Report (fh.last-report (hd (tl R)))
               Refinement (fh.member "refinement" Report)
               Kept [["a2-report" Report] ["a2-out" Out] ["a2-artifacts" Artifacts] | Memo]
            (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.service-fenrir/1")))
                (fh.row "UNKNOWN" ["The A2 refinement check did not report (or exceeded its time limit)"] [] Memo)
                (if (not (sg.scope-matches? Report))
                    (fh.row "UNKNOWN" ["The A2 check ran at another scope than the one this gate pins"] [] Kept)
                    (if (not (and (sg.untruncated? (fh.member "a1_model" Report)) (sg.untruncated? (fh.member "exploration" Refinement))))
                        (fh.row "UNKNOWN" ["An exploration was truncated or incomplete (state cap reached)"] [] Kept)
                        (if (and (= (fh.member "refines" Refinement) true)
                                 (= (fh.member "same_graph_as_a1_model" Refinement) true)
                                 (= (sg.show (fh.member "steps_differing" Refinement)) "0")
                                 (sg.positive? (fh.member "steps_compared_with_a1_model" Refinement))
                                 (empty? (fh.member "violations" (fh.member "a1_model" Report)))
                                 (empty? (fh.member "violations" (fh.member "exploration" Refinement)))
                                 (= (sg.show (fh.member "product_states" (fh.member "exploration" Refinement))) (sg.model-states)))
                            (fh.row "PASS" [] [["steps_compared_with_a1_model" (sg.show (fh.member "steps_compared_with_a1_model" Refinement))]
                                               ["steps_differing" "0"]
                                               ["product_states" (sg.show (fh.member "product_states" (fh.member "exploration" Refinement)))]
                                               ["distinct_completed_runs" (sg.show (fh.member "distinct_completed_runs" Refinement))]] Kept)
                            (fh.row "FAIL" ["A2: the handler does not refine the A1 model (a step differs, the graph differs, or the model is violated)"]
                                    [["steps_differing" (sg.show (fh.member "steps_differing" Refinement))]
                                     ["differing_samples" (json.stringify (fh.member "differing_samples" Refinement) [])]] Kept)))))))))

\\ The handler's distinct runs on the JavaScript TC1-D1 implementation, sandboxed, against the model.
(define sg.a2-js
  Memo ->
    (let Report (fh.member-in "a2-report" Memo)
         J (fh.member "javascript_sample" Report)
      (if (or (= Report []) (= J []))
          (fh.row "UNKNOWN" ["No A2 report in this run, or it carries no JavaScript sample"] [] Memo)
          (if (not (and (= (fh.member "ran" J) true) (= (fh.member "sandboxed" J) true) (sg.positive? (fh.member "runs" J))))
              (fh.row "UNKNOWN" ["The sandboxed JavaScript implementation did not run on the handler's runs"] [] Memo)
              (if (= (sg.show (fh.member "agreeing_step_for_step" J)) (sg.show (fh.member "runs" J)))
                  (fh.row "PASS" [] [["runs" (sg.show (fh.member "runs" J))] ["model_steps" (sg.show (fh.member "model_steps" J))]] Memo)
                  (fh.row "FAIL" [(make-string "The JavaScript implementation agrees with the model step for step on ~A of ~A runs" (sg.show (fh.member "agreeing_step_for_step" J)) (sg.show (fh.member "runs" J)))] [] Memo))))))

\\ The same runs in the Solo5 guest over control protocol v2, host-controlled
\\ (harness/solo5-durable.shen, quick), as harness/run-service-fenrir.sh does. No Solo5, or a
\\ guest build that fails: BLOCKED. A time limit or no report: UNKNOWN. The guest must
\\ have been driven on every run of the JavaScript sample.
(define sg.a2-solo5
  Memo ->
    (let Report (fh.member-in "a2-report" Memo)
         Out (fh.member-in "a2-out" Memo)
         Sample (if (string? Out) (cn Out "/service-sample.json") "")
         Present (if (string? Out) (hd (fh.exec "test" ["-s" Sample] 30)) 1)
      (if (or (= Report []) (not (= Present 0)))
          (fh.row "UNKNOWN" ["No A2 report or no run sample in this run"] [] Memo)
          (let Built (fh.exec "node" [(cn (value fh.*root*) "tools/solo5/control-durable-build.mjs") "--programs" Sample] 1800)
            (if (= (hd Built) -1)
                (fh.row "UNKNOWN" ["The Solo5 batch build did not complete within its time limit"] [] Memo)
            (if (not (= (hd Built) 0))
                (fh.row "BLOCKED" ["The Solo5 batch or guest could not be built (is Solo5 available at the pinned commit?)"] [] Memo)
                (let Batch (sg.last-line-of (hd (tl Built)))
                     Run (fh.subdir "service-solo5")
                     R (fh.exec (value fh.*jit*) ["script" (cn (value fh.*root*) "harness/solo5-durable.shen") (value fh.*lib*) (value fh.*root*) Batch Run "quick"] 1800)
                     G (fh.last-report (hd (tl R)))
                     Status (fh.member "status" G)
                     Runs (fh.member "runs" (fh.member "javascript_sample" Report))
                  (if (element? (hd R) [126 127])
                      (fh.row "BLOCKED" ["Shen/JIT could not be started for the Solo5 durable harness"] [] Memo)
                      (if (not (element? Status ["development-pass" "development-fail"]))
                          (fh.row "UNKNOWN" ["The Solo5 durable harness did not report (or exceeded its time limit)"] [] Memo)
                          (if (not (and (sg.positive? (fh.member "programs" G)) (= (sg.show (fh.member "programs" G)) (sg.show Runs))))
                              (fh.row "UNKNOWN" [(make-string "The guest was driven on ~A programs, the handler's sample has ~A runs" (sg.show (fh.member "programs" G)) (sg.show Runs))] [] Memo)
                              (if (and (= Status "development-pass") (= (sg.show (fh.member "programs_agreeing_with_model" G)) (sg.show (fh.member "programs" G))))
                                  (fh.row "PASS" [] [["programs" (sg.show (fh.member "programs" G))] ["steps_agreed" (sg.show (fh.member "steps_agreed" G))]
                                                     ["total_boots" (sg.show (fh.member "total_boots" G))]] Memo)
                                  (fh.row "FAIL" ["The Solo5 guest diverges from the model on a handler run, a tape did not replay exactly, or a hostile-host result was unexpected"]
                                          [["failures" (json.stringify (fh.member "failures" G) [])]] Memo))))))))))))

\\ The handler mutants against every A1 property, and the statically rejected one.
(define sg.a2-mutants
  Memo ->
    (let Report (fh.member-in "a2-report" Memo)
         Mutants (fh.member "mutants" Report)
         Static (fh.member "static" Report)
      (if (= Report [])
          (fh.row "UNKNOWN" ["No A2 report in this run"] [] Memo)
          (if (not (sg.every-untruncated? Mutants))
              (fh.row "UNKNOWN" ["A mutant exploration was truncated or incomplete (state cap reached)"] [] Memo)
              (if (not (and (sg.same-set? (sg.names Mutants "mutant") (sg.a2-machines))
                            (sg.same-set? (sg.names Static "mutant") (sg.a2-static))))
                  (fh.row "UNKNOWN" ["The set of handler mutants is not the one this gate pins"] [] Memo)
                  (if (and (empty? (sg.machines-failing Mutants))
                           (sg.all? (/. S (= (fh.member "rejected_statically" S) true)) Static))
                      (fh.row "PASS" [] [["mutants_caught" (sg.show (- (length Mutants) 1))]
                                         ["equivalent_control_unflagged" "true"]
                                         ["rejected_statically" (json.stringify (sg.names Static "mutant") [])]] Memo)
                      (fh.row "FAIL" ["A handler mutant is caught by no property, the equivalent control is flagged, or the statically rejected mutant is no longer rejected"]
                              [["machines_failing" (json.stringify (sg.machines-failing Mutants) [])]
                               ["static" (json.stringify Static [])]] Memo)))))))

\\ ---------- retained counterexamples ----------

\\ Replay each retained counterexample in a fresh process: it must give the status reproduced.
\\ Result: [Failures Unreported], the file names that did not reproduce or gave no report.
(define sg.replay-all
  _ _ [] Failures Unreported -> [(reverse Failures) (reverse Unreported)]
  Make Dir [File | Files] Failures Unreported ->
    (let Report (fh.last-report (hd (tl (fh.exec (value fh.*jit*) (Make (cn Dir (cn "/" File))) 600))))
         Status (fh.member "status" Report)
      (if (= Status "reproduced")
          (sg.replay-all Make Dir Files Failures Unreported)
          (if (= Report [])
              (sg.replay-all Make Dir Files Failures [File | Unreported])
              (sg.replay-all Make Dir Files [File | Failures] Unreported)))))

(define sg.retained-replay
  Memo ->
    (let A1Dir (cn (value fh.*root*) "spec/service/counterexamples")
         A2Dir (cn (value fh.*root*) "spec/service/counterexamples-a2")
         A1Files (sg.listing A1Dir ".json")
         A2Files (sg.listing A2Dir ".json")
         Artifacts (fh.member-in "a2-artifacts" Memo)
      (if (not (and (= (sg.show (length A1Files)) (sg.a1-retained)) (= (sg.show (length A2Files)) (sg.a2-retained))))
          (fh.row "UNKNOWN" [(make-string "The retained counterexamples are ~A (A1) and ~A (A2), not the pinned ~A and ~A"
                                          (sg.show (length A1Files)) (sg.show (length A2Files)) (sg.a1-retained) (sg.a2-retained))] [] Memo)
          (if (not (string? Artifacts))
              (fh.row "UNKNOWN" ["The elaborated handlers of the A2 row are not available in this run"] [] Memo)
              (let Out (fh.subdir "service-replay")
                   A1 (sg.replay-all (/. File ["script" (cn (value fh.*root*) "harness/service-explore.shen") (value fh.*lib*) (value fh.*root*) Out "replay" File])
                                     A1Dir A1Files [] [])
                   A2 (sg.replay-all (/. File ["script" (cn (value fh.*root*) "harness/service-fenrir.shen") (value fh.*lib*) (value fh.*root*) Out "replay" File Artifacts])
                                     A2Dir A2Files [] [])
                (if (and (empty? (hd A1)) (empty? (hd A2)) (empty? (hd (tl A1))) (empty? (hd (tl A2))))
                    (fh.row "PASS" [] [["a1_reproduced" (sg.show (length A1Files))] ["a2_reproduced" (sg.show (length A2Files))]] Memo)
                    (if (and (empty? (hd A1)) (empty? (hd A2)))
                        (fh.row "UNKNOWN" ["Some retained counterexample gave no replay report (or exceeded its time limit)"]
                                [["no_report" (json.stringify (append (hd (tl A1)) (hd (tl A2))) [])]] Memo)
                        (fh.row "FAIL" ["A retained counterexample is not reproduced: the named check no longer first fails at the recorded step"]
                                [["not_reproduced" (json.stringify (append (hd A1) (hd A2)) [])]] Memo))))))))

\\ ---------- optional row: stages A3 and A4 on the host (OTP, SQLite, Solo5) ----------

\\ The campaigns and host mutants the host report must carry (host/service/check.sh quick), and
\\ the number of the history checker's own negative tests (tests/host/histories). Stage A3 gave
\\ 10 campaigns, 8 mutants and 18 negative tests; stage A4 added the upgrade_* campaigns, ten
\\ A4 host mutants (the last an equivalent control) and 13 negative tests.
(define sg.a3-campaigns
  -> ["a2_runs" "busy" "crash_points" "duplicates" "hand_traces" "lost_ack" "random_schedules" "retries" "sqlite_kills" "two_workers"
      "upgrade_cas" "upgrade_crash" "upgrade_load" "upgrade_manifest" "upgrade_stale"])
(define sg.a3-mutants
  -> ["volatile_mailbox" "respond_before_commit" "two_transactions" "busy_as_success" "no_dedup" "no_transaction" "sync_off" "equivalent_control"
      "no_fencing" "migration_drops_pending" "migration_two_transactions" "keys_not_migrated" "receipt_rewritten"
      "cutover_before_migration" "stale_workers" "no_manifest_check" "volatile_upgrade_state" "equivalent_control_a4"])
(define sg.a3-negative-tests -> "31")

(define sg.a3-campaign-clean?
  C -> (let N (sg.show (fh.member "scenarios" C))
         (and (sg.positive? N)
              (= (sg.show (fh.member "histories_accepted" C)) N)
              (= (sg.show (fh.member "histories_rejected" C)) "0")
              (= (sg.show (fh.member "histories_indeterminate" C)) "0")
              (= (sg.show (fh.member "audits_clean" C)) N)
              (= (sg.show (fh.member "scenario_checks_ok" C)) N))))

(define sg.a3-campaigns-clean?
  [] -> true
  [[Name C] | Rest] -> (and (sg.a3-campaign-clean? C) (sg.a3-campaigns-clean? Rest)))

(define sg.a3-campaign-names
  [] -> []
  [[Name C] | Rest] -> [Name | (sg.a3-campaign-names Rest)])

\\ Every host mutant but the documented sync_off is caught by the history checker, the scenario
\\ checks or the SQLite audit; sync_off is documented as undetectable here (kill -9 keeps the page
\\ cache) and is accepted only as that; the equivalent control is unflagged.
(define sg.a3-mutant-ok?
  M -> (let Name (fh.member "mutant" M)
            Caught (or (cons? (fh.member "caught_by_history_checker" M)) (cons? (fh.member "caught_by_scenario_checks" M))
                       (cons? (fh.member "caught_by_sqlite_audit" M)))
         (and (= (fh.member "as_expected" M) true)
              (if (= Name "sync_off")
                  (and (= (fh.member "expected" M) "not_detectable_here") (not Caught))
                  (if (element? Name ["equivalent_control" "equivalent_control_a4"])
                      (and (= (fh.member "expected" M) "not_flagged") (= (sg.show (fh.member "flagged_scenarios" M)) "0") (not Caught))
                      (and (= (fh.member "expected" M) "caught") Caught))))))

(define sg.a3-negative-ok?
  T -> (= (fh.member "as_expected" T) true))

(define sg.a3-passes?
  Report ->
    (let Campaigns (tl (fh.member "campaigns" Report))
         Mutants (fh.member "host_mutants" Report)
         Negatives (fh.member "history_checker_negative_tests" Report)
      (and (= (fh.member "status" Report) "development-pass")
           (= (sg.show (fh.member "failed" (fh.member "unit_tests" Report))) "0")
           (sg.positive? (fh.member "passed" (fh.member "unit_tests" Report)))
           (sg.same-set? (sg.a3-campaign-names Campaigns) (sg.a3-campaigns))
           (sg.a3-campaigns-clean? Campaigns)
           (empty? (fh.member "flagged" (fh.member "normal_stack" Report)))
           (sg.same-set? (sg.names Mutants "mutant") (sg.a3-mutants))
           (sg.all? (/. M (sg.a3-mutant-ok? M)) Mutants)
           (= (sg.show (length Negatives)) (sg.a3-negative-tests))
           (sg.all? (/. T (sg.a3-negative-ok? T)) Negatives))))

\\ host/service/check.sh quick (about 2 to 5 minutes; it builds through nix from the flake's
\\ fenrir-a3-tools). The A3 tools output unavailable, no Solo5 (the script says BLOCKED) or Shen/JIT
\\ not startable: BLOCKED. A time limit or no report: UNKNOWN. A report that does not meet every
\\ condition above: FAIL.
(define sg.a3-host-quick
  Memo ->
    (let Tools (fh.exec "nix" ["build" "--no-link" "--print-out-paths" ".#fenrir-a3-tools"] 1800)
      (if (or (element? (hd Tools) [126 127]) (and (not (= (hd Tools) 0)) (not (= (hd Tools) -1))))
          (fh.row "BLOCKED" ["The A3 tools (nix build .#fenrir-a3-tools: Erlang/OTP, SQLite, gcc, node) are unavailable"] [] Memo)
      (if (= (hd Tools) -1)
          (fh.row "UNKNOWN" ["The A3 tools build did not complete within its time limit"] [] Memo)
          (let R (fh.exec "sh" [(cn (value fh.*root*) "host/service/check.sh") "quick"] 1800)
               Report (fh.last-report (hd (tl R)))
            (if (= (hd R) -1)
                (fh.row "UNKNOWN" ["The A3 check did not complete within its time limit"] [] Memo)
                (if (and (cons? Report) (sg.a3-blocked? (fh.member "reason" Report)))
                    (fh.row "BLOCKED" [(fh.member "reason" Report)] [] Memo)
                    (if (= Report [])
                        (fh.row "UNKNOWN" ["The A3 check did not report"] [] Memo)
                        (if (sg.a3-passes? Report)
                            (fh.row "PASS" [] [["unit_tests_passed" (sg.show (fh.member "passed" (fh.member "unit_tests" Report)))]
                                               ["histories_accepted" (sg.show (fh.member "histories_accepted" (fh.member "normal_stack" Report)))]
                                               ["crashes_injected" (sg.show (fh.member "crashes_injected" (fh.member "normal_stack" Report)))]
                                               ["host_mutants" (sg.show (length (fh.member "host_mutants" Report)))]
                                               ["sync_off" "documented: not detectable by this campaign"]] Memo)
                            (fh.row "FAIL" ["A3: a history was rejected or indeterminate, an audit was not clean, a host mutant other than the documented sync_off went uncaught, the equivalent control was flagged, a negative test of the history checker was not as expected, or a unit test failed"]
                                    [["status" (sg.show (fh.member "status" Report))]
                                     ["reason" (sg.show (fh.member "reason" Report))]
                                     ["unit_tests" (json.stringify (fh.member "unit_tests" Report) [])]
                                     ["flagged" (json.stringify (fh.member "flagged" (fh.member "normal_stack" Report)) [])]] Memo))))))))))

(define sg.a3-blocked?
  Reason -> (and (string? Reason) (fh.starts? "BLOCKED" Reason)))

\\ ---------- optional rows: stage A4, the versioned upgrade (spec/service/UPGRADE.md) ----------
\\ Four optional rows: the A4 model (harness/service-upgrade.shen), the A4 Fenrir refinement
\\ (harness/service-upgrade-fenrir.shen), the same runs in the Solo5 guest, and the retained A4
\\ counterexamples. The host side of A4 (the upgrade_* campaigns, the A4 host mutants and the
\\ /2 history negatives) is part of the a3-host-quick row. Truncation, another scope or another
\\ set of mutants is UNKNOWN, never a pass.

\\ The A4 default scope: tenants, keys, digests; budgets submits, deliveries, responses, crashes,
\\ dispatches, upgrade steps; the product-state cap (harness/run-service-upgrade.sh).
(define sg.a4-scope -> ["2" "1" "2" "2" "2" "1" "1" "1" "4" "1500000"])
(define sg.a4-model-states -> "545360")
(define sg.a4-system-states -> "64676")
(define sg.a4-edges -> "3511584")
(define sg.a4-machines
  -> ["migration-drops-pending" "migration-not-atomic" "cutover-before-migration" "stale-v1-commit" "keys-not-migrated"
      "receipt-rewritten" "deliver-to-v1" "no-manifest-check" "volatile-upgrade-state" "v2-shared-counter"
      "v2-duplicate-delivery-counted" "v2-retry-reapplies" "equivalent-control"])
(define sg.a4-fenrir-machines
  -> ["v2-forgot-count-attempt" "v2-stage-attempt-one" "v2-equivalent-control" "migrate-drops-pending"
      "migrate-rewrites-receipts" "migrate-drops-keys" "migrate-wrong-attempts" "migrate-equivalent-control"])
(define sg.a4-controls -> ["equivalent-control" "migrate-equivalent-control" "v2-equivalent-control"])
\\ A1 checks that fail on no A4 mutant: the A1 mutants cover them (harness/README.md, Service
\\ example A4). Any other property or check that fails on no mutant is a FAIL.
(define sg.a4-uncovered-checks -> ["recovery.obligations" "progress.terminal-stable"])
(define sg.a4-model-retained -> "43")
(define sg.a4-fenrir-retained -> "16")

(define sg.a4-scope-matches?
  Report ->
    (let P (fh.member "params" Report)
         B (fh.member "budgets" Report)
      (= (map (/. V (sg.show V))
              [(fh.member "tenants" P) (fh.member "keys" P) (fh.member "digests" P)
               (fh.member "submits" B) (fh.member "deliveries" B) (fh.member "responses" B) (fh.member "crashes" B)
               (fh.member "dispatches" B) (fh.member "upgrade_steps" B) (fh.member "state_cap" Report)])
         (sg.a4-scope))))

\\ The A4 model's graph at the pinned scope: product states, system states, edges.
(define sg.a4-graph?
  E -> (and (= (sg.show (fh.member "product_states" E)) (sg.a4-model-states))
            (= (sg.show (fh.member "system_states" E)) (sg.a4-system-states))
            (= (sg.show (fh.member "edges" E)) (sg.a4-edges))))

\\ As sg.machine-ok?, with the three equivalent controls of the A4 programs.
(define sg.a4-machine-ok?
  M -> (if (element? (fh.member "mutant" M) (sg.a4-controls))
           (and (= (fh.member "pass" M) true) (empty? (fh.member "caught_by" M))
                (empty? (fh.member "violations" (fh.member "exploration" M))))
           (and (= (fh.member "pass" M) true) (cons? (fh.member "caught_by" M))
                (cons? (fh.member "violations" (fh.member "exploration" M))))))

(define sg.a4-machines-failing
  [] -> []
  [M | Ms] -> (if (sg.a4-machine-ok? M) (sg.a4-machines-failing Ms) [(fh.member "mutant" M) | (sg.a4-machines-failing Ms)]))

\\ The A4 model, its 12 mutants, the equivalent control and the A1 sub-scope agreement
\\ (harness/service-upgrade.shen at the pinned scope, about 7 minutes and 4.3 GB). Truncated,
\\ another scope, another graph or set of mutants, a crash or no report: UNKNOWN. A hand trace
\\ that disagrees, a violation, a mutant caught by nothing, a flagged control, a different A1
\\ sub-scope graph or a property that fails on no mutant: FAIL.
(define sg.a4-model
  Memo ->
    (let Out (fh.subdir "service-upgrade")
         R (fh.exec (value fh.*jit*)
                    (append ["script" (cn (value fh.*root*) "harness/service-upgrade.shen") (value fh.*lib*) (value fh.*root*) Out "explore"]
                            (sg.a4-scope))
                    1800)
         Report (fh.last-report (hd (tl R)))
         Model (fh.member "model" Report)
         Sub (fh.member "a1_subscope" Report)
         Mutants (fh.member "mutants" Report)
      (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.service-upgrade/1")))
          (fh.row "UNKNOWN" ["The A4 model exploration did not report (a timeout, a crash or no report)"] [] Memo)
          (if (not (sg.a4-scope-matches? Report))
              (fh.row "UNKNOWN" ["The A4 exploration ran at another scope than the one this gate pins"] [] Memo)
              (if (not (and (sg.untruncated? Model)
                            (sg.untruncated? (fh.member "a4_model_without_dispatch_or_upgrade" Sub))
                            (sg.untruncated? (fh.member "a1_model" Sub))
                            (sg.every-untruncated? Mutants)))
                  (fh.row "UNKNOWN" ["An A4 exploration was truncated or incomplete (state cap reached)"] [] Memo)
                  (if (not (and (sg.a4-graph? Model) (sg.same-set? (sg.names Mutants "mutant") (sg.a4-machines))))
                      (fh.row "UNKNOWN" ["The A4 model's graph or the set of its mutants is not the one this gate pins"] [] Memo)
                      (if (and (= (fh.member "status" Report) "development-pass")
                               (= (fh.member "all_agree" (fh.member "hand_traces" Report)) true)
                               (cons? (fh.member "traces" (fh.member "hand_traces" Report)))
                               (empty? (fh.member "violations" Model))
                               (= (sg.show (fh.member "disabled_alphabet_steps" Model)) "0")
                               (= (fh.member "agree" Sub) true)
                               (empty? (sg.a4-machines-failing Mutants))
                               (empty? (fh.member "properties_never_failing_on_a_mutant" Report))
                               (sg.subset? (fh.member "checks_never_failing_on_a_mutant" Report) (sg.a4-uncovered-checks)))
                          (fh.row "PASS" [] [["product_states" (sg.show (fh.member "product_states" Model))]
                                             ["system_states" (sg.show (fh.member "system_states" Model))]
                                             ["edges" (sg.show (fh.member "edges" Model))]
                                             ["a1_subscope_agrees" "true"]
                                             ["mutants_caught" (sg.show (- (length Mutants) 1))]
                                             ["equivalent_control_unflagged" "true"]] Memo)
                          (fh.row "FAIL" ["A4 model: a hand trace disagrees, the model violates a property, the A1 sub-scope differs from A1, a mutant is caught by no property, the equivalent control is flagged, or a property fails on no mutant"]
                                  [["status" (sg.show (fh.member "status" Report))]
                                   ["model_violations" (json.stringify (fh.member "violations" Model) [])]
                                   ["machines_failing" (json.stringify (sg.a4-machines-failing Mutants) [])]
                                   ["a1_subscope_agrees" (sg.show (fh.member "agree" Sub))]
                                   ["properties_never_failing_on_a_mutant" (json.stringify (fh.member "properties_never_failing_on_a_mutant" Report) [])]
                                   ["checks_never_failing_on_a_mutant" (json.stringify (fh.member "checks_never_failing_on_a_mutant" Report) [])]] Memo)))))))))

(define sg.a4-sources
  -> (let Dir (cn (value fh.*root*) "examples/service/mutants-a4")
          Files (sg.listing Dir ".fen")
       [[(cn (value fh.*root*) "examples/service/accepted-job.fen") "accepted-job"]
        [(cn (value fh.*root*) "examples/service/accepted-job-v2.fen") "accepted-job-v2"]
        [(cn (value fh.*root*) "examples/service/migrate-v1-v2.fen") "migrate-v1-v2"]
        | (map (/. F [(cn Dir (cn "/" F)) (sg.strip-fen F)]) Files)]))

\\ The Fenrir handlers (v1 unchanged, v2) and the migration program against the A4 model
\\ (harness/service-upgrade-fenrir.shen at the pinned scope, sandboxed JavaScript side), their
\\ mutants and the compare-and-swap check; the report and the elaborated artifacts are kept in
\\ Memo for the Solo5 and replay rows. Truncated, another scope or graph, a JavaScript side that
\\ did not run, or no report: UNKNOWN; a step that differs, a compare-and-swap failure, a
\\ mutant caught by nothing or a flagged control: FAIL.
(define sg.a4-fenrir-refinement
  Memo ->
    (let Out (fh.subdir "service-upgrade-fenrir")
         Artifacts (fh.subdir "service-upgrade-fenrir/artifacts")
         Jit (fh.trim (hd (tl (fh.exec "dirname" [(value fh.*lib*)] 30))))
         Elaborated (sg.elaborate-all Jit Artifacts (sg.a4-sources))
      (if (= Elaborated failed)
          (fh.row "UNKNOWN" ["The frontend failed (not a rejection) on an A4 program or one of its mutants"] [] Memo)
          (let R (fh.exec (value fh.*jit*)
                          (append ["script" (cn (value fh.*root*) "harness/service-upgrade-fenrir.shen") (value fh.*lib*) (value fh.*root*) Out "check" Artifacts]
                                  (append (sg.a4-scope) ["sandbox"]))
                          1800)
               Report (fh.last-report (hd (tl R)))
               Refinement (fh.member "refinement" Report)
               Exploration (fh.member "exploration" Refinement)
               J (fh.member "javascript_sample" Report)
               Mutants (fh.member "mutants" Report)
               Kept [["a4-report" Report] ["a4-out" Out] ["a4-artifacts" Artifacts] | Memo]
            (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.service-upgrade-fenrir/1")))
                (fh.row "UNKNOWN" ["The A4 refinement check did not report (a timeout, a crash or no report)"] [] Memo)
                (if (not (sg.a4-scope-matches? Report))
                    (fh.row "UNKNOWN" ["The A4 refinement check ran at another scope than the one this gate pins"] [] Kept)
                    (if (not (and (sg.untruncated? (fh.member "a4_model" Report)) (sg.untruncated? Exploration) (sg.every-untruncated? Mutants)))
                        (fh.row "UNKNOWN" ["An A4 exploration was truncated or incomplete (state cap reached)"] [] Kept)
                        (if (not (and (sg.a4-graph? (fh.member "a4_model" Report)) (sg.a4-graph? Exploration)
                                      (sg.same-set? (sg.names Mutants "mutant") (sg.a4-fenrir-machines))))
                            (fh.row "UNKNOWN" ["The graph or the set of Fenrir mutants is not the one this gate pins"] [] Kept)
                            (if (not (and (= (fh.member "ran" J) true) (= (fh.member "sandboxed" J) true) (sg.positive? (fh.member "runs" J))))
                                (fh.row "UNKNOWN" ["The sandboxed JavaScript implementation did not run on the A4 runs"] [] Kept)
                                (if (and (= (fh.member "refines" Refinement) true)
                                         (= (fh.member "same_graph_as_a4_model" Refinement) true)
                                         (= (sg.show (fh.member "steps_differing" Refinement)) "0")
                                         (sg.positive? (fh.member "steps_compared_with_a4_model" Refinement))
                                         (sg.positive? (fh.member "compare_and_swap_checks" Refinement))
                                         (= (sg.show (fh.member "compare_and_swap_failures" Refinement)) "0")
                                         (empty? (fh.member "violations" (fh.member "a4_model" Report)))
                                         (empty? (fh.member "violations" Exploration))
                                         (= (sg.show (fh.member "agreeing_step_for_step" J)) (sg.show (fh.member "runs" J)))
                                         (empty? (sg.a4-machines-failing Mutants)))
                                    (fh.row "PASS" [] [["steps_compared_with_a4_model" (sg.show (fh.member "steps_compared_with_a4_model" Refinement))]
                                                       ["steps_differing" "0"]
                                                       ["compare_and_swap_checks" (sg.show (fh.member "compare_and_swap_checks" Refinement))]
                                                       ["distinct_completed_runs" (sg.show (fh.member "distinct_completed_runs" Refinement))]
                                                       ["javascript_runs_agreeing" (sg.show (fh.member "agreeing_step_for_step" J))]
                                                       ["mutants_caught" (sg.show (- (length Mutants) 2))]] Kept)
                                    (fh.row "FAIL" ["A4 Fenrir: the handlers and the migration do not refine the A4 model (a step or the graph differs, the model is violated), a compare-and-swap check failed, the JavaScript implementation disagrees on a run, a mutant is caught by nothing or an equivalent control is flagged"]
                                            [["steps_differing" (sg.show (fh.member "steps_differing" Refinement))]
                                             ["differing_samples" (json.stringify (fh.member "differing_samples" Refinement) [])]
                                             ["compare_and_swap_failures" (sg.show (fh.member "compare_and_swap_failures" Refinement))]
                                             ["javascript_agreeing" (sg.show (fh.member "agreeing_step_for_step" J))]
                                             ["machines_failing" (json.stringify (sg.a4-machines-failing Mutants) [])]] Kept)))))))))))

\\ The same A4 runs in the Solo5 guest over control protocol v2, host-controlled
\\ (harness/solo5-durable.shen, quick), as harness/run-service-upgrade-fenrir.sh does. No Solo5
\\ or a guest build that fails: BLOCKED. A time limit, no report or another number of programs
\\ than the JavaScript sample has runs: UNKNOWN; a divergence: FAIL.
(define sg.a4-solo5
  Memo ->
    (let Report (fh.member-in "a4-report" Memo)
         Out (fh.member-in "a4-out" Memo)
         Sample (if (string? Out) (cn Out "/service-upgrade-sample.json") "")
         Present (if (string? Out) (hd (fh.exec "test" ["-s" Sample] 30)) 1)
      (if (or (= Report []) (not (= Present 0)))
          (fh.row "UNKNOWN" ["No A4 refinement report or no run sample in this run"] [] Memo)
      (if (not (and (sg.a4-scope-matches? Report)
                    (sg.untruncated? (fh.member "exploration" (fh.member "refinement" Report)))
                    (= (fh.member "ran" (fh.member "javascript_sample" Report)) true)))
          (fh.row "UNKNOWN" ["The A4 refinement report of this run is at another scope, truncated, or its JavaScript side did not run; its sample is not evidence"] [] Memo)
          (let Built (fh.exec "node" [(cn (value fh.*root*) "tools/solo5/control-durable-build.mjs") "--programs" Sample] 1800)
            (if (= (hd Built) -1)
                (fh.row "UNKNOWN" ["The Solo5 batch build did not complete within its time limit"] [] Memo)
            (if (not (= (hd Built) 0))
                (fh.row "BLOCKED" ["The Solo5 batch or guest could not be built (is Solo5 available at the pinned commit?)"] [] Memo)
                (let Batch (sg.last-line-of (hd (tl Built)))
                     Run (fh.subdir "service-upgrade-solo5")
                     R (fh.exec (value fh.*jit*) ["script" (cn (value fh.*root*) "harness/solo5-durable.shen") (value fh.*lib*) (value fh.*root*) Batch Run "quick"] 1800)
                     G (fh.last-report (hd (tl R)))
                     Status (fh.member "status" G)
                     Runs (fh.member "runs" (fh.member "javascript_sample" Report))
                  (if (element? (hd R) [126 127])
                      (fh.row "BLOCKED" ["Shen/JIT could not be started for the Solo5 durable harness"] [] Memo)
                      (if (not (element? Status ["development-pass" "development-fail"]))
                          (fh.row "UNKNOWN" ["The Solo5 durable harness did not report (or exceeded its time limit)"] [] Memo)
                          (if (not (and (sg.positive? (fh.member "programs" G)) (= (sg.show (fh.member "programs" G)) (sg.show Runs))))
                              (fh.row "UNKNOWN" [(make-string "The guest was driven on ~A programs, the A4 sample has ~A runs" (sg.show (fh.member "programs" G)) (sg.show Runs))] [] Memo)
                              (if (and (= Status "development-pass") (= (sg.show (fh.member "programs_agreeing_with_model" G)) (sg.show (fh.member "programs" G))))
                                  (fh.row "PASS" [] [["programs" (sg.show (fh.member "programs" G))] ["steps_agreed" (sg.show (fh.member "steps_agreed" G))]
                                                     ["total_boots" (sg.show (fh.member "total_boots" G))]] Memo)
                                  (fh.row "FAIL" ["The Solo5 guest diverges from the model on an A4 run, a tape did not replay exactly, or a hostile-host result was unexpected"]
                                          [["failures" (json.stringify (fh.member "failures" G) [])]] Memo)))))))))))))

\\ Replay each retained A4 counterexample in a fresh process: the 43 of the A4 model
\\ (spec/service/counterexamples-a4, harness/service-upgrade.shen) and the 16 of the Fenrir
\\ machine (spec/service/counterexamples-a4-fenrir, on the elaborated artifacts of the A4
\\ refinement row). Another number of files, no replay report or no artifacts: UNKNOWN; a
\\ counterexample that is not reproduced: FAIL.
(define sg.a4-retained-replay
  Memo ->
    (let ModelDir (cn (value fh.*root*) "spec/service/counterexamples-a4")
         FenrirDir (cn (value fh.*root*) "spec/service/counterexamples-a4-fenrir")
         ModelFiles (sg.listing ModelDir ".json")
         FenrirFiles (sg.listing FenrirDir ".json")
         Artifacts (fh.member-in "a4-artifacts" Memo)
      (if (not (and (= (sg.show (length ModelFiles)) (sg.a4-model-retained)) (= (sg.show (length FenrirFiles)) (sg.a4-fenrir-retained))))
          (fh.row "UNKNOWN" [(make-string "The retained A4 counterexamples are ~A (model) and ~A (Fenrir), not the pinned ~A and ~A"
                                          (sg.show (length ModelFiles)) (sg.show (length FenrirFiles)) (sg.a4-model-retained) (sg.a4-fenrir-retained))] [] Memo)
          (if (not (string? Artifacts))
              (fh.row "UNKNOWN" ["The elaborated A4 programs of the A4 refinement row are not available in this run"] [] Memo)
              (let Out (fh.subdir "service-upgrade-replay")
                   M (sg.replay-all (/. File ["script" (cn (value fh.*root*) "harness/service-upgrade.shen") (value fh.*lib*) (value fh.*root*) Out "replay" File])
                                    ModelDir ModelFiles [] [])
                   F (sg.replay-all (/. File ["script" (cn (value fh.*root*) "harness/service-upgrade-fenrir.shen") (value fh.*lib*) (value fh.*root*) Out "replay" File Artifacts])
                                    FenrirDir FenrirFiles [] [])
                (if (and (empty? (hd M)) (empty? (hd F)) (empty? (hd (tl M))) (empty? (hd (tl F))))
                    (fh.row "PASS" [] [["a4_model_reproduced" (sg.show (length ModelFiles))] ["a4_fenrir_reproduced" (sg.show (length FenrirFiles))]] Memo)
                    (if (and (empty? (hd M)) (empty? (hd F)))
                        (fh.row "UNKNOWN" ["Some retained A4 counterexample gave no replay report (or exceeded its time limit)"]
                                [["no_report" (json.stringify (append (hd (tl M)) (hd (tl F))) [])]] Memo)
                        (fh.row "FAIL" ["A retained A4 counterexample is not reproduced: the named check no longer first fails at the recorded step"]
                                [["not_reproduced" (json.stringify (append (hd M) (hd F)) [])]] Memo))))))))

(define fh.check
  "source-identity" Memo -> (fh.source-identity Memo)
  "toolchain-pinned" Memo -> (fh.toolchain-pinned Memo)
  "service-unit-tests" Memo -> (fh.unit-suite "tests/service/*.test.mjs" Memo)
  "service-a1-explore" Memo -> (sg.a1-explore Memo)
  "service-a1-differential" Memo -> (sg.a1-differential Memo)
  "service-a2-refinement" Memo -> (sg.a2-refinement Memo)
  "service-a2-js" Memo -> (sg.a2-js Memo)
  "service-a2-solo5" Memo -> (sg.a2-solo5 Memo)
  "service-a2-mutants" Memo -> (sg.a2-mutants Memo)
  "service-retained-replay" Memo -> (sg.retained-replay Memo)
  "service-a3-host-quick" Memo -> (sg.a3-host-quick Memo)
  "service-a4-model" Memo -> (sg.a4-model Memo)
  "service-a4-fenrir" Memo -> (sg.a4-fenrir-refinement Memo)
  "service-a4-solo5" Memo -> (sg.a4-solo5 Memo)
  "service-a4-retained-replay" Memo -> (sg.a4-retained-replay Memo)
  Name Memo -> (fh.row "UNKNOWN" [(cn "The evaluator has no check named " Name)] [] Memo))

\\ Registered: the manifest is owner-accepted and the workflow has a service-qualification
\\ check that runs this gate. Neither holds today.
(define fh.registered?
  Manifest -> (fh.registered-as "service-qualification" "harness/run-service-gate.sh" Manifest))

(fh.gate-main "spec/service/service-requirements.json" "service-requirement-manifest/1" "service-gate-run/1" "harness/service-gate.shen" "Service gate (Shen, proposed)")
