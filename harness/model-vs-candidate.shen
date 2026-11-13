\\ Fenrir harness, in Shen: compare the Shen model with the JavaScript
\\ implementation, step for step, over every program of the bounded pure-data
\\ grammar, and classify the implementation's three injected defects.
\\ Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/model-vs-candidate.shen LIBDIR ROOT MAX_NODES OUTDIR
\\
\\ This program launches node on tools/tc0/run-pure-data-exhaustive.mjs, which
\\ enumerates the programs, validates them and runs the JavaScript
\\ implementation and its mutants, writing one JSON line per program. The model
\\ runs here, in this process, and never sees those traces before comparing.
\\ It covers the comparison done by the Python checker
\\ tools/check-tc0-pure-data-exhaustive.py, which the registered gate still uses.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*bound* (hd (tl (tl (tl (value *argv*))))))
(set fh.*out* (cn (hd (tl (tl (tl (tl (value *argv*)))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ The outcome the model reports in its final TaskTermination event.
(define fh.model-outcome
  Steps -> (fh.field "outcome" (hd (fh.field "events" (fh.last Steps)))))

\\ A trace record from the JavaScript side is {execution, outcome, steps}.
(define fh.agrees?
  [Execution Steps] Record ->
    (and (= Execution "Completed")
         (= (fh.field "execution" Record) "Completed")
         (= (fh.canon Steps) (fh.canon (fh.field "steps" Record)))
         (= (fh.canon (fh.model-outcome Steps)) (fh.canon (fh.field "outcome" Record)))))

\\ killed: completed with a different trace. survived: same trace. crashed: anything else.
(define fh.verdict
  [_ Steps] Record -> crashed where (not (= (fh.field "execution" Record) "Completed"))
  [_ Steps] Record -> (if (= (fh.canon Steps) (fh.canon (fh.field "steps" Record))) survived killed))

(define fh.bump
  Key [[Key N] | Rest] -> [[Key (+ N 1)] | Rest]
  Key [Pair | Rest] -> [Pair | (fh.bump Key Rest)])

(define fh.outcome-key
  ["Ok" _] -> "Ok"
  ["Trap" Code] -> (cn "Trap:" Code))

\\ Tally is [Agree Disagreements Steps Outcomes Reverse Wrap Arm].
(define fh.compare-rows
  [] Tally -> Tally
  [Row | Rows] [Agree Bad Steps Outcomes Reverse Wrap Arm] ->
    (let Model (fh.run (fh.state (fh.field "program" Row)) 200 0 [])
      (if (fh.agrees? Model (fh.field "candidate" Row))
          (fh.compare-rows Rows
            [(+ Agree 1) Bad (+ Steps (length (hd (tl Model))))
             (fh.bump (fh.outcome-key (fh.model-outcome (hd (tl Model)))) Outcomes)
             (fh.bump (fh.verdict Model (fh.field "reverse_operands" Row)) Reverse)
             (fh.bump (fh.verdict Model (fh.field "wrap_overflow" Row)) Wrap)
             (fh.bump (fh.verdict Model (fh.field "arm_by_position" Row)) Arm)])
          (fh.compare-rows Rows [Agree [(fh.field "name" Row) | Bad] Steps Outcomes Reverse Wrap Arm]))))

(define fh.counts
  Pairs -> [object | (map (/. P [(if (string? (hd P)) (hd P) (str (hd P))) (str (hd (tl P)))]) Pairs)])

(define fh.count-of
  Key [[Key N] | _] -> N
  Key [_ | Rest] -> (fh.count-of Key Rest))

(define fh.main
  -> (let File (cn (value fh.*out*) (cn "candidate-" (cn (value fh.*bound*) ".jsonl")))
          R (process.run "node" [(cn (value fh.*root*) "tools/tc0/run-pure-data-exhaustive.mjs") (value fh.*bound*) File]
                         (buffer.from-string "") [[timeout 600000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true
                  (error "harness: the JavaScript batch did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Lines (fh.json-lines View 0 (buffer.length View) [])
          Header (hd Lines)
          Rows (tl Lines)
          Complete (and (= (fh.field "truncated" Header) false)
                        (= (fh.field "count" Header) (str (length Rows))))
          Zero [[killed 0] [survived 0] [crashed 0]]
          Tally (fh.compare-rows Rows [0 [] 0 [["Ok" 0] ["Trap:Overflow" 0] ["Trap:DivZero" 0] ["Trap:Bounds" 0]] Zero Zero Zero])
          Bad (reverse (hd (tl Tally)))
          Reverse (nth 5 Tally)
          Wrap (nth 6 Tally)
          Arm (nth 7 Tally)
          \\ Every defect must be caught somewhere, and none may crash the implementation.
          Pass (and Complete (empty? Bad)
                    (> (fh.count-of killed Reverse) 0) (> (fh.count-of killed Wrap) 0) (> (fh.count-of killed Arm) 0)
                    (= (fh.count-of crashed Reverse) 0) (= (fh.count-of crashed Wrap) 0) (= (fh.count-of crashed Arm) 0))
          Report [object ["schema" "fenrir.harness.model-vs-candidate/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["scope" (cn "every program of the pure-data grammar with at most " (cn (value fh.*bound*) " nodes"))]
                         ["scope_complete" Complete]
                         ["programs" (str (length Rows))]
                         ["agreeing" (str (hd Tally))]
                         ["model_steps" (str (nth 3 Tally))]
                         ["outcomes" (fh.counts (nth 4 Tally))]
                         ["reverse_operands" (fh.counts Reverse)]
                         ["wrap_overflow" (fh.counts Wrap)]
                         ["arm_by_position" (fh.counts Arm)]
                         ["disagreements" (fh.take 10 Bad)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
