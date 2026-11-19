\\ Fenrir harness, in Shen: stage A4, the refinement check of the Fenrir handlers of both
\\ versions and of the Fenrir migration program against the A4 model
\\ (models/service-a4/upgrade.shen). Contract: spec/service/UPGRADE.md sections 2.2, 4.3,
\\ 5 and 9; host contracts models/service-a2/store-contract.shen (v1, unchanged) and
\\ models/service-a4/store-contract-v2.shen (v2, fencing, migration). Development
\\ evidence only ("bounded exploration passed").
\\
\\   shen-jit script harness/service-upgrade-fenrir.shen LIBDIR ROOT OUTDIR check ARTIFACTS T K D S C R X P G CAP [sandbox]
\\   shen-jit script harness/service-upgrade-fenrir.shen LIBDIR ROOT OUTDIR replay FILE ARTIFACTS
\\
\\ ARTIFACTS is a directory of elaborated programs NAME.json: accepted-job (v1),
\\ accepted-job-v2, migrate-v1-v2, and the mutants of examples/service/mutants-a4.
\\
\\ The Fenrir machine is the A4 model with every run executed by a program: a submit or a
\\ delivery (atomic, or dispatched and later landing) runs the handler of the run's
\\ version on the Shen TC1-D1 model with the request as its entry input; its one
\\ Store.commit is answered by sst4.commit (the v1 or v2 storage contract, with
\\ fencing); a fenced commit gets no reply and the run is answered unavailable. migrate
\\ runs the migration program, its snapshot and install answered on the current stores
\\ within the step (UPGRADE.md section 9, provisional). Every other label is the model's.
\\
\\ check: (1) the model, explored as in harness/service-upgrade.shen; (2) the Fenrir
\\ machine, explored the same way, with every step compared with the model's step from
\\ the same state (same next state and response on every edge, same graph), and on every
\\ edge from a prepared state on which a request changed the stores, the compare-and-swap
\\ check (the migration run with the snapshot of the state before and the install
\\ against the state after: Changed, nothing applied, then a fresh snapshot and the
\\ model's migration of the state after); (3) each Fenrir mutant explored against every
\\ A4 property with a retained, replayed shortest counterexample per violated check,
\\ against hand predictions; (4) every distinct completed run (program, input, replies)
\\ written as a sample, and the sandboxed JavaScript TC1-D1 implementation run on all of
\\ them step for step. The Solo5 guest is driven on the sample by
\\ harness/run-service-upgrade-fenrir.sh.

(set ux.*as-library* true)
(load (cn (nth 3 (value *argv*)) "/harness/service-upgrade.shen"))
(load (cn (value fh.*root*) "harness/tc1-durable-common.shen"))
(map (/. F (load (cn (value fh.*root*) F)))
     ["models/service-a2/store-contract.shen" "models/service-a4/store-contract-v2.shen"])

\\ ---------- programs: artifacts and memoized runs ----------

(set ufx.*prepared* (shen.dict 64))
(set ufx.*memo* (shen.dict 65536))
(set ufx.*runs* 0)
(set ufx.*fuel* 5000)

(define ufx.artifact
  Name -> (let A (sx.get (value ufx.*prepared*) [artifact Name])
            (if (= A sx.unset) (error "service-upgrade-fenrir: no artifact ~A" Name) A)))

(define ufx.load-artifact
  Dir Name -> (shen.dict-> (value ufx.*prepared*) [artifact Name]
                           (json.parse (read-file-as-string (cn Dir (cn Name ".json"))) [[byte-limit 16777216]])))

(define ufx.initial
  Name Input ->
    (let P (sx.get (value ufx.*prepared*) [initial Name])
      (if (= P sx.unset)
          (let S (dh.state-of-value (ufx.artifact Name) [unit])
               _ (shen.dict-> (value ufx.*prepared*) [initial Name] S)
            (ufx.with-input S Input))
          (ufx.with-input P Input))))

(define ufx.with-input
  [dm-state [tc1-state C [[P _]] F Codes Names] Seq Ctx] Input -> [dm-state [tc1-state C [[P Input]] F Codes Names] Seq Ctx])

\\ What a run of program Name on Input does after the host's Replies: [request Effect Op
\\ Value], [result V], or [failed Execution] (never a pass). A run is a function of
\\ (program, input, replies) (DURABLE.md section 6), so it is memoized on exactly that.
(define ufx.next
  Name Input Replies ->
    (let Key [Name Input Replies]
         Seen (sx.get (value ufx.*memo*) Key)
      (if (= Seen sx.unset)
          (let R (ufx.compute Name Input Replies)
               _ (set ufx.*runs* (+ 1 (value ufx.*runs*)))
               _ (shen.dict-> (value ufx.*memo*) Key R)
            R)
          Seen)))

