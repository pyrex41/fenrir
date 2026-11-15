\\ Fenrir harness, in Shen: compare the Shen model with the JavaScript handler
\\ machine, step for step, over every program of the bounded TC1 handler grammar H
\\ (tools/tc1/handler-enumerate.mjs), and classify the implementation's six injected
\\ defects on every program. Contract: spec/tc1/EFFECTS.md.
\\ Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/tc1-exhaustive.shen LIBDIR ROOT MAX_NODES OUTDIR [sandbox]
\\
\\ OUTDIR must exist and be empty. This program launches node on
\\ tools/tc1/run-handler-exhaustive.mjs, which enumerates the programs, validates
\\ them and runs the implementation and its defects, writing chunk files of one JSON
\\ line per program. The model runs here, in this process, and never sees those
\\ traces before comparing.
\\
\\ Pass requires all of:
\\   the scope is complete: the batch says it is not truncated and is for this bound,
\\     and the number of programs read equals both the batch's own count and the
\\     number this program derives from the grammar (fh.h-programs, below);
\\   every program agrees: model and implementation both complete, with the same
\\     steps and the same outcome;
\\   every one of the six defects is killed on at least one program.
\\ A defective run that crashes is counted as crashed, never as a kill.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*bound* (hd (tl (tl (tl (value *argv*))))))
(set fh.*out* (cn (hd (tl (tl (tl (tl (value *argv*)))))) "/"))
(set fh.*sandbox* (= (tl (tl (tl (tl (tl (value *argv*)))))) ["sandbox"]))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))

\\ ---------- the size of the scope, derived here from the grammar ----------
\\ The number of expressions of grammar H with exactly N nodes, by the grammar's
\\ productions and not by enumerating: an independent statement of how many programs
\\ a complete batch holds. A and B are 1 when Ask and Bid have a handler in scope,
\\ else 0; V is the number of binders in scope.

\\ The sum of (F I) for I from Lo to Hi.
(define fh.h-sum
  F Lo Hi -> 0 where (> Lo Hi)
  F Lo Hi -> (+ (F Lo) (fh.h-sum F (+ Lo 1) Hi)))

\\ tick always; deep and perform(Ask, .) under an Ask handler; perform(Bid, .) under a Bid handler.
(define fh.h-unary
  A B -> (+ 1 (+ (* 2 A) B)))

\\ Conditions: true, false, lt(E, E).
(define fh.h-conditions
  N A B V -> (+ (if (= N 1) 2 0)
                (fh.h-sum (/. I (* (fh.h-plain I A B V) (fh.h-plain (- (- N 1) I) A B V))) 1 (- N 2))))

\\ if(B, X, X) for a kind of branch whose count by size is Branch.
(define fh.h-ifs
  Branch N A B V ->
    (fh.h-sum (/. C (* (fh.h-conditions C A B V)
                       (fh.h-sum (/. I (* (Branch I) (Branch (- (- (- N 1) C) I)))) 1 (- (- N 2) C))))
              1 (- N 3)))

\\ handle(X, C, body) for X in Ask, Bid: a clause of either form, generated outside
\\ the handler with its binder in scope, and a body of the given kind under X.
(define fh.h-handles
  Body N A B V ->
    (fh.h-sum (/. I (* (+ (fh.h-plain I A B (+ V 1)) (fh.h-resuming I A B (+ V 1)))
                       (+ (Body (- (- N 1) I) 1 B V) (Body (- (- N 1) I) A 1 V))))
              1 (- N 2)))

\\ E: uses no resumption.
(define fh.h-plain
  N _ _ _ -> 0 where (< N 1)
  N A B V ->
    (+ (if (= N 1) (+ 1 V) 0)
       (* (fh.h-unary A B) (fh.h-plain (- N 1) A B V))
       (fh.h-sum (/. I (* (fh.h-plain I A B V) (fh.h-plain (- (- N 1) I) A B V))) 1 (- N 2))
       (fh.h-sum (/. I (* (fh.h-plain I A B V) (fh.h-plain (- (- N 1) I) A B (+ V 1)))) 1 (- N 2))
       (fh.h-ifs (/. I (fh.h-plain I A B V)) N A B V)
       (fh.h-handles (/. I A2 B2 V2 (fh.h-plain I A2 B2 V2)) N A B V)))

\\ R: uses the innermost resumption exactly once on every path.
(define fh.h-resuming
  N _ _ _ -> 0 where (< N 1)
  N A B V ->
    (+ (fh.h-plain (- N 1) A B V)
       (fh.h-plain (- N 2) A B V)
       (* (fh.h-unary A B) (fh.h-resuming (- N 1) A B V))
       (fh.h-sum (/. I (+ (* (fh.h-resuming I A B V) (fh.h-plain (- (- N 1) I) A B V))
                          (* (fh.h-plain I A B V) (fh.h-resuming (- (- N 1) I) A B V)))) 1 (- N 2))
       (fh.h-sum (/. I (+ (* (fh.h-resuming I A B V) (fh.h-plain (- (- N 1) I) A B (+ V 1)))
                          (* (fh.h-plain I A B V) (fh.h-resuming (- (- N 1) I) A B (+ V 1))))) 1 (- N 2))
       (fh.h-ifs (/. I (fh.h-resuming I A B V)) N A B V)
       (fh.h-handles (/. I A2 B2 V2 (fh.h-resuming I A2 B2 V2)) N A B V)))

\\ Programs of at most Bound nodes: main's body is an E with no handler and no binder in scope.
(define fh.h-programs
  Bound -> (fh.h-sum (/. N (fh.h-plain N 0 0 0)) 1 Bound))

\\ ---------- comparison ----------

