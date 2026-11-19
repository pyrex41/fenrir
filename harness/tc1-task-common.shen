\\ Fenrir harness, shared by the TC1-C1 programs (tc1-tasks.shen, tc1-task-explore.shen):
\\ the task machine's records, events and footers in JSON shape, a run under an explicit
\\ schedule, and the classification of a defective run. Load after common.shen.
\\ Contract: spec/tc1/CONCURRENCY.md. Transport and comparison only: no transition
\\ logic lives here.

(load (cn (value fh.*root*) "models/tc1/task-machine.shen"))

\\ ---------- program to model state ----------

\\ Decode C1 locally: shared PR10/service transport is unchanged. Leaf forms
\\ are already understood by fh.expr; recursive forms use the C1 decoder.
(define fh.task-exprs
  Es -> (map (/. E (fh.task-expr E)) Es))

(define fh.task-arm
  [Ctor Binders Body] -> [Ctor Binders (fh.task-expr Body)])

(define fh.task-clause
  [Op Binder Body] -> [Op Binder (fh.task-expr Body)]
  [Op Binder K Body] -> [Op Binder K (fh.task-expr Body)])

(define fh.task-expr
  ["let" Node Id Init Body] -> [let Node Id (fh.task-expr Init) (fh.task-expr Body)]
  ["if" Node C Y N] -> [if Node (fh.task-expr C) (fh.task-expr Y) (fh.task-expr N)]
  ["lambda" Node Id _ _ _ _ Body] -> [lambda Node Id (fh.task-expr Body)]
  ["apply" Node F A] -> [apply Node (fh.task-expr F) (fh.task-expr A)]
  ["call" Node Name Arg] -> [call Node (fh.function-name Name) (fh.task-expr Arg)]
  ["prim" Node Op | Args] -> [prim Node (fh.op Op) | (fh.task-exprs Args)]
  ["emit" Node Label Arg] -> [emit Node Label (fh.task-expr Arg)]
  ["tuple" Node | Args] -> [tuple Node | (fh.task-exprs Args)]
  ["project" Node E I] -> [project Node (fh.task-expr E) (tc0.i64.small I)]
  ["construct" Node Type Ctor | Args] -> [construct Node Type Ctor | (fh.task-exprs Args)]
  ["match" Node E | Arms] -> [match Node (fh.task-expr E) (map (/. A (fh.task-arm A)) Arms)]
  ["handle" Node Effect Clauses Body] -> [handle Node Effect (map (/. C (fh.task-clause C)) Clauses) (fh.task-expr Body)]
  ["perform" Node Effect Op Arg] -> [perform Node Effect Op (fh.task-expr Arg)]
  ["resume" Node K Arg] -> [resume Node K (fh.task-expr Arg)]
  ["scope" Node Body] -> [scope Node (fh.task-expr Body)]
  ["spawn" Node E] -> [spawn Node (fh.task-expr E)]
  ["await" Node E] -> [await Node (fh.task-expr E)]
  ["cancel" Node E] -> [cancel Node (fh.task-expr E)]
  ["yield" Node] -> [yield Node]
  ["channel" Node _ Capacity] -> [channel Node Capacity]
  ["send" Node C V] -> [send Node (fh.task-expr C) (fh.task-expr V)]
  ["receive" Node C] -> [receive Node (fh.task-expr C)]
  ["close" Node C] -> [close Node (fh.task-expr C)]
  E -> (fh.expr E))

(define fh.task-function
  F -> [(fh.field "id" F) (fh.field "name" F) (fh.field "parameter_id" F) (fh.task-expr (fh.field "body" F))])

\\ [Prog InitialState] for a decoded tc1-task-demo/1 artifact, input ["int","0"].
(define fh.task-program
  Artifact -> (error "harness: TC1-C1 artifact required") where (not (= (fh.field "schema_version" Artifact) "tc1-task-demo/1"))
  Artifact ->
    (let Rows (map (/. F (fh.task-function F)) (fh.field "functions" Artifact))
         Names (map (/. R [(fh.function-name (hd (tl R))) (hd R)]) Rows)
         Entry (fh.entry-row (fh.field "entry" Artifact) Rows)
      [[(fh.function-codes Rows) Names] (tm.initial (hd Entry) (hd (tl Entry)) [int "0"])]))

