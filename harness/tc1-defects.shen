\\ Fenrir harness: classifying the injected defects of the JavaScript handler machine
\\ against a model trace. Load after common.shen. Shared by tc1-handlers.shen (hand
\\ fixtures), tc1-exhaustive.shen (the exhaustive-small family) and the generated family
\\ (tc1-random.shen, tc1-reduce.shen, tc1-replay.shen). The second half compares a model
\\ run with an implementation run.

\\ The six defects of runtime/tc1/handler-machine.mjs, by report key. The harness holds
\\ this list itself, so a batch that leaves one out cannot pass.
(define fh.defect-names
  -> ["forgotten_resume" "double_resume" "outermost_handler" "dynamic_clause_environment" "resume_returns_argument" "shallow_resume"])

\\ killed: completed with a different trace. survived: same trace. crashed: anything else.
(define fh.verdict
  Steps Run -> crashed where (not (= (fh.field "execution" Run) "Completed"))
  Steps Run -> (if (= (fh.canon Steps) (fh.canon (fh.field "steps" Run))) survived killed))

(define fh.bump
  Key [[Key N] | Rest] -> [[Key (+ N 1)] | Rest]
  Key [Pair | Rest] -> [Pair | (fh.bump Key Rest)])

\\ Tally is a list of [MutantName [[killed N] [survived N] [crashed N]]].
(define fh.tally-mutants
  [] _ Tally -> Tally
  [[Name Run] | Runs] Steps Tally -> (fh.tally-mutants Runs Steps (fh.tally-one Name (fh.verdict Steps Run) Tally)))

(define fh.tally-one
  Name Verdict [] -> [[Name (fh.bump Verdict [[killed 0] [survived 0] [crashed 0]])]]
  Name Verdict [[Name Counts] | Rest] -> [[Name (fh.bump Verdict Counts)] | Rest]
  Name Verdict [Other | Rest] -> [Other | (fh.tally-one Name Verdict Rest)])

(define fh.count-of
  Key [[Key N] | _] -> N
  Key [_ | Rest] -> (fh.count-of Key Rest))

(define fh.undetected
  [] -> []
  [[Name Counts] | Rest] -> (if (> (fh.count-of killed Counts) 0) (fh.undetected Rest) [Name | (fh.undetected Rest)]))

(define fh.crashing
  [] -> []
  [[Name Counts] | Rest] -> (if (= (fh.count-of crashed Counts) 0) (fh.crashing Rest) [Name | (fh.crashing Rest)]))

(define fh.tally-json
  Tally -> [object | (map (/. T [(hd T) [object | (map (/. P [(str (hd P)) (str (hd (tl P)))]) (hd (tl T)))]]) Tally)])

\\ The names with no entry in Tally: defects no run was reported for.
(define fh.unreported
  [] _ -> []
  [Name | Names] Tally -> (if (fh.tallied? Name Tally) (fh.unreported Names Tally) [Name | (fh.unreported Names Tally)]))

(define fh.tallied?
  _ [] -> false
  Name [[Name _] | _] -> true
  Name [_ | Rest] -> (fh.tallied? Name Rest))

\\ ---------- model against implementation ----------

(define fh.first-divergence
  [] [] _ -> "none"
  [S | Ms] [S | Cs] I -> (fh.first-divergence Ms Cs (+ I 1))
  _ _ I -> (str I))

\\ [] when the model and the implementation agree on a program, else what differs.
\\ Both must complete, with the same steps and the same outcome.
(define fh.disagreement
  Name Model Candidate -> (fh.disagreement-within Name Model Candidate false))

\\ The same, for a family whose programs may reach the step bound: with Bounded true,
\\ two runs that both stop at the bound agree when their steps up to it are the same.
(define fh.disagreement-within
  Name [Execution Steps] Candidate true ->
    (if (= (fh.canon Steps) (fh.canon (fh.field "steps" Candidate)))
        []
        [object ["program" Name] ["first_divergent_epoch" (fh.first-divergence (fh.canon Steps) (fh.canon (fh.field "steps" Candidate)) 0)]
                ["model_execution" Execution] ["implementation_execution" "BudgetExhausted"]])
    where (and (= Execution "BudgetExhausted") (= (fh.field "execution" Candidate) "BudgetExhausted"))
  Name [Execution Steps] Candidate _ ->
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

(define fh.counts
  Pairs -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) Pairs)])
