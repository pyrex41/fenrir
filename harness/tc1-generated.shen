\\ Fenrir harness, in Shen: compare the Shen model with the JavaScript handler
\\ machine, step for step, over the generated TC1 handler family G
\\ (tools/tc1/handler-generate.mjs): multi-operation effects, nested and sequential
\\ handlers, same-effect forwarding, closures applied under another handler, explicit
\\ resumptions that continue after resume, discontinue, traps and emissions. Classify
\\ the implementation's six injected defects on every program, and state from the
\\ model's traces which handler behaviours the family exercised (tc1-features.shen).
\\ Contract: spec/tc1/EFFECTS.md. Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/tc1-generated.shen LIBDIR ROOT COUNT OUTDIR [sandbox]
\\
\\ OUTDIR must exist and be empty. Launches node on tools/tc1/run-handler-generated.mjs,
\\ which generates and validates the first COUNT programs and runs the implementation
\\ and its defects, writing chunk files. The model runs here and never sees those
\\ traces before comparing.
\\
\\ Pass requires all of:
\\   the batch is the whole family: not truncated, COUNT programs read, equal to the
\\     batch's count and family size, run at this harness's fuel;
\\   every program agrees: model and implementation complete within the fuel, with the
\\     same steps and outcome, and every closure descriptor the implementation reports
\\     was produced by the model;
\\   every feature of fh.features is exercised by at least one agreeing trace;
\\   every one of the six defects is killed on at least one program.
\\ A defective run that crashes is counted as crashed, never as a kill.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*count* (hd (tl (tl (tl (value *argv*))))))
(set fh.*out* (cn (hd (tl (tl (tl (tl (value *argv*)))))) "/"))
(set fh.*sandbox* (= (tl (tl (tl (tl (tl (value *argv*)))))) ["sandbox"]))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))
(load (cn (value fh.*root*) "harness/tc1-features.shen"))

\\ Reference steps the model may take on one generated program.
(define fh.g-fuel -> 1000)

\\ The model's run with the closure descriptors it produced, in one pass:
\\ [Execution Steps Descriptors].
(define fh.g-run
  State _ _ Acc Ds -> ["Completed" (reverse Acc) Ds] where (= (fh.phase State) terminal)
  _ 0 _ Acc Ds -> ["BudgetExhausted" (reverse Acc) Ds]
  State Fuel Epoch Acc Ds ->
    (let T (fh.model-step State)
         Next (hd (tl T))
         Step [object ["after" (fh.after (fh.phase Next))] ["depth" (str (fh.depth Next))] ["epoch" (str Epoch)]
                      ["events" (map (/. E (fh.event E)) (hd (tl (tl T))))] ["site" (fh.site (fh.model-site State))]]
      (fh.g-run Next (- Fuel 1) (+ Epoch 1) [Step | Acc] (fh.note-closure (hd (tl Next)) Ds))))

(define fh.g-first-divergence
  [] [] _ -> "none"
  [S | Ms] [S | Cs] I -> (fh.g-first-divergence Ms Cs (+ I 1))
  _ _ I -> (str I))

\\ [] when the model and the implementation agree on a program, else what differs.
(define fh.g-disagreement
  Name [Execution Steps Descriptors] Candidate ->
    (if (and (= Execution "Completed") (= (fh.field "execution" Candidate) "Completed"))
        (let Ours (fh.canon Steps)
             Theirs (fh.canon (fh.field "steps" Candidate))
          (if (and (= Ours Theirs) (= (fh.canon (fh.model-outcome Steps)) (fh.canon (fh.field "outcome" Candidate)))
                   (fh.all-members? (map (/. D (fh.canon D)) (fh.field "descriptors" Candidate)) Descriptors))
              []
              [object ["program" Name] ["first_divergent_epoch" (fh.g-first-divergence Ours Theirs 0)]
                      ["model_outcome" (fh.model-outcome Steps)] ["implementation_outcome" (fh.field "outcome" Candidate)]]))
        [object ["program" Name] ["model_execution" Execution] ["implementation_execution" (fh.field "execution" Candidate)]]))

(define fh.g-outcome-key
  ["Ok" _] -> "Ok"
  ["Trap" Code] -> (cn "Trap:" Code))

(define fh.g-verdicts
  Runs Steps -> (map (/. Run [(hd Run) (fh.verdict Steps (hd (tl Run)))]) Runs))

(define fh.g-tally-verdicts
  [] Defects -> Defects
  [[Name Verdict] | Verdicts] Defects -> (fh.g-tally-verdicts Verdicts (fh.tally-one Name Verdict Defects)))

(define fh.g-first-kills
  [] _ Firsts -> Firsts
  [[Name killed] | Verdicts] Row Firsts ->
    (fh.g-first-kills Verdicts Row
      (if (fh.tallied? Name Firsts) Firsts (append Firsts [[Name (fh.field "name" Row)]])))
  [_ | Verdicts] Row Firsts -> (fh.g-first-kills Verdicts Row Firsts))