(define ufx.compute
  Name Input Replies ->
    (let Run (dm.run (ufx.initial Name Input) [replies | Replies] (value ufx.*fuel*))
         Final (nth 3 Run)
      (cond ((= (hd Run) awaiting-host) (let C (dm.control Final) [request (nth 3 C) (nth 4 C) (nth 5 C)]))
            ((= (hd Run) completed) (ufx.result (dm.control Final)))
            (true [failed (hd Run)]))))

(define ufx.result
  [terminal [ok V]] -> [result V]
  [terminal [trap C]] -> [result [trap C]])

\\ ---------- the Fenrir machine ----------

\\ Hs is [V1Handler V2Handler MigrationProgram], artifact names.
(define ufx.request
  _ none _ U Sys -> [ok [up4 U Sys] unavailable]
  Hs V L U [sys Stores Outbox Trace] ->
    (let Name (nth V Hs)
         Input (sst.command L)
      (ufx.after-request Name Input (ufx.next Name Input []) U Stores Outbox Trace)))

(define ufx.after-request
  Name Input [request "Store" "commit" Tx] U Stores Outbox Trace ->
    (let C (sst4.commit U Stores Tx)
      (if (= C fenced)
          [ok [up4 U [sys Stores Outbox Trace]] unavailable]
          (ufx.finish (ufx.next Name Input [(nth 2 C)]) U (hd C) Outbox Trace)))
  _ _ R U Stores Outbox Trace -> (ufx.finish R U Stores Outbox Trace))

(define ufx.finish
  [result V] U Stores Outbox Trace -> (let Resp (sst4.response V) [ok [up4 U [sys Stores (sua.add-event Resp Outbox) Trace]] Resp])
  X _ _ _ _ -> (error "service-upgrade-fenrir: a handler run ended with ~S (A4 handlers make exactly one host request)" X))

\\ The migration program under the migration contract, with a fresh host session:
\\ [U' Stores' Result Replies]. SnapAt, when not none, are the stores the FIRST snapshot
\\ is taken from (the compare-and-swap check); every other request is answered on the
\\ current stores.
(define ufx.migration
  Mig U Stores Replies SnapAt -> (ufx.migration-from Mig U Stores none Replies SnapAt))

(define ufx.migration-from
  Mig U Stores Session Replies SnapAt ->
    (ufx.migration-with Mig U Stores Session Replies SnapAt (ufx.next Mig [unit] Replies)))

(define ufx.migration-with
  _ U Stores _ Replies _ [result V] -> [U Stores V Replies]
  Mig U Stores Session Replies SnapAt [request "Migration" "read" I] ->
    (let C (sst4.read Session (if (and (= I [int "0"]) (not (= SnapAt none))) SnapAt Stores) I)
      (ufx.migration-from Mig U Stores (hd C) (append Replies [(nth 2 C)]) (if (= I [int "0"]) none SnapAt)))
  Mig U Stores Session Replies SnapAt [request "Migration" "stage" Row] ->
    (let C (sst4.stage Session Row)
      (ufx.migration-from Mig U Stores (hd C) (append Replies [(nth 2 C)]) SnapAt))
  Mig U Stores Session Replies SnapAt [request "Migration" "install" N] ->
    (let C (sst4.install U Stores Session N)
      (ufx.migration-from Mig (hd C) (nth 2 C) (nth 3 C) (append Replies [(nth 4 C)]) SnapAt))
  _ _ _ _ _ _ X -> (error "service-upgrade-fenrir: a migration run ended with ~S" X))

