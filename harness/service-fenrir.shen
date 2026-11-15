\\ Fenrir harness, in Shen: stage A2, the refinement check of the Fenrir accepted-job
\\ handler (examples/service/accepted-job.fen) against the A1 model
\\ (models/service/accepted-job.shen). Contract: spec/service/HANDLER.md; language:
\\ spec/tc1/DURABLE.md. Development evidence only ("bounded exploration passed").
\\
\\   shen-jit script harness/service-fenrir.shen LIBDIR ROOT OUTDIR check ARTIFACTS T K D S C R X CAP [sandbox]
\\   shen-jit script harness/service-fenrir.shen LIBDIR ROOT OUTDIR replay FILE
\\
\\ ARTIFACTS is a directory of elaborated handlers, NAME.json (accepted-job and the
\\ mutants of examples/service/mutants), with NAME.rejected for a mutant the frontend
\\ refused (its message). The scope arguments are A1's (harness/service-explore.shen).
\\
\\ A Fenrir handler becomes an A1 machine: a submit or complete label starts one run of
\\ the program on the Shen TC1-D1 model with the label's request as its entry input; the
\\ host is the A1 store under the storage contract (models/service-a2/store-contract.shen):
\\ each Store.commit the run performs is applied to the current stores. The run's first
\\ request is answered within the label's step; a further request waits as the volatile
\\ outbox item [inflight T Id] for an internal step [internal host T I] (HANDLER.md
\\ section 3). The run's result is the response.
\\
\\ check: (1) the A1 model, explored as in A1; (2) the correct handler, explored the same
\\ way, with every step compared with the A1 model's step from the same state: it must
\\ give the same next state and response on every edge, and the same graph; (3) each
\\ handler mutant explored against every A1 property, a shortest counterexample retained
\\ per violated property and replayed, against hand predictions written before;
\\ (4) the distinct runs (request, replies) of the correct handler written out as a
\\ sample, and the sandboxed JavaScript TC1-D1 implementation run on all of them and
\\ compared step for step with the model. The Solo5 guest is driven on the same sample
\\ by harness/run-service-fenrir.sh through harness/solo5-durable.shen.
\\ A run is a function of (program, request, replies) (DURABLE.md section 6), so the
\\ program runs are memoized on exactly that; the number of distinct runs is reported.

(set sx.*as-library* true)
(load (cn (nth 3 (value *argv*)) "/harness/service-explore.shen"))
(load (cn (value fh.*root*) "harness/tc1-durable-common.shen"))
(load (cn (value fh.*root*) "models/service-a2/store-contract.shen"))

\\ ---------- handlers: artifacts and memoized runs ----------

(set sfx.*artifacts* [])
(set sfx.*prepared* (shen.dict 64))
(set sfx.*memo* (shen.dict 65536))
(set sfx.*runs* 0)
(set sfx.*ids* (shen.dict 4096))
(set sfx.*id-table* (shen.dict 4096))
(set sfx.*next-id* 0)
(set sfx.*fuel* 5000)

(define sfx.artifact
  Name -> (let A (sx.get (value sfx.*prepared*) [artifact Name])
            (if (= A sx.unset) (error "service-fenrir: no artifact ~A" Name) A)))

(define sfx.load-artifact
  Dir Name -> (let A (json.parse (read-file-as-string (cn Dir (cn Name ".json"))) [[byte-limit 16777216]])
                (shen.dict-> (value sfx.*prepared*) [artifact Name] A)))

\\ The initial state for a request: the handler's code tables are built once per handler.
(define sfx.initial
  Name Input ->
    (let P (sx.get (value sfx.*prepared*) [initial Name])
      (if (= P sx.unset)
          (let S (dh.state-of-value (sfx.artifact Name) [unit])
               _ (shen.dict-> (value sfx.*prepared*) [initial Name] S)
            (sfx.with-input S Input))
          (sfx.with-input P Input))))

(define sfx.with-input
  [dm-state [tc1-state C [[P _]] F Codes Names] Seq Ctx] Input -> [dm-state [tc1-state C [[P Input]] F Codes Names] Seq Ctx])

