\\ Fenrir harness, in Shen: the commuting obligation of TC1-C1 (spec/tc1/CONCURRENCY.md
\\ section 9, amendment section 14) on the exhaustive-small scope, grammar G of
\\ tools/tc1/task-enumerate.mjs.
\\
\\ For every program of G this program explores, on the Shen model, ALL reference
\\ schedules (any Runnable task at every step) and ALL production schedules (any Runnable
\\ task after a scheduling point, else the same task), with state deduplication keyed on
\\ the full machine state together with the observation so far, and computes the set of
\\ observations (section 9: footer, task sequences, channel sequences) each scheduler
\\ reaches. The obligation holds on a program when the two sets are equal; that the
\\ production set is included in the reference set is checked as well, not assumed.
\\ Two deliberately broken variants must each fail it on some program:
\\   send-not-a-point   the production scheduler does not switch after a send
\\   eager-cancel       cancellation is delivered at any step of normal control (so a pure
\\                      step reads another task's request); both schedulers explore it
\\ Then the JavaScript implementation, sandboxed, runs one witness schedule for every
\\ reference observation class of every program and must agree with the model, replayed
\\ here, step for step. Its nine injected defects run under the first witness of each
\\ program only (a sample, to bound the traces); their tally is reported, not required:
\\ detection of every defect is required of tc1-tasks.shen, on the hand fixtures.
\\ Development evidence, bounded exploration; no qualification verdict.
\\
\\   shen-jit script harness/tc1-task-explore.shen LIBDIR ROOT OUTDIR [sandbox] [limit N]
\\
\\ OUTDIR must exist and be empty. `limit N` explores only the first N programs, for
\\ development; the scope is then incomplete and the run cannot pass.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*options* (tl (tl (tl (tl (value *argv*))))))
(set fh.*sandbox* (element? "sandbox" (value fh.*options*)))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-task-common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))

(define fh.option-limit
  ["limit" N | _] -> (tc0.i64.small N)
  [_ | Rest] -> (fh.option-limit Rest)
  [] -> -1)
(set fh.*limit* (fh.option-limit (value fh.*options*)))

\\ Bounds. Crossing either truncates the program's exploration, which then cannot pass.
(set fh.*depth-bound* 400)
(define fh.option-states
  ["states" N | _] -> (tc0.i64.small N)
  [_ | Rest] -> (fh.option-states Rest)
  [] -> 2000000)
\\ `states N` lowers the per-exploration state bound, to demonstrate truncation.
(set fh.*state-bound* (fh.option-states (value fh.*options*)))

\\ ---------- the size of the scope, derived here from the grammar ----------
\\ Sequences of length Lo..Hi over an alphabet of N actions.
(define fh.sequences
  N Lo Hi -> 0 where (> Lo Hi)
  N Lo Hi -> (+ (fh.power N Lo) (fh.sequences N (+ Lo 1) Hi)))

(define fh.power
  N 0 -> 1
  N K -> (* N (fh.power N (- K 1))))

\\ one-channel: 2 capacities x child 1 (6 actions, 1-2) x child 2 (absent or 1 of 5) x root (0-1 of 5);
\\ two-channel: child 1 (8 actions, 1-2) x root (0-1 of 7).
(define fh.g-programs
  -> (+ (* 2 (* (fh.sequences 6 1 2) (* (+ 1 (fh.sequences 5 1 1)) (fh.sequences 5 0 1))))
        (* (fh.sequences 8 1 2) (fh.sequences 7 0 1))))

\\ ---------- exact counts: lists of base 10^9 limbs, least significant first ----------

(define fh.big-add
  [] B -> B
  A [] -> A
  [A | As] [B | Bs] -> (fh.big-carry (+ A B) (fh.big-add As Bs)))

(define fh.big-carry
  S Rest -> [(- S 1000000000) | (fh.big-add Rest [1])] where (>= S 1000000000)
  S Rest -> [S | Rest])

(define fh.slen
  "" -> 0
  (@s _ S) -> (+ 1 (fh.slen S)))

(define fh.pad9
  S -> S where (>= (fh.slen S) 9)
  S -> (fh.pad9 (cn "0" S)))

(define fh.big-string
  [] -> "0"
  Limbs -> (fh.big-digits (reverse Limbs) true))

(define fh.big-digits
  [] _ -> ""
  [L | Ls] true -> (cn (str L) (fh.big-digits Ls false))
  [L | Ls] false -> (cn (fh.pad9 (str L)) (fh.big-digits Ls false)))