(define ufx.step
  Hs L [up4 U Sys] -> (ufx.request Hs (sua.in-force U) L U Sys) where (sua.request? L (svc.stores Sys))
  Hs [land I] [up4 U [sys Stores Outbox Trace]] ->
    (let Run (nth (+ I 1) (sua.runs Outbox))
      (ufx.request Hs (nth 2 Run) (nth 3 Run) U [sys Stores (sua.drop-run I Outbox) Trace]))
    where (and (integer? I) (>= I 0) (< I (length (sua.runs Outbox))))
  Hs [migrate] [up4 [prepared Img] [sys Stores Outbox Trace]] ->
    (let R (ufx.migration (nth 3 Hs) [prepared Img] Stores [] none)
      [ok [up4 (hd R) [sys (nth 2 R) Outbox Trace]] none])
  _ L S -> (sua.step L S))

\\ ---------- the refinement comparison and the compare-and-swap check ----------

(set ufx.*compared* 0)
(set ufx.*mismatched* 0)
(set ufx.*mismatch-sample* [])
(set ufx.*cas* (shen.dict 65536))
(set ufx.*cas-checked* 0)
(set ufx.*cas-failed* 0)
(set ufx.*cas-sample* [])

(define ufx.checked-step
  Hs L S -> (let F (ufx.step Hs L S)
                 M (sua.step L S)
                 _ (set ufx.*compared* (+ 1 (value ufx.*compared*)))
                 _ (if (= F M) true
                       (do (set ufx.*mismatched* (+ 1 (value ufx.*mismatched*)))
                           (if (< (length (value ufx.*mismatch-sample*)) 3)
                               (set ufx.*mismatch-sample* [[(ux.label L) (ux.state S)] | (value ufx.*mismatch-sample*)])
                               true)))
              F))

\\ On an edge X -L-> Y from a prepared state on which a request changed the stores: the
\\ migration run that read X and installs at Y must be told Changed, apply nothing, read
\\ again and install the model's migration of Y.
(define ufx.cas-edge
  Mig X L Y Resp ->
    (let Xs (sup.stores X)
         Ys (sup.stores Y)
      (if (and (= (hd (sup.u X)) prepared) (= (sup.u X) (sup.u Y)) (not (= Xs Ys))
               (= (sx.get (value ufx.*cas*) [Xs Ys]) sx.unset))
          (let _ (shen.dict-> (value ufx.*cas*) [Xs Ys] true)
               R (ufx.migration Mig (sup.u Y) Ys [] Xs)
               Want (sua.step [migrate] [up4 (sup.u Y) [sys Ys [] []]])
               Ok (and (= (nth 3 R) [data "Migrated" "Installed"])
                       (= (ufx.install-replies (nth 4 R)) [[data "Migrated" "Changed"] [data "Migrated" "Installed"]])
                       (= [ok [up4 (hd R) [sys (nth 2 R) [] []]] none] Want))
               _ (set ufx.*cas-checked* (+ 1 (value ufx.*cas-checked*)))
            (if Ok done
                (do (set ufx.*cas-failed* (+ 1 (value ufx.*cas-failed*)))
                    (if (< (length (value ufx.*cas-sample*)) 3)
                        (set ufx.*cas-sample* [[(ux.label L) (ux.state X) (ux.state Y)] | (value ufx.*cas-sample*)])
                        done))))
          done)))

(define ufx.install-replies
  Replies -> (sx.filter (/. R (= (hd (tl R)) "Migrated")) Replies))

\\ ---------- machines by name (for exploration and replay) ----------

(define ufx.handlers
  "model" -> ["accepted-job" "accepted-job-v2" "migrate-v1-v2"]
  Name -> ["accepted-job" Name "migrate-v1-v2"] where (fh.starts? "v2-" Name)
  Name -> ["accepted-job" "accepted-job-v2" Name] where (fh.starts? "migrate-" Name)
  Name -> (error "service-upgrade-fenrir: unknown Fenrir machine ~A" Name))

