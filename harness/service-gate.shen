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
  Name Memo -> (fh.row "UNKNOWN" [(cn "The evaluator has no check named " Name)] [] Memo))

\\ Registered: the manifest is owner-accepted and the workflow has a service-qualification
\\ check that runs this gate. Neither holds today.
(define fh.registered?
  Manifest -> (fh.registered-as "service-qualification" "harness/run-service-gate.sh" Manifest))

(fh.gate-main "spec/service/service-requirements.json" "service-requirement-manifest/1" "service-gate-run/1" "harness/service-gate.shen" "Service gate (Shen, proposed)")