\\ ---------- a hash table of explored nodes ----------
\\ Entries carry the generation of the exploration that made them, so a new exploration
\\ never sees an old one's entries and the table is never cleared. Keys are compared with
\\ =, structurally: a hash collision never merges two nodes.

(set fh.*buckets* 1048573)
(set fh.*table* (vector (value fh.*buckets*)))
(define fh.fill
  V I N -> V where (> I N)
  V I N -> (do (vector-> V I []) (fh.fill V (+ I 1) N)))
(fh.fill (value fh.*table*) 1 (value fh.*buckets*))
(set fh.*gen* 0)

(define fh.slot
  Key -> (+ 1 (hash Key (value fh.*buckets*))))

(define fh.bucket-find
  G Key [] -> none
  G Key [[G Key V] | _] -> V
  G Key [_ | Es] -> (fh.bucket-find G Key Es))

(define fh.table-get
  Key -> (fh.bucket-find (value fh.*gen*) Key (<-vector (value fh.*table*) (fh.slot Key))))

(define fh.fresh-entries
  G [] -> []
  G [[G K V] | Es] -> [[G K V] | (fh.fresh-entries G Es)]
  G [_ | Es] -> (fh.fresh-entries G Es))

(define fh.table-put
  Key V -> (let I (fh.slot Key)
                G (value fh.*gen*)
             (vector-> (value fh.*table*) I [[G Key V] | (fh.fresh-entries G (<-vector (value fh.*table*) I))])))

\\ ---------- observations (section 9) ----------
\\ An observation so far is a list of [Process ReversedEvents], ordered by process name:
\\ "t<id>" for a task, "c<id>" for a channel. An event belongs to its task, to the channel
\\ it names, and a Spawn also to its child.

(define fh.channel-event?
  Kind -> (element? Kind [channel send sent send-closed send-wait send-removed receive received end receive-wait receive-removed close]))

(define fh.processes
  [spawn T C | _] -> [(cn "t" T) (cn "t" C)]
  [Kind T C | _] -> [(cn "t" T) (cn "c" C)] where (fh.channel-event? Kind)
  [Kind T | _] -> [(cn "t" T)])

(define fh.obs-put
  [] K E -> [[K [E]]]
  [[K Es] | Rest] K E -> [[K [E | Es]] | Rest]
  [[K2 Es] | Rest] K E -> [[K [E]] [K2 Es] | Rest] where (fh.string<? K K2)
  [P | Rest] K E -> [P | (fh.obs-put Rest K E)])

(define fh.obs-put-all
  Obs [] E -> Obs
  Obs [K | Ks] E -> (fh.obs-put-all (fh.obs-put Obs K E) Ks E))

(define fh.obs-add
  Obs [] -> Obs
  Obs [E | Es] -> (fh.obs-add (fh.obs-put-all Obs (fh.processes E) E) Es))

\\ ---------- the explored modes ----------
\\ reference, production, send-not-a-point (production without a switch after send),
\\ eager-reference and eager-production (the eager-cancel variant).
(define fh.production-mode?
  Mode -> (element? Mode [production send-not-a-point eager-production]))

(define fh.eager-mode?
  Mode -> (element? Mode [eager-reference eager-production]))

\\ A step at which the contract delivers a pending cancellation anyway (section 6).
(define fh.delivery-point?
  [start _] _ -> true
  [evaluate [scope | _] _] _ -> true
  [ready _ Op | _] _ -> (tm.runtime-op? Op)
  [pending | _] _ -> true
  [wait | _] _ -> true
  _ _ -> false)

(define fh.normal-control?
  [value _] [[scope-frame | _] | _] -> false
  [evaluate | _] _ -> true
  [value | _] _ -> true
  [ready | _] _ -> true
  _ _ -> false)

\\ The broken variant eager-cancel: a pending request is delivered at any step taken in
\\ normal control, as TC0-CANCEL's "next Run" would; such a step is not a scheduling point.
(define fh.eager-step
  Prog M Id -> (let T (tm.task Id M)
                    C (tm.control T)
                 (if (and (tm.due? T) (fh.normal-control? C (tm.frames T)) (not (fh.delivery-point? C (tm.frames T))))
                     (let R (tm.deliver M T [machine eager eager])
                       [step (hd (tl R)) [machine eager eager] (nth 4 R) false])
                     (tm.step Prog M Id))))

