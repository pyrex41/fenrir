\\ Fenrir harness, in Shen: closing the loop for TC1 slice C1 (spec/tc1/CONCURRENCY.md),
\\ as the handler slice did (tc1-generated, tc1-reduction, tc1-strict-replay,
\\ tc1-coverage). In one program:
\\
\\   generated   a seeded family beyond grammar G (tools/tc1/task-generate.mjs: 3 or 4
\\               tasks, nested scopes, a handler inside a task, traps, one or two
\\               channels of capacity 1-2, close, cancel, await), each program under five
\\               schedule policies: the model replays every schedule, agrees step for
\\               step with the sandboxed JavaScript implementation, and every production
\\               policy's schedule is a production schedule by the model's records;
\\   coverage    every C1 step of the model's traces on the hand fixtures, on grammar G
\\               (one witness per reference observation class, by the exploration of
\\               tc1-task-explore.shen, loaded as a library) and on the generated family
\\               is mapped to a transition of the versioned, pinned catalog
\\               spec/tc1/task-catalog.json; each step's control, depth change and
\\               scheduling-point flag are checked against its transition, every pure
\\               step against "not a scheduling point", and after every model step the
\\               channel queue invariant of section 4;
\\   campaigns   for four of the nine JavaScript task defects: discovery of the first
\\               generated (program, schedule) whose defective run shows the defect's
\\               discrepancy class while the model and the defect-free run agree; typed,
\\               schedule-aware reduction (tools/tc1/task-reduce.mjs: every proposal is
\\               revalidated and carries a schedule re-derived for it), a proposal
\\               accepted only when fresh model and implementation runs under its schedule
\\               show the same class; crashes never count; the original and minimized
\\               (program, schedule) retained and compared with the committed ones
\\               (fixtures/tc1/task-retained-failures.json);
\\   replay      strict tapes of the implementation (tools/tc1/task-replay.mjs; the tape
\\               binds the schedule) for every hand-fixture run and every retained
\\               failure: hand tapes replay exactly and are admitted; a retained failure's
\\               tape diverges at exactly its retained epoch with its defect and is
\\               admitted without; five edited tapes are refused.
\\ Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/tc1-task-loop.shen LIBDIR ROOT OUTDIR [sandbox] [stride N]
\\ stride N takes every Nth program of G for coverage (default 1: all of G).

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set tl.*options* (tl (tl (tl (tl (value *argv*))))))
(set fh.*sandbox* (element? "sandbox" (value tl.*options*)))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-task-common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))
(set fh.*explore-as-library* true)
(set fh.*options* [])
(load (cn (value fh.*root*) "harness/tc1-task-explore.shen"))

(define tl.option-stride
  ["stride" N | _] -> (tc0.i64.small N)
  [_ | Rest] -> (tl.option-stride Rest)
  [] -> 1)
(set tl.*stride* (tl.option-stride (value tl.*options*)))

(define tl.fuel -> 1000)
(define tl.seed -> "1")
(define tl.count -> "200")
(define tl.generated-policies -> ["lowest" "highest" "fifo" "random:1" "prandom:1"])
(define tl.catalog-path -> "spec/tc1/task-catalog.json")
(define tl.catalog-version -> "tc1-task-catalog/1")
\\ The pinned digest of the catalog: an edited catalog is not measured against.
(define tl.catalog-sha -> "01eb82cd2a6675c29f09dc8a1194f4255de2b4fb0261a35bf7aa611d04a5ee62")
(define tl.retained-path -> "fixtures/tc1/task-retained-failures.json")

\\ ---------- node transport ----------

(define tl.node
  Script Args Output Seconds ->
    (let R (fh.exec "node" (fh.node-arguments Script Args ["runtime/tc1" "tools/tc1" "fixtures/tc1" "spec/tc1" (value fh.*out*)] Output (value fh.*sandbox*)) Seconds)
      (if (= (hd R) 0) true (error "loop: ~A ~A exited ~A: ~A" Script (hd Args) (hd R) (nth 3 R)))))

(set tl.*scratch* 0)
(define tl.file
  Name -> (let _ (set tl.*scratch* (+ 1 (value tl.*scratch*))) (cn (value fh.*out*) (make-string "~A-~A" (value tl.*scratch*) Name))))

(define tl.lines
  File -> (let View (buffer.from-string (read-file-as-string File)) (fh.json-lines View 0 (buffer.length View) [])))

(define tl.json
  File -> (json.parse (read-file-as-string File) [[byte-limit 67108864]]))

\\ ---------- a model run with the queue invariant ----------

\\ The queue invariant of section 4 on every channel of M: [] when it holds.
(define tl.queue-violations
  [tm _ _ Cs | _] -> (fh.keep (/. C (not (tl.queue-ok? C))) Cs))

(define tl.queue-ok?
  [chan _ Cap Q _ Ss Rs] -> (and (<= (length Q) Cap) (or (= Ss []) (= (length Q) Cap)) (or (= Rs []) (= Q []))))

\\ [Execution Detail Steps Violations]: steps canonical, violations the number of
\\ model steps after which the queue invariant failed.
(define tl.run
  Prog M Choices -> (tl.run-from Prog M Choices 0 [] 0))

