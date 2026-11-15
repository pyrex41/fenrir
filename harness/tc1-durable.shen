\\ Fenrir harness, in Shen: TC1-D1 durable effects (contract spec/tc1/DURABLE.md). For
\\ every hand fixture, the Shen model run under the fixture's host replies and the
\\ sandboxed JavaScript implementation run under the same replies must agree step for
\\ step and in execution, and the model's run must satisfy the handwritten
\\ expectations; each defect injected into the implementation must be detected
\\ (killed) on at least one fixture, a crash never counting as a kill; and every
\\ expectation kind is shown able to fail, by perturbing it and requiring a reason.
\\ Development evidence only.
\\
\\   shen-jit script harness/tc1-durable.shen LIBDIR ROOT OUTDIR [sandbox]

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*sandbox* (element? "sandbox" (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/expectations.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))
(load (cn (value fh.*root*) "harness/tc1-durable-common.shen"))

\\ ---------- facts about a run ----------

(define dt.events
  [] -> []
  [S | Ss] -> (append (fh.field "events" S) (dt.events Ss)))

\\ The observations of DURABLE.md section 6, in order: emits and host requests.
(define dt.observations
  [] -> []
  [E | Es] -> (let K (fh.field "kind" E)
                (cond ((= K "Emit") [["emit" (fh.field "label" E) (fh.field "value" E)] | (dt.observations Es)])
                      ((= K "HostRequest")
                        [["request" (fh.field "seq" E) (cn (fh.field "effect" E) (cn "." (fh.field "operation" E))) (fh.field "value" E)]
                         | (dt.observations Es)])
                      (true (dt.observations Es)))))

\\ Handled performs: a Ready step at a perform node that did not become a host request.
(define dt.handled
  [] _ -> []
  [S | Ss] Table -> (let Site (fh.field "site" S)
                      (if (and (= (fh.member "rule" Site) "Ready") (not (= (fh.field "after" S) "HostWait")))
                          (append (fh.lookup-name (fh.site-node Site) Table) (dt.handled Ss Table))
                          (dt.handled Ss Table))))

\\ ---------- one expectation at a time ----------

\\ [] when it holds, or a one-line reason. Run is [Execution Records].
(define dt.expect
  "expected_execution" Want [E _] _ -> (if (= Want E) [] (cn "execution " E))
  "expected_outcome" Want [E Rs] _ -> (if (= (fh.canon Want) (fh.canon (dh.outcome E Rs))) [] "outcome differs from the hand expectation")
  "expected_observations" Want [_ Rs] _ -> (if (= (fh.canon Want) (fh.canon (dt.observations (dt.events Rs)))) [] "observations differ from the hand expectation")
  "expected_performs" Want [_ Rs] Program -> (if (= Want (dt.handled Rs (fh.perform-table (fh.field "functions" Program)))) [] "handled performs differ")
  "expected_staging" Want [_ Rs] _ -> (if (= Want (fh.staging Rs)) [] "step staging differs from the hand derivation")
  Key _ _ _ -> (cn "unknown expectation " Key))

(define dt.expectations
  [] _ _ -> []
  [[Key Want] | Rest] Run Program ->
    (let R (dt.expect Key Want Run Program)
      (if (= R []) (dt.expectations Rest Run Program) [R | (dt.expectations Rest Run Program)])))

\\ A wrong expectation of the same kind, for the able-to-fail check.
(define dt.perturb
  "expected_execution" "Completed" -> "AwaitingHost"
  "expected_execution" _ -> "Completed"
  "expected_outcome" W -> ["Ok" ["int" "123456789"]]
  "expected_observations" W -> [["request" "9" "Store.put" ["int" "0"]] | W]
  "expected_performs" W -> ["Nothing.none" | W]
  "expected_staging" W -> [["Eval" "99"] | W])

\\ ---------- one case ----------