(define fh.sends?
  [ready _ send | _] -> true
  _ -> false)

(define fh.initial-node
  Mode M -> (if (fh.production-mode? Mode) [M [] none true] [M []]))

(define fh.node-state
  [M | _] -> M)

(define fh.node-obs
  [_ Obs | _] -> Obs)

(define fh.enabled
  Mode [M _ Cur Sw] -> (if Sw (tm.runnable M) [Cur])
  Mode [M _] -> (tm.runnable M))

(define fh.successor
  Mode Prog [M Obs | Rest] Id ->
    (let Before (tm.control (tm.task Id M))
         R (if (fh.eager-mode? Mode) (fh.eager-step Prog M Id) (tm.step Prog M Id))
         M2 (hd (tl R))
         Obs2 (fh.obs-add Obs (nth 4 R))
         Point (and (nth 5 R) (not (and (= Mode send-not-a-point) (fh.sends? Before))))
      (if (fh.production-mode? Mode)
          [M2 Obs2 Id (or Point (not (element? Id (tm.runnable M2))))]
          [M2 Obs2])))

\\ ---------- depth-first exploration with memoized schedule counts ----------

(define fh.has-observation?
  O [] -> false
  O [[O _] | _] -> true
  O [_ | Os] -> (fh.has-observation? O Os))

(define fh.record
  O Path -> (if (fh.has-observation? O (value fh.*observations*)) true
                (set fh.*observations* [[O (reverse Path)] | (value fh.*observations*)])))

\\ The number of complete schedules from Node, as a big count; [] when truncated.
(define fh.visit
  Mode Prog Node Path Depth ->
    (let Found (fh.table-get Node)
      (if (= Found none)
          (let Count (fh.expand Mode Prog Node Path Depth)
               Stored (fh.table-put Node Count)
            Count)
          Found)))

(define fh.expand
  Mode Prog Node Path Depth ->
    (let M (fh.node-state Node)
         Footer (fh.task-footer M)
         Counted (set fh.*states* (+ 1 (value fh.*states*)))
      (if (not (= Footer []))
          (do (fh.record [Footer (fh.node-obs Node)] Path) [1])
          (if (or (>= Depth (value fh.*depth-bound*)) (> (value fh.*states*) (value fh.*state-bound*)))
              (do (set fh.*truncated* true) [])
              (fh.sum-successors Mode Prog Node (fh.enabled Mode Node) Path Depth [])))))

(define fh.sum-successors
  Mode Prog Node [] Path Depth Acc -> Acc
  Mode Prog Node [Id | Ids] Path Depth Acc ->
    (let Next (fh.successor Mode Prog Node Id)
         Edge (set fh.*edges* (+ 1 (value fh.*edges*)))
         C (fh.visit Mode Prog Next [Id | Path] (+ Depth 1))
      (fh.sum-successors Mode Prog Node Ids Path Depth (fh.big-add Acc C))))

\\ [Schedules States Edges Truncated Observations], Observations a list of [O Witness].
(define fh.explore
  Mode Prog M0 ->
    (do (set fh.*gen* (+ 1 (value fh.*gen*)))
        (set fh.*states* 0)
        (set fh.*edges* 0)
        (set fh.*truncated* false)
        (set fh.*observations* [])
        (let Count (fh.visit Mode Prog (fh.initial-node Mode M0) [] 0)
          [Count (value fh.*states*) (value fh.*edges*) (value fh.*truncated*) (value fh.*observations*)])))

(define fh.subset?
  [] _ -> true
  [[O _] | Os] Ps -> (and (fh.has-observation? O Ps) (fh.subset? Os Ps)))

(define fh.same-set?
  A B -> (and (fh.subset? A B) (fh.subset? B A)))

\\ ---------- one program ----------

\\ [Name Template R P SendNotAPoint EagerReference EagerProduction], each an exploration result.
(define fh.explore-program
  Row -> (let Program (fh.task-program (fh.field "program" Row))
              Prog (hd Program)
              M0 (hd (tl Program))
           [(fh.field "name" Row) (fh.field "template" Row)
            (fh.explore reference Prog M0) (fh.explore production Prog M0) (fh.explore send-not-a-point Prog M0)
            (fh.explore eager-reference Prog M0) (fh.explore eager-production Prog M0)]))

\\ ---------- the whole scope ----------
\\ Tally, kept as a property list of [Key Value]: counts are integers, schedule counts big.

(define fh.tget
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.tget Key Rest)
  Key [] -> 0)

