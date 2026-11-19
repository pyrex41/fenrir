\\ Fenrir harness, in Shen: Gleipnir's bounded exploration of the accepted-job upgrade
\\ contract, stage A4 (spec/service/UPGRADE.md, model models/service-a4/upgrade.shen).
\\ Development evidence only ("bounded exploration passed"); no gate verdict.
\\
\\   shen-jit script harness/service-upgrade.shen LIBDIR ROOT OUTDIR explore T K D S C R X P G CAP
\\   shen-jit script harness/service-upgrade.shen LIBDIR ROOT OUTDIR replay FILE
\\
\\ explore: T tenants, K keys, D digests; budgets S submits, C deliveries, R responses,
\\ X crashes, P dispatches, G upgrade steps (begin-upgrade, abort-upgrade, migrate,
\\ cut-over) per schedule; a landing and a mutant's internal step take no budget (each
\\ consumes a volatile item an earlier step made). CAP is the most product states
\\ admitted before the run is declared truncated; a truncated run is never a pass.
\\
\\ Breadth-first search over product states [State Monitor RemainingBudget], merged only
\\ when all three are equal (plan section 6). Every reachable product state gets every
\\ state predicate of models/service-a4/upgrade-properties.shen, every explored edge
\\ every edge predicate; layers are explored in order, so the first violation of each
\\ check has a shortest schedule.
\\
\\ Run in order: (1) the hand traces (spec/service/upgrade-hand-traces.json) on the
\\ model; (2) the model; (3) the A1 sub-scope: the A4 model with no dispatch and no
\\ upgrade step must give exactly A1's graph (product states, system states, edges) at
\\ the same parameters; (4) each mutant and the equivalent control
\\ (harness/service-upgrade-mutants.shen) against the hand predictions
\\ (spec/service/upgrade-mutant-predictions.json), a shortest counterexample retained per
\\ violated property in OUTDIR/counterexamples and replayed.
\\
\\ replay: re-executes a retained counterexample's schedule from the initial state with
\\ every check at every step, and exits 0 exactly when the named check first fails at the
\\ recorded step.
\\
\\ harness/service-upgrade-fenrir.shen (the Fenrir handlers) loads this file as a
\\ library with ux.*as-library* set.

(set sx.*as-library* true)
(load (cn (nth 3 (value *argv*)) "/harness/service-explore.shen"))
(set ux.*mode* (value sx.*mode*))
(set ux.*args* (value sx.*args*))
(map (/. F (load (cn (value fh.*root*) F)))
     ["models/service-a4/upgrade.shen" "models/service-a4/upgrade-properties.shen" "harness/service-upgrade-mutants.shen"])

\\ ---------- canonical observation (UPGRADE.md section 7) ----------

(define ux.generic
  X -> X where (boolean? X)
  X -> (str X) where (symbol? X)
  [X | Xs] -> (map (/. Y (ux.generic Y)) [X | Xs])
  X -> X)

(define ux.receipt
  [receipt T K D R J] -> [T K D R J]
  [receipt T K D R J 2] -> [T K D R J 2]
  X -> (ux.generic X))

(define ux.event
  [accepted Rc] -> ["accepted" (ux.receipt Rc)]
  [conflict T K] -> ["conflict" T K]
  [run V L] -> ["run" V (ux.label L)]
  X -> (ux.generic X))

(define ux.label
  [submit T K D] -> ["submit" T K D]
  [complete T J Ok] -> ["complete" T J Ok]
  [respond E] -> ["respond" (ux.event E)]
  [crash] -> ["crash"]
  [dispatch L] -> ["dispatch" (ux.label L)]
  [land I] -> ["land" I]
  [begin-upgrade Img] -> ["begin-upgrade" (str Img)]
  [abort-upgrade] -> ["abort-upgrade"]
  [migrate] -> ["migrate"]
  [cut-over] -> ["cut-over"]
  [internal Name | Args] -> ["internal" (str Name) | (ux.generic Args)])

