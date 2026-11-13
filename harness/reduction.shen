\\ Fenrir harness, in Shen: discover a failure in generated programs, shrink it,
\\ and replay it. One implementation defect is switched on; the campaign must
\\ (1) find the first generated program on which the defective implementation
\\ shows the expected kind of discrepancy from the model, (2) reduce that
\\ program by typed proposals, accepting a proposal only when fresh model and
\\ implementation runs show the same kind of discrepancy, and (3) replay the
\\ original and the minimized failure strictly, diverging at a recorded epoch.
\\ Development evidence only.
\\
\\   shen-jit script harness/reduction.shen LIBDIR ROOT OUTDIR FAMILY MUTANT
\\ FAMILY pure-call | pure-data      MUTANT reverse-operands | arm-by-position
\\
\\ JavaScript is used as transport for three things, none of which decide
\\ anything: generating the family, proposing smaller programs (each proposal is
\\ re-validated there and re-observed here), and running the implementation.
\\ Shen version of the campaign in tools/check-tc0-pure-call-reduction.py.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*family* (hd (tl (tl (tl (tl (value *argv*)))))))
(set fh.*mutant* (hd (tl (tl (tl (tl (tl (value *argv*))))))))
(load (cn (value fh.*root*) "harness/common.shen"))

(define fh.expected-discrepancy
  "reverse-operands" -> "reversed-emissions-same-outcome"
  "arm-by-position" -> "wrong-match-arm"
  M -> (error "reduction: unknown mutant ~A" M))

(define fh.predicted-key
  "reverse-operands" -> "reverse_operands_outcome"
  "arm-by-position" -> "arm_by_position_outcome")

\\ Decoded JSON printed by a node tool, or an error.
(define fh.node-json
  Script Args ->
    (let R (process.run "node" [(cn (value fh.*root*) Script) | Args] (buffer.from-string "")
                        [[timeout 30000] [stdout-limit 8388608] [stderr-limit 1048576]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (json.decode (process.output-bytes (hd (tl R))) [[byte-limit 8388608]])
          (error "reduction: ~A did not complete" Script))))

(define fh.optional
  Key [object | Members] -> (fh.optional-in Key Members))

(define fh.optional-in
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.optional-in Key Rest)
  _ [] -> none)

\\ Emission labels of a decoded trace, by field name rather than member position.
(define fh.labels
  [] -> []
  [S | Steps] -> (append (fh.event-labels (fh.field "events" S)) (fh.labels Steps)))

(define fh.event-labels
  [] -> []
  [E | Es] -> (if (= (fh.field "kind" E) "Emit") [(fh.field "label" E) | (fh.event-labels Es)] (fh.event-labels Es)))

\\ ---------- the kind of discrepancy shown ----------

(define fh.first-difference
  [] _ _ -> none
  _ [] _ -> none
  [A | As] [B | Bs] I -> (if (= A B) (fh.first-difference As Bs (+ I 1)) I))

(define fh.rule-at
  Steps I -> (fh.field "rule" (fh.field "site" (nth (+ I 1) Steps))))

(define fh.node-at
  Steps I -> (fh.optional "node" (fh.field "site" (nth (+ I 1) Steps))))

\\ none when the defective run matches the model (a survivor) or shows some other difference.
(define fh.classify
  "reverse-operands" Model Candidate Mutant Expected ->
    (if (and (= (fh.labels (fh.field "steps" Candidate)) ["left" "right"])
             (= (fh.labels (fh.field "steps" Mutant)) ["right" "left"])
             (= (fh.canon (fh.field "outcome" Mutant)) (fh.canon Expected)))
        "reversed-emissions-same-outcome" none)
  "arm-by-position" Model _ Mutant _ ->
    \\ The traces agree through a MatchReturn step, then dispatch different nodes:
    \\ the defective run entered a different arm body.
    (let Steps (fh.canon (fh.field "steps" Mutant))
         K (fh.first-difference Model Steps 0)
      (if (and (not (= K none)) (> K 0)
               (= (fh.rule-at Model (- K 1)) "MatchReturn")
               (= (fh.rule-at Model K) "Dispatch") (= (fh.rule-at Steps K) "Dispatch")
               (not (= (fh.node-at Model K) (fh.node-at Steps K))))
          "wrong-match-arm" none)))

\\ ---------- one fresh observation ----------