(define tl.run-from
  Prog M Choices Epoch Acc V ->
    (let Footer (fh.task-footer M)
      (cond ((not (= Footer [])) [(hd Footer) (fh.canon (hd (tl Footer))) (reverse Acc) V])
            ((>= Epoch (tl.fuel)) ["BudgetExhausted" [] (reverse Acc) V])
            ((= Choices []) ["ScheduleIncomplete" [] (reverse Acc) V])
            ((not (element? (hd Choices) (tm.runnable M))) ["ScheduleDiverged" [] (reverse Acc) V])
            (true (let R (tm.step Prog M (hd Choices))
                       M2 (hd (tl R))
                    (tl.run-from Prog M2 (tl Choices) (+ Epoch 1) [(fh.canon (fh.task-record Epoch (hd Choices) R)) | Acc]
                                 (if (= (tl.queue-violations M2) []) V (+ V 1))))))))

(define tl.model
  Artifact Choices -> (let P (fh.task-program Artifact) (tl.run (hd P) (hd (tl P)) Choices)))

\\ Same execution, footer and steps as a JavaScript run.
(define tl.same?
  [E D Steps _] Run -> (and (= E (fh.field "execution" Run)) (= D (fh.canon (fh.js-detail Run))) (= Steps (fh.canon (fh.field "steps" Run)))))

\\ ---------- the catalog ----------

(set tl.*catalog-json* (tl.json (cn (value fh.*root*) (tl.catalog-path))))
(set tl.*catalog-ok* (and (= (fh.sha256 (cn (value fh.*root*) (tl.catalog-path))) (tl.catalog-sha))
                          (= (fh.field "version" (value tl.*catalog-json*)) (tl.catalog-version))))
\\ [[Key Afters DepthChange Point] ...]
(set tl.*transitions* (map (/. T [(fh.field "key" T) (fh.field "after" T) (fh.field "depth_change" T) (fh.field "scheduling_point" T)])
                           (fh.field "transitions" (value tl.*catalog-json*))))

(define tl.transition
  Key [] -> none
  Key [[Key | R] | _] -> [Key | R]
  Key [_ | Ts] -> (tl.transition Key Ts))

\\ ---------- the program's forms: node ID to tag ----------

(define tl.tags
  -> ["unit" "bool" "int" "bytes" "var" "let" "if" "lambda" "apply" "call" "prim" "emit" "tuple" "project" "construct" "match"
      "handle" "perform" "resume" "discontinue" "scope" "spawn" "await" "cancel" "yield" "channel" "send" "receive" "close"])

(define tl.forms
  [T Id | Rest] Acc -> (tl.forms-all Rest [[Id T] | Acc]) where (and (string? T) (string? Id) (element? T (tl.tags)))
  [X | Xs] Acc -> (tl.forms-all [X | Xs] Acc)
  _ Acc -> Acc)

(define tl.forms-all
  [] Acc -> Acc
  [X | Xs] Acc -> (tl.forms-all Xs (if (cons? X) (tl.forms X Acc) Acc)))

(define tl.program-forms
  Artifact -> (tl.forms-all (map (/. F (fh.field "body" F)) (fh.field "functions" Artifact)) []))

(define tl.tag-of
  Id [] -> none
  Id [[Id T] | _] -> T
  Id [_ | Fs] -> (tl.tag-of Id Fs))

\\ ---------- classification of a step record (catalog keys) ----------

(define tl.kinds
  R -> (map (/. E (fh.field "kind" E)) (fh.field "events" R)))

(define tl.event-of
  Kind [] -> none
  Kind [E | Es] -> (if (= (fh.field "kind" E) Kind) E (tl.event-of Kind Es)))

(define tl.second-kind
  R -> (let Ks (tl.kinds R) (if (> (length Ks) 1) (hd (tl Ks)) none)))

(define tl.runtime-op?
  T -> (element? T ["spawn" "await" "cancel" "yield" "channel" "send" "receive" "close"]))

(define tl.implicit?
  R -> (= (fh.member "machine" (fh.field "site" R)) "TaskScope"))

(define tl.key
  R Forms -> (let Rule (fh.field "rule" (fh.field "site" R))
                  Ks (tl.kinds R)
                  Tag (tl.tag-of (fh.member "node" (fh.field "site" R)) Forms)
               (tl.key-by Rule Tag Ks R)))

(define tl.deliver?
  Ks -> (and (cons? Ks) (= (hd Ks) "CancelEffective")))

(define tl.key-by
  "TaskStart" _ Ks _ -> (if (tl.deliver? Ks) "task-start/deliver" "task-start")
  "Dispatch" "scope" Ks _ -> (if (tl.deliver? Ks) "scope/deliver" "scope/enter")
  "Dispatch" T _ _ -> (cn "dispatch/" T) where (tl.runtime-op? T)
  "Ready" T Ks _ -> (cn T "/deliver") where (and (tl.runtime-op? T) (tl.deliver? Ks))
  "Ready" "spawn" Ks _ -> (if (element? "Spawn" Ks) "spawn/child" "spawn/child-failed")
  "Ready" "await" Ks _ -> (if (element? "Awaited" Ks) "await/terminal" "await/wait")
  "Ready" "cancel" _ R -> (if (fh.field "new_request" (hd (fh.field "events" R))) "cancel/new" "cancel/repeat")
  "Ready" "yield" _ _ -> "yield"
  "Ready" "channel" _ _ -> "channel"
  "Ready" "send" _ R -> (tl.second "send" (tl.second-kind R) [["SendClosed" "closed"] ["Sent" "enqueued"] ["SendWait" "wait"]])
  "Ready" "receive" _ R -> (tl.second "receive" (tl.second-kind R) [["Received" "item"] ["End" "end"] ["ReceiveWait" "wait"]])
  "Ready" "close" _ R -> (if (fh.field "first" (hd (fh.field "events" R))) "close/first" "close/again")
  "Wake" _ Ks _ -> (if (tl.deliver? Ks) "wake/deliver" "wake/value")
  "ScopeClose" _ _ R -> (if (tl.implicit? R) "scope-close/implicit" "scope-close/explicit")
  "ScopeAbort" _ _ R -> (if (tl.implicit? R) "scope-abort/implicit" "scope-abort/explicit")
  "Join" _ Ks R -> (cond ((tl.deliver? Ks) "join/deliver")
                         ((element? "ScopeExit" Ks) (tl.exit-key (fh.field "outcome" (tl.event-of "ScopeExit" (fh.field "events" R)))))
                         (true "join/block"))
  "Terminate" _ Ks R -> (tl.terminate-key (fh.field "outcome" (tl.event-of "Termination" (fh.field "events" R))) Ks)
  _ _ _ _ -> inherited)

