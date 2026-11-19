\\ Fenrir harness, in Shen: find a failure in generated TC1 handler programs and
\\ shrink it, once for each of the six injected defects of the JavaScript handler
\\ machine. Contract: spec/tc1/EFFECTS.md. Development evidence only.
\\
\\   shen-jit script harness/tc1-reduce.shen LIBDIR ROOT OUTDIR [sandbox]
\\
\\ OUTDIR must exist and be empty. It receives reduced.jsonl, one line per defect, which
\\ harness/tc1-replay.shen replays in a fresh process.
\\
\\ Discovery. Programs are generated from one fixed seed (harness/tc1-generate.shen), in
\\ batches. The failure of a defect on a program is: the model and the undefective
\\ implementation agree on it (both complete, same steps and outcome), and the defective
\\ implementation completes with a different trace. A defective run that crashes or
\\ reaches the step bound is not a failure. The first program on which a defect fails
\\ is that defect's original.
\\
\\ Shrinking is on the choice list (fh.shrink): each round proposes smaller lists,
\\ regenerates a program from each (so every candidate is valid; the validator is
\\ asked anyway and one rejection stops the run), and keeps one on which the failure
\\ still holds. JavaScript is transport: it runs the implementation, and it ranks a
\\ round's candidates by size, passing on only the smallest few on which its own
\\ undefective and defective runs differ. Whether the failure holds on a candidate is
\\ decided here, against the model, for each one that is kept.
\\
\\ Pass requires: every defect has an original; the failure holds on every shrunk
\\ program, checked once more in a final run; no shrunk program is larger than its
\\ original; and no program showed a disagreement between the model and the
\\ undefective implementation.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*sandbox* (= (tl (tl (tl (tl (value *argv*))))) ["sandbox"]))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))
(load (cn (value fh.*root*) "harness/tc1-generate.shen"))

(define fh.d-fuel -> 1000)
\\ The discovery seed is not one of the family's (tc1-random.shen uses the first twenty).
(define fh.d-seed -> (fh.g-seed 100))
(define fh.d-batch -> 100)
(define fh.d-batches -> 30)
(define fh.d-rounds -> 400)

(set fh.*d-run* 0)

\\ Generate, write, run the implementation in Mode: [Header Rows Generated].
(define fh.d-run
  Generated Mode ->
    (let N (set fh.*d-run* (+ 1 (value fh.*d-run*)))
         File (cn (value fh.*out*) (cn "batch-" (cn (str N) ".jsonl")))
         Written (fh.g-write Generated File)
         Out (cn (value fh.*out*) (cn "batch-" (cn (str N) "/")))
         Header (fh.g-implementation File Out (fh.d-fuel) Mode (value fh.*sandbox*))
         Valid (if (= (fh.field "invalid" Header) "0") true (error "reduction: the validator rejected a generated program in batch ~A" N))
      [Header (fh.g-rows Out Header) Generated]))

\\ ---------- the failure ----------

\\ reference when the model and the undefective implementation agree and complete;
\\ bounded when both reach the step bound; else what differs.
(define fh.d-reference
  Name Model Candidate ->
    (let Difference (fh.disagreement Name Model Candidate)
      (if (= Difference []) reference
          (if (and (= (hd Model) "BudgetExhausted") (= (fh.field "execution" Candidate) "BudgetExhausted")) bounded Difference))))

\\ Whether the failure of Defect holds on a row that carries that defect's run.
(define fh.d-holds?
  Defect Row ->
    (let Model (fh.run (fh.state (fh.field "program" Row)) (fh.d-fuel) 0 [])
      (and (= (fh.d-reference (fh.field "name" Row) Model (fh.field "candidate" Row)) reference)
           (= (fh.verdict (hd (tl Model)) (fh.member Defect (fh.field "mutants" Row))) killed))))

\\ ---------- discovery ----------
\\ State is [Found Scanned Bounded Unexpected]; Found a list of [Defect Name Nodes Choices].

(define fh.d-found?
  _ [] -> false
  Defect [[Defect | _] | _] -> true
  Defect [_ | Found] -> (fh.d-found? Defect Found))

