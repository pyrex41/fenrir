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
\\ Performs are read from the step records, not from events: a perform is the Ready
\\ step at a perform node. Table maps each perform node of the program to "Effect.operation".
(define fh.perform-table
  ["perform" Node Effect Op Arg] -> [[Node (cn Effect (cn "." Op))] | (fh.perform-table Arg)]
  [X | Xs] -> (append (fh.perform-table X) (fh.perform-table Xs))
  _ -> [])

(define fh.performed
  Site Table -> (if (= (fh.field "rule" Site) "Ready") (fh.lookup-name (fh.site-node Site) Table) []))

(define fh.site-node
  [object ["node" Node] | _] -> Node
  _ -> none)

(define fh.lookup-name
  Node [[Node Name] | _] -> [Name]
  Node [_ | Rest] -> (fh.lookup-name Node Rest)
  _ [] -> [])

(define fh.performs
  [] _ -> []
  [S | Steps] Table -> (append (fh.performed (fh.field "site" S) Table) (fh.performs Steps Table)))

(define fh.expect
  "expected_outcome" Want Steps _ _ -> (if (= (fh.canon Want) (fh.canon (fh.model-outcome Steps))) [] "outcome differs from the hand expectation")
  "expected_staging" Want Steps _ _ -> (if (= Want (fh.staging Steps)) [] "step staging differs from the hand derivation")
  "expected_return_frames" Want Steps _ _ -> (if (= Want (str (fh.return-frames Steps 0))) [] "return frame count differs")
  "maximum_depth" Want Steps _ _ -> (if (<= (fh.max-depth Steps 0) (tc0.i64.small Want)) [] "continuation depth exceeds the hand bound")
  "expected_descriptor_count" Want _ Candidate _ -> (if (= Want (str (length (fh.field "descriptors" Candidate)))) [] "closure descriptor count differs")
  "expected_emissions" Want Steps _ _ -> (if (= Want (fh.emissions Steps)) [] "emission order differs")
  "expected_performs" Want Steps _ Program -> (if (= Want (fh.performs Steps (fh.perform-table (fh.field "functions" Program)))) [] "order of performed operations differs")
  Key _ _ _ _ -> (cn "unknown expectation " Key))

(define fh.expectations
  [] _ _ _ -> []
  [[Key Want] | Rest] Steps Candidate Program ->
    (let Reason (fh.expect Key Want Steps Candidate Program)
      (if (= Reason []) (fh.expectations Rest Steps Candidate Program) [Reason | (fh.expectations Rest Steps Candidate Program)])))

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
                         (fh.expectations Expectations (hd (tl Model)) Candidate (fh.field "program" Row)))
      [(fh.field "name" Row) Reasons (length Expectations) (length (hd (tl Model))) (fh.field "program" Row) (hd (tl Model))]))