(define ux.response
  none -> null
  unavailable -> "unavailable"
  refused -> "refused"
  E -> (ux.event E))

(define ux.upgrade
  [v1] -> ["v1"]
  [Tag Img] -> [(str Tag) (str Img)]
  X -> (ux.generic X))

(define ux.job
  [J R St] -> [J R (sx.status St)]
  [J R St A] -> [J R (sx.status St) A]
  X -> (ux.generic X))

(define ux.tenant
  [store Reports Jobs Keys N] ->
    [(sx.sort-by-head Reports)
     (map (/. J (ux.job J)) (sx.sort-by-head Jobs))
     (map (/. E [(hd E) (nth 2 E) (ux.receipt (nth 3 E))]) (sx.sort-by-head Keys))
     N])

(define ux.sort-events
  [] Acc -> Acc
  [E | Es] Acc -> (ux.sort-events Es (sua.insert-event E Acc)))

(define ux.state
  [up4 U [sys Stores Outbox Trace]] ->
    [(ux.upgrade U)
     (map (/. S (ux.tenant S)) Stores)
     (map (/. E (ux.event E)) (append (ux.sort-events (sua.events Outbox) []) (sua.items Outbox)))
     (reverse (map (/. E (ux.event E)) Trace))])

(define ux.decode-receipt
  [T K D R J] -> [receipt (sx.int T) (sx.int K) (sx.int D) (sx.int R) (sx.int J)]
  [T K D R J V] -> [receipt (sx.int T) (sx.int K) (sx.int D) (sx.int R) (sx.int J) (sx.int V)]
  X -> (error "service-upgrade: not a receipt ~S" X))

(define ux.decode-event
  ["accepted" Rc] -> [accepted (ux.decode-receipt Rc)]
  ["conflict" T K] -> [conflict (sx.int T) (sx.int K)]
  X -> (error "service-upgrade: not an event ~S" X))

(define ux.decode-label
  ["submit" T K D] -> [submit (sx.int T) (sx.int K) (sx.int D)]
  ["complete" T J Ok] -> [complete (sx.int T) (sx.int J) Ok]
  ["respond" E] -> [respond (ux.decode-event E)]
  ["crash"] -> [crash]
  ["dispatch" L] -> [dispatch (ux.decode-label L)]
  ["land" I] -> [land (sx.int I)]
  ["begin-upgrade" Img] -> [begin-upgrade (intern Img)]
  ["abort-upgrade"] -> [abort-upgrade]
  ["migrate"] -> [migrate]
  ["cut-over"] -> [cut-over]
  ["internal" Name | Args] -> [internal (intern Name) | (map (/. A (sx.int A)) Args)]
  X -> (error "service-upgrade: not a label ~S" X))

\\ ---------- budgets ----------

\\ Budget [Submits Deliveries Responses Crashes Dispatches UpgradeSteps]; kind 0 is free.
(define ux.kind
  [submit | _] -> 1
  [complete | _] -> 2
  [respond | _] -> 3
  [crash] -> 4
  [dispatch | _] -> 5
  [begin-upgrade | _] -> 6
  [abort-upgrade] -> 6
  [migrate] -> 6
  [cut-over] -> 6
  _ -> 0)

\\ ---------- exploration ----------

(define ux.reset
  -> (do (set ux.*visited* (shen.dict 1048576))
         (set ux.*runtime* (shen.dict 262144))
         (set ux.*rb* (shen.dict 524288))
         (set ux.*states* 0)
         (set ux.*rb-states* 0)
         (set ux.*runtime-states* 0)
         (set ux.*by-upgrade* [])
         (set ux.*edges* 0)
         (set ux.*bound-hits* [0 0 0 0 0 0])
         (set ux.*disabled* 0)
         (set ux.*truncated* false)
         (set ux.*found* [])
         (set ux.*on-edge* (/. X L Y R done))))