(define ufx.machine-of
  Name Checked -> (let Hs (ufx.handlers Name)
                    [machine (cn "fenrir-" Name)
                             (if Checked (/. L S (ufx.checked-step Hs L S)) (/. L S (ufx.step Hs L S)))
                             (/. P S (sua.labels P S))]))

(set ux.*machine-of* (/. Name (if (fh.starts? "fenrir-" Name) (ufx.machine-of (fh.drop "fenrir-" Name) false) (umu.machine Name))))
(set ux.*replay-command* "sh harness/run-service-upgrade-fenrir.sh replay ")

\\ ---------- mutants ----------

(define ufx.mutant-names
  -> ["v2-forgot-count-attempt" "v2-stage-attempt-one" "v2-equivalent-control"
      "migrate-drops-pending" "migrate-rewrites-receipts" "migrate-drops-keys" "migrate-wrong-attempts"
      "migrate-equivalent-control"])

(define ufx.mutant-run
  Name Params Budget Cap Predictions Model ->
    (let Machine (ufx.machine-of Name false)
         MachineName (cn "fenrir-" Name)
         Explored (ux.explore Machine Params Budget Cap (/. X L Y R done))
         Report (ux.machine-report Machine Explored)
         Written (ux.write-counterexamples MachineName Params Budget (ux.caught (sup.properties)))
         Prediction (sx.prediction-check Written (fh.field Name (fh.field "mutants" Predictions)))
         Replayed (svcp.all? (/. W (nth 5 W)) Written)
         Control (fh.starts? "equivalent-control" (ufx.after-dash Name))
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

\\ "v2-equivalent-control" -> "equivalent-control"
(define ufx.after-dash
  Name -> (if (fh.starts? "v2-" Name) (fh.drop "v2-" Name) (if (fh.starts? "migrate-" Name) (fh.drop "migrate-" Name) Name)))

(define ufx.mutant-runs
  [] _ _ _ _ _ Acc -> (reverse Acc)
  [N | Ns] Params Budget Cap Predictions Model Acc ->
    (ufx.mutant-runs Ns Params Budget Cap Predictions Model [(ufx.mutant-run N Params Budget Cap Predictions Model) | Acc]))

\\ ---------- the sample, and the JavaScript implementation on it ----------

\\ Every distinct completed run of the correct programs: [Name Input Replies].
(define ufx.completed-runs
  Names -> (shen.dict-fold (/. K V Acc (if (and (element? (hd K) Names) (= (hd V) result)) [K | Acc] Acc)) (value ufx.*memo*) []))

(define ufx.run-json
  [Name Input Replies] -> [object ["program" Name] ["input" (fh.value Input)] ["replies" (map (/. V (fh.value V)) Replies)]])

(define ufx.sorted-runs
  Runs -> (map (/. P (tl P)) (ufx.sort-pairs (map (/. R [(json.stringify (ufx.run-json R) []) | R]) Runs))))

(define ufx.sort-pairs
  [] -> []
  [X | Xs] -> (ufx.insert-pair X (ufx.sort-pairs Xs)))

(define ufx.insert-pair
  X [] -> [X]
  X [Y | Ys] -> [X Y | Ys] where (fh.string<? (hd X) (hd Y))
  X [Y | Ys] -> [Y | (ufx.insert-pair X Ys)])

(define ufx.numbered
  _ [] _ -> []
  F [R | Rs] N -> [(F R N) | (ufx.numbered F Rs (+ N 1))])

(define ufx.sample-json
  Runs -> [object ["family" "service-a4"] ["fuel" (str (value ufx.*fuel*))]
                  ["programs" (ufx.numbered (/. R N [object ["name" (make-string "run-~A-~A" N (hd R))] ["program" (ufx.artifact (hd R))]
                                                            ["input" (fh.value (nth 2 R))]
                                                            ["replies" (map (/. V (fh.value V)) (nth 3 R))]])
                                            Runs 0)]])

(define ufx.model-run
  [Name Input Replies] -> (let R (dm.run (ufx.initial Name Input) [replies | Replies] (value ufx.*fuel*))
                            [(dh.execution (hd R)) (dh.records 0 (nth 2 R))]))

(define ufx.agreeing
  [] _ _ N Steps -> [N Steps]
  [R | Rs] [Row | Rows] I N Steps ->
    (let M (ufx.model-run R)
         C (fh.field "candidate" Row)
         Same (and (= (fh.field "name" Row) (make-string "run-~A-~A" I (hd R)))
                   (= (hd M) (fh.field "execution" C))
                   (= (fh.canon (nth 2 M)) (fh.canon (fh.field "steps" C))))
      (ufx.agreeing Rs Rows (+ I 1) (if Same (+ N 1) N) (+ Steps (length (nth 2 M)))))
  _ [] _ N Steps -> [N Steps])

(define ufx.javascript
  Runs SamplePath Sandbox ->
    (let Out (cn (value fh.*out*) "js-sample.jsonl")
         Run (process.run "node" (fh.node-arguments "tools/service/run-fenrir-sample.mjs" [SamplePath Out]
                                                    ["runtime/tc1" "tools/service" "fixtures/tc1" SamplePath] (value fh.*out*) Sandbox)
                          (buffer.from-string "") [[timeout 600000] [stdout-limit 4194304] [stderr-limit 4194304]])
         Ran (and (= (hd Run) ok) (process.success? (hd (tl Run))))
         View (if Ran (buffer.from-string (read-file-as-string Out)) (buffer.from-string ""))
         Rows (if Ran (fh.json-lines View 0 (buffer.length View) []) [])
         Agree (ufx.agreeing Runs Rows 0 0 0)
      [(and Ran (cons? Runs) (= (length Rows) (length Runs)) (= (hd Agree) (length Runs)))
       [object ["implementation" "runtime/tc1/durable-machine.mjs"] ["sandboxed" Sandbox] ["ran" Ran]
               ["runs" (str (length Runs))] ["agreeing_step_for_step" (str (hd Agree))] ["model_steps" (str (nth 2 Agree))]
               ["stderr" (if (= (hd Run) ok) (fh.take-string 2000 (buffer.string (process.error-bytes (hd (tl Run))))) "did not run")]]]))

(define ufx.count-program
  Name Runs -> (length (sx.filter (/. R (= (hd R) Name)) Runs)))

\\ ---------- main ----------

(define ufx.programs
  -> ["accepted-job" "accepted-job-v2" "migrate-v1-v2" | (ufx.mutant-names)])

(define ufx.check
  Dir Args ->
    (let Scope (ux.scope Args)
         Params (hd Scope)
         Budget (nth 2 Scope)
         Cap (nth 3 Scope)
         Sandbox (element? "sandbox" Args)
         Start (get-time run)
         _ (fh.subdir "counterexamples")
         _ (map (/. N (ufx.load-artifact Dir N)) (ufx.programs))
         \\ (1) the A4 model
         Model (umu.machine "model")
         ModelExplored (ux.explore Model Params Budget Cap (/. X L Y R done))
         ModelReport (ux.machine-report Model ModelExplored)
         \\ (2) the Fenrir machine, every step compared, the compare-and-swap check on the way
         T0 (get-time run)
         Fenrir (ufx.machine-of "model" true)
         FenrirExplored (ux.explore Fenrir Params Budget Cap (/. X L Y R (ufx.cas-edge "migrate-v1-v2" X L Y R)))
         FenrirReport (ux.machine-report Fenrir FenrirExplored)
         Runs (ufx.sorted-runs (ufx.completed-runs ["accepted-job" "accepted-job-v2" "migrate-v1-v2"]))
         RunsAll (value ufx.*runs*)
         T1 (get-time run)
         SameGraph (and (= (fh.field "product_states" FenrirReport) (fh.field "product_states" ModelReport))
                        (= (fh.field "edges" FenrirReport) (fh.field "edges" ModelReport))
                        (= (fh.field "system_states" FenrirReport) (fh.field "system_states" ModelReport)))
         CasOk (and (> (value ufx.*cas-checked*) 0) (= (value ufx.*cas-failed*) 0))
         Refines (and SameGraph (= (value ufx.*mismatched*) 0) (> (value ufx.*compared*) 0) CasOk
                      (fh.field "complete" FenrirReport) (empty? (fh.field "violations" FenrirReport)))
         \\ (4) the sample
         SamplePath (cn (value fh.*out*) "service-upgrade-sample.json")
         _ (write-to-file SamplePath (json.stringify (ufx.sample-json Runs) [[byte-limit 134217728]]))
         SampleSha (fh.sha256 SamplePath)
         JS (ufx.javascript Runs SamplePath Sandbox)
         \\ (3) mutants
         Predictions (json.parse (read-file-as-string (cn (value fh.*root*) "spec/service/upgrade-fenrir-mutant-predictions.json")) [[byte-limit 1048576]])
         Mutants (ufx.mutant-runs (ufx.mutant-names) Params Budget Cap Predictions ModelReport [])
         MutantsOk (svcp.all? (/. R (hd R)) Mutants)
         Pass (and Refines (hd JS) (= (string-length SampleSha) 64) MutantsOk
                   (fh.field "complete" ModelReport) (empty? (fh.field "violations" ModelReport)))
         Report [object ["schema" "fenrir.harness.service-upgrade-fenrir/1"]
                        ["status" (if Pass "development-pass" "development-fail")]
                        ["evidence" "bounded exploration passed (development grade) when status is development-pass; not a gate verdict"]
                        ["qualification" "UNKNOWN"]
                        ["harness" "Shen"]
                        ["contract" "spec/service/UPGRADE.md"]
                        ["programs" ["examples/service/accepted-job.fen" "examples/service/accepted-job-v2.fen" "examples/service/migrate-v1-v2.fen"]]
                        ["params" (ux.params-json Params)] ["budgets" (ux.budget-json Budget)] ["state_cap" Cap]
                        ["a4_model" ModelReport]
                        ["refinement" [object ["refines" Refines]
                                              ["same_graph_as_a4_model" SameGraph]
                                              ["steps_compared_with_a4_model" (str (value ufx.*compared*))]
                                              ["steps_differing" (str (value ufx.*mismatched*))]
                                              ["differing_samples" (value ufx.*mismatch-sample*)]
                                              ["compare_and_swap_checks" (str (value ufx.*cas-checked*))]
                                              ["compare_and_swap_failures" (str (value ufx.*cas-failed*))]
                                              ["compare_and_swap_failure_samples" (value ufx.*cas-sample*)]
                                              ["program_runs_computed" (str RunsAll)]
                                              ["distinct_completed_runs" (str (length Runs))]
                                              ["distinct_runs_by_program" [object ["accepted-job" (ufx.count-program "accepted-job" Runs)]
                                                                                  ["accepted-job-v2" (ufx.count-program "accepted-job-v2" Runs)]
                                                                                  ["migrate-v1-v2" (ufx.count-program "migrate-v1-v2" Runs)]]]
                                              ["seconds" (- T1 T0)]
                                              ["exploration" FenrirReport]]]
                        ["javascript_sample" (nth 2 JS)]
                        ["sample" (sx.relative SamplePath)]
                        ["sample_sha256" SampleSha]
                        ["mutants" (map (/. R (nth 3 R)) Mutants)]
                        ["seconds" (- (get-time run) Start)]]
         _ (write-to-file (cn (value fh.*out*) "report.json") (sx.json Report))
      (do (output "~A~%" (sx.json Report))
          (shen-jit.exit (if Pass 0 1)))))

(define ufx.main
  "check" -> (let Args (value ux.*args*) (ufx.check (cn (hd Args) "/") (tl Args)))
  "replay" -> (let Args (value ux.*args*)
                   _ (map (/. N (ufx.load-artifact (cn (hd (tl Args)) "/") N)) (ufx.programs))
                   R (ux.replay-file (hd Args))
                (do (output "~A~%" (sx.json (nth 2 R)))
                    (shen-jit.exit (if (hd R) 0 1))))
  Mode -> (do (output "unknown mode ~A~%" Mode) (shen-jit.exit 2)))

(ufx.main (value ux.*mode*))
