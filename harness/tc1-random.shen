\\ Fenrir harness, in Shen: a randomly generated family of TC1 handler programs.
\\ The programs are generated here (harness/tc1-generate.shen) from fixed seeds; the
\\ validator must accept every one; the Shen model, run in this process, and the
\\ JavaScript handler machine must agree on every step; and, when asked, the Solo5
\\ guest must agree with the model as well. Contract: spec/tc1/EFFECTS.md.
\\ Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/tc1-random.shen LIBDIR ROOT OUTDIR SEEDS PER_SEED [OPTION...]
\\
\\ SEEDS     how many of the fixed seeds to use (fh.g-seed 0, 1, ...)
\\ PER_SEED  programs generated from each seed
\\ OPTIONS   sandbox         run the JavaScript implementation in the sandbox
\\           guest=SHEN_JIT  also build a Solo5 guest per seed and compare it with the
\\                           model (harness/solo5-pure-call.shen, run with SHEN_JIT)
\\           defect=NAME     NEGATIVE CONTROL: switch that injected defect on in the
\\                           implementation. The check must then fail.
\\
\\ OUTDIR must exist and be empty. It receives seed-<i>.jsonl, the programs of seed i
\\ as {name, program} lines, and js-<i>/, the implementation's runs on them.
\\
\\ Pass requires all of:
\\   the validator accepted every program, and counted the nodes the generator counted;
\\   SEEDS x PER_SEED programs were compared;
\\   every program agrees: model and implementation both complete with the same steps
\\     and outcome, or both reach the step bound with the same steps up to it;
\\   each of performing, resuming, discontinuing and abandoning happens in some program;
\\   with guest=: every seed's guest batch was built and agrees with the model.
\\ The report also says what the family looks like: sizes, handler nesting, outcomes,
\\ and how often each step kind of EFFECTS.md section 6 and each machine rule occurs.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*seeds* (hd (tl (tl (tl (tl (value *argv*)))))))
(set fh.*per-seed* (hd (tl (tl (tl (tl (tl (value *argv*))))))))
(set fh.*options* (tl (tl (tl (tl (tl (tl (value *argv*))))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))
(load (cn (value fh.*root*) "harness/tc1-step-kinds.shen"))
(load (cn (value fh.*root*) "harness/tc1-generate.shen"))
(load (cn (value fh.*root*) "harness/tc1-random-guest.shen"))

\\ The step bound, for the model, the implementation and the guest alike.
(define fh.r-fuel -> 1000)

\\ The value of the option that starts with Prefix, or [].
(define fh.r-option
  Prefix [] -> []
  Prefix [O | Os] -> (if (fh.starts? Prefix O) (fh.drop Prefix O) (fh.r-option Prefix Os)))

\\ ---------- the tally ----------
\\ A list of [Group Value]; a counting group's value is a list of [Key N].

(define fh.r-get
  _ [] -> []
  Group [[Group V] | _] -> V
  Group [_ | Rest] -> (fh.r-get Group Rest))

(define fh.r-set
  Group V [] -> [[Group V]]
  Group V [[Group _] | Rest] -> [[Group V] | Rest]
  Group V [P | Rest] -> [P | (fh.r-set Group V Rest)])

(define fh.r-add-key
  Key N [] -> [[Key N]]
  Key N [[Key M] | Rest] -> [[Key (+ M N)] | Rest]
  Key N [P | Rest] -> [P | (fh.r-add-key Key N Rest)])

(define fh.r-add
  Group Key N Tally -> (fh.r-set Group (fh.r-add-key Key N (fh.r-get Group Tally)) Tally))

(define fh.r-push
  Group X Tally -> (fh.r-set Group [X | (fh.r-get Group Tally)] Tally))

(define fh.r-number
  Group Key Tally -> (let N (fh.c-find Key (fh.r-get Group Tally)) (if (= N []) 0 N)))

\\ ---------- what one agreeing program adds ----------

(define fh.r-two
  N -> (if (< N 10) (cn "0" (str N)) (str N)))

\\ Node counts in fives: "01-05", "06-10", ...
(define fh.r-bucket
  Nodes -> (let Low (+ 1 (* 5 (fh.g-div (- Nodes 1) 5)))
             (cn (fh.r-two Low) (cn "-" (fh.r-two (+ Low 4))))))

\\ Steps and programs per kind. Kinds is a list of [Kind StepsInThisProgram].
(define fh.r-kinds
  _ _ [] Tally -> Tally
  Steps Programs [[Kind N] | Kinds] Tally ->
    (fh.r-kinds Steps Programs Kinds (fh.r-add Programs Kind 1 (fh.r-add Steps Kind N Tally))))

(define fh.r-any?
  _ [] -> false
  Prefix [[Kind _] | Kinds] -> (or (fh.starts? Prefix Kind) (fh.r-any? Prefix Kinds)))

\\ What the program did, read from its section 6 step kinds and its outcome.
(define fh.r-behaviours
  Kinds Outcome -> (append (if (fh.r-any? "Ready perform" Kinds) ["performing"] [])
                           (if (fh.r-any? "ClauseReturn" Kinds) ["tail_resuming"] [])
                           (if (fh.r-any? "Ready resume" Kinds) ["resuming"] [])
                           (if (fh.r-any? "Ready discontinue" Kinds) ["discontinuing"] [])
                           (if (fh.r-any? "AbandonFrame" Kinds) ["abandoning"] [])
                           (if (fh.r-any? "UnwindFrame at a clause frame" Kinds) ["trapping_in_a_clause"] [])
                           (if (fh.starts? "Trap" Outcome) ["trapping"] [])))

(define fh.r-count-all
  _ [] Tally -> Tally
  Group [Key | Keys] Tally -> (fh.r-count-all Group Keys (fh.r-add Group Key 1 Tally)))

\\ Steps by machine rule and the phase the step leaves the machine in.
(define fh.r-rules
  [] Rules -> Rules
  [Step | Steps] Rules ->
    (fh.r-rules Steps (fh.r-add-key [(fh.field "rule" (fh.field "site" Step)) (fh.field "after" Step)] 1 Rules)))

(define fh.r-agreeing
  Program Nodes Execution Steps Tally ->
    (let Counts (fh.c-steps Steps 0 (fh.c-functions (fh.field "functions" Program) [[] []]) [[] []])
         Outcome (if (= Execution "Completed") (fh.outcome-key (fh.model-outcome Steps)) "BudgetExhausted")
         Depth (fh.g-handler-depth (fh.g-main-body Program))
         T1 (fh.r-add "count" "agreeing" 1 (fh.r-add "count" "model_steps" (length Steps) Tally))
         T2 (fh.r-add "outcomes" Outcome 1 T1)
         T3 (fh.r-add "nodes" (fh.r-bucket Nodes) 1 T2)
         T4 (fh.r-add "handler_depth" (fh.r-two Depth) 1 T3)
         T5 (fh.r-kinds "kind_steps" "kind_programs" (hd Counts) T4)
         T6 (fh.r-kinds "other_steps" "other_programs" (hd (tl Counts)) T5)
         T7 (fh.r-count-all "behaviours" (fh.r-behaviours (hd Counts) Outcome) T6)
      (fh.r-set "rules" (fh.r-rules Steps (fh.r-get "rules" T7)) T7)))

\\ ---------- comparison ----------

\\ Rows are the implementation's, Generated the generator's, in the same order.
(define fh.r-compare
  [] [] Tally -> Tally
  [Row | Rows] [[Name _ Nodes _ Helpers] | Generated] Tally ->
    (fh.r-compare Rows Generated
      (if (not (= (fh.field "name" Row) Name))
          (error "harness: the implementation's rows are out of order at ~A" Name)
          (if (not (= (fh.field "valid" Row) true))
              (fh.r-push "rejected" [object ["program" Name] ["error" (fh.field "error" Row)]] Tally)
              (if (not (= (fh.field "nodes" Row) (str (+ Nodes Helpers))))
                  (fh.r-push "miscounted" [object ["program" Name] ["generator" (str (+ Nodes Helpers))] ["validator" (fh.field "nodes" Row)]] Tally)
                  (let Program (fh.field "program" Row)
                       Model (fh.run (fh.state Program) (fh.r-fuel) 0 [])
                       Difference (fh.disagreement-within Name Model (fh.field "candidate" Row) true)
                    (if (= Difference [])
                        (fh.r-agreeing Program Nodes (hd Model) (hd (tl Model)) Tally)
                        (fh.r-push "disagreements" Difference Tally)))))))
  _ _ _ -> (error "harness: the implementation did not report every generated program"))

(define fh.r-chunks
  Out I Chunks Generated Tally -> (if (empty? Generated) Tally (error "harness: the implementation did not report every generated program"))
    where (>= I Chunks)
  Out I Chunks Generated Tally ->
    (let Rows (fh.g-chunk Out I)
         N (length Rows)
      (fh.r-chunks Out (+ I 1) Chunks (fh.g-drop N Generated) (fh.r-compare Rows (fh.take N Generated) Tally))))

\\ One seed: generate, write, run the implementation, compare.
(define fh.r-seed
  I PerSeed Mode Sandbox Tally ->
    (let Generated (hd (fh.g-programs (cn "tc1-random-" (cn (str I) "-")) 0 PerSeed (fh.g-seed I) []))
         File (cn (value fh.*out*) (cn "seed-" (cn (str I) ".jsonl")))
         Written (fh.g-write Generated File)
         Out (cn (value fh.*out*) (cn "js-" (cn (str I) "/")))
         Header (fh.g-implementation File Out (fh.r-fuel) Mode Sandbox)
      (fh.r-chunks Out 0 (tc0.i64.small (fh.field "chunks" Header)) Generated Tally)))

(define fh.r-seeds
  I Seeds _ _ _ Tally -> Tally where (>= I Seeds)
  I Seeds PerSeed Mode Sandbox Tally -> (fh.r-seeds (+ I 1) Seeds PerSeed Mode Sandbox (fh.r-seed I PerSeed Mode Sandbox Tally)))

\\ ---------- report ----------

\\ "12.3%" of Total, rounded down.
(define fh.r-share
  N 0 -> "0.0%"
  N Total -> (let Tenths (fh.g-div (* N 1000) Total)
               (cn (str (fh.g-div Tenths 10)) (cn "." (cn (str (shen.mod Tenths 10)) "%")))))

(define fh.r-behaviour-names
  -> ["performing" "tail_resuming" "resuming" "discontinuing" "abandoning" "trapping" "trapping_in_a_clause"])

\\ The four behaviours whose absence fails the check.
(define fh.r-required-behaviours
  -> ["performing" "resuming" "discontinuing" "abandoning"])

(define fh.r-absent
  [] _ -> []
  [B | Bs] Tally -> (if (= (fh.r-number "behaviours" B Tally) 0) [B | (fh.r-absent Bs Tally)] (fh.r-absent Bs Tally)))

(define fh.r-behaviour-table
  Tally Total -> [object | (map (/. B [B [object ["programs" (str (fh.r-number "behaviours" B Tally))]
                                                 ["share" (fh.r-share (fh.r-number "behaviours" B Tally) Total)]]])
                                (fh.r-behaviour-names))])

\\ Counts as a JSON object, keys in order.
(define fh.r-sorted
  Pairs -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) (fh.sort-members Pairs))])