\\ Case is [Name Program ExpectedOutcome ExpectedEmissions Predicted], absent parts none.
\\ Result is [Name Program ModelSteps Nodes Discrepancy ModelOutcome].
(define fh.observe
  [Name Program Expected Emissions Predicted] ->
    (let Path (cn (value fh.*out*) (cn Name ".json"))
         Written (write-to-file Path (json.stringify Program [[byte-limit 8388608]]))
         State (fh.state Program)
         Run (fh.run State 200 0 [])
         Model (fh.canon (hd (tl Run)))
         Outcome (fh.model-outcome (hd (tl Run)))
         Candidate (fh.node-json "tools/tc0/run-pure-call.mjs" [Path])
         \\ A second default run is an equivalent control, not a mutation.
         Control (fh.node-json "tools/tc0/run-pure-call.mjs" [Path])
         Mutant (fh.node-json "tools/tc0/run-pure-call.mjs" [Path (cn "--" (value fh.*mutant*))])
         Nodes (json.integer (fh.field "nodes" (fh.field "metric" (fh.node-json "tools/tc0/pure-call-campaign-bridge.mjs" ["reduce" Path]))))
         Want (if (= Expected none) Outcome Expected)
         Agree (if (and (= (hd Run) "Completed") (= (fh.field "execution" Candidate) "Completed")
                        (= Model (fh.canon (fh.field "steps" Candidate)))
                        (= (fh.canon Outcome) (fh.canon Want))
                        (= (fh.canon (fh.field "outcome" Candidate)) (fh.canon Want))
                        (fh.all-members? (map (/. D (fh.canon D)) (fh.field "descriptors" Candidate)) (fh.descriptors State 200 []))
                        (or (= Emissions none) (= Emissions (fh.labels Model))))
                    true (error "semantic: model, implementation and expectations disagree on ~A" Name))
         Same (if (= (fh.canon Candidate) (fh.canon Control)) true (error "semantic: equivalent control disagrees with the fresh baseline on ~A" Name))
         Complete (if (= (fh.field "execution" Mutant) "Completed") true (error "reduction: defective run incomplete on ~A; no semantic kill" Name))
         Bound (if (> Nodes 200) (error "reduction: AST node bound exceeded") true)
         Discrepancy (if (= Model (fh.canon (fh.field "steps" Mutant))) none
                         (fh.classify (value fh.*mutant*) Model Candidate Mutant Want))
         \\ Generated cases may carry an independently derived outcome for the defective run.
         Checked (if (and (not (= Predicted none)) (not (= Discrepancy none))
                          (not (= (fh.canon (fh.field "outcome" Mutant)) (fh.canon Predicted))))
                     (error "semantic: defective outcome differs from the generator-derived prediction on ~A" Name) true)
      [Name Program Model Nodes Discrepancy]))

(define fh.case-of
  C -> [(fh.field "name" C) (fh.field "program" C) (fh.optional "expected_outcome" C)
        (fh.optional "expected_emissions" C) (fh.optional (fh.predicted-key (value fh.*mutant*)) C)])

\\ ---------- discovery ----------

\\ [Index Observation] for the first case showing the expected discrepancy.
(define fh.discover
  [] _ _ -> (error "semantic: no expected discrepancy discovered in the generated prefix")
  [C | Cs] I Expected ->
    (let O (fh.observe (fh.case-of C))
         D (nth 5 O)
      (if (= D none)
          (fh.discover Cs (+ I 1) Expected)
          (if (= D Expected) [I O] (error "semantic: unexpected discrepancy class ~A" D)))))

\\ ---------- reduction ----------

\\ Try proposals in order, largest reduction first. State: [Current History Attempts CapHit].
\\ History entries are [Rule Nodes Accepted], newest first.
(define fh.try-proposals
  [] Current History Attempts Original -> [Current History Attempts false false]
  _ Current History 100 _ -> [Current History 100 false true]
  [P | Ps] Current History Attempts Original ->
    (let Trial (fh.observe [(cn "reduction-" (str Attempts)) (fh.field "program" P) none none none])
         Smaller (if (< (nth 4 Trial) (nth 4 Current)) true (error "reduction: a proposal did not decrease the node count"))
         Accepted (= (nth 5 Trial) (nth 5 Original))
         History2 [[(fh.field "rule" P) (nth 4 Trial) Accepted] | History]
      (if Accepted
          [Trial History2 (+ Attempts 1) true false]
          (fh.try-proposals Ps Current History2 (+ Attempts 1) Original))))