(define ux.path
  P -> (ux.path-from (shen.<-dict (value ux.*visited*) P) []))

(define ux.path-from
  root Acc -> Acc
  [Parent Label] Acc -> (ux.path-from (shen.<-dict (value ux.*visited*) Parent) [Label | Acc]))

(define ux.record
  [] _ _ -> done
  [[Property Check] | Vs] Kind Schedule ->
    (do (if (sx.found? Check (value ux.*found*)) done
            (set ux.*found* (append (value ux.*found*) [[Property Check Kind (thaw Schedule)]])))
        (ux.record Vs Kind Schedule)))

(define ux.count-upgrade
  Tag [] -> [[Tag 1]]
  Tag [[Tag N] | Rest] -> [[Tag (+ N 1)] | Rest]
  Tag [X | Rest] -> [X | (ux.count-upgrade Tag Rest)])

(define ux.admit
  [S M B] Parent ->
    (let _ (shen.dict-> (value ux.*visited*) [S M B] Parent)
         _ (set ux.*states* (+ (value ux.*states*) 1))
         _ (if (= (sx.get (value ux.*runtime*) S) sx.unset)
               (do (shen.dict-> (value ux.*runtime*) S true)
                   (set ux.*runtime-states* (+ (value ux.*runtime-states*) 1))
                   (set ux.*by-upgrade* (ux.count-upgrade (hd (sup.u S)) (value ux.*by-upgrade*))))
               done)
      (if (= (sx.get (value ux.*rb*) [S B]) sx.unset)
          (do (shen.dict-> (value ux.*rb*) [S B] true) (set ux.*rb-states* (+ (value ux.*rb-states*) 1)))
          done)))

(define ux.edge
  Machine P L Cap Next ->
    (let I (ux.kind L)
         B (sx.spend I (nth 3 P))
      (if (= B exhausted)
          (do (set ux.*bound-hits* (sx.bump I (value ux.*bound-hits*))) Next)
          (ux.edge-to Machine P L ((sx.step-fn Machine) L (hd P)) B Cap Next))))

(define ux.edge-to
  _ _ _ disabled _ _ Next -> (do (set ux.*disabled* (+ (value ux.*disabled*) 1)) Next)
  Machine [S M B0] L [ok S2 Resp] B Cap Next ->
    (let M2 (sup.monitor-step S L Resp M)
         Q [S2 M2 B]
         _ (set ux.*edges* (+ (value ux.*edges*) 1))
         _ (ux.record (sup.edge-violations (sx.step-fn Machine) S M L S2 Resp) edge
                      (freeze (append (ux.path [S M B0]) [L])))
         _ ((value ux.*on-edge*) S L S2 Resp)
      (if (= (sx.get (value ux.*visited*) Q) sx.unset)
          (if (< (value ux.*states*) Cap)
              (do (ux.admit Q [[S M B0] L]) [Q | Next])
              (do (set ux.*truncated* true) Next))
          Next)))

(define ux.edges
  _ _ [] _ Next -> Next
  Machine P [L | Ls] Cap Next -> (ux.edges Machine P Ls Cap (ux.edge Machine P L Cap Next)))

(define ux.visit
  Machine Params P Cap Next ->
    (let S (hd P)
         _ (ux.record (sup.state-violations (sx.step-fn Machine) (nth 2 P) S) state (freeze (ux.path P)))
      (ux.edges Machine P ((sx.labels-fn Machine) Params S) Cap Next)))

(define ux.layer
  _ _ [] _ Next -> Next
  Machine Params [P | Ps] Cap Next -> (ux.layer Machine Params Ps Cap (ux.visit Machine Params P Cap Next)))

(define ux.layers
  _ _ [] _ Depth -> (- Depth 1)
  Machine Params Layer Cap Depth -> (ux.layers Machine Params (reverse (ux.layer Machine Params Layer Cap [])) Cap (+ Depth 1)))