(define fh.r-kind-table
  Tally -> [object | (map (/. K [K [object ["steps" (str (fh.r-number "kind_steps" K Tally))]
                                           ["programs" (str (fh.r-number "kind_programs" K Tally))]]])
                          (fh.kinds))])

(define fh.r-kinds-missing
  [] _ -> []
  [K | Ks] Tally -> (if (= (fh.r-number "kind_steps" K Tally) 0) [K | (fh.r-kinds-missing Ks Tally)] (fh.r-kinds-missing Ks Tally)))

(define fh.r-rule-table
  Rules -> (fh.r-sorted (map (/. P [(make-string "~A -> ~A" (hd (hd P)) (hd (tl (hd P)))) (hd (tl P))]) Rules)))

(define fh.r-rule-names
  [] Seen -> Seen
  [[[Rule _] _] | Rules] Seen -> (fh.r-rule-names Rules (if (element? Rule Seen) Seen [Rule | Seen])))

(define fh.r-highest
  [] Max -> Max
  [[Key _] | Rest] Max -> (fh.r-highest Rest (if (fh.string<? Max Key) Key Max)))

(define fh.r-seed-list
  I Seeds -> [] where (>= I Seeds)
  I Seeds -> [(str (fh.g-seed I)) | (fh.r-seed-list (+ I 1) Seeds)])