\\ What the run of handler Name on Input does next after the host's Replies:
\\ [request Tx] (its next host request), [result V] (it finished with V), or
\\ [failed Execution] (budget, violation; never a pass).
(define sfx.next
  Name Input Replies ->
    (let Key [Name Input Replies]
         Seen (sx.get (value sfx.*memo*) Key)
      (if (= Seen sx.unset)
          (let R (sfx.compute Name Input Replies)
               _ (set sfx.*runs* (+ 1 (value sfx.*runs*)))
               _ (shen.dict-> (value sfx.*memo*) Key R)
            R)
          Seen)))

(define sfx.compute
  Name Input Replies ->
    (let Run (dm.run (sfx.initial Name Input) [replies | Replies] (value sfx.*fuel*))
         Final (nth 3 Run)
      (cond ((= (hd Run) awaiting-host) [request (nth 5 (dm.control Final))])
            ((= (hd Run) completed) (sfx.result (dm.control Final)))
            (true [failed (hd Run)]))))

(define sfx.result
  [terminal [ok V]] -> [result V]
  [terminal [trap C]] -> [result [trap C]])

\\ Ids for in-flight runs (volatile outbox items), interned so states stay small.
(define sfx.intern
  Key -> (let Id (sx.get (value sfx.*ids*) Key)
           (if (= Id sx.unset)
               (let N (value sfx.*next-id*)
                    _ (set sfx.*next-id* (+ N 1))
                    _ (shen.dict-> (value sfx.*ids*) Key N)
                    _ (shen.dict-> (value sfx.*id-table*) N Key)
                 N)
               Id)))

(define sfx.unintern
  Id -> (shen.<-dict (value sfx.*id-table*) Id))

\\ ---------- the handler as an A1 machine ----------