(define fh.reduce
  Current History Attempts Original ->
    (let Proposals (fh.field "proposals" (fh.node-json "tools/tc0/pure-call-campaign-bridge.mjs"
                                                       ["reduce" (cn (value fh.*out*) (cn (hd Current) ".json"))]))
         R (fh.try-proposals Proposals Current History Attempts Original)
      (if (and (nth 4 R) (not (nth 5 R)))
          (fh.reduce (hd R) (nth 2 R) (nth 3 R) Original)
          [(hd R) (nth 2 R) (nth 3 R) (nth 5 R)])))

(define fh.count-accepted
  [] N -> N
  [[_ _ true] | H] N -> (fh.count-accepted H (+ N 1))
  [_ | H] N -> (fh.count-accepted H N))

(define fh.history
  H -> (map (/. E [object ["rule" (hd E)] ["nodes" (str (nth 2 E))] ["accepted" (nth 3 E)]]) (reverse H)))

\\ ---------- replay of the failure ----------

(define fh.diverged?
  R -> (and (= (fh.field "replay" R) "Exact") (= (fh.field "conformance" R) "Diverged") (= (fh.field "execution" R) "StoppedAtDivergence")))

(define fh.campaign
  -> (let Expected (fh.expected-discrepancy (value fh.*mutant*))
          Family (fh.node-json "tools/tc0/pure-call-campaign-bridge.mjs" ["generate" "24" (value fh.*family*)])
          Found (fh.discover (fh.field "cases" Family) 0 Expected)
          Original (hd (tl Found))
          Reduced (fh.reduce Original [] 0 Original)
          Minimized (hd Reduced)
          Smaller (if (< (nth 4 Minimized) (nth 4 Original)) true (error "semantic: no smaller valid failure obtained"))
          Replayed (fh.replay [["original" (nth 2 Original) (nth 3 Original) (value fh.*mutant*)]
                               ["minimized" (nth 2 Minimized) (nth 3 Minimized) (value fh.*mutant*)]]
                              (value fh.*out*) false)
          Exact (if (and (= (length Replayed) 2) (fh.diverged? (hd Replayed)) (fh.diverged? (hd (tl Replayed)))) true
                    (error "semantic: same-defect first-discrepancy replay failed"))
          Kept (do (write-to-file (cn (value fh.*out*) "original.json") (json.stringify (nth 2 Original) [[byte-limit 8388608]]))
                   (write-to-file (cn (value fh.*out*) "minimized.json") (json.stringify (nth 2 Minimized) [[byte-limit 8388608]])))
       [object ["status" "development-pass"]
               ["family" (value fh.*family*)] ["mutant" (value fh.*mutant*)] ["discrepancy" Expected]
               ["discovered_index" (str (hd Found))]
               ["attempts" (str (nth 3 Reduced))]
               ["accepted" (str (fh.count-accepted (nth 2 Reduced) 0))]
               ["reduction_cap_hit" (nth 4 Reduced)]
               ["original_nodes" (str (nth 4 Original))]
               ["minimized_nodes" (str (nth 4 Minimized))]
               ["original_divergence_epoch" (fh.field "divergence_epoch" (hd Replayed))]
               ["minimized_divergence_epoch" (fh.field "divergence_epoch" (hd (tl Replayed)))]
               ["original_program" (cn (value fh.*out*) "original.json")]
               ["minimized_program" (cn (value fh.*out*) "minimized.json")]
               ["history" (fh.history (nth 2 Reduced))]]))

\\ A semantic failure (no discovery, disagreement, failed replay) is a failed campaign.
\\ Anything else is an error of the campaign itself and credits nothing.
(define fh.failure
  Message -> [object ["status" (if (fh.semantic? Message) "development-fail" "error")]
                     ["family" (value fh.*family*)] ["mutant" (value fh.*mutant*)] ["reason" Message]])

(define fh.semantic?
  (@s "semantic: " _) -> true
  _ -> false)

(define fh.main
  -> (let Body (trap-error (fh.campaign) (/. E (fh.failure (error-to-string E))))
          Report [object ["schema" "fenrir.harness.reduction/1"] ["qualification" "UNKNOWN"] ["harness" "Shen"] | (tl Body)]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if (= (fh.field "status" Report) "development-pass") 0 1)))))

(fh.main)
