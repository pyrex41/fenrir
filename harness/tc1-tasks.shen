\\ Fenrir harness, in Shen: TC1 slice C1, structured tasks and bounded channels (contract
\\ spec/tc1/CONCURRENCY.md). For every hand fixture and every schedule it is run under,
\\ the Shen model replays the recorded schedule, checking each choice against its own
\\ Runnable set, and must agree step for step with the sandboxed JavaScript
\\ implementation run under the same schedule; both must satisfy the handwritten
\\ expectations; a schedule recorded by a production policy must be a production
\\ schedule by the model's own records; and each defect injected into the
\\ implementation must be detected (killed) on at least one run. A defective run that
\\ crashes is counted separately and never as a detection.
\\ Development evidence only.
\\
\\   shen-jit script harness/tc1-tasks.shen LIBDIR ROOT OUTDIR [sandbox]

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*sandbox* (element? "sandbox" (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-task-common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))

\\ The nine defects of runtime/tc1/task-machine.mjs. The harness holds the list itself, so
\\ a batch that leaves one out cannot pass.
(define fh.task-defect-names
  -> ["stale_waiter" "waiter_not_woken" "waiter_woken_twice" "eager_cancel" "lifo_channel"
      "no_sibling_cancel" "capacity_off_by_one" "lost_wakeup_close" "lost_wakeup_await"])

\\ ---------- expectations (fixtures/tc1/task-hand-cases.mjs header) ----------

(define fh.lookup-member
  Key [object | Ms] -> (fh.lookup-in Key Ms)
  _ _ -> absent)

(define fh.lookup-in
  Key [[Key V] | _] -> V
  Key [_ | Ms] -> (fh.lookup-in Key Ms)
  _ [] -> absent)

(define fh.matches?
  [object | Ms] E -> (fh.all-match? Ms E))

(define fh.all-match?
  [] _ -> true
  [[K V] | Ms] E -> (let X (fh.lookup-member K E) (and (not (= X absent)) (= (fh.canon V) (fh.canon X)) (fh.all-match? Ms E))))

\\ Index of the first event matching P, or -1.
(define fh.first-match
  P [] _ -> -1
  P [E | Es] I -> (if (fh.matches? P E) I (fh.first-match P Es (+ I 1))))

(define fh.any-before?
  P Es J -> (let I (fh.first-match P Es 0) (and (>= I 0) (< I J))))

(define fh.of-task
  T Es -> (fh.keep (/. E (= (fh.lookup-member "task" E) T)) Es))

(define fh.emission-list
  Es -> (map (/. E [(fh.field "label" E) (fh.field "value" E)]) (fh.keep (/. E (= (fh.field "kind" E) "Emit")) Es)))

(define fh.termination-of
  T Es -> (let Ts (fh.keep (/. E (= (fh.field "kind" E) "Termination")) (fh.of-task T Es))
            (if (= Ts []) none (fh.field "outcome" (hd Ts)))))

(define fh.channel-kinds
  C Es -> (map (/. E (cn (fh.field "kind" E) (cn ":" (fh.field "task" E))))
               (fh.keep (/. E (= (fh.lookup-member "channel" E) C)) Es)))

(define fh.same?
  A B -> (= (fh.canon A) (fh.canon B)))

(define fh.member-of?
  X [] -> false
  X [Y | Ys] -> (or (fh.same? X Y) (fh.member-of? X Ys)))

\\ Each check gives [] when it holds or a one-line reason. Run is [Execution Detail Steps M].
(define fh.check-entry
  "terminations" [T Want] Es -> (if (fh.same? Want (fh.termination-of T Es)) [] (cn "termination of task " T))
  "terminations_one_of" [T Wants] Es -> (if (fh.member-of? (fh.termination-of T Es) Wants) [] (cn "termination of task " (cn T " (one of)")))
  "emissions" [T Want] Es -> (if (fh.same? Want (fh.emission-list (fh.of-task T Es))) [] (cn "emissions of task " T))
  "emissions_one_of" [T Wants] Es -> (if (fh.member-of? (fh.emission-list (fh.of-task T Es)) Wants) [] (cn "emissions of task " (cn T " (one of)")))
  "task_kinds" [T Want] Es -> (if (fh.same? Want (map (/. E (fh.field "kind" E)) (fh.of-task T Es))) [] (cn "event kinds of task " T))
  "channel_kinds" [C Want] Es -> (if (fh.same? Want (fh.channel-kinds C Es)) [] (cn "sequence of channel " C))
  "order" [P Q] Es -> (let I (fh.first-match P Es 0) J (fh.first-match Q Es 0)
                        (if (and (>= I 0) (>= J 0) (< I J)) [] (make-string "order ~A before ~A" (json.stringify P []) (json.stringify Q []))))
  "absent_before" [P Q] Es -> (let J (fh.first-match Q Es 0)
                                (if (or (< J 0) (not (fh.any-before? P Es J))) [] (make-string "~A before ~A" (json.stringify P []) (json.stringify Q []))))
  "absent" P Es -> (if (< (fh.first-match P Es 0) 0) [] (make-string "~A occurs" (json.stringify P []))))