\\ Answer the run's next request on Stores, then continue: [Stores' Outcome] with
\\ Outcome [done Response] or [waiting Replies'].
(define sfx.advance
  Name Input Replies Stores -> (sfx.advance-with Name Input Replies Stores (sfx.next Name Input Replies) true))

(define sfx.advance-with
  _ _ _ Stores [result V] _ -> [Stores [done (sst.response V)]]
  _ _ _ _ [failed X] _ -> (error "service-fenrir: a handler run ended with ~A" X)
  Name Input Replies Stores [request Tx] true ->
    (let C (sst.commit Stores Tx)
         Replies2 (append Replies [(nth 2 C)])
      (sfx.advance-with Name Input Replies2 (hd C) (sfx.next Name Input Replies2) false))
  _ _ Replies Stores [request _] false -> [Stores [waiting Replies]])

(define sfx.tenant
  [submit T | _] -> T
  [complete T | _] -> T)

(define sfx.settle
  T Input [Stores [done Resp]] Outbox Trace -> [ok [sys Stores (smu.add-event Resp Outbox) Trace] Resp]
  T Input [Stores [waiting Replies]] Outbox Trace ->
    [ok [sys Stores (smu.add-items [[inflight T (sfx.intern [Input Replies])]] Outbox) Trace] none])

(define sfx.step
  Name [submit T K D] [sys Stores Outbox Trace] -> (sfx.start Name [submit T K D] Stores Outbox Trace) where (svc.tenant? T Stores)
  Name [complete T J Ok] [sys Stores Outbox Trace] -> (sfx.start Name [complete T J Ok] Stores Outbox Trace) where (svc.tenant? T Stores)
  Name [internal host T I] Sys -> (sfx.host-step Name T I Sys)
  _ Label Sys -> (svc.step Label Sys))

(define sfx.start
  Name Label Stores Outbox Trace ->
    (let Input (sst.command Label)
      (sfx.settle (sfx.tenant Label) Input (sfx.advance Name Input [] Stores) Outbox Trace)))

\\ The I-th in-flight run in the outbox answers its next request.
(define sfx.inflight
  [] -> []
  [[inflight T Id] | Is] -> [[inflight T Id] | (sfx.inflight Is)]
  [_ | Is] -> (sfx.inflight Is))

(define sfx.host-step
  Name T I [sys Stores Outbox Trace] ->
    (let Items (sfx.inflight Outbox)
      (if (< I (length Items))
          (let Item (nth (+ I 1) Items)
               Key (sfx.unintern (nth 3 Item))
               Without (remove Item Outbox)
               R (sfx.advance-with Name (hd Key) (nth 2 Key) Stores (sfx.next Name (hd Key) (nth 2 Key)) true)
            (if (= (nth 2 Item) T) (sfx.settle T (hd Key) R Without Trace) disabled))
          disabled)))

(define sfx.internal-labels
  _ [] -> []
  I [[inflight T _] | Is] -> [[internal host T I] | (sfx.internal-labels (+ I 1) Is)])

(define sfx.labels
  Params [sys Stores Outbox Trace] -> (append (svc.labels Params [sys Stores Outbox Trace]) (sfx.internal-labels 0 (sfx.inflight Outbox))))

\\ ---------- the refinement comparison ----------

(set sfx.*compared* 0)
(set sfx.*mismatched* 0)
(set sfx.*mismatch-sample* [])

\\ The handler's step, compared with the A1 model's step from the same state.
(define sfx.checked-step
  Name L S -> (let F (sfx.step Name L S)
                   M (svc.step L S)
                   _ (set sfx.*compared* (+ 1 (value sfx.*compared*)))
                   _ (if (= F M) true
                         (do (set sfx.*mismatched* (+ 1 (value sfx.*mismatched*)))
                             (if (< (length (value sfx.*mismatch-sample*)) 3)
                                 (set sfx.*mismatch-sample* [[(sx.label L) (sx.state S)] | (value sfx.*mismatch-sample*)])
                                 true)))
                F))

(define sfx.machine-of
  Name Checked -> [machine (cn "fenrir-" Name)
                           (if Checked (/. L S (sfx.checked-step Name L S)) (/. L S (sfx.step Name L S)))
                           (/. P S (sfx.labels P S))])

\\ Every machine Gleipnir and replay know: A1's table and the Fenrir handlers.
(define sfx.a1-machine
  Name -> (smu.mutant-or-model Name))

(define smu.mutant-or-model
  "model" -> [machine "model" (/. L S (svc.step L S)) (/. P S (svc.labels P S))]
  "volatile-mailbox" -> (smu.mutant "volatile-mailbox" (fn smu.mailbox-tx) (fn smu.mailbox-deliver) (fn smu.no-internal))
  "respond-before-commit" -> (smu.mutant "respond-before-commit" (fn smu.early-tx) (fn smu.model-deliver) (fn smu.commit-internal))
  "non-atomic-write" -> (smu.mutant "non-atomic-write" (fn smu.split-tx) (fn smu.model-deliver) (fn smu.stage-internal))
  "retry-reapplies" -> (smu.mutant "retry-reapplies" (fn smu.reapply-tx) (fn smu.model-deliver) (fn smu.no-internal))
  "key-reuse-accepted" -> (smu.mutant "key-reuse-accepted" (fn smu.reuse-tx) (fn smu.model-deliver) (fn smu.no-internal))
  "cross-tenant-counter" -> (smu.mutant "cross-tenant-counter" (fn smu.shared-counter-tx) (fn smu.model-deliver) (fn smu.no-internal))
  "undeduplicated-delivery" -> (smu.mutant "undeduplicated-delivery" (fn smu.model-tx) (fn smu.overwrite-deliver) (fn smu.no-internal))
  "volatile-status" -> [machine "volatile-status" (/. L S (smu.volatile-status-step L S)) (/. P S (svc.labels P S))]
  "failure-not-terminal" -> (smu.mutant "failure-not-terminal" (fn smu.model-tx) (fn smu.success-only-deliver) (fn smu.no-internal))
  "equivalent-control" -> (smu.mutant "equivalent-control" (fn smu.control-tx) (fn smu.control-deliver) (fn smu.no-internal))
  Name -> (error "service: unknown machine ~A" Name))

(define smu.machine
  Name -> (sfx.machine-of (fh.drop "fenrir-" Name) false) where (fh.starts? "fenrir-" Name)
  Name -> (smu.mutant-or-model Name))

\\ ---------- counterexamples, with this harness's replay command ----------

(define sx.counterexample
  Name Params Budget [Property Check Kind Schedule] Path ->
    [object ["schema" "fenrir.service.counterexample/1"]
            ["evidence" "bounded exploration: a shortest schedule violating the check, within the bounds below"]
            ["machine" Name]
            ["property" (str Property)]
            ["check" Check]
            ["kind" (str Kind)]
            ["length" (length Schedule)]
            ["params" (sx.params-json Params)]
            ["budgets" (sx.budget-json Budget)]
            ["schedule" (map (/. L (sx.label L)) Schedule)]
            ["final_state" (sx.state (hd (sx.run-schedule (smu.machine Name) Params Schedule)))]
            ["replay" (cn "sh harness/run-service-fenrir.sh replay " (sx.relative Path))]])

\\ ---------- mutants of the handler ----------

(define sfx.mutant-run
  Name Params Budget Cap Predictions Model ->
    (let Machine (sfx.machine-of Name false)
         MachineName (cn "fenrir-" Name)
         Explored (sx.explore Machine Params Budget Cap false)
         Report (sx.machine-report Machine Params Budget Explored)
         Written (sx.write-counterexamples MachineName Params Budget (sx.caught (svcp.properties)))
         Prediction (sx.prediction-check Written (fh.field Name (fh.field "mutants" Predictions)))
         Replayed (svcp.all? (/. W (nth 5 W)) Written)
         Control (= Name "equivalent-control")
         SameGraph (and (= (fh.field "product_states" Report) (fh.field "product_states" Model))
                        (= (fh.field "edges" Report) (fh.field "edges" Model)))
         Pass (if Control
                  (and (empty? Written) SameGraph (fh.field "complete" Report))
                  (and (empty? (hd Prediction)) Replayed (not (empty? Written)) (fh.field "complete" Report)))
      [Pass Written
       [object ["mutant" Name] ["pass" Pass]
               ["caught_by" (map (/. W (sx.written-json W)) Written)]
               ["expected_properties_not_caught" (hd Prediction)]
               ["length_differs_from_prediction" (nth 2 Prediction)]
               ["caught_by_unpredicted_property" (nth 3 Prediction)]
               ["predicted_clean_but_caught" (nth 4 Prediction)]
               ["same_graph_as_model" SameGraph]
               ["exploration" Report]]]))

\\ A mutant the frontend refused: rejected statically, which is what is predicted.
(define sfx.static-row
  Dir Name Predicted ->
    (let Message (trap-error (fh.trim (read-file-as-string (cn Dir (cn Name ".rejected")))) (/. E ""))
         HasArtifact (trap-error (do (read-file-as-string (cn Dir (cn Name ".json"))) true) (/. E false))
      [(and (not (= Message "")) (not HasArtifact))
       [object ["mutant" Name] ["predicted" Predicted] ["rejected_statically" (and (not (= Message "")) (not HasArtifact))]
               ["frontend_message" Message]]]))

\\ ---------- the sample, and the JavaScript implementation on it ----------

\\ Every distinct completed run of handler Name: [Input Replies], from the memo.
(define sfx.completed-runs
  Name -> (shen.dict-fold (/. K V Acc (if (and (= (hd K) Name) (= (hd V) result)) [(tl K) | Acc] Acc)) (value sfx.*memo*) []))

(define sfx.sorted-runs
  Runs -> (map (/. P (tl P)) (sfx.sort-pairs (map (/. R [(json.stringify (sfx.run-json R) []) | R]) Runs))))

(define sfx.sort-pairs
  [] -> []
  [X | Xs] -> (sfx.insert-pair X (sfx.sort-pairs Xs)))

(define sfx.insert-pair
  X [] -> [X]
  X [Y | Ys] -> [X Y | Ys] where (fh.string<? (hd X) (hd Y))
  X [Y | Ys] -> [Y | (sfx.insert-pair X Ys)])

(define sfx.run-json
  [Input Replies] -> [object ["input" (fh.value Input)] ["replies" (map (/. V (fh.value V)) Replies)]])

(define sfx.sample-json
  Name Runs -> (let Artifact (sfx.artifact Name)
                    I (/. R N [object ["name" (make-string "run-~A" N)] ["program" Artifact] ["input" (fh.value (hd R))]
                                      ["replies" (map (/. V (fh.value V)) (nth 2 R))]])
                 [object ["family" "service-a2"] ["programs" (sfx.numbered I Runs 0)]]))

(define sfx.numbered
  _ [] _ -> []
  F [R | Rs] N -> [(F R N) | (sfx.numbered F Rs (+ N 1))])

\\ The model's records of one run in JSON shape.
(define sfx.model-run
  Name [Input Replies] -> (let R (dm.run (sfx.initial Name Input) [replies | Replies] (value sfx.*fuel*))
                            [(dh.execution (hd R)) (dh.records 0 (nth 2 R))]))

(define sfx.javascript
  Name Runs SamplePath Sandbox ->
    (let Out (cn (value fh.*out*) "js-sample.jsonl")
         Run (process.run "node" (fh.node-arguments "tools/service/run-fenrir-sample.mjs" [SamplePath Out]
                                                    ["runtime/tc1" "tools/service" "fixtures/tc1" SamplePath] (value fh.*out*) Sandbox)
                          (buffer.from-string "") [[timeout 600000] [stdout-limit 4194304] [stderr-limit 4194304]])
         Ran (and (= (hd Run) ok) (process.success? (hd (tl Run))))
         View (if Ran (buffer.from-string (read-file-as-string Out)) (buffer.from-string ""))
         Rows (if Ran (fh.json-lines View 0 (buffer.length View) []) [])
         Agree (sfx.agreeing Name Runs Rows 0 0)
      [(and Ran (= (length Rows) (length Runs)) (= (hd Agree) (length Runs)))
       [object ["implementation" "runtime/tc1/durable-machine.mjs"] ["sandboxed" Sandbox] ["ran" Ran]
               ["runs" (str (length Runs))] ["agreeing_step_for_step" (str (hd Agree))] ["model_steps" (str (nth 2 Agree))]
               ["stderr" (if (= (hd Run) ok) (fh.take-string 2000 (buffer.string (process.error-bytes (hd (tl Run))))) "did not run")]]]))

(define sfx.agreeing
  _ [] _ N Steps -> [N Steps]
  Name [R | Rs] [Row | Rows] N Steps ->
    (let M (sfx.model-run Name R)
         C (fh.field "candidate" Row)
         Same (and (= (hd M) (fh.field "execution" C)) (= (fh.canon (nth 2 M)) (fh.canon (fh.field "steps" C))))
      (sfx.agreeing Name Rs Rows (if Same (+ N 1) N) (+ Steps (length (nth 2 M)))))
  _ _ [] N Steps -> [N Steps])

\\ ---------- main ----------

(define sfx.handler-mutants
  -> ["respond-before-commit" "two-commits" "no-key-check" "wrong-tenant" "conflict-undetected"
      "undeduplicated-delivery" "equivalent-control"])

(define sfx.mutant-runs
  [] _ _ _ _ _ Acc -> (reverse Acc)
  [N | Ns] Params Budget Cap Predictions Model Acc ->
    (sfx.mutant-runs Ns Params Budget Cap Predictions Model [(sfx.mutant-run N Params Budget Cap Predictions Model) | Acc]))

(define sfx.check
  Dir Args ->
    (let Ns (sx.ints (fh.take 8 Args))
         Params (fh.take 3 Ns)
         Budget [(nth 4 Ns) (nth 5 Ns) (nth 6 Ns) (nth 7 Ns)]
         Cap (nth 8 Ns)
         Sandbox (element? "sandbox" Args)
         Start (get-time run)
         _ (fh.subdir "counterexamples")
         _ (map (/. N (sfx.load-artifact Dir N)) ["accepted-job" | (sfx.handler-mutants)])
         \\ (1) the A1 model
         Model (smu.machine "model")
         ModelExplored (sx.explore Model Params Budget Cap false)
         ModelReport (sx.machine-report Model Params Budget ModelExplored)
         \\ (2) the handler, every step compared with the model's
         T0 (get-time run)
         Handler (sfx.machine-of "accepted-job" true)
         HandlerExplored (sx.explore Handler Params Budget Cap false)
         HandlerReport (sx.machine-report Handler Params Budget HandlerExplored)
         Runs (sfx.sorted-runs (sfx.completed-runs "accepted-job"))
         RunsAll (value sfx.*runs*)
         T1 (get-time run)
         SameGraph (and (= (fh.field "product_states" HandlerReport) (fh.field "product_states" ModelReport))
                        (= (fh.field "edges" HandlerReport) (fh.field "edges" ModelReport))
                        (= (fh.field "system_states" HandlerReport) (fh.field "system_states" ModelReport)))
         Refines (and SameGraph (= (value sfx.*mismatched*) 0) (> (value sfx.*compared*) 0)
                      (fh.field "complete" HandlerReport) (empty? (fh.field "violations" HandlerReport)))
         \\ (4) the sample, written for the JavaScript and Solo5 comparisons
         SamplePath (cn (value fh.*out*) "service-sample.json")
         _ (write-to-file SamplePath (json.stringify (sfx.sample-json "accepted-job" Runs) [[byte-limit 67108864]]))
         JS (sfx.javascript "accepted-job" Runs SamplePath Sandbox)
         \\ (3) mutants of the handler
         Predictions (json.parse (read-file-as-string (cn (value fh.*root*) "spec/service/fenrir-mutant-predictions.json")) [[byte-limit 1048576]])
         Mutants (sfx.mutant-runs (sfx.handler-mutants) Params Budget Cap Predictions ModelReport [])
         MutantsOk (svcp.all? (/. R (hd R)) Mutants)
         Static (map (/. P (sfx.static-row Dir (hd P) (nth 2 P))) (tl (fh.field "static" Predictions)))
         StaticOk (svcp.all? (/. R (hd R)) Static)
         Pass (and Refines (hd JS) MutantsOk StaticOk (fh.field "complete" ModelReport) (empty? (fh.field "violations" ModelReport)))
         Report [object ["schema" "fenrir.harness.service-fenrir/1"]
                        ["status" (if Pass "development-pass" "development-fail")]
                        ["evidence" "bounded exploration passed (development grade) when status is development-pass; not a gate verdict"]
                        ["qualification" "UNKNOWN"]
                        ["harness" "Shen"]
                        ["contract" "spec/service/HANDLER.md"]
                        ["handler" "examples/service/accepted-job.fen"]
                        ["params" (sx.params-json Params)] ["budgets" (sx.budget-json Budget)] ["state_cap" Cap]
                        ["a1_model" ModelReport]
                        ["refinement" [object ["refines" Refines]
                                              ["same_graph_as_a1_model" SameGraph]
                                              ["steps_compared_with_a1_model" (str (value sfx.*compared*))]
                                              ["steps_differing" (str (value sfx.*mismatched*))]
                                              ["differing_samples" (value sfx.*mismatch-sample*)]
                                              ["handler_runs_computed" (str RunsAll)]
                                              ["distinct_completed_runs" (str (length Runs))]
                                              ["seconds" (- T1 T0)]
                                              ["exploration" HandlerReport]]]
                        ["javascript_sample" (nth 2 JS)]
                        ["sample" (sx.relative SamplePath)]
                        ["mutants" (map (/. R (nth 3 R)) Mutants)]
                        ["static" (map (/. R (nth 2 R)) Static)]
                        ["seconds" (- (get-time run) Start)]]
         _ (write-to-file (cn (value fh.*out*) "report.json") (sx.json Report))
      (do (output "~A~%" (sx.json Report))
          (shen-jit.exit (if Pass 0 1)))))

(define sfx.main
  "check" -> (let Args (value sx.*args*) (sfx.check (cn (hd Args) "/") (tl Args)))
  "replay" -> (let Args (value sx.*args*)
                   Dir (hd (tl Args))
                   _ (map (/. N (sfx.load-artifact (cn Dir "/") N)) ["accepted-job" | (sfx.handler-mutants)])
                   R (sx.replay-file (hd Args))
                (do (output "~A~%" (sx.json (nth 2 R)))
                    (shen-jit.exit (if (hd R) 0 1))))
  Mode -> (do (output "unknown mode ~A~%" Mode) (shen-jit.exit 2)))

(sfx.main (value sx.*mode*))