(define tl.second
  Op K Table -> (let Found (fe-lookup K Table) (if (= Found none) (cn Op "/?") (cn Op (cn "/" Found)))))

(define fe-lookup
  _ [] -> none
  K [[K V] | _] -> V
  K [_ | Rest] -> (fe-lookup K Rest))

(define tl.exit-key
  ["Ok" _] -> "join/exit-ok"
  ["Trap" "ChildFailed"] -> "join/exit-child-failed"
  ["Trap" _] -> "join/exit-trap"
  ["Cancelled"] -> "join/exit-cancelled"
  ["Abandoned"] -> "join/exit-abandoned")

(define tl.terminate-key
  ["Ok" _] _ -> "terminate/ok"
  ["Cancelled"] _ -> "terminate/cancelled"
  ["Trap" _] Ks -> (if (element? "ScopeFailure" Ks) "terminate/trap-latched" "terminate/trap-root"))

\\ ---------- coverage of one trace ----------
\\ Tally is a property list: ["key:K" N], "inherited", "outside" (unknown keys),
\\ "bad-after", "bad-depth", "bad-point", "steps". Examples of problems are kept.

(define tl.bump
  K N [] -> [[K N]]
  K N [[K M] | R] -> [[K (+ M N)] | R]
  K N [P | R] -> [P | (tl.bump K N R)])

(define tl.get
  K [] -> 0
  K [[K V] | _] -> V
  K [_ | R] -> (tl.get K R))

(define tl.depth-change
  "+1" -> 1
  "0" -> 0
  "-1" -> -1
  _ -> unchecked)

(define tl.cover-trace
  Steps Forms Depths T -> T where (= Steps [])
  [R | Rs] Forms Depths T ->
    (let Task (fh.field "task" R)
         Depth (tc0.i64.small (fh.field "depth" R))
         Before (fe-lookup Task Depths)
         Key (tl.key R Forms)
         T1 (tl.bump "steps" 1 T)
         T2 (if (= Key inherited)
                (tl.bump (if (fh.field "point" R) "bad-point" "inherited") 1 T1)
                (tl.check-step Key (tl.transition Key (value tl.*transitions*)) R Depth Before T1))
      (tl.cover-trace Rs Forms [[Task Depth] | Depths] T2)))

(define tl.check-step
  Key none _ _ _ T -> (tl.bump "outside" 1 (tl.bump (cn "outside:" Key) 1 T))
  Key [_ Afters Change Point] R Depth Before T ->
    (let D (tl.depth-change Change)
         T1 (tl.bump (cn "key:" Key) 1 T)
         T2 (if (element? (fh.field "after" R) Afters) T1 (tl.bump "bad-after" 1 (tl.bump (cn "bad-after:" Key) 1 T1)))
         T3 (if (or (= D unchecked) (= Before none) (= Depth (+ Before D))) T2 (tl.bump "bad-depth" 1 (tl.bump (cn "bad-depth:" Key) 1 T2)))
         T4 (if (= (fh.field "point" R) Point) T3 (tl.bump "bad-point" 1 (tl.bump (cn "bad-point:" Key) 1 T3)))
      T4))

(define tl.cover
  [] T -> T
  [[Steps Forms] | Traces] T -> (tl.cover Traces (tl.cover-trace Steps Forms [] T)))

\\ ---------- 1 hand fixtures ----------

(define tl.hand
  -> (let File (tl.file "tasks.jsonl")
          _ (tl.node "tools/tc1/run-task-cases.mjs" [File] File 300)
          Rows (tl.lines File)
       (map (/. Row (let M (tl.model (fh.field "program" Row) (fh.field "choices" Row))
                      [Row M (tl.same? M (fh.field "candidate" Row))]))
            Rows)))

\\ ---------- 2 the generated family ----------

(define tl.unique
  [] Seen -> Seen
  [K | Ks] Seen -> (tl.unique Ks (if (element? K Seen) Seen [K | Seen])))

(define tl.generated
  -> (let File (tl.file "generated.jsonl")
          _ (tl.node "tools/tc1/task-loop-bridge.mjs" ["generated" File (tl.seed) (tl.count)] File 600)
          Rows (tl.lines File)
          Keys (map (/. Row [(fh.field "name" Row) (fh.field "schedule" Row)]) Rows)
       (if (and (= (length Keys) (* (tc0.i64.small (tl.count)) (length (tl.generated-policies))))
                (= (length Keys) (length (tl.unique Keys [])))
                (= (tl.count) (str (length (tl.unique (map (/. K (hd K)) Keys) []))))
                (fh.every? (/. K (element? (nth 2 K) (tl.generated-policies))) Keys))
           (map (/. Row (let M (tl.model (fh.field "program" Row) (fh.field "choices" Row))
                          [Row M (tl.same? M (fh.field "candidate" Row))])) Rows)
           (error "loop: incomplete or duplicated generated runs"))))