\\ OnEdge X L Y Resp is called on every explored edge (the Fenrir harness compares there).
(define ux.explore
  Machine Params Budget Cap OnEdge ->
    (let _ (ux.reset)
         _ (set ux.*on-edge* OnEdge)
         Init [(sua.initial (hd Params)) (sup.monitor-initial) Budget]
         _ (ux.admit Init root)
         T0 (get-time run)
         Depth (ux.layers Machine Params [Init] Cap 0)
         T1 (get-time run)
      [Depth (- T1 T0)]))

\\ ---------- reports ----------

(define ux.params-json
  [T K D] -> [object ["tenants" T] ["keys" K] ["digests" D]])

(define ux.budget-json
  [S C R X P G] -> [object ["submits" S] ["deliveries" C] ["responses" R] ["crashes" X] ["dispatches" P] ["upgrade_steps" G]])

(define ux.check-json
  [Property Check Kind Schedule] ->
    [object ["property" (str Property)] ["check" Check] ["kind" (str Kind)] ["length" (length Schedule)]
            ["schedule" (map (/. L (ux.label L)) Schedule)]])

(define ux.machine-report
  Machine [Depth Seconds] ->
    (let H (value ux.*bound-hits*)
      [object ["machine" (sx.name Machine)]
              ["complete" (not (value ux.*truncated*))]
              ["truncated" (value ux.*truncated*)]
              ["product_states" (value ux.*states*)]
              ["states_without_monitor" (value ux.*rb-states*)]
              ["system_states" (value ux.*runtime-states*)]
              ["system_states_by_upgrade_state" [object | (map (/. P [(str (hd P)) (nth 2 P)]) (value ux.*by-upgrade*))]]
              ["edges" (value ux.*edges*)]
              ["max_depth" Depth]
              ["bound_hits" [object ["submits" (nth 1 H)] ["deliveries" (nth 2 H)] ["responses" (nth 3 H)]
                                    ["crashes" (nth 4 H)] ["dispatches" (nth 5 H)] ["upgrade_steps" (nth 6 H)]]]
              ["disabled_alphabet_steps" (value ux.*disabled*)]
              ["violations" (map (/. F (ux.check-json F)) (value ux.*found*))]
              ["seconds" Seconds]]))

\\ ---------- counterexamples and replay ----------

(set ux.*replay-command* "sh harness/run-service-upgrade.sh replay ")
(set ux.*machine-of* (/. Name (umu.machine Name)))

(define ux.machine
  Name -> ((value ux.*machine-of*) Name))

(define ux.run-schedule
  Machine Params Schedule -> (ux.run-from (sx.step-fn Machine) (sua.initial (hd Params)) Schedule))

(define ux.run-from
  _ S [] -> [S]
  Step S [L | Ls] -> (ux.run-next Step (Step L S) Ls))

(define ux.run-next
  Step [ok S _] Ls -> (ux.run-from Step S Ls)
  _ _ _ -> [disabled])

(define ux.final-json
  [disabled] -> null
  [S] -> (ux.state S))

(define ux.counterexample
  Name Params Budget [Property Check Kind Schedule] Path ->
    [object ["schema" "fenrir.service.upgrade-counterexample/1"]
            ["evidence" "bounded exploration: a shortest schedule violating the check, within the bounds below"]
            ["machine" Name]
            ["property" (str Property)]
            ["check" Check]
            ["kind" (str Kind)]
            ["length" (length Schedule)]
            ["params" (ux.params-json Params)]
            ["budgets" (ux.budget-json Budget)]
            ["schedule" (map (/. L (ux.label L)) Schedule)]
            ["final_state" (ux.final-json (ux.run-schedule (ux.machine Name) Params Schedule))]
            ["replay" (cn (value ux.*replay-command*) (sx.relative Path))]])

(define ux.replay-run
  Machine Params Schedule ->
    (let S (sua.initial (hd Params))
         M (sup.monitor-initial)
         First (sx.note-first (sup.state-violations (sx.step-fn Machine) M S) 0 [])
      (ux.replay-steps Machine Params S M Schedule 1 First)))