(define fh.d-note
  [] _ _ _ Found -> Found
  [[Defect killed] | Verdicts] Name Nodes Choices Found ->
    (fh.d-note Verdicts Name Nodes Choices
      (if (fh.d-found? Defect Found) Found (append Found [[Defect Name Nodes Choices]])))
  [_ | Verdicts] Name Nodes Choices Found -> (fh.d-note Verdicts Name Nodes Choices Found))

(define fh.d-scan
  [] [] State -> State
  [Row | Rows] [[Name _ Nodes Choices _] | Generated] [Found Scanned Bounded Unexpected] ->
    (let Model (fh.run (fh.state (fh.field "program" Row)) (fh.d-fuel) 0 [])
         Reference (fh.d-reference Name Model (fh.field "candidate" Row))
      (fh.d-scan Rows Generated
        (if (= Reference reference)
            [(fh.d-note (fh.verdicts (tl (fh.field "mutants" Row)) (hd (tl Model))) Name Nodes Choices Found) (+ Scanned 1) Bounded Unexpected]
            (if (= Reference bounded)
                [Found (+ Scanned 1) (+ Bounded 1) Unexpected]
                [Found (+ Scanned 1) Bounded [Reference | Unexpected]])))))

(define fh.d-discover
  Batch X State -> State where (or (>= Batch (fh.d-batches)) (= (length (hd State)) (length (fh.defect-names))))
  Batch X State ->
    (let G (fh.g-programs (cn "tc1-found-" (cn (str Batch) "-")) 0 (fh.d-batch) X [])
         Run (fh.d-run (hd G) "mutants")
      (fh.d-discover (+ Batch 1) (hd (tl G)) (fh.d-scan (hd (tl Run)) (hd G) State))))

\\ ---------- shrinking ----------

(define fh.d-candidates
  [] _ _ -> []
  [Choices | Rest] Prefix I -> [[(cn Prefix (str I)) | (fh.generate (cn Prefix (str I)) Choices)] | (fh.d-candidates Rest Prefix (+ I 1))])

(define fh.d-choices-of
  Name [[Name _ _ Choices _] | _] -> Choices
  Name [_ | Generated] -> (fh.d-choices-of Name Generated))

\\ The choices of the first kept row on which the failure holds, or [].
(define fh.d-first-holding
  _ [] _ -> []
  Defect [Row | Rows] Generated ->
    (if (fh.d-holds? Defect Row)
        (fh.d-choices-of (fh.field "name" Row) Generated)
        (fh.d-first-holding Defect Rows Generated)))

(define fh.d-evaluate
  Defect Candidates ->
    (let Run (fh.d-run (fh.d-candidates Candidates "tc1-candidate-" 0) (cn "shrink:" Defect))
      (fh.d-first-holding Defect (hd (tl Run)) (hd (tl (tl Run))))))

\\ [Defect Name Nodes Choices] -> [Defect Name Nodes Choices Shrunk Rounds Candidates]
(define fh.d-shrink
  [Defect Name Nodes Choices] ->
    (let R (fh.shrink Choices (/. Candidates (fh.d-evaluate Defect Candidates)) (fh.d-rounds))
      [Defect Name Nodes Choices (hd R) (hd (tl R)) (hd (tl (tl R)))]))

\\ ---------- the final check and the record ----------

(define fh.d-strings
  Choices -> (map (/. C (str C)) Choices))

(define fh.d-row-named
  Name [] -> (error "reduction: no final run for ~A" Name)
  Name [Row | Rows] -> (if (= (fh.field "name" Row) Name) Row (fh.d-row-named Name Rows)))