(define tl.production-ok?
  [Row M _] -> (or (not (fh.field "production" Row)) (fh.production? (nth 3 M))))

(define tl.complete?
  [_ M _] -> (element? (hd M) ["Completed" "Deadlock"]))

\\ ---------- 3 grammar G, one witness per reference observation class ----------

(define tl.g-programs
  -> (let Dir (fh.subdir "g")
          _ (tl.node "tools/tc1/run-task-explore.mjs" ["enumerate" Dir] Dir 600)
          Header (tl.json (cn Dir "/family.json"))
          Chunks (tc0.i64.small (fh.field "chunks" Header))
          Rows (tl.g-chunks Dir 0 Chunks [])
       (if (and (= (fh.field "truncated" Header) false)
                (= (str (length Rows)) (fh.field "count" Header)) (not (empty? Rows)))
           Rows (error "loop: incomplete grammar G"))))

(define tl.g-chunks
  Dir I N Acc -> (reverse Acc) where (>= I N)
  Dir I N Acc -> (tl.g-chunks Dir (+ I 1) N (append (reverse (tl.lines (make-string "~A/programs-~A.jsonl" Dir I))) Acc)))

\\ Every Nth element, from the first: K counts down to the next one taken.
(define tl.every-nth
  [] _ _ -> []
  [X | Xs] N 0 -> [X | (tl.every-nth Xs N (- N 1))]
  [_ | Xs] N K -> (tl.every-nth Xs N (- K 1)))

\\ [Programs Witnesses Truncated Traces], Traces [[Steps Forms] ...].
(define tl.g-witnesses
  [] P W X Acc -> [P W X Acc]
  [Row | Rows] P W X Acc ->
    (let Program (fh.task-program (fh.field "program" Row))
         Forms (tl.program-forms (fh.field "program" Row))
         E (fh.explore reference (hd Program) (hd (tl Program)))
         Runs (map (/. O (tl.run (hd Program) (hd (tl Program)) (hd (tl O)))) (nth 5 E))
         Bad (if (empty? Runs) 1 (fc-count (/. R (not (element? (hd R) ["Completed" "Deadlock"]))) Runs))
      (tl.g-witnesses Rows (+ P 1) (+ W (length Runs)) (+ X (+ Bad (if (nth 4 E) 1 0)))
                      (append (map (/. R [(nth 3 R) Forms]) Runs) Acc))))

(define fc-count
  F L -> (length (fh.keep F L)))

\\ ---------- 4 discrepancy classes and campaigns ----------

(define tl.expected-class
  "lifo_channel" -> "received-other-value"
  "lost_wakeup_await" -> "termination-without-awaited"
  "no_sibling_cancel" -> "failure-without-sibling-cancel"
  "capacity_off_by_one" -> "send-admitted-over-capacity"
  D -> (error "loop: no discrepancy class is defined for defect ~A" D))

(define tl.campaign-defects -> ["lifo_channel" "lost_wakeup_await" "no_sibling_cancel" "capacity_off_by_one"])

(define tl.first-difference
  [] [] _ -> none
  [] _ I -> I
  _ [] I -> I
  [A | As] [B | Bs] I -> (if (= A B) (tl.first-difference As Bs (+ I 1)) I))

(define tl.count-kind
  K R -> (length (fh.keep (/. E (= (fh.field "kind" E) K)) (fh.field "events" R))))

\\ [Class Epoch] of the first difference between model steps and defective steps.
(define tl.classify
  Model Mutant -> (let K (tl.first-difference Model Mutant 0)
                    (cond ((= K none) [none none])
                          ((or (>= K (length Model)) (>= K (length Mutant))) ["unclassified" (str K)])
                          (true [(tl.class-at (nth (+ K 1) Model) (nth (+ K 1) Mutant)) (str K)]))))

(define tl.class-at
  M X -> (let Same (and (= (fh.field "task" M) (fh.field "task" X)) (= (fh.field "site" M) (fh.field "site" X)))
              Rule (fh.field "rule" (fh.field "site" M))
              RM (tl.event-of "Received" (fh.field "events" M))
              RX (tl.event-of "Received" (fh.field "events" X))
           (cond ((and Same (not (= RM none)) (not (= RX none)) (not (= (fh.field "value" RM) (fh.field "value" RX))))
                   "received-other-value")
                 ((and Same (= Rule "Terminate") (> (tl.count-kind "Awaited" M) (tl.count-kind "Awaited" X)))
                   "termination-without-awaited")
                 ((and Same (= Rule "Terminate") (> (tl.count-kind "ScopeFailure" X) 0)
                       (> (tl.count-kind "CancelRequest" M) 0) (= (tl.count-kind "CancelRequest" X) 0))
                   "failure-without-sibling-cancel")
                 ((and Same (= Rule "Ready") (> (tl.count-kind "SendWait" M) 0) (= (tl.count-kind "SendWait" X) 0) (> (tl.count-kind "Sent" X) 0))
                   "send-admitted-over-capacity")
                 (true "unclassified"))))

