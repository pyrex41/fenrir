\\ Fenrir harness, in Shen: Gleipnir's bounded exploration of the accepted-job
\\ contract (spec/service/ACCEPTED_JOB.md, model models/service/accepted-job.shen).
\\ Development evidence only ("bounded exploration passed"); no gate verdict.
\\
\\   shen-jit script harness/service-explore.shen LIBDIR ROOT OUTDIR explore T K D S C R X CAP [sandbox]
\\   shen-jit script harness/service-explore.shen LIBDIR ROOT OUTDIR replay FILE
\\
\\ explore: T tenants, K keys, D payload digests; budgets S submits, C deliveries,
\\ R responses, X crashes per schedule (a mutant's internal steps take no budget:
\\ each consumes a volatile item a submit created); CAP the most product states
\\ admitted before the run is declared truncated.
\\
\\ Breadth-first search over product states [Sys Monitor RemainingBudget]. Two
\\ product states merge only when all three are equal, so identical system states
\\ with different monitor obligations stay apart (plan section 6). Every reachable
\\ product state gets every state predicate, every explored edge every edge
\\ predicate. Layers are explored in order, so the first violation of each check
\\ has a shortest schedule. A step cut off by a budget is counted as a bound hit;
\\ exceeding CAP is truncation, and a truncated run is never a pass.
\\
\\ Run in order: the hand traces (spec/service/hand-traces.json) on the model; the
\\ model, collecting its runtime edges; each mutant and the equivalent control
\\ (harness/service-mutants.shen), retaining a shortest counterexample per violated
\\ property in OUTDIR/counterexamples and replaying each; the JavaScript
\\ implementation (runtime/service/accepted-job.mjs) explored by its own driver
\\ and compared edge for edge with the model.
\\
\\ replay: re-executes the schedule of a retained counterexample from the initial
\\ state, checking every predicate at every step, and exits 0 exactly when the named
\\ check first fails at the recorded step.