(define ux.replay-steps
  _ _ _ _ [] _ First -> First
  Machine Params S M [L | Ls] I First ->
    (if (element? L ((sx.labels-fn Machine) Params S))
        (ux.replay-next Machine Params S M L ((sx.step-fn Machine) L S) Ls I First)
        [disabled I]))

(define ux.replay-next
  Machine Params S M L [ok S2 Resp] Ls I First ->
    (let Step (sx.step-fn Machine)
         M2 (sup.monitor-step S L Resp M)
         F1 (sx.note-first (sup.edge-violations Step S M L S2 Resp) I First)
         F2 (sx.note-first (sup.state-violations Step M2 S2) I F1)
      (ux.replay-steps Machine Params S2 M2 Ls (+ I 1) F2))
  _ _ _ _ _ _ _ I _ -> [disabled I])

(define ux.read-budget
  B -> (map (/. K (let N (sx.int (fh.field K B))
                    (if (>= N 0) N
                        (error "invalid A4 replay budget ~A" K))))
            ["submits" "deliveries" "responses" "crashes" "dispatches" "upgrade_steps"]))

(define ux.within-budget?
  [] _ -> true
  [L | Ls] B -> (let Next (sx.spend (ux.kind L) B)
                 (and (not (= Next exhausted)) (ux.within-budget? Ls Next))))

(define ux.replay-file
  Path ->
    (let C (json.parse (read-file-as-string Path) [[byte-limit 16777216]])
         Name (fh.field "machine" C)
         Check (fh.field "check" C)
         Length (sx.int (fh.field "length" C))
         Schedule (map (/. L (ux.decode-label L)) (fh.field "schedule" C))
         Within (ux.within-budget? Schedule (ux.read-budget (fh.field "budgets" C)))
         Run (ux.replay-run (ux.machine Name) (sx.decode-params (fh.field "params" C)) Schedule)
         Disabled (and (cons? Run) (= (hd Run) disabled))
         At (if Disabled none (sx.first-index Check Run))
         Reproduced (and (= (fh.field "schema" C) "fenrir.service.upgrade-counterexample/1")
                         Within (= At Length) (= (length Schedule) Length))
      [Reproduced
       [object ["schema" "fenrir.service.replay/1"]
               ["status" (if Reproduced "reproduced" "not-reproduced")]
               ["qualification" "UNKNOWN"]
               ["file" Path] ["machine" Name] ["check" Check] ["length" Length]
               ["first_failure_at" (if (= At none) null At)]
               ["schedule_within_budget" Within]
               ["schedule_enabled" (not Disabled)]
               ["checks_failing" (if Disabled [] (map (/. F [object ["check" (nth 2 F)] ["at" (hd F)]]) Run))]]]))

(define ux.shortest
  _ [] Best -> Best
  Property [[Property Check Kind Schedule] | Fs] Best ->
    (ux.shortest Property Fs (if (or (= Best none) (< (length Schedule) (length (nth 4 Best)))) [Property Check Kind Schedule] Best))
  Property [_ | Fs] Best -> (ux.shortest Property Fs Best))

\\ Every violated check with its shortest schedule (the first found: layers are explored
\\ in order), grouped by property in the order of sup.properties and, within a property,
\\ shortest first, so that the first entry of a property is that property's shortest.
(define ux.caught
  [] -> []
  [Property | Ps] -> (append (ux.by-length (sx.filter (/. F (= (hd F) Property)) (value ux.*found*)) [])
                             (ux.caught Ps)))

(define ux.by-length
  [] Acc -> (map (/. F [(hd F) F]) Acc)
  [F | Fs] Acc -> (ux.by-length Fs (ux.insert-by-length F Acc)))

(define ux.insert-by-length
  F [] -> [F]
  F [G | Gs] -> [F G | Gs] where (< (length (nth 4 F)) (length (nth 4 G)))
  F [G | Gs] -> [G | (ux.insert-by-length F Gs)])