\\ The class a defective run shows against model run M, or crashed.
(define tl.class-of
  M Mutant -> [crashed none] where (= (fh.field "execution" Mutant) "Crashed")
  M Mutant -> (tl.classify (nth 3 M) (fh.canon (fh.field "steps" Mutant))))

(define tl.nodes
  Artifact -> (length (tl.program-forms Artifact)))

\\ A case is [Name Program Policy Choices Nodes Switches Class Epoch].
(define tl.switches
  [] -> 0
  [_] -> 0
  [A B | Cs] -> (+ (if (= A B) 0 1) (tl.switches [B | Cs])))

(define tl.discover
  [] _ _ Skipped -> [none Skipped]
  [[Row M Agree] | Rows] Defect Expected [S X O] ->
    (if (not Agree) (tl.discover Rows Defect Expected [S X O])
        (let C (tl.class-of M (fh.field Defect (fh.field "mutants" Row)))
          (if (= (hd C) Expected)
              [[(fh.field "name" Row) (fh.field "program" Row) (fh.field "schedule" Row) (fh.field "choices" Row)
                (tl.nodes (fh.field "program" Row)) (tl.switches (fh.field "choices" Row)) (hd C) (hd (tl C))] [S X O]]
              (tl.discover Rows Defect Expected
                (cond ((= (hd C) none) [(+ S 1) X O]) ((= (hd C) crashed) [S (+ X 1) O]) (true [S X (+ O 1)])))))))

\\ A fresh observation of a case: the bridge re-derives the schedule and runs the
\\ implementation; the model runs here. [Case Agree].
(define tl.observe
  Name Program Policy Defect ->
    (let In (tl.file (cn Name ".json"))
         _ (write-to-file In (json.stringify Program [[byte-limit 8388608]]))
         Out (tl.file (cn Name "-observed.json"))
         _ (tl.node "tools/tc1/task-loop-bridge.mjs" ["observe" In Policy Defect Out] Out 120)
         J (tl.json Out)
         Choices (fh.field "choices" J)
         M (tl.model Program Choices)
         Agree (and (tl.same? M (fh.field "candidate" J)) (= (fh.canon (fh.field "candidate" J)) (fh.canon (fh.field "control" J))))
         C (tl.class-of M (fh.field "mutant" J))
      [[Name Program Policy Choices (tl.nodes Program) (tl.switches Choices) (hd C) (hd (tl C))] Agree]))

(define tl.smaller?
  [_ _ _ _ N S | _] [_ _ _ _ N2 S2 | _] -> (or (< N N2) (and (= N N2) (< S S2))))

\\ Try the proposals in order: [Accepted? Case Attempts Crashed].
(define tl.try
  [] Current Expected Attempts Crashed -> [false Current Attempts Crashed]
  [P | Ps] Current Expected Attempts Crashed ->
    (let Program (fh.field "program" P)
         Choices (fh.field "choices" P)
         M (tl.model Program Choices)
         Agree (tl.same? M (fh.field "candidate" P))
         Mutant (fh.field "mutant" P)
         C (tl.class-of M Mutant)
         Case [(cn "reduced-" (str Attempts)) Program (fh.field "policy" P) Choices (tl.nodes Program) (tl.switches Choices) (hd C) (hd (tl C))]
         Crash (= (hd C) crashed)
         _ (if Agree skip (set tl.*disagreements* (+ 1 (value tl.*disagreements*))))
      (if (and Agree (= (hd C) Expected) (tl.smaller? Case Current))
          [true Case (+ Attempts 1) Crashed]
          (tl.try Ps Current Expected (+ Attempts 1) (if Crash (+ Crashed 1) Crashed)))))

(set tl.*disagreements* 0)
(define tl.reduce
  Current Defect Expected Attempts Accepted Crashed Rounds ->
    (if (>= Rounds 80) [Current Attempts Accepted Crashed true]
        (let In (tl.file "current.json")
             _ (write-to-file In (json.stringify (nth 2 Current) [[byte-limit 8388608]]))
             Out (tl.file "proposals.json")
             _ (tl.node "tools/tc1/task-loop-bridge.mjs" ["reduce" In (nth 3 Current) Defect Out] Out 600)
             R (tl.try (fh.field "proposals" (tl.json Out)) Current Expected Attempts Crashed)
          (if (hd R)
              (tl.reduce (nth 2 R) Defect Expected (nth 3 R) [(nth 3 (nth 2 R)) | Accepted] (nth 4 R) (+ Rounds 1))
              [Current (nth 3 R) Accepted (nth 4 R) false]))))

(define tl.case-json
  Defect Role [Name Program Policy Choices Nodes Switches Class Epoch] ->
    [object ["choices" Choices] ["defect" Defect] ["discrepancy" Class] ["divergence_epoch" Epoch] ["name" Name]
            ["nodes" (str Nodes)] ["policy" Policy] ["program" Program] ["role" Role] ["switches" (str Switches)]])

