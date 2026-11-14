\\ Fenrir harness: checking one case against a person's written expectations and
\\ against the implementation's trace. Load after common.shen.

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
\\ "Effect.operation" for every Perform event, in order.
(define fh.perform-names
  [] -> []
  [E | Es] -> (if (= (fh.field "kind" E) "Perform")
                  [(cn (fh.field "effect" E) (cn "." (fh.field "operation" E))) | (fh.perform-names Es)]
                  (fh.perform-names Es)))

(define fh.performs
  [] -> []
  [S | Steps] -> (append (fh.perform-names (fh.field "events" S)) (fh.performs Steps)))

(define fh.expect
  "expected_outcome" Want Steps _ -> (if (= (fh.canon Want) (fh.canon (fh.model-outcome Steps))) [] "outcome differs from the hand expectation")
  "expected_staging" Want Steps _ -> (if (= Want (fh.staging Steps)) [] "step staging differs from the hand derivation")
  "expected_return_frames" Want Steps _ -> (if (= Want (str (fh.return-frames Steps 0))) [] "return frame count differs")
  "maximum_depth" Want Steps _ -> (if (<= (fh.max-depth Steps 0) (tc0.i64.small Want)) [] "continuation depth exceeds the hand bound")
  "expected_descriptor_count" Want _ Candidate -> (if (= Want (str (length (fh.field "descriptors" Candidate)))) [] "closure descriptor count differs")
  "expected_emissions" Want Steps _ -> (if (= Want (fh.emissions Steps)) [] "emission order differs")
  "expected_performs" Want Steps _ -> (if (= Want (fh.performs Steps)) [] "order of performed operations differs")
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