(define fh.tset
  Key V [] -> [[Key V]]
  Key V [[Key _] | Rest] -> [[Key V] | Rest]
  Key V [P | Rest] -> [P | (fh.tset Key V Rest)])

(define fh.tadd
  Key N T -> (fh.tset Key (+ (fh.tget Key T) N) T))

(define fh.tbig
  Key N T -> (fh.tset Key (fh.big-add (let X (fh.tget Key T) (if (= X 0) [] X)) N) T))

(define fh.tmax
  Key N T -> (if (> N (fh.tget Key T)) (fh.tset Key N T) T))

\\ Keep the first few examples under Key.
(define fh.texample
  Key X T -> (let L (fh.tget Key T) (if (and (cons? L) (>= (length L) 5)) T (fh.tset Key (append (if (= L 0) [] L) [X]) T))))

(define fh.add-exploration
  Prefix [Count States Edges Truncated Obs] T ->
    (fh.tmax (cn Prefix "_max_states") States
      (fh.tbig (cn Prefix "_schedules") Count
        (fh.tadd (cn Prefix "_states") States
          (fh.tadd (cn Prefix "_edges") Edges
            (fh.tadd (cn Prefix "_observation_classes") (length Obs)
              (fh.tadd (cn Prefix "_truncated") (if Truncated 1 0) T)))))))

(define fh.example
  X -> [object ["program" (hd X)] ["template" (hd (tl X))]])

\\ Fold one program's explorations into the tally.
(define fh.tally-program
  [Name Template R P N ER EP] T ->
    (let Equal (fh.same-set? (nth 5 R) (nth 5 P))
         T1 (fh.add-exploration "production" P (fh.add-exploration "reference" R (fh.tadd "programs" 1 T)))
         T2 (if Equal (fh.tadd "programs_equal" 1 T1) (fh.texample "unequal" (fh.example [Name Template]) T1))
         T3 (if (fh.subset? (nth 5 P) (nth 5 R)) (fh.tadd "programs_production_subset" 1 T2) T2)
         T4 (if (fh.same-set? (nth 5 R) (nth 5 N)) T3 (fh.texample "send_not_a_point_examples" (fh.example [Name Template]) (fh.tadd "send_not_a_point_unequal" 1 T3)))
         T5 (if (fh.subset? (nth 5 N) (nth 5 R)) (fh.tadd "send_not_a_point_subset" 1 T4) T4)
         T6 (if (fh.same-set? (nth 5 ER) (nth 5 EP)) T5 (fh.texample "eager_cancel_examples" (fh.example [Name Template]) (fh.tadd "eager_cancel_unequal" 1 T5)))
         T7 (if (fh.subset? (nth 5 EP) (nth 5 ER)) (fh.tadd "eager_cancel_subset" 1 T6) T6)
         T8 (fh.tadd "variants_truncated" (+ (if (nth 4 N) 1 0) (+ (if (nth 4 ER) 1 0) (if (nth 4 EP) 1 0))) T7)
      T8))

\\ One witness line per reference observation class: the schedule that first reached it.
(define fh.write-witnesses
  Stream Name [] I -> I
  Stream Name [[O Choices] | Os] I ->
    (do (pr (json.stringify [object ["name" Name] ["schedule" (cn "obs-" (str I))] ["choices" Choices]] [[byte-limit 16777216]]) Stream)
        (pr "c#10;" Stream)
        (fh.write-witnesses Stream Name Os (+ I 1))))

(define fh.explore-rows
  [] Stream Done T -> [Done T]
  _ Stream Done T -> [Done T] where (= Done (value fh.*limit*))
  [Row | Rows] Stream Done T ->
    (let X (fh.explore-program Row)
         Written (fh.write-witnesses Stream (hd X) (reverse (nth 5 (nth 3 X))) 0)
      (fh.explore-rows Rows Stream (+ Done 1) (fh.tally-program X T))))

(define fh.chunk-rows
  Prefix I -> (let View (buffer.from-string (read-file-as-string (cn (value fh.*out*) (cn Prefix (cn (str I) ".jsonl")))))
                (fh.json-lines View 0 (buffer.length View) [])))

(define fh.explore-chunks
  I Chunks Stream Done T -> [Done T] where (>= I Chunks)
  I Chunks Stream Done T -> [Done T] where (= Done (value fh.*limit*))
  I Chunks Stream Done T ->
    (let R (fh.explore-rows (fh.chunk-rows "programs-" I) Stream Done T)
      (fh.explore-chunks (+ I 1) Chunks Stream (hd R) (hd (tl R)))))