(define fh.g-count-all
  [] Counts -> Counts
  [K | Ks] Counts -> (fh.g-count-all Ks (fh.count-key K Counts)))

\\ Tally is [Agreeing Disagreements Steps Outcomes Defects FirstKills Features].
(define fh.g-compare-rows
  [] Tally -> Tally
  [Row | Rows] [Agree Bad Steps Outcomes Defects Firsts Features] ->
    (let Model (fh.g-run (fh.state (fh.field "program" Row)) (fh.g-fuel) 0 [] [])
         Trace (hd (tl Model))
         Difference (fh.g-disagreement (fh.field "name" Row) Model (fh.field "candidate" Row))
      (fh.g-compare-rows Rows
        (if (= Difference [])
            (let Verdicts (fh.g-verdicts (tl (fh.field "mutants" Row)) Trace)
              [(+ Agree 1) Bad (+ Steps (length Trace))
               (fh.count-key (fh.g-outcome-key (fh.model-outcome Trace)) Outcomes)
               (fh.g-tally-verdicts Verdicts Defects)
               (fh.g-first-kills Verdicts Row Firsts)
               (fh.g-count-all (fh.trace-features (fh.field "program" Row) Trace) Features)])
            [Agree [Difference | Bad] Steps Outcomes Defects Firsts Features]))))

(define fh.g-compare-chunks
  I Chunks Tally -> Tally where (>= I Chunks)
  I Chunks Tally ->
    (let View (buffer.from-string (read-file-as-string (cn (value fh.*out*) (cn "chunk-" (cn (str I) ".jsonl")))))
      (fh.g-compare-chunks (+ I 1) Chunks (fh.g-compare-rows (fh.json-lines View 0 (buffer.length View) []) Tally))))

(define fh.g-counts
  Pairs -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) Pairs)])

\\ Every feature with its count, in fh.features order; and the ones never exercised.
(define fh.g-feature-counts
  [] _ -> []
  [F | Fs] Counts -> [[F (str (fh.g-count F Counts))] | (fh.g-feature-counts Fs Counts)])

(define fh.g-count
  F [] -> 0
  F [[F N] | _] -> N
  F [_ | Rest] -> (fh.g-count F Rest))

(define fh.g-unexercised
  [] _ -> []
  [F | Fs] Counts -> (if (= (fh.g-count F Counts) 0) [F | (fh.g-unexercised Fs Counts)] (fh.g-unexercised Fs Counts)))

(define fh.main
  -> (let R (process.run "node" (fh.node-arguments "tools/tc1/run-handler-generated.mjs" [(value fh.*count*) (value fh.*out*)]
                                                   ["runtime/tc1" "tools/tc1"] (value fh.*out*) (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 600000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true
                  (error "harness: the JavaScript batch did not complete"))
          Header (json.parse (read-file-as-string (cn (value fh.*out*) "family.json")) [[byte-limit 1048576]])
          Tally (fh.g-compare-chunks 0 (tc0.i64.small (fh.field "chunks" Header)) [0 [] 0 [] [] [] []])
          Agree (hd Tally)
          Bad (reverse (nth 2 Tally))
          Defects (nth 5 Tally)
          Programs (+ Agree (length Bad))
          Complete (and (= (fh.field "truncated" Header) false)
                        (= (fh.field "count" Header) (value fh.*count*))
                        (= (fh.field "family_size" Header) (value fh.*count*))
                        (= (fh.field "fuel" Header) (str (fh.g-fuel)))
                        (= (str Programs) (value fh.*count*)))
          Undetected (append (fh.unreported (fh.defect-names) Defects) (fh.undetected Defects))
          Unexercised (fh.g-unexercised (fh.features) (nth 7 Tally))
          Pass (and Complete (empty? Bad) (empty? Undetected) (empty? Unexercised))
          Report [object ["schema" "fenrir.harness.tc1-generated/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["scope" (cn "the first " (cn (value fh.*count*) " programs of the generated TC1 handler family G, NOT exhaustive"))]
                         ["scope_complete" Complete]
                         ["seed_base" (fh.field "seed_base" Header)]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["programs" (str Programs)]
                         ["agreeing" (str Agree)]
                         ["model_steps" (str (nth 3 Tally))]
                         ["outcomes" (fh.g-counts (nth 4 Tally))]
                         ["features" [object | (fh.g-feature-counts (fh.features) (nth 7 Tally))]]
                         ["features_unexercised" Unexercised]
                         ["defects" (fh.tally-json Defects)]
                         ["defects_first_killed_on" [object | (nth 6 Tally)]]
                         ["defects_undetected" Undetected]
                         ["defects_crashing" (fh.crashing Defects)]
                         ["disagreements" (fh.take 10 Bad)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
