\\ Fenrir harness, in Shen: discover a handler defect in the generated TC1 family,
\\ shrink the failure by typed proposals, and replay it strictly. The TC1 counterpart
\\ of harness/reduction.shen. One injected defect of the JavaScript handler machine is
\\ switched on; the campaign must
\\ (1) find the first generated program (family G, tools/tc1/handler-generate.mjs, in
\\     index order) on which the defective implementation shows the discrepancy class
\\     expected of that defect, while the model and the defect-free implementation agree;
\\ (2) reduce it by typed proposals (tools/tc1/handler-reduce.mjs: handle-to-body,
\\     perform-to-argument, resume-to-argument, clause-to-binder, ... each one revalidated
\\     there, incl. effect sets and the one-shot rule), accepting a proposal only when
\\     fresh model and implementation observations here show the same discrepancy class;
\\ (3) replay the original and the minimized failure strictly: with the defect the tape
\\     diverges at the epoch the classification found, without it the tape is admitted;
\\ and it retains both, comparing them with the committed retained failures
\\ (fixtures/tc1/handler-retained-failures.json). Development evidence only.
\\
\\   shen-jit script harness/tc1-reduction.shen LIBDIR ROOT OUTDIR DEFECT [sandbox]
\\ DEFECT forgotten_resume | double_resume | outermost_handler | shallow_resume
\\
\\ JavaScript is transport for three things, none of which decide anything: generating
\\ the family, proposing smaller programs, and running the implementation (sandboxed
\\ when asked). A crashed defective run is never a kill: during discovery the program is
\\ passed over and counted, during reduction the proposal is rejected.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*defect* (hd (tl (tl (tl (tl (value *argv*)))))))
(set fh.*sandbox* (element? "sandbox" (tl (tl (tl (tl (tl (value *argv*))))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-features.shen"))
(load (cn (value fh.*root*) "harness/tc1-replay.shen"))

(define fh.r-prefix -> "256")
(define fh.r-fuel -> 1000)
(define fh.r-cap -> 300)
(define fh.r-retained -> "fixtures/tc1/handler-retained-failures.json")

\\ The discrepancy class each defect is expected to show (EFFECTS.md sections 4, 6, 7).
(define fh.expected-class
  "forgotten_resume" -> "clause-return-drops-segment"
  "double_resume" -> "clause-return-duplicates-segment"
  "outermost_handler" -> "selected-other-handler"
  "shallow_resume" -> "resume-drops-handler"
  D -> (error "reduction: no discrepancy class is defined for defect ~A" D))

\\ Decoded JSON printed by a node tool, or an error.
(define fh.node-json
  Script Args ->
    (let R (process.run "node" [(cn (value fh.*root*) Script) | Args] (buffer.from-string "")
                        [[timeout 60000] [stdout-limit 16777216] [stderr-limit 1048576]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (json.decode (process.output-bytes (hd (tl R))) [[byte-limit 16777216]])
          (error "reduction: ~A did not complete" Script))))

\\ ---------- the class of a discrepancy ----------

(define fh.r-first-difference
  [] _ _ -> none
  _ [] _ -> none
  [A | As] [B | Bs] I -> (if (= A B) (fh.r-first-difference As Bs (+ I 1)) I))

(define fh.r-rule
  S -> (fh.field "rule" (fh.field "site" S)))

(define fh.r-depth
  S -> (tc0.i64.small (fh.field "depth" S)))

(define fh.r-resumes
  ["resume" Node _ Arg] -> [Node | (fh.r-resumes Arg)]
  [X | Xs] -> (append (fh.r-resumes X) (fh.r-resumes Xs))
  _ -> [])

\\ [Class Epoch]: the class of the first difference between the model's trace and the
\\ defective run's, and its epoch. Class is none when the traces are equal.
\\   clause-return-drops-segment       both take ClauseReturn at the same node; the defective
\\                                     run ends with fewer frames: the segment was not restored
\\   clause-return-duplicates-segment  the same, with more frames: the segment was restored twice
\\   selected-other-handler            both take Ready at the same perform; the next steps enter
\\                                     the clause bodies of two different handles for its effect
\\   resume-drops-handler              both take Ready at the same resume; the defective run
\\                                     ends with exactly one frame fewer: the segment came back
\\                                     without its handler frame
\\   unclassified                      any other first difference
(define fh.r-classify
  Program Model Mutant ->
    (let K (fh.r-first-difference Model Mutant 0)
      (if (= K none)
          (if (= (length Model) (length Mutant)) [none none] ["unclassified" (str (if (< (length Model) (length Mutant)) (length Model) (length Mutant)))])
          [(fh.r-class-at Program Model Mutant K) (str K)])))

(define fh.r-class-at
  Program Model Mutant K ->
    (let M (nth (+ K 1) Model)
         X (nth (+ K 1) Mutant)
         Node (fh.f-node M)
         Same (and (= (fh.r-rule M) (fh.r-rule X)) (= Node (fh.f-node X)) (not (= Node [])))
         Facts (fh.f-program Program)
      (if (and Same (= (fh.r-rule M) "ClauseReturn") (< (fh.r-depth X) (fh.r-depth M))) "clause-return-drops-segment"
      (if (and Same (= (fh.r-rule M) "ClauseReturn") (> (fh.r-depth X) (fh.r-depth M))) "clause-return-duplicates-segment"
      (if (and Same (= (fh.r-rule M) "Ready") (fh.r-other-handler? (fh.f-find Node (hd Facts)) (nth 4 Facts) Model Mutant K))
          "selected-other-handler"
      (if (and Same (= (fh.r-rule M) "Ready") (element? Node (fh.r-resumes (fh.field "functions" Program)))
               (= (fh.r-depth X) (- (fh.r-depth M) 1)))
          "resume-drops-handler"
          "unclassified"))))))

(define fh.r-other-handler?
  none _ _ _ _ -> false
  Info Roots Model Mutant K ->
    (and (> (length Model) (+ K 1)) (> (length Mutant) (+ K 1))
         (let M (nth (+ K 2) Model)
              X (nth (+ K 2) Mutant)
              A (fh.f-find (fh.f-node M) Roots)
              B (fh.f-find (fh.f-node X) Roots)
           (and (= (fh.r-rule M) "Dispatch") (= (fh.r-rule X) "Dispatch") (not (= A none)) (not (= B none))
                (= (hd (tl A)) (hd Info)) (= (hd (tl B)) (hd Info)) (not (= (hd A) (hd B)))))))

\\ ---------- one fresh observation ----------

\\ [Name Program ModelSteps Nodes Class Epoch]. Class is none for a surviving defect,
\\ crashed for a defective run that did not complete, incomplete for a program the model
\\ does not finish within the fuel (the implementation must then agree on the prefix). A disagreement between the model
\\ and the defect-free implementation, or between that and its equivalent control, is a
\\ semantic failure of the campaign.
(define fh.observe
  Name Program ->
    (let Path (cn (value fh.*out*) (cn Name ".json"))
         Out (cn (value fh.*out*) (cn Name "-observed.json"))
         Written (write-to-file Path (json.stringify Program [[byte-limit 8388608]]))
         State (fh.state Program)
         Run (fh.g-run State (fh.r-fuel) 0 [] [])
         Model (fh.canon (hd (tl Run)))
         R (process.run "node" (fh.node-arguments "tools/tc1/handler-observe.mjs" [Path (value fh.*defect*) Out]
                                                  ["runtime/tc1" "tools/tc1" Path] Out (value fh.*sandbox*))
                        (buffer.from-string "") [[timeout 60000]])
         Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "reduction: the implementation run did not complete on ~A" Name))
         Observed (json.parse (read-file-as-string Out) [[byte-limit 16777216]])
         Candidate (fh.field "candidate" Observed)
         Mutant (fh.field "mutant" Observed)
         \\ A proposal may not terminate (a reduced recursive helper): then both must have
         \\ run out of steps on the same prefix, and the observation shows nothing.
         Agree (if (and (= (hd Run) (fh.field "execution" Candidate))
                        (= Model (fh.canon (fh.field "steps" Candidate)))
                        (or (not (= (hd Run) "Completed"))
                            (= (fh.canon (fh.model-outcome (hd (tl Run)))) (fh.canon (fh.field "outcome" Candidate))))
                        (fh.all-members? (map (/. D (fh.canon D)) (fh.field "descriptors" Candidate)) (nth 3 Run)))
                   true (error "semantic: the model and the defect-free implementation disagree on ~A" Name))
         Same (if (= (fh.canon Candidate) (fh.canon (fh.field "control" Observed))) true
                  (error "semantic: the equivalent control disagrees with the fresh baseline on ~A" Name))
         Nodes (tc0.i64.small (fh.field "nodes" Observed))
         Class (if (not (= (hd Run) "Completed")) [incomplete none]
                   (if (= (fh.field "execution" Mutant) "Completed")
                       (fh.r-classify Program Model (fh.canon (fh.field "steps" Mutant)))
                       [crashed none]))
      [Name Program Model Nodes (hd Class) (hd (tl Class))]))

\\ The model's run with its closure descriptors, as in tc1-generated.shen.
(define fh.g-run
  State _ _ Acc Ds -> ["Completed" (reverse Acc) Ds] where (= (fh.phase State) terminal)
  _ 0 _ Acc Ds -> ["BudgetExhausted" (reverse Acc) Ds]
  State Fuel Epoch Acc Ds ->
    (let T (fh.model-step State)
         Next (hd (tl T))
         Step [object ["after" (fh.after (fh.phase Next))] ["depth" (str (fh.depth Next))] ["epoch" (str Epoch)]
                      ["events" (map (/. E (fh.event E)) (hd (tl (tl T))))] ["site" (fh.site (fh.model-site State))]]
      (fh.g-run Next (- Fuel 1) (+ Epoch 1) [Step | Acc] (fh.note-closure (hd (tl Next)) Ds))))

\\ ---------- discovery ----------

\\ [Index Observation Skipped] for the first case showing the expected class. Skipped
\\ counts the programs passed over before it: [survived crashed other-class].
(define fh.discover
  [] _ _ _ -> (error "semantic: no program of the generated prefix shows the expected discrepancy class")
  [C | Cs] I Expected [S X O] ->
    (let Obs (fh.observe (fh.field "name" C) (fh.field "program" C))
         Class (nth 5 Obs)
      (if (= Class Expected) [I Obs [S X O]]
          (fh.discover Cs (+ I 1) Expected
            (if (= Class none) [(+ S 1) X O] (if (element? Class [crashed incomplete]) [S (+ X 1) O] [S X (+ O 1)]))))))

\\ ---------- reduction ----------

\\ Try proposals in order, largest reduction first. Result [Current History Attempts Accepted CapHit].
\\ History entries are [Rule Nodes Accepted], newest first.
(define fh.try-proposals
  [] Current History Attempts Original -> [Current History Attempts false false]
  _ Current History Attempts _ -> [Current History Attempts false true] where (>= Attempts (fh.r-cap))
  [P | Ps] Current History Attempts Original ->
    (let Trial (fh.observe (cn "reduction-" (str Attempts)) (fh.field "program" P))
         Smaller (if (< (nth 4 Trial) (nth 4 Current)) true (error "reduction: a proposal did not decrease the node count"))
         Accepted (= (nth 5 Trial) (nth 5 Original))
         History2 [[(fh.field "rule" P) (nth 4 Trial) Accepted] | History]
      (if Accepted
          [Trial History2 (+ Attempts 1) true false]
          (fh.try-proposals Ps Current History2 (+ Attempts 1) Original))))

(define fh.reduce
  Current History Attempts Original ->
    (let Proposals (fh.field "proposals" (fh.node-json "tools/tc1/handler-campaign-bridge.mjs"
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

\\ ---------- retained failures ----------

(define fh.retained
  Role [Name Program Model Nodes Class Epoch] ->
    [object ["defect" (value fh.*defect*)] ["role" Role] ["name" Name] ["discrepancy" Class] ["divergence_epoch" Epoch]
            ["nodes" (str Nodes)] ["program" Program]])

\\ Whether the committed retained failures hold exactly this campaign's case for Role.
(define fh.matches-retained?
  Role Program ->
    (let File (cn (value fh.*root*) (fh.r-retained))
         Retained (trap-error (json.parse (read-file-as-string File) [[byte-limit 16777216]]) (/. E []))
      (fh.f-some? (/. C (and (= (fh.member "defect" C) (value fh.*defect*)) (= (fh.member "role" C) Role)
                             (= (fh.canon (fh.member "program" C)) (fh.canon Program))))
                  (if (= Retained []) [] (fh.field "cases" Retained)))))

(define fh.campaign
  -> (let Expected (fh.expected-class (value fh.*defect*))
          Family (fh.node-json "tools/tc1/handler-campaign-bridge.mjs" ["generate" (fh.r-prefix)])
          Found (fh.discover (fh.field "cases" Family) 0 Expected [0 0 0])
          Original (hd (tl Found))
          Reduced (fh.reduce Original [] 0 Original)
          Minimized (hd Reduced)
          Smaller (if (< (nth 4 Minimized) (nth 4 Original)) true (error "semantic: no smaller valid failure obtained"))
          Cases [["original" (nth 2 Original) (nth 3 Original) (value fh.*defect*)] ["minimized" (nth 2 Minimized) (nth 3 Minimized) (value fh.*defect*)]
                 ["original-fixed" (nth 2 Original) (nth 3 Original) null] ["minimized-fixed" (nth 2 Minimized) (nth 3 Minimized) null]]
          Replayed (fh.tc1-replay "failures" Cases (value fh.*out*) (value fh.*sandbox*))
          Exact (if (and (= (length Replayed) 4)
                         (fh.diverged-at? (nth 6 Original) (nth 1 Replayed)) (fh.diverged-at? (nth 6 Minimized) (nth 2 Replayed))
                         (fh.admitted? (nth 3 Replayed)) (fh.admitted? (nth 4 Replayed)))
                    true (error "semantic: strict replay of the original or minimized failure did not diverge at the classified epoch, or a defect-free replay was not admitted"))
          Kept (write-to-file (cn (value fh.*out*) "failure-report.json")
                 (json.stringify [object ["schema" "tc1-handler-reduction/1"] ["qualification" "UNKNOWN"] ["producer" "harness/tc1-reduction.shen"]
                                         ["family" "tc1-handler-generated/1"] ["defect" (value fh.*defect*)]
                                         ["cases" [(fh.retained "original" Original) (fh.retained "minimized" Minimized)]]]
                                 [[byte-limit 16777216]]))
          Skipped (nth 3 Found)
       [object ["status" "development-pass"]
               ["defect" (value fh.*defect*)] ["discrepancy" Expected]
               ["discovered_index" (str (hd Found))] ["discovered_program" (hd Original)]
               ["passed_over" [object ["survived" (str (hd Skipped))] ["crashed" (str (nth 2 Skipped))] ["other_class" (str (nth 3 Skipped))]]]
               ["attempts" (str (nth 3 Reduced))]
               ["accepted" (str (fh.count-accepted (nth 2 Reduced) 0))]
               ["reduction_cap_hit" (nth 4 Reduced)]
               ["original_nodes" (str (nth 4 Original))]
               ["minimized_nodes" (str (nth 4 Minimized))]
               ["original_divergence_epoch" (nth 6 Original)]
               ["minimized_divergence_epoch" (nth 6 Minimized)]
               ["replay" (map (/. R [object ["case" (fh.member "name" R)] ["conformance" (fh.member "conformance" R)]
                                            ["divergence_epoch" (fh.member "divergence_epoch" R)]]) Replayed)]
               ["matches_retained" (and (fh.matches-retained? "original" (nth 2 Original)) (fh.matches-retained? "minimized" (nth 2 Minimized)))]
               ["failure_report" (cn (value fh.*out*) "failure-report.json")]
               ["history" (fh.history (nth 2 Reduced))]]))

\\ A semantic failure (no discovery, disagreement, failed replay) is a failed campaign.
\\ Anything else is an error of the campaign itself and credits nothing.
(define fh.failure
  Message -> [object ["status" (if (fh.semantic? Message) "development-fail" "error")]
                     ["defect" (value fh.*defect*)] ["reason" Message]])

(define fh.semantic?
  (@s "semantic: " _) -> true
  _ -> false)

(define fh.main
  -> (let Body (trap-error (fh.campaign) (/. E (fh.failure (error-to-string E))))
          Report [object ["schema" "fenrir.harness.tc1-reduction/1"] ["qualification" "UNKNOWN"] ["harness" "Shen"]
                         ["implementation_sandboxed" (value fh.*sandbox*)] | (tl Body)]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if (= (fh.field "status" Report) "development-pass") 0 1)))))

(fh.main)