\\ ---------- model against implementation on the witnesses ----------

\\ The program named Name, walking forward through the programs in order: [Program Rest].
(define fh.program-named
  Name [] -> (error "harness: witness for unknown program ~A" Name)
  Name [Row | Rows] -> [(fh.field "program" Row) [Row | Rows]] where (= Name (fh.field "name" Row))
  Name [_ | Rows] -> (fh.program-named Name Rows))

(define fh.compare-witnesses
  [] Programs Choices T -> [Programs T]
  [Run | Runs] Programs [W | Ws] T ->
    (let Found (fh.program-named (fh.field "name" Run) Programs)
         Program (fh.task-program (hd Found))
         Model (fh.task-run (hd Program) (hd (tl Program)) (fh.field "choices" W) 1000)
         Agree (and (= (fh.field "name" Run) (fh.field "name" W)) (= (fh.field "schedule" Run) (fh.field "schedule" W))
                    (element? (hd Model) ["Completed" "Deadlock"]) (fh.task-same? Model (fh.field "candidate" Run)))
         T2 (fh.tadd "witness_steps" (length (hd (tl (tl Model)))) (fh.tadd "witnesses_compared" 1 T))
         T3 (if Agree (fh.tadd "witnesses_agreeing" 1 (fh.task-tally (tl (fh.field "mutants" Run)) Model T2))
                (fh.texample "witness_disagreements" [object ["program" (fh.field "name" Run)] ["schedule" (fh.field "schedule" Run)]
                                                             ["first_divergent_epoch" (fh.task-divergence (hd (tl (tl Model))) (fh.field "steps" (fh.field "candidate" Run)) 0)]] T2))
      (fh.compare-witnesses Runs (hd (tl Found)) Ws T3)))

\\ Defect tallies live in the tally under their own names; fh.task-tally needs them as a list.
(define fh.compare-witness-chunks
  I Chunks Programs Witnesses T -> T where (>= I Chunks)
  I Chunks Programs Witnesses T ->
    (let Runs (fh.chunk-rows "witness-runs-" I)
         R (fh.compare-witnesses Runs Programs (fh.take (length Runs) Witnesses) T)
      (fh.compare-witness-chunks (+ I 1) Chunks (hd R) (fh.drop-n (length Runs) Witnesses) (hd (tl R)))))

(define fh.drop-n
  0 L -> L
  _ [] -> []
  N [_ | L] -> (fh.drop-n (- N 1) L))

(define fh.all-programs
  I Chunks Acc -> Acc where (>= I Chunks)
  I Chunks Acc -> (fh.all-programs (+ I 1) Chunks (append Acc (fh.chunk-rows "programs-" I))))

(define fh.defects-of
  T -> (fh.keep (/. P (element? (hd P) (fh.task-defect-names))) T))