\\ One record per defect, from the final run of the shrunk programs.
(define fh.d-records
  [] _ _ -> []
  [[Defect Name Nodes Choices Shrunk Rounds Tried] | Rest] [[Final _ ShrunkNodes _ _] | Generated] Rows ->
    (let Row (fh.d-row-named Final Rows)
         Model (fh.run (fh.state (fh.field "program" Row)) (fh.d-fuel) 0 [])
         Steps (fh.canon (hd (tl Model)))
         Run (fh.member Defect (fh.field "mutants" Row))
      [[object ["defect" Defect] ["seed" (str (fh.d-seed))] ["step_bound" (str (fh.d-fuel))]
               ["original" [object ["program" Name] ["nodes" (str Nodes)] ["choices" (fh.d-strings Choices)]]]
               ["shrunk" [object ["nodes" (str ShrunkNodes)] ["choices" (fh.d-strings Shrunk)] ["program" (fh.field "program" Row)]]]
               ["rounds" (str Rounds)] ["candidates" (str Tried)]
               ["failure_holds" (fh.d-holds? Defect Row)]
               ["first_divergent_epoch" (if (= (fh.member "execution" Run) "Completed") (fh.first-divergence Steps (fh.canon (fh.field "steps" Run)) 0) "none")]
               ["model_outcome" (if (= (hd Model) "Completed") (fh.model-outcome (hd (tl Model))) "none")]
               ["defective_outcome" (fh.member "outcome" Run)]]
       | (fh.d-records Rest Generated Rows)]))

(define fh.d-finals
  [] -> []
  [[Defect _ _ _ Shrunk | _] | Rest] -> [[(cn "tc1-reduced-" Defect) | (fh.generate (cn "tc1-reduced-" Defect) Shrunk)] | (fh.d-finals Rest)])

(define fh.d-write-records
  [] Stream -> (close Stream)
  [R | Rs] Stream -> (do (pr (cn (json.stringify R [[byte-limit 4194304]]) "c#10;") Stream) (fh.d-write-records Rs Stream)))

(define fh.d-good?
  R -> (and (= (fh.field "failure_holds" R) true)
            (<= (tc0.i64.small (fh.field "nodes" (fh.field "shrunk" R))) (tc0.i64.small (fh.field "nodes" (fh.field "original" R))))))

(define fh.d-all-good?
  [] -> true
  [R | Rs] -> (and (fh.d-good? R) (fh.d-all-good? Rs)))

(define fh.d-summary
  R -> [(fh.field "defect" R)
        [object ["original" (fh.field "program" (fh.field "original" R))]
                ["original_nodes" (fh.field "nodes" (fh.field "original" R))]
                ["shrunk_nodes" (fh.field "nodes" (fh.field "shrunk" R))]
                ["original_choices" (str (length (fh.field "choices" (fh.field "original" R))))]
                ["shrunk_choices" (str (length (fh.field "choices" (fh.field "shrunk" R))))]
                ["rounds" (fh.field "rounds" R)] ["candidates" (fh.field "candidates" R)]
                ["failure_holds" (fh.field "failure_holds" R)]
                ["first_divergent_epoch" (fh.field "first_divergent_epoch" R)]
                ["model_outcome" (fh.field "model_outcome" R)] ["defective_outcome" (fh.field "defective_outcome" R)]]])

(define fh.d-missing
  [] _ -> []
  [D | Ds] Found -> (if (fh.d-found? D Found) (fh.d-missing Ds Found) [D | (fh.d-missing Ds Found)]))

(define fh.main
  -> (let State (fh.d-discover 0 (fh.d-seed) [[] 0 0 []])
          Found (hd State)
          Shrunk (map (/. F (fh.d-shrink F)) Found)
          Finals (fh.d-finals Shrunk)
          Records (if (empty? Finals) [] (fh.d-records Shrunk Finals (hd (tl (fh.d-run Finals "mutants")))))
          File (cn (value fh.*out*) "reduced.jsonl")
          Written (fh.d-write-records Records (open File out))
          Missing (fh.d-missing (fh.defect-names) Found)
          Unexpected (reverse (nth 4 State))
          Pass (and (empty? Missing) (empty? Unexpected) (fh.d-all-good? Records))
          Report [object ["schema" "fenrir.harness.tc1-reduce/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["generator" "harness/tc1-generate.shen"]
                         ["seed" (str (fh.d-seed))]
                         ["step_bound" (str (fh.d-fuel))]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["programs_scanned" (str (nth 2 State))]
                         ["scanned_reaching_the_step_bound" (str (nth 3 State))]
                         ["unexpected_disagreements" (fh.take 10 Unexpected)]
                         ["defects_without_a_failure" Missing]
                         ["defects" [object | (map (/. R (fh.d-summary R)) Records)]]
                         ["reduced" File]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