\\ [Name Reasons Expectations Steps [Execution Records] Kinds-able-to-fail Kinds]
(define dt.check-case
  Row ->
    (let Program (fh.field "program" Row)
         Model (dh.run Program (fh.field "input" Row) (dh.json-replies (fh.field "replies" Row)) 200)
         Run [(hd Model) (nth 2 Model)]
         Candidate (fh.field "candidate" Row)
         Expectations (tl (fh.field "expectations" Row))
         Agreement (append
                     (if (= (hd Model) (fh.field "execution" Candidate)) [] [(cn "executions differ: model " (hd Model))])
                     (if (= (fh.canon (nth 2 Model)) (fh.canon (fh.field "steps" Candidate))) [] ["model and implementation traces differ"]))
         Reasons (append Agreement (dt.expectations Expectations Run Program))
         Failing (dh.keep (/. E (not (= (dt.expect (hd E) (dt.perturb (hd E) (nth 2 E)) Run Program) []))) Expectations)
      [(fh.field "name" Row) Reasons (length Expectations) (length (nth 2 Model)) Run
       (map (/. E (hd E)) Failing) (map (/. E (hd E)) Expectations)]))

\\ killed: an orderly run whose execution or steps differ; survived: the same; crashed: it threw.
(define dt.verdict
  _ Run -> crashed where (= (fh.field "execution" Run) "Crashed")
  [E Records] Run -> (if (and (= E (fh.field "execution" Run)) (= (fh.canon Records) (fh.canon (fh.field "steps" Run)))) survived killed))

(define dt.tally
  [] _ Tally -> Tally
  [[Name Run] | Runs] Model Tally -> (dt.tally Runs Model (fh.tally-one Name (dt.verdict Model Run) Tally)))

(define dt.mutants
  [] [] Tally -> Tally
  [Row | Rows] [[_ Reasons _ _ Run | _] | Results] Tally ->
    (dt.mutants Rows Results (if (= Reasons []) (dt.tally (tl (fh.field "mutants" Row)) Run Tally) Tally)))

(define dt.defect-names
  -> ["double_reply" "late_request_record" "early_request" "host_first" "stale_handler" "unchecked_reply" "seq_reuse"])

(define dt.failed
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (dt.failed Rest) [[object ["case" Name] ["reasons" Reasons]] | (dt.failed Rest)]))

(define dt.sum
  [] _ N -> N
  [R | Rs] F N -> (dt.sum Rs F (+ N (F R))))

(define dt.kinds
  [] Acc -> Acc
  [K | Ks] Acc -> (dt.kinds Ks (if (element? K Acc) Acc [K | Acc])))

(define dt.all-kinds
  [] Acc -> Acc
  [R | Rs] Acc -> (dt.all-kinds Rs (dt.kinds (nth 7 R) Acc)))

(define dt.failing-kinds
  [] Acc -> Acc
  [R | Rs] Acc -> (dt.failing-kinds Rs (dt.kinds (nth 6 R) Acc)))

(define dt.executions
  [] Acc -> Acc
  [R | Rs] Acc -> (dt.executions Rs (fh.count-key (hd (nth 5 R)) Acc)))

(define dt.main
  -> (let File (cn (value fh.*out*) "durable.jsonl")
          R (process.run "node" (fh.node-arguments "tools/tc1/run-durable-cases.mjs" [File] ["runtime/tc1" "tools/tc1" "fixtures/tc1"] File (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 120000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript durable run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (dt.check-case Row)) Rows)
          Failures (dt.failed Results)
          Tally (dt.mutants Rows Results [])
          Undetected (append (fh.unreported (dt.defect-names) Tally) (fh.undetected Tally))
          Kinds (dt.all-kinds Results [])
          CannotFail (dh.keep (/. K (not (element? K (dt.failing-kinds Results [])))) Kinds)
          Pass (and (empty? Failures) (> (length Rows) 0) (empty? Undetected) (empty? CannotFail))
          Report [object ["schema" "fenrir.harness.tc1-durable/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["slice" "TC1-D1 durable effects discharged by the host"]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["cases" (str (length Rows))]
                         ["executions" [object | (map (/. P [(hd P) (str (nth 2 P))]) (dt.executions Results []))]]
                         ["expectations_checked" (str (dt.sum Results (/. X (nth 3 X)) 0))]
                         ["expectation_kinds" Kinds]
                         ["expectation_kinds_unable_to_fail" CannotFail]
                         ["model_steps" (str (dt.sum Results (/. X (nth 4 X)) 0))]
                         ["defects" (fh.tally-json Tally)]
                         ["defects_undetected" Undetected]
                         ["defects_crashing" (fh.crashing Tally)]
                         ["failures" Failures]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(dt.main)
