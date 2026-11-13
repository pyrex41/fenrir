\\ Fenrir harness, in Shen: the hand cases. For every hand fixture, the Shen
\\ model and the JavaScript implementation must agree step for step, and both
\\ must satisfy the expectations a person wrote down for that case: outcome,
\\ step staging, count of return frames, continuation depth bound, closure
\\ descriptor count and emission order. Development evidence only.
\\
\\   shen-jit script harness/hand-cases.shen LIBDIR ROOT OUTDIR
\\
\\ Launches node on tools/tc0/run-pure-call-hand.mjs for the implementation's
\\ traces. The model runs in this process and does not see them before comparing.
\\ Covers the checks of the Python tool tools/check-tc0-pure-call.py.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ ---------- closure descriptors the model produced ----------

(define fh.captured
  [closure Code Captures []] -> (fh.descriptor [closure Code Captures []])
  V -> (fh.value V))

(define fh.descriptor
  [closure Code Captures []] ->
    [object ["code_id" Code]
            ["captures" (map (/. Pair [(hd Pair) (fh.captured (hd (tl Pair)))]) Captures)]
            ["capture_support" []]])

\\ Every closure value the model yields, in order, as descriptors.
(define fh.descriptors
  State _ Acc -> (reverse Acc) where (= (fh.phase State) terminal)
  _ 0 Acc -> (reverse Acc)
  State Fuel Acc ->
    (let Next (hd (tl (tc0.pc.step State)))
      (fh.descriptors Next (- Fuel 1) (fh.note-closure (hd (tl Next)) Acc))))

(define fh.note-closure
  [value [closure Code Captures []]] Acc -> [(fh.canon (fh.descriptor [closure Code Captures []])) | Acc]
  _ Acc -> Acc)

\\ ---------- facts about a trace ----------

(define fh.model-outcome
  Steps -> (fh.field "outcome" (hd (fh.field "events" (fh.last Steps)))))

(define fh.staging
  Steps -> (map (/. S [(fh.field "after" S) (fh.field "depth" S)]) Steps))

(define fh.return-frames
  [] N -> N
  [S | Steps] N -> (fh.return-frames Steps (if (= (fh.field "rule" (fh.field "site" S)) "ReturnReturn") (+ N 1) N)))

(define fh.max-depth
  [] N -> N
  [S | Steps] N -> (let D (tc0.i64.small (fh.field "depth" S)) (fh.max-depth Steps (if (> D N) D N))))

(define fh.emit-labels
  [] -> []
  [[object ["kind" "Emit"] | Rest] | Events] -> [(fh.assoc "label" Rest) | (fh.emit-labels Events)]
  [_ | Events] -> (fh.emit-labels Events))

(define fh.emissions
  [] -> []
  [S | Steps] -> (append (fh.emit-labels (fh.field "events" S)) (fh.emissions Steps)))

(define fh.all-members?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (fh.all-members? Xs Ys)))

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
      [(fh.field "name" Row) Reasons (length Expectations) (length (hd (tl Model)))]))

(define fh.sum
  [] _ N -> N
  [R | Rs] F N -> (fh.sum Rs F (+ N (F R))))

(define fh.failed
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (fh.failed Rest) [[object ["case" Name] ["reasons" Reasons]] | (fh.failed Rest)]))

(define fh.main
  -> (let File (cn (value fh.*out*) "hand.jsonl")
          R (process.run "node" [(cn (value fh.*root*) "tools/tc0/run-pure-call-hand.mjs") File] (buffer.from-string "") [[timeout 60000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript hand-case run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (fh.check-case Row)) Rows)
          Failures (fh.failed Results)
          Pass (and (empty? Failures) (> (length Rows) 0))
          Report [object ["schema" "fenrir.harness.hand-cases/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["cases" (str (length Rows))]
                         ["expectations_checked" (str (fh.sum Results (/. R (nth 3 R)) 0))]
                         ["model_steps" (str (fh.sum Results (/. R (nth 4 R)) 0))]
                         ["failures" Failures]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