(define tl.campaign
  Generated Defect ->
    (let Expected (tl.expected-class Defect)
         Found (tl.discover Generated Defect Expected [0 0 0])
      (if (= (hd Found) none)
          [object ["defect" Defect] ["status" "development-fail"] ["reason" "no generated (program, schedule) shows the expected class"]]
          (let Fresh (tl.observe "original" (nth 2 (hd Found)) (nth 3 (hd Found)) Defect)
               Original (hd Fresh)
               Confirmed (and (nth 2 Fresh) (= (nth 7 Original) Expected))
               R (if Confirmed (tl.reduce Original Defect Expected 0 [] 0 0) [Original 0 [] 0 false])
               Minimized (hd R)
               Skipped (hd (tl Found))
               Pass (and Confirmed (tl.smaller? Minimized Original))
            [object ["defect" Defect] ["status" (if Pass "development-pass" "development-fail")] ["discrepancy" Expected]
                    ["discovered" (nth 1 (hd Found))] ["discovered_policy" (nth 3 (hd Found))]
                    ["passed_over" [object ["survived" (str (hd Skipped))] ["crashed" (str (nth 2 Skipped))] ["other_class" (str (nth 3 Skipped))]]]
                    ["fresh_observation_confirms" Confirmed]
                    ["attempts" (str (nth 2 R))] ["accepted" (str (length (nth 3 R)))] ["accepted_policies" (reverse (nth 3 R))]
                    ["proposals_crashed_rejected" (str (nth 4 R))] ["reduction_round_cap_hit" (nth 5 R)]
                    ["original" [object ["nodes" (str (nth 5 Original))] ["schedule_steps" (str (length (nth 4 Original)))] ["switches" (str (nth 6 Original))] ["divergence_epoch" (nth 8 Original)]]]
                    ["minimized" [object ["nodes" (str (nth 5 Minimized))] ["schedule_steps" (str (length (nth 4 Minimized)))] ["switches" (str (nth 6 Minimized))] ["divergence_epoch" (nth 8 Minimized)]
                                         ["policy" (nth 3 Minimized)]]]
                    ["cases" [(tl.case-json Defect "original" Original) (tl.case-json Defect "minimized" Minimized)]]]))))

\\ ---------- 5 strict replay ----------

\\ Cases [Name Program Choices Reference Mutant Tamper]: the result rows.
(define tl.replay
  Tag Cases -> (let In (tl.file (cn Tag "-replay-input.jsonl"))
                    Out (tl.file (cn Tag "-replay-output.jsonl"))
                    Identity (json.stringify [object ["identity" [object ["evaluator" "Shen harness"]
                                               ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]]]] [])
                    _ (write-to-file In (cn Identity (cn "c#10;" (tl.replay-lines Cases))))
                    _ (tl.node "tools/tc1/task-replay.mjs" [In Out] Out 600)
                 (tl.lines Out)))

(define tl.replay-lines
  [] -> ""
  [[Name Program Choices Reference Mutant Tamper] | Cs] ->
    (cn (json.stringify [object ["name" Name] ["program" Program] ["choices" Choices] ["reference" Reference] ["mutant" Mutant] ["tamper" Tamper]] [[byte-limit 67108864]])
        (cn "c#10;" (tl.replay-lines Cs))))

(define tl.case-name
  Prefix C -> (make-string "~A-~A-~A" Prefix (fh.field "defect" C) (fh.field "role" C)))

(define tl.admitted?
  R -> (and (= (fh.member "replay" R) "Exact") (= (fh.member "conformance" R) "Admitted")))

(define tl.diverged-at?
  Epoch R -> (and (= (fh.member "replay" R) "Exact") (= (fh.member "conformance" R) "Diverged") (= (fh.member "divergence_epoch" R) Epoch)))

\\ ---------- the check ----------

(define tl.retained-cases
  -> (let Report (tl.json (cn (value fh.*root*) (tl.retained-path)))
          Cases (fh.field "cases" Report)
       (if (and (= (fh.field "schema" Report) "tc1-task-retained-failures/1")
                (= (length Cases) (* 2 (length (tl.campaign-defects)))))
           Cases (error "loop: incomplete retained failure set"))))

(define tl.tamper-expected
  "tamper-choice" -> "Diverged:choices"
  "tamper-step" -> "Diverged:step 0"
  "tamper-schedule" -> "Incompatible:schedule_hash"
  "tamper-program" -> "Incompatible:program_hash"
  "tamper-catalog" -> "Incompatible:catalog_hash"
  _ -> "")

(define tl.same-case?
  A B -> (and (= (fh.field "defect" A) (fh.field "defect" B)) (= (fh.field "role" A) (fh.field "role" B))
              (= (fh.canon (fh.field "program" A)) (fh.canon (fh.field "program" B))) (= (fh.field "choices" A) (fh.field "choices" B))
              (= (fh.field "divergence_epoch" A) (fh.field "divergence_epoch" B))))

(define tl.keys-json
  T -> [object | (map (/. K [K (str (tl.get (cn "key:" K) T))]) (map (/. X (hd X)) (value tl.*transitions*)))])

(define tl.problems
  Prefix T -> (map (/. P [(fh.drop Prefix (hd P)) (str (hd (tl P)))]) (fh.keep (/. P (and (string? (hd P)) (fh.starts? Prefix (hd P)))) T)))