(define fh.first-divergence
  [] [] _ -> "none"
  [S | Ms] [S | Cs] I -> (fh.first-divergence Ms Cs (+ I 1))
  _ _ I -> (str I))

\\ [] when the model and the implementation agree on a program, else what differs.
(define fh.disagreement
  Name [Execution Steps] Candidate ->
    (if (and (= Execution "Completed") (= (fh.field "execution" Candidate) "Completed"))
        (let Ours (fh.canon Steps)
             Theirs (fh.canon (fh.field "steps" Candidate))
          (if (and (= Ours Theirs) (= (fh.canon (fh.model-outcome Steps)) (fh.canon (fh.field "outcome" Candidate))))
              []
              [object ["program" Name] ["first_divergent_epoch" (fh.first-divergence Ours Theirs 0)]
                      ["model_outcome" (fh.model-outcome Steps)] ["implementation_outcome" (fh.field "outcome" Candidate)]]))
        [object ["program" Name] ["model_execution" Execution] ["implementation_execution" (fh.field "execution" Candidate)]]))

(define fh.outcome-key
  ["Ok" _] -> "Ok"
  ["Trap" Code] -> (cn "Trap:" Code))

\\ One [Name Verdict] per defective run of a program.
(define fh.verdicts
  Runs Steps -> (map (/. Run [(hd Run) (fh.verdict Steps (hd (tl Run)))]) Runs))

(define fh.tally-verdicts
  [] Defects -> Defects
  [[Name Verdict] | Verdicts] Defects -> (fh.tally-verdicts Verdicts (fh.tally-one Name Verdict Defects)))

\\ The first program that kills each defect. Programs come in order of size, so it is
\\ one of the smallest: a reproduction that needs no reduction.
(define fh.first-kills
  [] _ Firsts -> Firsts
  [[Name killed] | Verdicts] Row Firsts ->
    (fh.first-kills Verdicts Row
      (if (fh.tallied? Name Firsts) Firsts
          (append Firsts [[Name [object ["program" (fh.field "name" Row)] ["nodes" (fh.field "nodes" Row)]]]])))
  [_ | Verdicts] Row Firsts -> (fh.first-kills Verdicts Row Firsts))

\\ Tally is [Agreeing Disagreements Steps Outcomes Defects FirstKills]. Only a program on
\\ which the model and the implementation agree gives a reference for the defects.
(define fh.compare-rows
  [] Tally -> Tally
  [Row | Rows] [Agree Bad Steps Outcomes Defects Firsts] ->
    (let Model (fh.run (fh.state (fh.field "program" Row)) 200 0 [])
         Difference (fh.disagreement (fh.field "name" Row) Model (fh.field "candidate" Row))
      (fh.compare-rows Rows
        (if (= Difference [])
            (let Verdicts (fh.verdicts (tl (fh.field "mutants" Row)) (hd (tl Model)))
              [(+ Agree 1) Bad (+ Steps (length (hd (tl Model))))
               (fh.count-key (fh.outcome-key (fh.model-outcome (hd (tl Model)))) Outcomes)
               (fh.tally-verdicts Verdicts Defects)
               (fh.first-kills Verdicts Row Firsts)])
            [Agree [Difference | Bad] Steps Outcomes Defects Firsts]))))

\\ One chunk file at a time, so only one chunk of traces is held.
(define fh.compare-chunks
  I Chunks Tally -> Tally where (>= I Chunks)
  I Chunks Tally ->
    (let View (buffer.from-string (read-file-as-string (cn (value fh.*out*) (cn "chunk-" (cn (str I) ".jsonl")))))
      (fh.compare-chunks (+ I 1) Chunks (fh.compare-rows (fh.json-lines View 0 (buffer.length View) []) Tally))))

(define fh.counts
  Pairs -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) Pairs)])

(define fh.main
  -> (let Bound (tc0.i64.small (value fh.*bound*))
          R (process.run "node" (fh.node-arguments "tools/tc1/run-handler-exhaustive.mjs" [(value fh.*bound*) (value fh.*out*)]
                                                   ["runtime/tc1" "tools/tc1"] (value fh.*out*) (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 600000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true
                  (error "harness: the JavaScript batch did not complete"))
          Header (json.parse (read-file-as-string (cn (value fh.*out*) "family.json")) [[byte-limit 1048576]])
          Tally (fh.compare-chunks 0 (tc0.i64.small (fh.field "chunks" Header)) [0 [] 0 [] [] []])
          Agree (hd Tally)
          Bad (reverse (nth 2 Tally))
          Defects (nth 5 Tally)
          Programs (+ Agree (length Bad))
          Expected (fh.h-programs Bound)
          Complete (and (= (fh.field "truncated" Header) false)
                        (= (fh.field "max_nodes" Header) (value fh.*bound*))
                        (= (fh.field "count" Header) (str Programs))
                        (= Programs Expected))
          Undetected (append (fh.unreported (fh.defect-names) Defects) (fh.undetected Defects))
          Pass (and Complete (empty? Bad) (empty? Undetected))
          Report [object ["schema" "fenrir.harness.tc1-exhaustive/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["scope" (cn "every program of the TC1 handler grammar H with at most " (cn (value fh.*bound*) " nodes"))]
                         ["scope_complete" Complete]
                         ["programs_expected" (str Expected)]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["programs" (str Programs)]
                         ["agreeing" (str Agree)]
                         ["model_steps" (str (nth 3 Tally))]
                         ["outcomes" (fh.counts (nth 4 Tally))]
                         ["defects" (fh.tally-json Defects)]
                         ["defects_first_killed_on" [object | (nth 6 Tally)]]
                         ["defects_undetected" Undetected]
                         ["defects_crashing" (fh.crashing Defects)]
                         ["disagreements" (fh.take 10 Bad)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