\\ ---------- JSON shapes (CONCURRENCY.md section 10) ----------

(define fh.task-trap
  overflow -> "Overflow"
  div-zero -> "DivZero"
  bounds -> "Bounds"
  child-failed -> "ChildFailed")

(define fh.task-outcome
  [ok V] -> ["Ok" (fh.value V)]
  [trap C] -> ["Trap" (fh.task-trap C)]
  cancelled -> ["Cancelled"]
  abandoned -> ["Abandoned"])

(define fh.ev
  Kind Task Fields -> [object ["kind" Kind] ["task" Task] | Fields])

(define fh.task-event
  [emit T L V] -> (fh.ev "Emit" T [["label" L] ["value" (fh.value V)]])
  [scope-enter T S] -> (fh.ev "ScopeEnter" T [["scope" S]])
  [scope-exit T S O] -> (fh.ev "ScopeExit" T [["scope" S] ["outcome" (fh.task-outcome O)]])
  [spawn T C S CS] -> (fh.ev "Spawn" T [["child" C] ["scope" S] ["child_scope" CS]])
  [await T X] -> (fh.ev "Await" T [["target" X]])
  [await-wait T X] -> (fh.ev "AwaitWait" T [["target" X]])
  [await-removed T X] -> (fh.ev "AwaitRemoved" T [["target" X]])
  [awaited T X O] -> (fh.ev "Awaited" T [["target" X] ["outcome" (fh.value (tm.outcome-value O))]])
  [cancel-request T X New] -> (fh.ev "CancelRequest" T [["target" X] ["new_request" New]])
  [cancel-effective T] -> (fh.ev "CancelEffective" T [])
  [yield T] -> (fh.ev "Yield" T [])
  [channel T C Cap] -> (fh.ev "Channel" T [["channel" C] ["capacity" Cap]])
  [send T C V] -> (fh.ev "Send" T [["channel" C] ["value" (fh.value V)]])
  [sent T C] -> (fh.ev "Sent" T [["channel" C]])
  [send-closed T C] -> (fh.ev "SendClosed" T [["channel" C]])
  [send-wait T C] -> (fh.ev "SendWait" T [["channel" C]])
  [send-removed T C] -> (fh.ev "SendRemoved" T [["channel" C]])
  [receive T C] -> (fh.ev "Receive" T [["channel" C]])
  [received T C V] -> (fh.ev "Received" T [["channel" C] ["value" (fh.value V)]])
  [end T C] -> (fh.ev "End" T [["channel" C]])
  [receive-wait T C] -> (fh.ev "ReceiveWait" T [["channel" C]])
  [receive-removed T C] -> (fh.ev "ReceiveRemoved" T [["channel" C]])
  [close T C First] -> (fh.ev "Close" T [["channel" C] ["first" First]])
  [scope-failure T S C] -> (fh.ev "ScopeFailure" T [["scope" S] ["code" (fh.task-trap C)]])
  [termination T O] -> (fh.ev "Termination" T [["outcome" (fh.task-outcome O)]]))

(define fh.task-rule
  task-start -> "TaskStart"
  wake -> "Wake"
  scope-close -> "ScopeClose"
  scope-abort -> "ScopeAbort"
  R -> (fh.rule R))

(define fh.task-machine-site
  task-start -> "TaskStart"
  task-scope -> "TaskScope"
  terminate -> "Terminate")

(define fh.task-site
  [node N R] -> [object ["node" N] ["rule" (fh.task-rule R)]]
  [machine S R] -> [object ["machine" (fh.task-machine-site S)] ["rule" (fh.task-rule R)]])

\\ The step record of task Id's step with result [step M Site Events Point].
(define fh.task-record
  Epoch Id [step M Site Events Point] ->
    (let T (tm.task Id M)
      [object ["epoch" (str Epoch)] ["task" Id] ["site" (fh.task-site Site)] ["after" (tm.after (tm.control T))]
              ["depth" (str (length (tm.frames T)))] ["events" (map (/. E (fh.task-event E)) Events)]
              ["point" Point] ["runnable" (tm.runnable M)]]))

(define fh.wait-entry
  [I [running]] -> [object ["task" I] ["running" true]]
  [I [Kind X]] -> [object ["task" I] [(fh.wait-kind Kind) X]])

(define fh.wait-kind
  receive -> "receive"
  send -> "send"
  await -> "await"
  join -> "join")