(define tl.main
  -> (let Start (clock.monotonic)
          Hand (tl.hand)
          HandAgree (fc-count (/. X (nth 3 X)) Hand)
          Generated (tl.generated)
          GenAgree (fc-count (/. X (nth 3 X)) Generated)
          GenComplete (fc-count (/. X (tl.complete? X)) Generated)
          GenProduction (fc-count (/. X (tl.production-ok? X)) Generated)
          GenProductionRuns (fc-count (/. X (fh.field "production" (hd X))) Generated)
          GenTally (tl.tally-defects Generated [])
          GenSteps (st-sum (map (/. X (length (nth 3 (nth 2 X)))) Generated))
          GenMs (- (clock.monotonic) Start)
          \\ Coverage.
          G (tl.g-programs)
          GSample (tl.every-nth G (value tl.*stride*) 0)
          GStart (clock.monotonic)
          GW (tl.g-witnesses GSample 0 0 0 [])
          GMs (- (clock.monotonic) GStart)
          HandTraces (map (/. X [(nth 3 (nth 2 X)) (tl.program-forms (fh.field "program" (hd X)))]) Hand)
          GenTraces (map (/. X [(nth 3 (nth 2 X)) (tl.program-forms (fh.field "program" (hd X)))]) Generated)
          CHand (tl.cover HandTraces [])
          CG (tl.cover (nth 4 GW) [])
          CGen (tl.cover GenTraces [])
          CAll (tl.cover GenTraces (tl.cover (nth 4 GW) CHand))
          Unexercised (map (/. X (hd X)) (fh.keep (/. X (= 0 (tl.get (cn "key:" (hd X)) CAll))) (value tl.*transitions*)))
          QueueViolations (+ (st-sum (map (/. X (nth 4 (nth 2 X))) Hand)) (st-sum (map (/. X (nth 4 (nth 2 X))) Generated)))
          CoverageClean (and (value tl.*catalog-ok*) (= 0 (tl.get "outside" CAll)) (= 0 (tl.get "bad-after" CAll))
                             (= 0 (tl.get "bad-depth" CAll)) (= 0 (tl.get "bad-point" CAll)) (= QueueViolations 0))
          \\ Campaigns.
          CampStart (clock.monotonic)
          Campaigns (map (/. D (tl.campaign Generated D)) (tl.campaign-defects))
          CampMs (- (clock.monotonic) CampStart)
          CampaignsPass (and (fh.every? (/. C (= (fh.field "status" C) "development-pass")) Campaigns) (= 0 (value tl.*disagreements*)))
          NewCases (fh.flatten-cases Campaigns)
          _ (write-to-file (cn (value fh.*out*) "task-retained-failures.json")
                           (json.stringify [object ["schema" "tc1-task-retained-failures/1"] ["qualification" "UNKNOWN"] ["producer" "harness/tc1-task-loop.shen"]
                                                   ["family" "tc1-task-generated/1"] ["seed" (tl.seed)] ["count" (tl.count)] ["cases" NewCases]] [[byte-limit 67108864]]))
          Committed (tl.retained-cases)
          Matches (and (= (length Committed) (length NewCases)) (fh.every? (/. C (fh.some? (/. K (tl.same-case? C K)) Committed)) NewCases))
          \\ Replay: hand tapes, retained tapes (with and without their defect), tampered tapes.
          ReplayStart (clock.monotonic)
          HandCases (map (/. X [(cn (fh.field "name" (hd X)) (cn "/" (fh.field "schedule" (hd X)))) (fh.field "program" (hd X)) (fh.field "choices" (hd X)) (nth 3 (nth 2 X)) null null])
                         (fh.keep (/. X (nth 3 X)) Hand))
          HandReplays (tl.replay "hand" HandCases)
          HandExact (fc-count (/. R (tl.admitted? R)) HandReplays)
          Retained Committed
          RetainedRef (map (/. C [C (nth 3 (tl.model (fh.field "program" C) (fh.field "choices" C)))]) Retained)
          RetainedCases (append (map (/. P [(tl.case-name "with-defect" (hd P)) (fh.field "program" (hd P)) (fh.field "choices" (hd P)) (hd (tl P)) (fh.field "defect" (hd P)) null]) RetainedRef)
                                (map (/. P [(tl.case-name "fixed" (hd P)) (fh.field "program" (hd P)) (fh.field "choices" (hd P)) (hd (tl P)) null null]) RetainedRef))
          RetainedReplays (tl.replay "retained" RetainedCases)
          N (length Retained)
          RetainedOk (and (= (length RetainedReplays) (* 2 N))
                          (fh.every? (/. P (tl.diverged-at? (fh.field "divergence_epoch" (hd P)) (hd (tl P)))) (fc-pairs Retained (fh.take N RetainedReplays)))
                          (fh.every? (/. R (tl.admitted? R)) (fh.drop-n N RetainedReplays)))
          Base (hd HandCases)
          Tampers (tl.replay "tamper" (map (/. T [(cn "tamper-" T) (nth 2 Base) (nth 3 Base) (nth 4 Base) null T]) ["choice" "step" "schedule" "program" "catalog"]))
          TamperRows (map (/. R [object ["test" (fh.member "name" R)] ["observed" (fh.member "replay" R)]
                                        ["result" (if (= (fh.member "replay" R) (tl.tamper-expected (fh.member "name" R))) "refused" "UNEXPECTED")]])
                          Tampers)
          TampersOk (and (= (length Tampers) 5) (= (map (/. R (fh.field "tamper" R)) Tampers) ["choice" "step" "schedule" "program" "catalog"])
                         (fh.every? (/. R (= (fh.member "result" R) "refused")) TamperRows))
          ReplayMs (- (clock.monotonic) ReplayStart)
          Pass (and (not (empty? Hand)) (= HandAgree (length Hand)) (> (length Generated) 0) (= GenAgree (length Generated)) (= GenComplete (length Generated))
                    (= GenProduction (length Generated)) (= (nth 3 GW) 0) CoverageClean (empty? Unexercised) CampaignsPass
                    (= HandExact (length HandCases)) (= HandExact (length Hand)) RetainedOk TampersOk
                    Matches)
          Report [object ["schema" "fenrir.harness.tc1-task-loop/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"] ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["generated" [object ["family" "tc1-task-generated/1"] ["seed" (tl.seed)] ["programs" (tl.count)]
                                              ["runs" (str (length Generated))] ["production_policy_runs" (str GenProductionRuns)]
                                              ["agreeing" (str GenAgree)] ["reaching_a_footer" (str GenComplete)]
                                              ["production_schedules_hold" (str GenProduction)] ["model_steps" (str GenSteps)]
                                              ["executions" (tl.executions Generated)]
                                              ["defects" (fh.tally-json GenTally)]
                                              ["defects_undetected" (append (fh.unreported (fh.task-defect-names) GenTally) (fh.undetected GenTally))]
                                              ["defects_crashing" (fh.crashing GenTally)]
                                              ["milliseconds" (str GenMs)]]]
                         ["coverage" [object ["catalog" (tl.catalog-path)] ["catalog_version" (tl.catalog-version)] ["catalog_sha256" (tl.catalog-sha)]
                                             ["catalog_pin_holds" (value tl.*catalog-ok*)]
                                             ["transitions" (str (length (value tl.*transitions*)))]
                                             ["exercised" (str (- (length (value tl.*transitions*)) (length Unexercised)))]
                                             ["unexercised" Unexercised]
                                             ["status" (cond ((not CoverageClean) "outside-catalog") ((empty? Unexercised) "complete") (true "incomplete"))]
                                             ["traces" [object ["hand" (str (length HandTraces))] ["exhaustive_witnesses" (str (nth 2 GW))]
                                                               ["exhaustive_programs" (str (hd GW))] ["exhaustive_stride" (str (value tl.*stride*))]
                                                               ["generated" (str (length GenTraces))]]]
                                             ["steps" [object ["hand" (str (tl.get "steps" CHand))] ["exhaustive" (str (tl.get "steps" CG))] ["generated" (str (tl.get "steps" CGen))]]]
                                             ["c1_steps" (str (- (tl.get "steps" CAll) (tl.get "inherited" CAll)))]
                                             ["inherited_handler_steps" (str (tl.get "inherited" CAll))]
                                             ["outside_catalog" (str (tl.get "outside" CAll))] ["outside_keys" (tl.problems "outside:" CAll)]
                                             ["control_mismatches" (str (tl.get "bad-after" CAll))] ["depth_mismatches" (str (tl.get "bad-depth" CAll))]
                                             ["point_mismatches" (str (tl.get "bad-point" CAll))]
                                             ["problems" (append (tl.problems "bad-after:" CAll) (tl.problems "bad-depth:" CAll) (tl.problems "bad-point:" CAll))]
                                             ["queue_invariant_violations_hand_and_generated" (str QueueViolations)]
                                             ["exhaustive_bound_hit_or_incomplete" (str (nth 3 GW))]
                                             ["exhaustive_milliseconds" (str GMs)]
                                             ["by_transition" (tl.keys-json CAll)]]]
                         ["campaigns" Campaigns]
                         ["campaigns_milliseconds" (str CampMs)]
                         ["proposals_where_model_and_implementation_disagree" (str (value tl.*disagreements*))]
                         ["retained" [object ["file" (tl.retained-path)] ["committed_cases" (str (length Committed))]
                                             ["this_run_cases" (str (length NewCases))] ["matches_committed" Matches]
                                             ["written" (cn (value fh.*out*) "task-retained-failures.json")]]]
                         ["replay" [object ["hand_tapes" (str (length HandCases))] ["hand_exact_and_admitted" (str HandExact)]
                                           ["retained_tapes" (str (length RetainedCases))] ["retained_as_expected" RetainedOk]
                                           ["retained_rows" (map (/. R [object ["case" (fh.member "name" R)] ["replay" (fh.member "replay" R)]
                                                                               ["conformance" (fh.member "conformance" R)] ["divergence_epoch" (fh.member "divergence_epoch" R)]])
                                                                 RetainedReplays)]
                                           ["tampered" TamperRows] ["milliseconds" (str ReplayMs)]]]
                         ["milliseconds" (str (- (clock.monotonic) Start))]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 16777216]]))
           (shen-jit.exit (if Pass 0 1)))))

(define tl.tally-defects
  [] T -> T
  [[Row M Agree] | Rs] T -> (tl.tally-defects Rs (if Agree (fh.task-tally (tl (fh.field "mutants" Row)) M T) T)))

(define tl.executions
  Rows -> (let Es (map (/. X (hd (nth 2 X))) Rows)
            [object ["Completed" (str (fc-count (/. E (= E "Completed")) Es))] ["Deadlock" (str (fc-count (/. E (= E "Deadlock")) Es))]
                    ["other" (str (fc-count (/. E (not (element? E ["Completed" "Deadlock"]))) Es))]]))

(define st-sum
  [] -> 0
  [X | Xs] -> (+ X (st-sum Xs)))

(define fc-pairs
  [] [] -> []
  [A | As] [B | Bs] -> [[A B] | (fc-pairs As Bs)])

(define fh.flatten-cases
  [] -> []
  [C | Cs] -> (append (let X (fh.member "cases" C) (if (cons? X) X [])) (fh.flatten-cases Cs)))

(define fh.every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (fh.every? F Xs)))

(define fh.some?
  _ [] -> false
  F [X | Xs] -> (or (F X) (fh.some? F Xs)))

(tl.main)
