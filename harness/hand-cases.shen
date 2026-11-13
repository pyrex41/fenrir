\\ Fenrir harness, in Shen: the hand cases. For every hand fixture, the Shen
\\ model and the JavaScript implementation must agree step for step, and both
\\ must satisfy the expectations a person wrote down for that case: outcome,
\\ step staging, count of return frames, continuation depth bound, closure
\\ descriptor count and emission order. Development evidence only.
\\
\\   shen-jit script harness/hand-cases.shen LIBDIR ROOT OUTDIR [sandbox] [pure-call|pure-data]
\\
\\ Launches node on tools/tc0/run-pure-call-hand.mjs for the implementation's
\\ traces. The model runs in this process and does not see them before comparing.
\\ Covers the checks of the Python tool tools/check-tc0-pure-call.py.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
\\ Optional further arguments, in any order:
\\   sandbox                 run the implementation inside tools/tc0/sandbox.mjs
\\   pure-call | pure-data   check that generated family instead of the hand fixtures
(set fh.*options* (tl (tl (tl (tl (value *argv*))))))
(set fh.*sandbox* (element? "sandbox" (value fh.*options*)))
(set fh.*family* (if (element? "pure-call" (value fh.*options*)) ["pure-call"] (if (element? "pure-data" (value fh.*options*)) ["pure-data"] [])))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ ---------- facts about a trace ----------

(define fh.staging
  Steps -> (map (/. S [(fh.field "after" S) (fh.field "depth" S)]) Steps))

(define fh.return-frames
  [] N -> N
  [S | Steps] N -> (fh.return-frames Steps (if (= (fh.field "rule" (fh.field "site" S)) "ReturnReturn") (+ N 1) N)))

(define fh.max-depth
  [] N -> N
  [S | Steps] N -> (let D (tc0.i64.small (fh.field "depth" S)) (fh.max-depth Steps (if (> D N) D N))))

\\ ---------- one expectation at a time ----------

\\ Each returns [] when it holds or a one-line reason.
(define fh.expect
  "expected_outcome" Want Steps _ -> (if (= (fh.canon Want) (fh.canon (fh.model-outcome Steps))) [] "outcome differs from the hand expectation")
  "expected_staging" Want Steps _ -> (if (= Want (fh.staging Steps)) [] "step staging differs from the hand derivation")
  "expected_return_frames" Want Steps _ -> (if (= Want (str (fh.return-frames Steps 0))) [] "return frame count differs")
  "maximum_depth" Want Steps _ -> (if (<= (fh.max-depth Steps 0) (tc0.i64.small Want)) [] "continuation depth exceeds the hand bound")
  "expected_descriptor_count" Want _ Candidate -> (if (= Want (str (length (fh.field "descriptors" Candidate)))) [] "closure descriptor count differs")
  "expected_emissions" Want Steps _ -> (if (= Want (fh.emissions Steps)) [] "emission order differs")
  Key _ _ _ -> (cn "unknown expectation " Key))

(define fh.expectations
  [] _ _ -> []
  [[Key Want] | Rest] Steps Candidate ->
    (let Reason (fh.expect Key Want Steps Candidate)
      (if (= Reason []) (fh.expectations Rest Steps Candidate) [Reason | (fh.expectations Rest Steps Candidate)])))

(define fh.agreement
  [Execution Steps] Candidate Descriptors ->
    (append
      (if (= Execution "Completed") [] ["model did not complete within the reference steps"])
      (if (= (fh.field "execution" Candidate) "Completed") [] ["implementation did not complete"])
      (if (= (fh.canon Steps) (fh.canon (fh.field "steps" Candidate))) [] ["model and implementation traces differ"])
      (if (= (fh.canon (fh.model-outcome Steps)) (fh.canon (fh.field "outcome" Candidate))) [] ["model and implementation outcomes differ"])
      (if (fh.all-members? (map (/. D (fh.canon D)) (fh.field "descriptors" Candidate)) Descriptors) []
          ["an implementation closure descriptor was not produced by the model"])))

(define fh.check-case
  Row ->
    (let State (fh.state (fh.field "program" Row))
         Model (fh.run State 200 0 [])
         Candidate (fh.field "candidate" Row)
         Expectations (tl (fh.field "expectations" Row))
         Reasons (append (fh.agreement Model Candidate (fh.descriptors State 200 []))
                         (fh.expectations Expectations (hd (tl Model)) Candidate))
      [(fh.field "name" Row) Reasons (length Expectations) (length (hd (tl Model))) (fh.field "program" Row) (hd (tl Model))]))

(define fh.sum
  [] _ N -> N
  [R | Rs] F N -> (fh.sum Rs F (+ N (F R))))

(define fh.failed
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (fh.failed Rest) [[object ["case" Name] ["reasons" Reasons]] | (fh.failed Rest)]))

\\ Strict replay: a tape of the implementation recorded against the model's trace
\\ must replay exactly on a fresh machine and be admitted, for every case.
(define fh.not-admitted
  [] -> []
  [R | Rs] -> (if (and (= (fh.field "replay" R) "Exact") (= (fh.field "conformance" R) "Admitted") (= (fh.field "execution" R) "Completed"))
                  (fh.not-admitted Rs)
                  [[object ["case" (fh.field "name" R)] ["reasons" ["strict replay was not admitted"]]] | (fh.not-admitted Rs)]))

(define fh.main
  -> (let File (cn (value fh.*out*) "hand.jsonl")
          R (process.run "node" (fh.node-arguments "tools/tc0/run-pure-call-hand.mjs" [File | (value fh.*family*)] ["fixtures/tc0"] File (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 60000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript hand-case run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (fh.check-case Row)) Rows)
          Agreement (fh.failed Results)
          \\ Replay only what agreed: a disagreeing case has no reference to replay against.
          Replayed (if (empty? Agreement)
                       (fh.replay (map (/. R [(hd R) (nth 5 R) (nth 6 R) null]) Results) (value fh.*out*) (value fh.*sandbox*))
                       [])
          Failures (append Agreement (fh.not-admitted Replayed))
          Pass (and (empty? Failures) (> (length Rows) 0) (= (length Replayed) (length Rows)))
          Report [object ["schema" "fenrir.harness.hand-cases/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["source" (if (empty? (value fh.*family*)) "hand fixtures" (hd (value fh.*family*)))]
                         ["cases" (str (length Rows))]
                         ["expectations_checked" (str (fh.sum Results (/. R (nth 3 R)) 0))]
                         ["model_steps" (str (fh.sum Results (/. R (nth 4 R)) 0))]
                         ["strict_replay_admitted" (str (- (length Replayed) (length (fh.not-admitted Replayed))))]
                         ["failures" Failures]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