(define fh.map-entries
  [object | Ms] -> Ms
  L -> L)

\\ [Reasons Count] for one expectation key.
(define fh.task-expect
  "execution" Want [E | _] _ -> [(if (= Want E) [] [(cn "execution " E)]) 1]
  "outcome" Want [E D | _] _ -> [(if (and (= E "Completed") (fh.same? Want D)) [] ["root outcome"]) 1]
  "wait_graph" Want [E D | _] _ -> [(if (and (= E "Deadlock") (fh.same? Want D)) [] ["wait graph"]) 1]
  Key Want _ Es -> (let Entries (fh.map-entries Want)
                     [(fh.keep (/. R (not (= R []))) (map (/. X (fh.check-entry Key X Es)) Entries)) (length Entries)]))

(define fh.task-expectations
  [] _ _ Reasons N -> [Reasons N]
  [[Key Want] | Rest] Run Es Reasons N ->
    (let R (fh.task-expect Key Want Run Es)
      (fh.task-expectations Rest Run Es (append Reasons (hd R)) (+ N (hd (tl R))))))

\\ ---------- one (fixture, schedule) run ----------

\\ [Name Reasons Expectations Steps Model Production?]
(define fh.check-task-run
  Row ->
    (let Program (fh.task-program (fh.field "program" Row))
         Model (fh.task-run (hd Program) (hd (tl Program)) (fh.field "choices" Row) 1000)
         Steps (hd (tl (tl Model)))
         Candidate (fh.field "candidate" Row)
         Expected (fh.task-expectations (tl (fh.field "expectations" Row)) Model (fh.task-events Steps) [] 0)
         Production (fh.field "production" Row)
         Reasons (append
                   (if (element? (hd Model) ["Completed" "Deadlock"]) [] [(cn "model execution " (hd Model))])
                   (if (fh.task-same? Model Candidate) []
                       [(cn "model and implementation differ at epoch " (fh.task-divergence Steps (fh.field "steps" Candidate) 0))])
                   (if (or (not Production) (fh.production? Steps)) [] ["a production policy's schedule switches after a pure step"])
                   (hd Expected))
      [(cn (fh.field "name" Row) (cn "/" (fh.field "schedule" Row))) Reasons (hd (tl Expected)) (length Steps) Model Production]))

(define fh.task-failures
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (fh.task-failures Rest) [[object ["run" Name] ["reasons" Reasons]] | (fh.task-failures Rest)]))

\\ Defect verdicts, only on runs where the model and the implementation agree.
(define fh.task-mutants
  [] [] Tally -> Tally
  [Row | Rows] [[_ Reasons _ _ Model _] | Results] Tally ->
    (fh.task-mutants Rows Results
      (if (= Reasons [])
          (fh.task-tally (tl (fh.field "mutants" Row)) Model Tally)
          Tally)))

(define fh.task-tally
  [] _ Tally -> Tally
  [[Name Run] | Runs] Model Tally -> (fh.task-tally Runs Model (fh.tally-one Name (fh.task-verdict Model Run) Tally)))

(define fh.sum-of
  [] _ N -> N
  [R | Rs] F N -> (fh.sum-of Rs F (+ N (F R))))

(define fh.distinct-names
  [] Acc -> Acc
  [Row | Rows] Acc -> (fh.distinct-names Rows (if (element? (fh.field "name" Row) Acc) Acc [(fh.field "name" Row) | Acc])))

(define fh.main
  -> (let File (cn (value fh.*out*) "tasks.jsonl")
          R (process.run "node" (fh.node-arguments "tools/tc1/run-task-cases.mjs" [File] ["runtime/tc1" "tools/tc1" "fixtures/tc1"] File (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 300000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript task run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (fh.check-task-run Row)) Rows)
          Failures (fh.task-failures Results)
          Tally (fh.task-mutants Rows Results [])
          Undetected (append (fh.unreported (fh.task-defect-names) Tally) (fh.undetected Tally))
          Pass (and (empty? Failures) (> (length Rows) 0) (empty? Undetected))
          Report [object ["schema" "fenrir.harness.tc1-tasks/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["slice" "TC1-C1 structured tasks and bounded channels"]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["cases" (str (length (fh.distinct-names Rows [])))]
                         ["runs" (str (length Rows))]
                         ["production_runs" (str (length (fh.keep (/. X (nth 6 X)) Results)))]
                         ["expectations_checked" (str (fh.sum-of Results (/. X (nth 3 X)) 0))]
                         ["model_steps" (str (fh.sum-of Results (/. X (nth 4 X)) 0))]
                         ["defects" (fh.tally-json Tally)]
                         ["defects_undetected" Undetected]
                         ["defects_crashing" (fh.crashing Tally)]
                         ["failures" Failures]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