(set fh.*lib* (cn (nth 2 (value *argv*)) "/"))
(set fh.*root* (cn (nth 3 (value *argv*)) "/"))
(set fh.*out* (cn (nth 4 (value *argv*)) "/"))
(set sx.*mode* (nth 5 (value *argv*)))
(set sx.*args* (tl (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(map (/. F (load (cn (value fh.*root*) F)))
     ["models/service/accepted-job.shen" "models/service/accepted-job-properties.shen" "harness/service-mutants.shen"])

\\ ---------- canonical observation (ACCEPTED_JOB.md section 3) ----------

(define sx.json
  V -> (json.stringify V [[byte-limit 67108864]]))

(define sx.insert-by-head
  X [] -> [X]
  X [Y | Ys] -> [X Y | Ys] where (<= (hd X) (hd Y))
  X [Y | Ys] -> [Y | (sx.insert-by-head X Ys)])

(define sx.sort-by-head
  [] -> []
  [X | Xs] -> (sx.insert-by-head X (sx.sort-by-head Xs)))

(define sx.receipt
  [receipt T K D R J] -> [T K D R J])

(define sx.status
  pending -> "pending"
  done -> "done"
  failed -> "failed")

(define sx.item
  [accepted Rc] -> ["accepted" (sx.receipt Rc)]
  [conflict T K] -> ["conflict" T K]
  [Tag | Args] -> [(str Tag) | Args])

(define sx.response
  none -> null
  E -> (sx.item E))

(define sx.tenant
  [store Reports Jobs Keys N] ->
    [(sx.sort-by-head Reports)
     (map (/. J [(hd J) (nth 2 J) (sx.status (nth 3 J))]) (sx.sort-by-head Jobs))
     (map (/. E [(hd E) (nth 2 E) (sx.receipt (nth 3 E))]) (sx.sort-by-head Keys))
     N])

(define sx.add-events
  [] Acc -> Acc
  [E | Es] Acc -> (sx.add-events Es (svc.add-event E Acc)))

(define sx.state
  [sys Stores Outbox Trace] ->
    [(map (/. S (sx.tenant S)) Stores)
     (map (/. E (sx.item E)) (append (sx.add-events (smu.events Outbox) []) (smu.items Outbox)))
     (reverse (map (/. E (sx.item E)) Trace))])

(define sx.label
  [submit T K D] -> ["submit" T K D]
  [complete T J Ok] -> ["complete" T J Ok]
  [respond E] -> ["respond" (sx.item E)]
  [crash] -> ["crash"]
  [internal Name | Args] -> ["internal" (str Name) | Args])

(define sx.int
  V -> (json.integer V))

(define sx.decode-event
  ["accepted" [T K D R J]] -> [accepted [receipt (sx.int T) (sx.int K) (sx.int D) (sx.int R) (sx.int J)]]
  ["conflict" T K] -> [conflict (sx.int T) (sx.int K)]
  X -> (error "service: not an event ~S" X))

(define sx.decode-label
  ["submit" T K D] -> [submit (sx.int T) (sx.int K) (sx.int D)]
  ["complete" T J Ok] -> [complete (sx.int T) (sx.int J) Ok]
  ["respond" E] -> [respond (sx.decode-event E)]
  ["crash"] -> [crash]
  ["internal" Name | Args] -> [internal (intern Name) | (map (/. A (sx.int A)) Args)]
  X -> (error "service: not a label ~S" X))

\\ ---------- machines and budgets ----------

(define sx.name
  [machine Name _ _] -> Name)

(define sx.step-fn
  [machine _ Step _] -> Step)

(define sx.labels-fn
  [machine _ _ Labels] -> Labels)

\\ Budget [Submits Deliveries Responses Crashes]; kind 0 takes no budget.
(define sx.kind
  [submit | _] -> 1
  [complete | _] -> 2
  [respond | _] -> 3
  [crash] -> 4
  _ -> 0)

(define sx.spend-at
  1 [0 | _] -> exhausted
  1 [N | Ns] -> [(- N 1) | Ns]
  I [N | Ns] -> (let R (sx.spend-at (- I 1) Ns) (if (= R exhausted) exhausted [N | R])))

(define sx.spend
  0 B -> B
  I B -> (sx.spend-at I B))

(define sx.bump
  1 [N | Ns] -> [(+ N 1) | Ns]
  I [N | Ns] -> [N | (sx.bump (- I 1) Ns)])

(define sx.get
  D K -> (trap-error (shen.<-dict D K) (/. E sx.unset)))

\\ ---------- exploration ----------

(define sx.reset
  Collect ->
    (do (set sx.*visited* (shen.dict 1048576))
        (set sx.*runtime* (shen.dict 262144))
        (set sx.*rb* (shen.dict 1048576))
        (set sx.*edge-keys* (shen.dict (if Collect 1048576 16)))
        (set sx.*lines* (shen.dict (if Collect 1048576 16)))
        (set sx.*encoded* (shen.dict (if Collect 262144 16)))
        (set sx.*collect* Collect)
        (set sx.*states* 0)
        (set sx.*rb-states* 0)
        (set sx.*runtime-states* 0)
        (set sx.*edges* 0)
        (set sx.*bound-hits* [0 0 0 0])
        (set sx.*disabled* 0)
        (set sx.*truncated* false)
        (set sx.*found* [])
        (set sx.*split* [])))

(define sx.path
  P -> (sx.path-from (shen.<-dict (value sx.*visited*) P) []))

(define sx.path-from
  root Acc -> Acc
  [Parent Label] Acc -> (sx.path-from (shen.<-dict (value sx.*visited*) Parent) [Label | Acc]))

(define sx.found?
  _ [] -> false
  Check [[_ Check | _] | _] -> true
  Check [_ | Fs] -> (sx.found? Check Fs))

\\ Record the first violation of each check: [Property Check Kind Schedule].
(define sx.record
  [] _ _ -> done
  [[Property Check] | Vs] Kind Schedule ->
    (do (if (sx.found? Check (value sx.*found*)) done
            (set sx.*found* (append (value sx.*found*) [[Property Check Kind (thaw Schedule)]])))
        (sx.record Vs Kind Schedule)))

(define sx.admit
  [Sys M B] Parent ->
    (let _ (shen.dict-> (value sx.*visited*) [Sys M B] Parent)
         _ (set sx.*states* (+ (value sx.*states*) 1))
         _ (if (= (sx.get (value sx.*runtime*) Sys) sx.unset)
               (do (shen.dict-> (value sx.*runtime*) Sys true) (set sx.*runtime-states* (+ (value sx.*runtime-states*) 1)))
               done)
         Seen (sx.get (value sx.*rb*) [Sys B])
      (if (= Seen sx.unset)
          (do (shen.dict-> (value sx.*rb*) [Sys B] M) (set sx.*rb-states* (+ (value sx.*rb-states*) 1)))
          (if (and (not (= Seen M)) (empty? (value sx.*split*)))
              (set sx.*split* [[Sys Seen B] [Sys M B]])
              done))))

(define sx.encoded
  Sys -> (let E (sx.get (value sx.*encoded*) Sys)
           (if (= E sx.unset)
               (let S (sx.json (sx.state Sys)) (do (shen.dict-> (value sx.*encoded*) Sys S) S))
               E)))

(define sx.collect-edge
  Sys L Sys2 Resp ->
    (if (= (sx.get (value sx.*edge-keys*) [Sys L]) sx.unset)
        (do (shen.dict-> (value sx.*edge-keys*) [Sys L] true)
            (shen.dict-> (value sx.*lines*)
                         (cn "[" (cn (sx.encoded Sys) (cn "," (cn (sx.json (sx.label L)) (cn "," (cn (sx.encoded Sys2) (cn "," (cn (sx.json (sx.response Resp)) "]"))))))))
                         0))
        done))

(define sx.edge
  Machine P L Cap Next ->
    (let Sys (hd P)
         M (nth 2 P)
         I (sx.kind L)
         B (sx.spend I (nth 3 P))
      (if (= B exhausted)
          (do (set sx.*bound-hits* (sx.bump I (value sx.*bound-hits*))) Next)
          (sx.edge-to Machine P L ((sx.step-fn Machine) L Sys) B Cap Next))))

(define sx.edge-to
  _ _ _ disabled _ _ Next -> (do (set sx.*disabled* (+ (value sx.*disabled*) 1)) Next)
  Machine [Sys M B0] L [ok Sys2 Resp] B Cap Next ->
    (let M2 (svcp.monitor-step L Resp M)
         Q [Sys2 M2 B]
         _ (set sx.*edges* (+ (value sx.*edges*) 1))
         _ (sx.record (svcp.edge-violations (sx.step-fn Machine) Sys M L Sys2 Resp) edge
                      (freeze (append (sx.path [Sys M B0]) [L])))
         _ (if (value sx.*collect*) (sx.collect-edge Sys L Sys2 Resp) done)
      (if (= (sx.get (value sx.*visited*) Q) sx.unset)
          (if (< (value sx.*states*) Cap)
              (do (sx.admit Q [[Sys M B0] L]) [Q | Next])
              (do (set sx.*truncated* true) Next))
          Next)))

(define sx.edges
  _ _ [] _ Next -> Next
  Machine P [L | Ls] Cap Next -> (sx.edges Machine P Ls Cap (sx.edge Machine P L Cap Next)))

(define sx.visit
  Machine Params P Cap Next ->
    (let Sys (hd P)
         _ (sx.record (svcp.state-violations (sx.step-fn Machine) (nth 2 P) Sys) state (freeze (sx.path P)))
      (sx.edges Machine P ((sx.labels-fn Machine) Params Sys) Cap Next)))

(define sx.layer
  _ _ [] _ Next -> Next
  Machine Params [P | Ps] Cap Next -> (sx.layer Machine Params Ps Cap (sx.visit Machine Params P Cap Next)))

\\ The depth of the deepest layer.
(define sx.layers
  _ _ [] _ Depth -> (- Depth 1)
  Machine Params Layer Cap Depth -> (sx.layers Machine Params (reverse (sx.layer Machine Params Layer Cap [])) Cap (+ Depth 1)))

(define sx.explore
  Machine Params Budget Cap Collect ->
    (let _ (sx.reset Collect)
         Init [(svc.initial (hd Params)) (svcp.monitor-initial) Budget]
         _ (sx.admit Init root)
         T0 (get-time run)
         Depth (sx.layers Machine Params [Init] Cap 0)
         T1 (get-time run)
      [Depth (- T1 T0)]))

\\ ---------- counterexamples ----------

(define sx.params-json
  [T K D] -> [object ["tenants" T] ["keys" K] ["digests" D]])

(define sx.budget-json
  [S C R X] -> [object ["submits" S] ["deliveries" C] ["responses" R] ["crashes" X]])

\\ A path under the repository root, relative to it.
(define sx.relative
  Path -> (if (fh.starts? (value fh.*root*) Path) (fh.drop (value fh.*root*) Path) Path))

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
            ["replay" (cn "sh harness/run-service-explore.sh replay " (sx.relative Path))]])

(define sx.run-schedule
  Machine Params Schedule -> (sx.run-from (sx.step-fn Machine) (svc.initial (hd Params)) Schedule))

(define sx.run-from
  _ Sys [] -> [Sys]
  Step Sys [L | Ls] -> (sx.run-next Step (Step L Sys) Ls))

(define sx.run-next
  Step [ok Sys _] Ls -> (sx.run-from Step Sys Ls)
  _ _ _ -> [disabled])

\\ The shortest recorded violation of each property, by property.
(define sx.shortest
  _ [] Best -> Best
  Property [[Property Check Kind Schedule] | Fs] Best ->
    (sx.shortest Property Fs (if (or (= Best none) (< (length Schedule) (length (nth 4 Best)))) [Property Check Kind Schedule] Best))
  Property [_ | Fs] Best -> (sx.shortest Property Fs Best))

\\ ---------- replay ----------

\\ Re-execute Schedule from the initial state with every check; [Index Check] for the
\\ first violation of each check, in order, or [disabled Index].
(define sx.replay-run
  Machine Params Schedule ->
    (let Sys (svc.initial (hd Params))
         M (svcp.monitor-initial)
         First (sx.note-first (svcp.state-violations (sx.step-fn Machine) M Sys) 0 [])
      (sx.replay-steps Machine Params Sys M Schedule 1 First)))

(define sx.note-first
  [] _ Acc -> Acc
  [[_ Check] | Vs] I Acc -> (sx.note-first Vs I (if (sx.noted? Check Acc) Acc (append Acc [[I Check]]))))

(define sx.noted?
  _ [] -> false
  Check [[_ Check] | _] -> true
  Check [_ | As] -> (sx.noted? Check As))

(define sx.replay-steps
  _ _ _ _ [] _ First -> First
  Machine Params Sys M [L | Ls] I First ->
    (if (element? L ((sx.labels-fn Machine) Params Sys))
        (sx.replay-next Machine Params Sys M L ((sx.step-fn Machine) L Sys) Ls I First)
        [disabled I]))

(define sx.replay-next
  Machine Params Sys M L [ok Sys2 Resp] Ls I First ->
    (let Step (sx.step-fn Machine)
         M2 (svcp.monitor-step L Resp M)
         F1 (sx.note-first (svcp.edge-violations Step Sys M L Sys2 Resp) I First)
         F2 (sx.note-first (svcp.state-violations Step M2 Sys2) I F1)
      (sx.replay-steps Machine Params Sys2 M2 Ls (+ I 1) F2))
  _ _ _ _ _ _ _ I _ -> [disabled I])

(define sx.first-index
  _ [] -> none
  Check [[I Check] | _] -> I
  Check [_ | Fs] -> (sx.first-index Check Fs))

(define sx.decode-params
  P -> [(sx.int (fh.field "tenants" P)) (sx.int (fh.field "keys" P)) (sx.int (fh.field "digests" P))])

\\ [Reproduced Report] for a counterexample file.
(define sx.replay-file
  Path ->
    (let C (json.parse (read-file-as-string Path) [[byte-limit 16777216]])
         Name (fh.field "machine" C)
         Check (fh.field "check" C)
         Length (sx.int (fh.field "length" C))
         Schedule (map (/. L (sx.decode-label L)) (fh.field "schedule" C))
         Run (sx.replay-run (smu.machine Name) (sx.decode-params (fh.field "params" C)) Schedule)
         Disabled (and (cons? Run) (= (hd Run) disabled))
         At (if Disabled none (sx.first-index Check Run))
         Reproduced (and (= At Length) (= (length Schedule) Length))
      [Reproduced
       [object ["schema" "fenrir.service.replay/1"]
               ["status" (if Reproduced "reproduced" "not-reproduced")]
               ["qualification" "UNKNOWN"]
               ["file" Path] ["machine" Name] ["check" Check] ["length" Length]
               ["first_failure_at" (if (= At none) null At)]
               ["schedule_enabled" (not Disabled)]
               ["checks_failing" (if Disabled [] (map (/. F [object ["check" (nth 2 F)] ["at" (hd F)]]) Run))]]]))

\\ ---------- hand traces ----------

(define sx.trace-run
  Machine Params Sys [] Resps -> [completed (reverse Resps) Sys]
  Machine Params Sys [L | Ls] Resps ->
    (if (element? L ((sx.labels-fn Machine) Params Sys))
        (sx.trace-next Machine Params ((sx.step-fn Machine) L Sys) Ls Resps)
        [disabled (length Resps)]))

(define sx.trace-next
  Machine Params [ok Sys Resp] Ls Resps -> (sx.trace-run Machine Params Sys Ls [Resp | Resps])
  _ _ _ _ Resps -> [disabled (length Resps)])

(define sx.member-or-null
  Key [object | Members] -> (fh.member-in Key Members))

(define sx.hand-trace
  Machine Tenants T ->
    (let Schedule (map (/. L (sx.decode-label L)) (fh.field "schedule" T))
         Params [Tenants 2 2]
         Run (sx.trace-run Machine Params (svc.initial Tenants) Schedule [])
         Disabled (sx.member-or-null "disabled_at" T)
         Ok (if (= Disabled [])
                (and (= (hd Run) completed)
                     (= (sx.json (map (/. R (sx.response R)) (nth 2 Run))) (sx.json (fh.field "responses" T)))
                     (= (sx.json (sx.state (nth 3 Run))) (sx.json (fh.field "final" T))))
                (= Run [disabled (sx.int Disabled)]))
      [Ok [object ["trace" (fh.field "name" T)] ["agrees" Ok]
                  ["observed" (if (= (hd Run) completed)
                                  [object ["responses" (map (/. R (sx.response R)) (nth 2 Run))] ["final" (sx.state (nth 3 Run))]]
                                  [object ["disabled_at" (nth 2 Run)]])]]]))

\\ ---------- the differential check ----------

(define sx.count-js
  [] Tally -> Tally
  [L | Ls] [Lines Matched Missing Dups Samples] ->
    (let Seen (sx.get (value sx.*lines*) L)
      (sx.count-js Ls
        (if (= Seen sx.unset)
            [(+ Lines 1) Matched (+ Missing 1) Dups (if (< (length Samples) 3) [L | Samples] Samples)]
            (if (= Seen 0)
                (do (shen.dict-> (value sx.*lines*) L 1) [(+ Lines 1) (+ Matched 1) Missing Dups Samples])
                [(+ Lines 1) Matched Missing (+ Dups 1) Samples])))))

(define sx.nonempty
  [] -> []
  ["" | Ls] -> (sx.nonempty Ls)
  [L | Ls] -> [L | (sx.nonempty Ls)])

(define sx.unmatched-model
  -> (shen.dict-fold (/. K V Acc (if (= V 0) [K | Acc] Acc)) (value sx.*lines*) []))

(define sx.differential
  [T K D] [S C R X] Cap Sandbox ->
    (let Out (cn (value fh.*out*) "js-edges.jsonl")
         Summary (cn (value fh.*out*) "js-summary.json")
         Args (map (/. N (str N)) [T K D S C R X Cap])
         T0 (get-time run)
         Run (process.run "node" (fh.node-arguments "runtime/service/explore-graph.mjs" (append Args [Out Summary])
                                                    ["runtime/service"] (value fh.*out*) Sandbox)
                          (buffer.from-string "") [[timeout 600000] [stdout-limit 4194304] [stderr-limit 4194304]])
         Ran (and (= (hd Run) ok) (process.success? (hd (tl Run))))
         Js (if Ran (json.parse (read-file-as-string Summary) [[byte-limit 1048576]]) [])
         Lines (if Ran (sx.nonempty (fh.lines (read-file-as-string Out))) [])
         Tally (sx.count-js Lines [0 0 0 0 []])
         ModelEdges (shen.dict-count (value sx.*lines*))
         Unmatched (sx.unmatched-model)
         T1 (get-time run)
         Agree (and Ran
                    (= (fh.field "truncated" Js) false)
                    (= (nth 1 Tally) ModelEdges)
                    (= (nth 2 Tally) ModelEdges)
                    (= (nth 3 Tally) 0)
                    (= (nth 4 Tally) 0)
                    (= (sx.int (fh.field "runtime_edges" Js)) ModelEdges)
                    (= (sx.int (fh.field "runtime_states" Js)) (value sx.*runtime-states*))
                    (= (sx.int (fh.field "states" Js)) (value sx.*rb-states*)))
      [Agree
       [object ["agree" Agree]
               ["implementation" "runtime/service/accepted-job.mjs"]
               ["driver" "runtime/service/explore-graph.mjs"]
               ["implementation_sandboxed" Sandbox]
               ["implementation_ran" Ran]
               ["implementation_summary" Js]
               ["model_runtime_edges" ModelEdges]
               ["model_runtime_states" (value sx.*runtime-states*)]
               ["model_states_without_monitor" (value sx.*rb-states*)]
               ["implementation_edge_lines" (nth 1 Tally)]
               ["matched" (nth 2 Tally)]
               ["implementation_only" (nth 3 Tally)]
               ["implementation_duplicates" (nth 4 Tally)]
               ["model_only" (length Unmatched)]
               ["samples_implementation_only" (nth 5 Tally)]
               ["samples_model_only" (fh.take 3 Unmatched)]
               ["seconds" (- T1 T0)]
               ["stderr" (if (= (hd Run) ok) (fh.take-string 2000 (buffer.string (process.error-bytes (hd (tl Run))))) "did not run")]]]))

\\ ---------- one machine's exploration, as a report ----------

(define sx.check-json
  [Property Check Kind Schedule] ->
    [object ["property" (str Property)] ["check" Check] ["kind" (str Kind)] ["length" (length Schedule)]
            ["schedule" (map (/. L (sx.label L)) Schedule)]])

(define sx.split-json
  [] -> null
  [A B] -> [object ["system_state" (sx.state (hd A))]
                   ["budget" (sx.budget-json (nth 3 A))]
                   ["schedule_a" (map (/. L (sx.label L)) (sx.path A))]
                   ["monitor_a" (map (/. I (sx.item I)) (nth 2 A))]
                   ["schedule_b" (map (/. L (sx.label L)) (sx.path B))]
                   ["monitor_b" (map (/. I (sx.item I)) (nth 2 B))]])

(define sx.machine-report
  Machine Params Budget [Depth Seconds] ->
    [object ["machine" (sx.name Machine)]
            ["complete" (not (value sx.*truncated*))]
            ["truncated" (value sx.*truncated*)]
            ["product_states" (value sx.*states*)]
            ["states_without_monitor" (value sx.*rb-states*)]
            ["system_states" (value sx.*runtime-states*)]
            ["edges" (value sx.*edges*)]
            ["max_depth" Depth]
            ["bound_hits" [object ["submits" (nth 1 (value sx.*bound-hits*))] ["deliveries" (nth 2 (value sx.*bound-hits*))]
                                  ["responses" (nth 3 (value sx.*bound-hits*))] ["crashes" (nth 4 (value sx.*bound-hits*))]]]
            ["disabled_alphabet_steps" (value sx.*disabled*)]
            ["violations" (map (/. F (sx.check-json F)) (value sx.*found*))]
            ["seconds" Seconds]])

\\ ---------- mutants against their predictions ----------

(define sx.caught
  [] -> []
  [Property | Ps] -> (let Best (sx.shortest Property (value sx.*found*) none)
                       (if (= Best none) (sx.caught Ps) [[Property Best] | (sx.caught Ps)])))

(define sx.write-counterexamples
  _ _ _ [] -> []
  Name Params Budget [[Property Best] | Cs] ->
    (let Rel (cn "counterexamples/" (cn Name (cn "--" (cn (str Property) ".json"))))
         Path (cn (value fh.*out*) Rel)
         _ (write-to-file Path (sx.json (sx.counterexample Name Params Budget Best Path)))
         Replay (sx.replay-file Path)
      [[Property (length (nth 4 Best)) (nth 2 Best) Path (hd Replay)] | (sx.write-counterexamples Name Params Budget Cs)]))

(define sx.lookup-caught
  _ [] -> none
  Property [[Property | Rest] | _] -> [Property | Rest]
  Property [_ | Cs] -> (sx.lookup-caught Property Cs))

(define sx.prediction-check
  Written [object | Members] ->
    (let Expected (fh.assoc "expected" Members)
         Also (fh.assoc "also" Members)
         Clean (fh.assoc "clean" Members)
         ExpectedNames (map (/. M (hd M)) (tl Expected))
         Missing (sx.filter (/. P (= (sx.lookup-caught (intern P) Written) none)) ExpectedNames)
         Mismatch (sx.length-mismatches (append (tl Expected) (tl Also)) Written)
         Unpredicted (sx.unpredicted Written (append ExpectedNames (map (/. M (hd M)) (tl Also))) (map (/. S S) Clean))
         CleanBroken (sx.filter (/. P (not (= (sx.lookup-caught (intern P) Written) none))) Clean)
      [Missing Mismatch Unpredicted CleanBroken]))

(define sx.filter
  _ [] -> []
  P [X | Xs] -> (if (P X) [X | (sx.filter P Xs)] (sx.filter P Xs)))

(define sx.length-mismatches
  [] _ -> []
  [[P Len] | Ps] Written ->
    (let C (sx.lookup-caught (intern P) Written)
      (if (or (= C none) (= (nth 2 C) (sx.int Len)))
          (sx.length-mismatches Ps Written)
          [[object ["property" P] ["predicted_length" Len] ["actual_length" (nth 2 C)]] | (sx.length-mismatches Ps Written)])))

(define sx.unpredicted
  [] _ _ -> []
  [[P | _] | Ws] Predicted Clean ->
    (if (or (element? (str P) Predicted) (element? (str P) Clean))
        (sx.unpredicted Ws Predicted Clean)
        [(str P) | (sx.unpredicted Ws Predicted Clean)]))

(define sx.written-json
  [Property Len Check Path Reproduced] ->
    [object ["property" (str Property)] ["length" Len] ["check" Check] ["counterexample" (sx.relative Path)] ["replay_reproduced" Reproduced]])

(define sx.mutant-run
  Name Params Budget Cap Predictions Model ->
    (let Machine (smu.machine Name)
         Explored (sx.explore Machine Params Budget Cap false)
         Report (sx.machine-report Machine Params Budget Explored)
         Written (sx.write-counterexamples Name Params Budget (sx.caught (svcp.properties)))
         Prediction (sx.prediction-check Written (fh.field Name (fh.field "mutants" Predictions)))
         Replayed (svcp.all? (/. W (nth 5 W)) Written)
         Control (= Name "equivalent-control")
         SameGraph (and (= (fh.field "product_states" Report) (fh.field "product_states" Model))
                        (= (fh.field "edges" Report) (fh.field "edges" Model)))
         Pass (if Control
                  (and (empty? Written) SameGraph (fh.field "complete" Report))
                  (and (empty? (hd Prediction)) Replayed (not (empty? Written))))
      [Pass Written
       [object ["mutant" Name] ["pass" Pass]
               ["caught_by" (map (/. W (sx.written-json W)) Written)]
               ["expected_properties_not_caught" (hd Prediction)]
               ["length_differs_from_prediction" (nth 2 Prediction)]
               ["caught_by_unpredicted_property" (nth 3 Prediction)]
               ["predicted_clean_but_caught" (nth 4 Prediction)]
               ["same_graph_as_model" SameGraph]
               ["exploration" Report]]]))

(define sx.mutant-runs
  [] _ _ _ _ _ Acc -> (reverse Acc)
  [Name | Names] Params Budget Cap Predictions Model Acc ->
    (sx.mutant-runs Names Params Budget Cap Predictions Model [(sx.mutant-run Name Params Budget Cap Predictions Model) | Acc]))

\\ Every property and every check that some mutant made fail.
(define sx.fired
  [] Acc -> Acc
  [[_ Written _] | Rs] Acc -> (sx.fired Rs (sx.fired-in Written Acc)))

(define sx.fired-in
  [] Acc -> Acc
  [[Property _ Check _ _] | Ws] Acc -> (sx.fired-in Ws (if (element? Property Acc) Acc [Property | Acc])))

\\ Every check that failed anywhere in any mutant's exploration, not only the shortest per property.
(define sx.checks-fired
  [] Acc -> Acc
  [[_ _ Report] | Rs] Acc ->
    (sx.checks-fired Rs (sx.fired-checks (fh.field "violations" (fh.field "exploration" Report)) Acc)))

(define sx.fired-checks
  [] Acc -> Acc
  [V | Vs] Acc -> (sx.fired-checks Vs (let C (fh.field "check" V) (if (element? C Acc) Acc [C | Acc]))))

\\ ---------- main ----------

(define sx.ints
  Args -> (map (/. A (tc0.i64.small A)) Args))

(define sx.main
  "explore" ->
    (let Args (value sx.*args*)
         Ns (sx.ints (fh.take 8 Args))
         Params (fh.take 3 Ns)
         Budget [(nth 4 Ns) (nth 5 Ns) (nth 6 Ns) (nth 7 Ns)]
         Cap (nth 8 Ns)
         Sandbox (element? "sandbox" Args)
         Start (get-time run)
         _ (fh.subdir "counterexamples")
         Hand (json.parse (read-file-as-string (cn (value fh.*root*) "spec/service/hand-traces.json")) [[byte-limit 16777216]])
         Model (smu.machine "model")
         HandRuns (map (/. T (sx.hand-trace Model (sx.int (fh.field "tenants" Hand)) T)) (fh.field "traces" Hand))
         HandOk (svcp.all? (/. R (hd R)) HandRuns)
         Explored (sx.explore Model Params Budget Cap true)
         ModelReport (sx.machine-report Model Params Budget Explored)
         Split (sx.split-json (value sx.*split*))
         ModelOk (and (fh.field "complete" ModelReport) (empty? (fh.field "violations" ModelReport))
                      (= (fh.field "disabled_alphabet_steps" ModelReport) 0))
         Differential (sx.differential Params Budget Cap Sandbox)
         Predictions (json.parse (read-file-as-string (cn (value fh.*root*) "spec/service/mutant-predictions.json")) [[byte-limit 1048576]])
         Mutants (sx.mutant-runs (smu.mutant-names) Params Budget Cap Predictions ModelReport [])
         MutantsOk (svcp.all? (/. R (hd R)) Mutants)
         Fired (sx.fired Mutants [])
         NeverFired (sx.filter (/. P (not (element? (intern P) Fired))) (map (/. P (str P)) (svcp.properties)))
         ChecksFired (sx.checks-fired Mutants [])
         ChecksNeverFired (sx.filter (/. C (not (element? C ChecksFired))) (map (/. C (nth 2 C)) (svcp.checks)))
         Pass (and HandOk ModelOk (hd Differential) MutantsOk (empty? NeverFired))
         Report [object ["schema" "fenrir.harness.service-explore/1"]
                        ["status" (if Pass "development-pass" "development-fail")]
                        ["evidence" "bounded exploration passed (development grade) when status is development-pass; not a gate verdict"]
                        ["qualification" "UNKNOWN"]
                        ["harness" "Shen"]
                        ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                        ["contract" "spec/service/ACCEPTED_JOB.md"]
                        ["params" (sx.params-json Params)]
                        ["budgets" (sx.budget-json Budget)]
                        ["state_cap" Cap]
                        ["hand_traces" [object ["all_agree" HandOk] ["traces" (map (/. R (nth 2 R)) HandRuns)]]]
                        ["model" ModelReport]
                        ["monitor_split_witness" Split]
                        ["differential" (nth 2 Differential)]
                        ["mutants" (map (/. R (nth 3 R)) Mutants)]
                        ["properties_never_failing_on_a_mutant" NeverFired]
                        ["checks_never_failing_on_a_mutant" ChecksNeverFired]
                        ["seconds" (- (get-time run) Start)]]
         _ (write-to-file (cn (value fh.*out*) "report.json") (sx.json Report))
      (do (output "~A~%" (sx.json Report))
          (shen-jit.exit (if Pass 0 1))))
  "replay" ->
    (let R (sx.replay-file (hd (value sx.*args*)))
      (do (output "~A~%" (sx.json (nth 2 R)))
          (shen-jit.exit (if (hd R) 0 1))))
  Mode -> (do (output "unknown mode ~A~%" Mode) (shen-jit.exit 2)))

\\ harness/service-fenrir.shen (stage A2) loads this file for its definitions and sets
\\ sx.*as-library* first; run on its own, this is the A1 check.
(if (trap-error (value sx.*as-library*) (/. E false)) skip (sx.main (value sx.*mode*)))