(define fh.main
  -> (let Seeds (tc0.i64.small (value fh.*seeds*))
          PerSeed (tc0.i64.small (value fh.*per-seed*))
          Valid (if (and (> Seeds 0) (> PerSeed 0)) true (error "harness: SEEDS and PER_SEED are positive integers"))
          Sandbox (element? "sandbox" (value fh.*options*))
          Defect (fh.r-option "defect=" (value fh.*options*))
          Known (if (or (= Defect []) (element? Defect (fh.defect-names))) true (error "harness: unknown defect ~A" Defect))
          Jit (fh.r-option "guest=" (value fh.*options*))
          Tally (fh.r-seeds 0 Seeds PerSeed (if (= Defect []) "family" (cn "family:" Defect)) Sandbox [])
          Expected (* Seeds PerSeed)
          Agree (fh.r-number "count" "agreeing" Tally)
          Bad (reverse (fh.r-get "disagreements" Tally))
          Rejected (reverse (fh.r-get "rejected" Tally))
          Miscounted (reverse (fh.r-get "miscounted" Tally))
          Programs (+ Agree (+ (length Bad) (+ (length Rejected) (length Miscounted))))
          Absent (fh.r-absent (fh.r-required-behaviours) Tally)
          Guest (if (= Jit []) [] (do (set fh.*jit* Jit) (fh.rg-family (value fh.*out*) Seeds PerSeed (fh.r-fuel))))
          Pass (and (= Programs Expected) (= Agree Programs) (empty? Absent)
                    (or (= Guest []) (= (fh.member "status" Guest) "pass")))
          Report [object ["schema" "fenrir.harness.tc1-random/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["family" (make-string "generated in Shen by harness/tc1-generate.shen: main bodies of at most ~A nodes, three effects, both clause forms" (fh.g-max-nodes))]
                         ["seeds" (fh.r-seed-list 0 Seeds)]
                         ["programs_per_seed" (str PerSeed)]
                         ["programs_expected" (str Expected)]
                         ["step_bound" (str (fh.r-fuel))]
                         ["implementation_sandboxed" Sandbox]
                         ["injected_defect" (if (= Defect []) "none" Defect)]
                         ["programs" (str Programs)]
                         ["rejected_by_validator" (str (length Rejected))]
                         ["rejections" (fh.take 10 Rejected)]
                         ["node_count_differs" (fh.take 10 Miscounted)]
                         ["agreeing" (str Agree)]
                         ["disagreeing" (str (length Bad))]
                         ["disagreements" (fh.take 10 Bad)]
                         ["model_steps" (str (fh.r-number "count" "model_steps" Tally))]
                         ["outcomes" (fh.r-sorted (fh.r-get "outcomes" Tally))]
                         ["behaviours" (fh.r-behaviour-table Tally Agree)]
                         ["behaviours_absent" Absent]
                         ["nodes" (fh.r-sorted (fh.r-get "nodes" Tally))]
                         ["handler_nesting_depth" (fh.r-sorted (fh.r-get "handler_depth" Tally))]
                         ["max_handler_nesting_depth" (str (tc0.i64.small (fh.r-highest (fh.r-get "handler_depth" Tally) "00")))]
                         ["step_kinds" (str (length (fh.kinds)))]
                         ["step_kinds_covered" (str (- (length (fh.kinds)) (length (fh.r-kinds-missing (fh.kinds) Tally))))]
                         ["step_kinds_missing" (fh.r-kinds-missing (fh.kinds) Tally)]
                         ["steps_by_kind" (fh.r-kind-table Tally)]
                         ["untabulated_handler_steps" (fh.r-sorted (fh.r-get "other_steps" Tally))]
                         ["rules_exercised" (str (length (fh.r-rule-names (fh.r-get "rules" Tally) [])))]
                         ["steps_by_rule" (fh.r-rule-table (fh.r-get "rules" Tally))]
                         ["guest" (if (= Guest []) "not run" Guest)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