(define ux.write-counterexamples
  _ _ _ [] -> []
  Name Params Budget [[Property Best] | Cs] ->
    (let Rel (cn "counterexamples/" (cn Name (cn "--" (cn (nth 2 Best) ".json"))))
         Path (cn (value fh.*out*) Rel)
         _ (write-to-file Path (sx.json (ux.counterexample Name Params Budget Best Path)))
         Replay (ux.replay-file Path)
      [[Property (length (nth 4 Best)) (nth 2 Best) Path (hd Replay)] | (ux.write-counterexamples Name Params Budget Cs)]))

\\ ---------- hand traces ----------

(define ux.trace-run
  Machine Params S [] Resps -> [completed (reverse Resps) S]
  Machine Params S [L | Ls] Resps ->
    (if (element? L ((sx.labels-fn Machine) Params S))
        (ux.trace-next Machine Params ((sx.step-fn Machine) L S) Ls Resps)
        [disabled (length Resps)]))

(define ux.trace-next
  Machine Params [ok S Resp] Ls Resps -> (ux.trace-run Machine Params S Ls [Resp | Resps])
  _ _ _ _ Resps -> [disabled (length Resps)])

(define ux.hand-trace
  Machine Tenants T ->
    (let Schedule (map (/. L (ux.decode-label L)) (fh.field "schedule" T))
         Params [Tenants 2 2]
         Run (ux.trace-run Machine Params (sua.initial Tenants) Schedule [])
         Disabled (sx.member-or-null "disabled_at" T)
         Ok (if (= Disabled [])
                (and (= (hd Run) completed)
                     (= (sx.json (map (/. R (ux.response R)) (nth 2 Run))) (sx.json (fh.field "responses" T)))
                     (= (sx.json (ux.state (nth 3 Run))) (sx.json (fh.field "final" T))))
                (= Run [disabled (sx.int Disabled)]))
      [Ok [object ["trace" (fh.field "name" T)] ["agrees" Ok]
                  ["observed" (if (= (hd Run) completed)
                                  [object ["responses" (map (/. R (ux.response R)) (nth 2 Run))] ["final" (ux.state (nth 3 Run))]]
                                  [object ["disabled_at" (nth 2 Run)]])]]]))

\\ ---------- mutants against their predictions ----------