\\ The execution footer: [Execution Detail], Detail the outcome or the wait graph.
(define fh.task-footer
  M -> (let O (tm.root-outcome M)
         (if (= O none)
             (if (= (tm.runnable M) []) ["Deadlock" (map (/. W (fh.wait-entry W)) (tm.wait-graph M))] [])
             ["Completed" (fh.task-outcome O)])))

\\ ---------- a run under an explicit schedule ----------

\\ [Execution Detail Steps FinalState]. Stops at a footer, at the fuel bound, at the end
\\ of the schedule, or at a choice that is not Runnable (ScheduleDiverged).
(define fh.task-run
  Prog M Choices Fuel -> (fh.task-run-from Prog M Choices Fuel 0 []))

(define fh.task-run-from
  Prog M Choices Fuel Epoch Acc ->
    (let Footer (fh.task-footer M)
      (if (not (= Footer [])) [(hd Footer) (hd (tl Footer)) (reverse Acc) M]
          (if (>= Epoch Fuel) ["BudgetExhausted" [] (reverse Acc) M]
              (if (= Choices []) ["ScheduleIncomplete" [] (reverse Acc) M]
                  (if (not (element? (hd Choices) (tm.runnable M))) ["ScheduleDiverged" [] (reverse Acc) M]
                      (let R (tm.step Prog M (hd Choices))
                        (fh.task-run-from Prog (hd (tl R)) (tl Choices) Fuel (+ Epoch 1) [(fh.task-record Epoch (hd Choices) R) | Acc]))))))))

\\ The footer detail of a JavaScript run object.
(define fh.js-detail
  Run -> (let E (fh.field "execution" Run)
           (if (= E "Completed") (fh.field "outcome" Run) (if (= E "Deadlock") (fh.field "wait_graph" Run) []))))

\\ Same execution, same footer, same steps.
(define fh.task-same?
  [E D Steps _] Run -> (and (= E (fh.field "execution" Run)) (= (fh.canon D) (fh.canon (fh.js-detail Run)))
                            (= (fh.canon Steps) (fh.canon (fh.field "steps" Run)))))

\\ killed: an orderly run whose trace differs. survived: the same. crashed: it threw.
(define fh.task-verdict
  Model Run -> crashed where (= (fh.field "execution" Run) "Crashed")
  Model Run -> (if (fh.task-same? Model Run) survived killed))

\\ The nine defects of runtime/tc1/task-machine.mjs. The harness holds the list itself, so
\\ a batch that leaves one out cannot pass.
(define fh.task-defect-names
  -> ["stale_waiter" "waiter_not_woken" "waiter_woken_twice" "eager_cancel" "lifo_channel"
      "no_sibling_cancel" "capacity_off_by_one" "lost_wakeup_close" "lost_wakeup_await"])

\\ Tally the defective runs [[Name Run]...] of one schedule against the model's run.
\\ Tally is a list of [Name [[killed N] [survived N] [crashed N]]] (tc1-defects.shen).
(define fh.task-tally
  [] _ Tally -> Tally
  [[Name Run] | Runs] Model Tally -> (fh.task-tally Runs Model (fh.tally-one Name (fh.task-verdict Model Run) Tally)))

\\ The first epoch at which two step lists differ, or "none".
(define fh.task-divergence
  [] [] _ -> "none"
  [S | Ms] [T | Cs] I -> (if (= (fh.canon S) (fh.canon T)) (fh.task-divergence Ms Cs (+ I 1)) (str I))
  _ _ I -> (str I))

\\ Every switch of task follows a scheduling point or a task that stopped being Runnable
\\ (section 9), judged by the model's own records.
(define fh.production?
  [] -> true
  [_] -> true
  [S T | Ss] -> (and (or (= (fh.field "task" S) (fh.field "task" T)) (fh.field "point" S)
                         (not (element? (fh.field "task" S) (fh.field "runnable" S))))
                     (fh.production? [T | Ss])))

\\ The elements of Xs that satisfy F, in order.
(define fh.keep
  F [] -> []
  F [X | Xs] -> (if (F X) [X | (fh.keep F Xs)] (fh.keep F Xs)))

\\ All events of a run, in order.
(define fh.task-events
  [] -> []
  [S | Ss] -> (append (fh.field "events" S) (fh.task-events Ss)))