(define fh.run-node
  Mode Seconds -> (let R (process.run "node" (fh.node-arguments "tools/tc1/run-task-explore.mjs" [Mode (value fh.*out*)] ["runtime/tc1" "tools/tc1" (value fh.*out*)] (value fh.*out*) (value fh.*sandbox*))
                                      (buffer.from-string "") [[timeout (* Seconds 1000)]])
                    (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript ~A step did not complete" Mode))))

(define fh.stat
  Key T -> (str (fh.tget Key T)))

(define fh.bigstat
  Key T -> (fh.big-string (let X (fh.tget Key T) (if (= X 0) [] X))))

(define fh.list-stat
  Key T -> (let X (fh.tget Key T) (if (= X 0) [] X)))

(define fh.main
  -> (let Enumerated (fh.run-node "enumerate" 600)
          Header (json.parse (read-file-as-string (cn (value fh.*out*) "family.json")) [[byte-limit 1048576]])
          Chunks (tc0.i64.small (fh.field "chunks" Header))
          Start (get-time run)
          Stream (open (cn (value fh.*out*) "witnesses.jsonl") out)
          Explored (fh.explore-chunks 0 Chunks Stream 0 [])
          Closed (close Stream)
          Seconds (- (get-time run) Start)
          T (hd (tl Explored))
          Programs (hd Explored)
          Expected (fh.g-programs)
          Complete (and (= (fh.field "truncated" Header) false) (= (fh.field "count" Header) (str Programs)) (= Programs Expected))
          Ran (fh.run-node "witnesses" 3600)
          RunHeader (json.parse (read-file-as-string (cn (value fh.*out*) "witness-runs.json")) [[byte-limit 1048576]])
          WView (buffer.from-string (read-file-as-string (cn (value fh.*out*) "witnesses.jsonl")))
          Witnesses (fh.json-lines WView 0 (buffer.length WView) [])
          TW (fh.compare-witness-chunks 0 (tc0.i64.small (fh.field "chunks" RunHeader)) (fh.all-programs 0 Chunks []) Witnesses T)
          Defects (fh.defects-of TW)
          Undetected (append (fh.unreported (fh.task-defect-names) Defects) (fh.undetected Defects))
          Truncated (+ (fh.tget "reference_truncated" TW) (+ (fh.tget "production_truncated" TW) (fh.tget "variants_truncated" TW)))
          Obligation (and (= (fh.tget "programs_equal" TW) Programs) (= (fh.tget "programs_production_subset" TW) Programs))
          SendBroken (> (fh.tget "send_not_a_point_unequal" TW) 0)
          EagerBroken (> (fh.tget "eager_cancel_unequal" TW) 0)
          Agree (and (= (fh.tget "witnesses_compared" TW) (length Witnesses)) (= (fh.tget "witnesses_agreeing" TW) (length Witnesses))
                     (= (fh.tget "witnesses_compared" TW) (fh.tget "reference_observation_classes" TW)))
          Pass (and Complete (= Truncated 0) Obligation SendBroken EagerBroken Agree)
          Report [object ["schema" "fenrir.harness.tc1-task-explore/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["evidence" "bounded exploration, development grade"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["scope" "every program of grammar G (tools/tc1/task-enumerate.mjs) x every reference and every production schedule"]
                         ["scope_complete" Complete]
                         ["programs_expected" (str Expected)]
                         ["programs" (str Programs)]
                         ["bounds" [object ["steps_per_schedule" (str (value fh.*depth-bound*))] ["states_per_exploration" (str (value fh.*state-bound*))]]]
                         ["bounds_hit" (str Truncated)]
                         ["exploration_seconds" (str Seconds)]
                         ["reference" [object ["states" (fh.stat "reference_states" TW)] ["edges" (fh.stat "reference_edges" TW)]
                                              ["schedules" (fh.bigstat "reference_schedules" TW)] ["observation_classes" (fh.stat "reference_observation_classes" TW)]
                                              ["max_states_one_program" (fh.stat "reference_max_states" TW)]]]
                         ["production" [object ["states" (fh.stat "production_states" TW)] ["edges" (fh.stat "production_edges" TW)]
                                               ["schedules" (fh.bigstat "production_schedules" TW)] ["observation_classes" (fh.stat "production_observation_classes" TW)]
                                               ["max_states_one_program" (fh.stat "production_max_states" TW)]]]
                         ["obligation_holds" Obligation]
                         ["programs_equal_observation_sets" (fh.stat "programs_equal" TW)]
                         ["programs_production_subset_of_reference" (fh.stat "programs_production_subset" TW)]
                         ["unequal_examples" (fh.list-stat "unequal" TW)]
                         ["broken_send_not_a_point" [object ["programs_failing_the_check" (fh.stat "send_not_a_point_unequal" TW)]
                                                            ["programs_subset" (fh.stat "send_not_a_point_subset" TW)]
                                                            ["examples" (fh.list-stat "send_not_a_point_examples" TW)]]]
                         ["broken_eager_cancel" [object ["programs_failing_the_check" (fh.stat "eager_cancel_unequal" TW)]
                                                        ["programs_subset" (fh.stat "eager_cancel_subset" TW)]
                                                        ["examples" (fh.list-stat "eager_cancel_examples" TW)]]]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["witnesses" "one schedule per reference observation class of every program (all classes)"]
                         ["witnesses_compared" (fh.stat "witnesses_compared" TW)]
                         ["witnesses_agreeing" (fh.stat "witnesses_agreeing" TW)]
                         ["witness_steps" (fh.stat "witness_steps" TW)]
                         ["witness_disagreements" (fh.list-stat "witness_disagreements" TW)]
                         ["defects_on_witnesses" (fh.tally-json Defects)]
                         ["defects_on_witnesses_sample" "the first witness of each program; reported, not a pass condition"]
                         ["defects_undetected_on_sample" Undetected]
                         ["defects_crashing" (fh.crashing Defects)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