(define ux.mutant-run
  Name Params Budget Cap Predictions Model ->
    (let Machine (ux.machine Name)
         Explored (ux.explore Machine Params Budget Cap (/. X L Y R done))
         Report (ux.machine-report Machine Explored)
         Written (ux.write-counterexamples Name Params Budget (ux.caught (sup.properties)))
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

(define ux.mutant-runs
  [] _ _ _ _ _ Acc -> (reverse Acc)
  [Name | Names] Params Budget Cap Predictions Model Acc ->
    (ux.mutant-runs Names Params Budget Cap Predictions Model [(ux.mutant-run Name Params Budget Cap Predictions Model) | Acc]))

\\ ---------- main ----------

(define ux.scope
  Args -> (let Ns (sx.ints (fh.take 10 Args))
            [(fh.take 3 Ns) [(nth 4 Ns) (nth 5 Ns) (nth 6 Ns) (nth 7 Ns) (nth 8 Ns) (nth 9 Ns)] (nth 10 Ns)]))

(define ux.main
  "explore" ->
    (let Scope (ux.scope (value ux.*args*))
         Params (hd Scope)
         Budget (nth 2 Scope)
         Cap (nth 3 Scope)
         Start (get-time run)
         _ (fh.subdir "counterexamples")
         Hand (json.parse (read-file-as-string (cn (value fh.*root*) "spec/service/upgrade-hand-traces.json")) [[byte-limit 16777216]])
         Model (ux.machine "model")
         HandRuns (map (/. T (ux.hand-trace Model (sx.int (fh.field "tenants" Hand)) T)) (fh.field "traces" Hand))
         HandOk (svcp.all? (/. R (hd R)) HandRuns)
         Explored (ux.explore Model Params Budget Cap (/. X L Y R done))
         ModelReport (ux.machine-report Model Explored)
         ModelOk (and (fh.field "complete" ModelReport) (empty? (fh.field "violations" ModelReport))
                      (= (fh.field "disabled_alphabet_steps" ModelReport) 0))
         \\ the A1 sub-scope: no dispatch, no upgrade step
         A1Budget (fh.take 4 Budget)
         SubExplored (ux.explore Model Params (append A1Budget [0 0]) Cap (/. X L Y R done))
         SubReport (ux.machine-report Model SubExplored)
         A1Explored (sx.explore (smu.machine "model") Params A1Budget Cap false)
         A1Report (sx.machine-report (smu.machine "model") Params A1Budget A1Explored)
         SubOk (and (= (fh.field "product_states" SubReport) (fh.field "product_states" A1Report))
                    (= (fh.field "system_states" SubReport) (fh.field "system_states" A1Report))
                    (= (fh.field "edges" SubReport) (fh.field "edges" A1Report))
                    (fh.field "complete" SubReport) (fh.field "complete" A1Report)
                    (empty? (fh.field "violations" SubReport)) (empty? (fh.field "violations" A1Report)))
         Predictions (json.parse (read-file-as-string (cn (value fh.*root*) "spec/service/upgrade-mutant-predictions.json")) [[byte-limit 1048576]])
         Mutants (ux.mutant-runs (umu.mutant-names) Params Budget Cap Predictions ModelReport [])
         MutantsOk (svcp.all? (/. R (hd R)) Mutants)
         Fired (sx.fired Mutants [])
         NeverFired (sx.filter (/. P (not (element? (intern P) Fired))) (map (/. P (str P)) (sup.properties)))
         ChecksFired (sx.checks-fired Mutants [])
         ChecksNeverFired (sx.filter (/. C (not (element? C ChecksFired))) (map (/. C (nth 2 C)) (sup.checks)))
         Pass (and HandOk ModelOk SubOk MutantsOk (empty? NeverFired))
         Report [object ["schema" "fenrir.harness.service-upgrade/1"]
                        ["status" (if Pass "development-pass" "development-fail")]
                        ["evidence" "bounded exploration passed (development grade) when status is development-pass; not a gate verdict"]
                        ["qualification" "UNKNOWN"]
                        ["harness" "Shen"]
                        ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                        ["contract" "spec/service/UPGRADE.md"]
                        ["params" (ux.params-json Params)]
                        ["budgets" (ux.budget-json Budget)]
                        ["state_cap" Cap]
                        ["hand_traces" [object ["all_agree" HandOk] ["traces" (map (/. R (nth 2 R)) HandRuns)]]]
                        ["model" ModelReport]
                        ["a1_subscope" [object ["agree" SubOk] ["a4_model_without_dispatch_or_upgrade" SubReport] ["a1_model" A1Report]]]
                        ["mutants" (map (/. R (nth 3 R)) Mutants)]
                        ["properties_never_failing_on_a_mutant" NeverFired]
                        ["checks_never_failing_on_a_mutant" ChecksNeverFired]
                        ["seconds" (- (get-time run) Start)]]
         _ (write-to-file (cn (value fh.*out*) "report.json") (sx.json Report))
      (do (output "~A~%" (sx.json Report))
          (shen-jit.exit (if Pass 0 1))))
  "replay" ->
    (let R (ux.replay-file (hd (value ux.*args*)))
      (do (output "~A~%" (sx.json (nth 2 R)))
          (shen-jit.exit (if (hd R) 0 1))))
  Mode -> (do (output "unknown mode ~A~%" Mode) (shen-jit.exit 2)))

(if (trap-error (value ux.*as-library*) (/. E false)) skip (ux.main (value ux.*mode*)))
