\\ TC1 task machine, slice C1: structured tasks and bounded channels.
\\ Contract: spec/tc1/CONCURRENCY.md. UNQUALIFIED.
\\ Load ../tc0/i64.shen and handler-machine.shen first. This file adds to the TC1
\\ handler machine and changes nothing in it: every step of a task that is not one of
\\ C1's is the handler machine's own step (tc1.step), on the task's control,
\\ environment and frames. I64 values and every ID are canonical decimal strings.
\\
\\ Machine state: [tm Tasks Scopes Channels Awaits [NextTask NextScope NextChannel]]
\\   Task    [task Id Status Control Env Frames Cancel OwningScope]
\\           Status runnable | blocked | [terminal Outcome]; Cancel none | requested | delivered
\\   Scope   [scope Id Owner Phase Reason Children Failed Failures JoinWaiting]
\\           Phase open | joining | exited; Reason none | [normal V] | [trap Code] | cancelled | abandon
\\           Failures [[TaskId Code]...] in task-ID order
\\   Channel [chan Id Capacity Queue Closed Senders Receivers]
\\           Queue oldest first; Senders [[TaskId V]...] and Receivers [TaskId...] in registration order
\\   Awaits  [[Waiter Target]...] in registration order
\\ Tasks, scopes and channels are kept in increasing ID order.
\\ New controls: [start Closure], [wait Node Kind] (Kind [receive C] | [send C] | [await T]),
\\ [pending Node V], [join], [terminal]. New frame: [scope-frame Node S], Node implicit for a
\\ task's implicit scope. A task outcome is [ok V] | [trap Code] | cancelled.
\\ The program context Prog is [Codes Names], as the handler machine takes them.
\\ The schedule is an input: tm.step runs one step of the task it is given.

\\ ---------- initial state (section 4) ----------

\\ The root, task 0, runs the entry function's body on its input, over the frame of its
\\ implicit scope 0. Counters: next task 1, next scope 1, next channel 0.
(define tm.initial
  Param Body Input -> [tm [[task "0" runnable [evaluate Body true] [[Param Input]] [[scope-frame implicit "0"]] none none]]
                          [[scope "0" "0" open none [] false [] false]] [] [] [1 1 0]])

\\ ---------- records ----------

(define tm.find
  Id [[Tag Id | R] | _] -> [Tag Id | R]
  Id [_ | Rs] -> (tm.find Id Rs)
  Id [] -> (error "task machine: no record ~A" Id))

(define tm.replace
  [Tag Id | R] [[Tag Id | _] | Rs] -> [[Tag Id | R] | Rs]
  X [Y | Rs] -> [Y | (tm.replace X Rs)])

(define tm.task Id [tm Ts _ _ _ _] -> (tm.find Id Ts))
(define tm.scope Id [tm _ Ss _ _ _] -> (tm.find Id Ss))
(define tm.chan Id [tm _ _ Cs _ _] -> (tm.find Id Cs))
(define tm.put-task X [tm Ts Ss Cs As N] -> [tm (tm.replace X Ts) Ss Cs As N])
(define tm.put-scope X [tm Ts Ss Cs As N] -> [tm Ts (tm.replace X Ss) Cs As N])
(define tm.put-chan X [tm Ts Ss Cs As N] -> [tm Ts Ss (tm.replace X Cs) As N])

\\ Task fields.
(define tm.status [task _ S | _] -> S)
(define tm.control [task _ _ C | _] -> C)
(define tm.frames [task _ _ _ _ F | _] -> F)
(define tm.cancel [task _ _ _ _ _ K _] -> K)
(define tm.owner [task _ _ _ _ _ _ O] -> O)
(define tm.set-status S [task I _ C E F K O] -> [task I S C E F K O])
(define tm.set-control C [task I S _ E F K O] -> [task I S C E F K O])
(define tm.set-frames F [task I S C E _ K O] -> [task I S C E F K O])
(define tm.set-cancel K [task I S C E F _ O] -> [task I S C E F K O])

\\ Update task Id in M by F.
(define tm.update-task
  Id F M -> (tm.put-task (F (tm.task Id M)) M))

(define tm.terminal?
  [terminal _] -> true
  _ -> false)

(define tm.runnable
  [tm Ts | _] -> (tm.runnable-in Ts))

(define tm.runnable-in
  [] -> []
  [[task I runnable | _] | Ts] -> [I | (tm.runnable-in Ts)]
  [_ | Ts] -> (tm.runnable-in Ts))

\\ ---------- values ----------

(define tm.trap-ctor
  overflow -> "Overflow"
  div-zero -> "DivZero"
  bounds -> "Bounds"
  child-failed -> "ChildFailed")

\\ A task outcome as the Outcome value await returns.
(define tm.outcome-value
  [ok V] -> [data "Outcome" "Ok" V]
  cancelled -> [data "Outcome" "Cancelled"]
  [trap C] -> [data "Outcome" "Failed" [data "TrapCode" (tm.trap-ctor C)]])

\\ ---------- cancellation requests (section 6) ----------

\\ [M Events] after Requester asks for the cancellation of task X.
(define tm.request
  M Requester X -> (tm.request-task M Requester (tm.task X M)))

(define tm.request-task
  M R [task X [terminal O] | Rest] -> [M [[cancel-request R X false]]]
  M R [task X S C E F requested O] -> [M [[cancel-request R X false]]]
  M R [task X S C E F delivered O] -> [M [[cancel-request R X false]]]
  M R [task X blocked C E F none O] ->
    (let M2 (tm.put-task [task X runnable C E F requested O] M)
         Removed (tm.remove-registration M2 X C)
      [(hd Removed) [[cancel-request R X true] | (hd (tl Removed))]])
  M R [task X runnable C E F none O] -> [(tm.put-task [task X runnable C E F requested O] M) [[cancel-request R X true]]])

\\ Remove the registration of blocked task X, whose control is C: [M Events].
(define tm.remove-registration
  M X [wait N [receive Ch]] -> (tm.remove-from M X (tm.chan Ch M) receive)
  M X [wait N [send Ch]] -> (tm.remove-from M X (tm.chan Ch M) send)
  [tm Ts Ss Cs As N] X [wait Node [await Y]] -> [[tm Ts Ss Cs (remove [X Y] As) N] [[await-removed X Y]]]
  M X [join] -> [(tm.set-join-waiting (tm.scope (tm.top-scope (tm.frames (tm.task X M))) M) false M) []])

\\ Remove X from a channel's receivers or senders and stabilize it: [M Events].
(define tm.remove-from
  M X [chan Ch Cap Q Closed Ss Rs] receive ->
    (let Stable (tm.stabilize (tm.put-chan [chan Ch Cap Q Closed Ss (remove X Rs)] M) Ch)
      [(hd Stable) [[receive-removed X Ch] | (hd (tl Stable))]])
  M X [chan Ch Cap Q Closed Ss Rs] send ->
    (let Stable (tm.stabilize (tm.put-chan [chan Ch Cap Q Closed (tm.remove-sender X Ss) Rs] M) Ch)
      [(hd Stable) [[send-removed X Ch] | (hd (tl Stable))]]))

(define tm.set-join-waiting
  [scope S O P R Ch Fd Fs _] W M -> (tm.put-scope [scope S O P R Ch Fd Fs W] M))

(define tm.remove-sender
  X [[X V] | Ss] -> Ss
  X [S | Ss] -> [S | (tm.remove-sender X Ss)]
  X [] -> [])

(define tm.top-scope
  [[scope-frame N S] | _] -> S)

\\ Request cancellation of each task of Xs that is not Terminal, in order.
(define tm.request-all
  M R [] Acc -> [M Acc]
  M R [X | Xs] Acc ->
    (if (tm.terminal? (tm.status (tm.task X M)))
        (tm.request-all M R Xs Acc)
        (let Result (tm.request M R X)
          (tm.request-all (hd Result) R Xs (append Acc (hd (tl Result)))))))

\\ ---------- channels (section 5) ----------

\\ Commit V to the waiting task W: its control becomes Pending and it is Runnable.
(define tm.commit
  M W V -> (tm.update-task W (/. T (tm.commit-task T V)) M))

(define tm.commit-task
  [task I blocked [wait N K] E F C O] V -> [task I runnable [pending N V] E F C O])

\\ Stabilize channel Ch: [M Events].
(define tm.stabilize
  M Ch -> (tm.stabilize-chan M (tm.chan Ch M) []))

(define tm.stabilize-chan
  M [chan Ch Cap [V | Q] Closed Ss [R | Rs]] Acc ->
    (let M2 (tm.commit (tm.put-chan [chan Ch Cap Q Closed Ss Rs] M) R [data "ReceiveResult" "Item" V])
      (tm.stabilize-chan M2 (tm.chan Ch M2) (append Acc [[received R Ch V]])))
  M [chan Ch Cap Q false [[S V] | Ss] Rs] Acc ->
    (let M2 (tm.commit (tm.put-chan [chan Ch Cap (append Q [V]) false Ss Rs] M) S [data "SendResult" "Sent"])
      (tm.stabilize-chan M2 (tm.chan Ch M2) (append Acc [[sent S Ch]])))
      where (< (length Q) Cap)
  M _ Acc -> [M Acc])

\\ ---------- results of a step ----------

\\ A step result: [step M Site Events Point].
(define tm.result
  M Site Events Point -> [step M Site Events Point])

\\ Pending cancellation, delivered by a scheduling-point step in normal control.
(define tm.due?
  Task -> (= (tm.cancel Task) requested))

(define tm.deliver
  M [task I S C E F K O] Site ->
    (tm.result (tm.put-task [task I S [unwind cancelled] E F delivered O] M) Site [[cancel-effective I]] true))

\\ ---------- one step ----------

(define tm.step
  Prog M Id -> (tm.step-task Prog M (tm.task Id M)))

(define tm.step-task
  Prog M [task I runnable C E F K O] -> (tm.local Prog M [task I runnable C E F K O] C F)
  _ _ _ -> [schedule-error])

(define tm.runtime-op?
  Op -> (element? Op [spawn await cancel yield channel send receive close]))

(define tm.local
  Prog M Task [start Clo] _ -> (if (tm.due? Task) (tm.deliver M Task [machine task-start task-start]) (tm.start Prog M Task Clo))
  Prog M Task [evaluate [scope N Body] _] _ ->
    (if (tm.due? Task) (tm.deliver M Task [node N dispatch]) (tm.enter-scope M Task N Body))
  Prog M Task [evaluate [Op N | Args] Tail] _ -> (tm.collect Prog M Task Op N Args Tail) where (tm.runtime-op? Op)
  Prog M Task [evaluate [lambda N Id Body] _] _ -> (tm.lambda M Task N Id Body)
  Prog M Task [ready N Op Meta Vs Tail] _ ->
    (if (tm.due? Task) (tm.deliver M Task [node N ready]) (tm.ready M Task N Op Meta Vs)) where (tm.runtime-op? Op)
  Prog M Task [pending N V] _ -> (if (tm.due? Task) (tm.deliver M Task [node N wake])
                                     (tm.result (tm.put-task (tm.set-control [value V] Task) M) [node N wake] [] true))
  Prog M Task [wait N K] _ -> (if (tm.due? Task) (tm.deliver M Task [node N wake]) (error "task machine: Wait without a request"))
  Prog M Task [value V] [[scope-frame N S] | _] -> (tm.scope-close M Task N S V)
  Prog M Task [unwind R] [[scope-frame N S] | _] -> (tm.scope-abort M Task N S (if (= R cancelled) cancelled [trap R]))
  Prog M Task [abandon] [[scope-frame N S] | _] -> (tm.scope-abort M Task N S abandon)
  Prog M Task [join] [[scope-frame N S] | _] -> (tm.join M Task N S)
  Prog M Task [value V] [] -> (tm.terminate M Task [ok V])
  Prog M Task [unwind cancelled] [] -> (tm.terminate M Task cancelled)
  Prog M Task [unwind R] [] -> (tm.terminate M Task [trap R])
  Prog M Task _ _ -> (tm.pure Prog M Task))

\\ A lambda captures its free bindings, as in the handler machine, found by a walk that
\\ also knows C1's forms (tc1.free does not, and is not changed).
(define tm.lambda
  M [task I S C E F K O] Node Id Body ->
    (tm.result (tm.put-task [task I S [value [closure Node (tc1.capture (tc1.ordered (tc1.remove Id (tm.free Body))) E) []]] E F K O] M)
               [node Node dispatch] [] false))

(define tm.free-list
  [] -> []
  [X | Xs] -> (append (tm.free X) (tm.free-list Xs)))

(define tm.free
  [unit _] -> []
  [bool _ _] -> []
  [int _ _] -> []
  [bytes _ _] -> []
  [yield _] -> []
  [channel _ _] -> []
  [discontinue _ K] -> [K]
  [var _ Id] -> [Id]
  [let _ Id Init Body] -> (append (tm.free Init) (tc1.remove Id (tm.free Body)))
  [lambda _ Id Body] -> (tc1.remove Id (tm.free Body))
  [match _ E Arms] -> (append (tm.free E) (tm.free-arms Arms))
  [handle _ Effect Clauses Body] -> (append (tm.free-clauses Clauses) (tm.free Body))
  [resume _ K Arg] -> [K | (tm.free Arg)]
  [call _ Name Arg] -> (tm.free Arg)
  [emit _ Label Arg] -> (tm.free Arg)
  [perform _ Effect Op Arg] -> (tm.free Arg)
  [project _ E I] -> (tm.free E)
  [construct _ Type Ctor | Args] -> (tm.free-list Args)
  [prim _ Op | Args] -> (tm.free-list Args)
  [Tag _ | Args] -> (tm.free-list Args))

(define tm.free-arms
  [] -> []
  [[Ctor Binders Body] | Arms] -> (append (tc1.remove-all Binders (tm.free Body)) (tm.free-arms Arms)))

(define tm.free-clauses
  [] -> []
  [[Op Binder Body] | Clauses] -> (append (tc1.remove Binder (tm.free Body)) (tm.free-clauses Clauses))
  [[Op Binder K Body] | Clauses] -> (append (tc1.remove K (tc1.remove Binder (tm.free Body))) (tm.free-clauses Clauses)))

\\ Every other step is the handler machine's, on this task's local state. Only emit
\\ produces events there; C1 keeps its Emit event and not its Invoke and Commit.
(define tm.pure
  [Codes Names] M [task I S C E F K O] ->
    (let Local [tc1-state C E F Codes Names]
         T (tc1.step Local)
      (tm.result (tm.put-task (tm.adopt [task I S C E F K O] (hd (tl T))) M) (tc1.site Local) (tm.emits I (hd (tl (tl T)))) false)))

\\ The task with the control, environment and frames of a handler-machine state.
(define tm.adopt
  [task I S _ _ _ K O] [tc1-state C E F _ _] -> [task I S C E F K O])

(define tm.emits
  I [] -> []
  I [[emit Node Label V] | Es] -> [[emit I Label V] | (tm.emits I Es)]
  I [_ | Es] -> (tm.emits I Es))

\\ Dispatch of a runtime operation: collect its operands, as the handler machine does
\\ for every strict form. yield and channel have none and are Ready at once.
(define tm.collect
  [Codes Names] M [task I S C E F K O] Op N Args Tail ->
    (let Operands (if (= Op channel) [] Args)
         Meta (if (= Op channel) (hd Args) none)
         T (tc1.collect N Op Meta Operands Tail E F Codes Names)
      (tm.result (tm.put-task (tm.adopt [task I S C E F K O] (hd (tl T))) M) [node N dispatch] [] false)))

\\ TaskStart: apply the spawned closure to unit, its body in tail position.
(define tm.start
  [Codes Names] M [task I S C E F K O] [closure Code Captures []] ->
    (let Lambda (tc1.lookup Code Codes)
      (tm.result (tm.put-task [task I S [evaluate (hd (tl Lambda)) true] [[(hd Lambda) [unit]] | Captures] F K O] M) [machine task-start task-start] [] true)))

(define tm.enter-scope
  [tm Ts Ss Cs As [NT NS NC]] [task I S C E F K O] N Body ->
    (let Sid (str NS)
         M [tm Ts (append Ss [[scope Sid I open none [] false [] false]]) Cs As [NT (+ NS 1) NC]]
      (tm.result (tm.put-task [task I S [evaluate Body true] E [[scope-frame N Sid] | F] K O] M) [node N dispatch] [[scope-enter I Sid]] true)))

\\ ---------- Ready of a runtime operation (section 5) ----------

\\ Set the stepping task's control to C and status to St.
(define tm.continue
  M I C St -> (tm.update-task I (/. T (tm.set-status St (tm.set-control C T))) M))

(define tm.ready
  M Task N Op Meta Vs -> (tm.op M Task N Op Meta Vs))

(define tm.op
  M [task I S C E F K O] N spawn _ [Clo] ->
    (let Owning (tm.innermost-scope F)
      (if (tm.failed? (tm.scope Owning M))
          (tm.result (tm.continue M I [unwind child-failed] runnable) [node N ready] [] true)
          (tm.spawn M I N Clo F Owning)))
  M [task I | _] N await _ [[task-handle X]] ->
    (let Target (tm.status (tm.task X M))
      (if (tm.terminal? Target)
          (tm.result (tm.continue M I [value (tm.outcome-value (hd (tl Target)))] runnable) [node N ready] [[await I X] [awaited I X (hd (tl Target))]] true)
          (tm.result (tm.add-await (tm.continue M I [wait N [await X]] blocked) [I X]) [node N ready] [[await I X] [await-wait I X]] true)))
  M [task I | _] N cancel _ [[task-handle X]] ->
    (let Result (tm.request M I X)
      (tm.result (tm.continue (hd Result) I [value [unit]] runnable) [node N ready] (hd (tl Result)) true))
  M [task I | _] N yield _ [] -> (tm.result (tm.continue M I [value [unit]] runnable) [node N ready] [[yield I]] true)
  [tm Ts Ss Cs As [NT NS NC]] [task I | _] N channel Cap [] ->
    (let Ch (str NC)
         M [tm Ts Ss (append Cs [[chan Ch (tc0.i64.small Cap) [] false [] []]]) As [NT NS (+ NC 1)]]
      (tm.result (tm.continue M I [value [channel-handle Ch]] runnable) [node N ready] [[channel I Ch Cap]] true))
  M [task I | _] N send _ [[channel-handle Ch] V] -> (tm.send M I N (tm.chan Ch M) V)
  M [task I | _] N receive _ [[channel-handle Ch]] -> (tm.receive M I N (tm.chan Ch M))
  M [task I | _] N close _ [[channel-handle Ch]] -> (tm.close M I N (tm.chan Ch M)))

\\ The innermost scope frame among the active frames: those of the frame list itself,
\\ not of a suspended segment held in a clause frame or a resumption.
(define tm.failed?
  [scope S O P R Ch Fd | _] -> Fd)

(define tm.add-await
  [tm Ts Ss Cs As N] A -> [tm Ts Ss Cs (append As [A]) N])

(define tm.innermost-scope
  [[scope-frame N S] | _] -> S
  [_ | Fs] -> (tm.innermost-scope Fs))

\\ The handler frames among the active frames, in order: what a child gets.
(define tm.handlers
  [] -> []
  [[handler | H] | Fs] -> [[handler | H] | (tm.handlers Fs)]
  [_ | Fs] -> (tm.handlers Fs))

(define tm.spawn
  [tm Ts Ss Cs As [NT NS NC]] I N Clo Frames Owning ->
    (let Child (str NT)
         Implicit (str NS)
         Ss2 (append (tm.replace (tm.add-child (tm.find Owning Ss) Child) Ss) [[scope Implicit Child open none [] false [] false]])
         Ts2 (append Ts [[task Child runnable [start Clo] [] (append (tm.handlers Frames) [[scope-frame implicit Implicit]]) none Owning]])
         M [tm Ts2 Ss2 Cs As [(+ NT 1) (+ NS 1) NC]]
      (tm.result (tm.continue M I [value [task-handle Child]] runnable) [node N ready] [[spawn I Child Owning Implicit]] true)))

(define tm.add-child
  [scope S O P R Ch Fd Fs W] C -> [scope S O P R (append Ch [C]) Fd Fs W])

(define tm.send
  M I N [chan Ch Cap Q true Ss Rs] V ->
    (tm.result (tm.continue M I [value [data "SendResult" "Closed"]] runnable) [node N ready] [[send I Ch V] [send-closed I Ch]] true)
  M I N [chan Ch Cap Q false Ss Rs] V ->
    (let Stable (tm.stabilize (tm.put-chan [chan Ch Cap (append Q [V]) false Ss Rs] M) Ch)
      (tm.result (tm.continue (hd Stable) I [value [data "SendResult" "Sent"]] runnable) [node N ready]
                 [[send I Ch V] [sent I Ch] | (hd (tl Stable))] true))
      where (< (length Q) Cap)
  M I N [chan Ch Cap Q false Ss Rs] V ->
    (tm.result (tm.continue (tm.put-chan [chan Ch Cap Q false (append Ss [[I V]]) Rs] M) I [wait N [send Ch]] blocked) [node N ready]
               [[send I Ch V] [send-wait I Ch]] true))

(define tm.receive
  M I N [chan Ch Cap [V | Q] Closed Ss Rs] ->
    (let Stable (tm.stabilize (tm.put-chan [chan Ch Cap Q Closed Ss Rs] M) Ch)
      (tm.result (tm.continue (hd Stable) I [value [data "ReceiveResult" "Item" V]] runnable) [node N ready]
                 [[receive I Ch] [received I Ch V] | (hd (tl Stable))] true))
  M I N [chan Ch Cap [] true Ss Rs] ->
    (tm.result (tm.continue M I [value [data "ReceiveResult" "End"]] runnable) [node N ready] [[receive I Ch] [end I Ch]] true)
  M I N [chan Ch Cap [] false Ss Rs] ->
    (tm.result (tm.continue (tm.put-chan [chan Ch Cap [] false Ss (append Rs [I])] M) I [wait N [receive Ch]] blocked) [node N ready]
               [[receive I Ch] [receive-wait I Ch]] true))

(define tm.close
  M I N [chan Ch Cap Q true Ss Rs] ->
    (tm.result (tm.continue M I [value [unit]] runnable) [node N ready] [[close I Ch false]] true)
  M I N [chan Ch Cap Q false Ss Rs] ->
    (let Senders (tm.commit-all (tm.put-chan [chan Ch Cap Q true [] Rs] M) (map (/. P (hd P)) Ss) [data "SendResult" "Closed"] (/. S [send-closed S Ch]) [])
         Served (tm.stabilize (hd Senders) Ch)
         Ends (tm.end-receivers (hd Served) (tm.chan Ch (hd Served)))
      (tm.result (tm.continue (hd Ends) I [value [unit]] runnable) [node N ready]
                 (append [[close I Ch true]] (hd (tl Senders)) (hd (tl Served)) (hd (tl Ends))) true)))

\\ After a first close: commit End to the receivers still waiting once the queue is empty.
(define tm.end-receivers
  M [chan Ch Cap [] Closed Ss Rs] -> (tm.commit-all (tm.put-chan [chan Ch Cap [] Closed Ss []] M) Rs [data "ReceiveResult" "End"] (/. R [end R Ch]) [])
  M _ -> [M []])

\\ Commit V to each of the waiting tasks Ws, in order, with one event each: [M Events].
(define tm.commit-all
  M [] V Event Acc -> [M Acc]
  M [W | Ws] V Event Acc -> (tm.commit-all (tm.commit M W V) Ws V Event (append Acc [(Event W)])))

\\ ---------- scopes, joins and termination (section 7) ----------

(define tm.scope-site
  implicit Rule -> [machine task-scope Rule]
  N Rule -> [node N Rule])

(define tm.scope-close
  M Task N S V -> (tm.scope-close-rec M Task N (tm.scope S M) V))

(define tm.scope-close-rec
  M [task I | _] N [scope S Ow P R Ch Fd Fs W] V ->
    (tm.result (tm.continue (tm.put-scope [scope S Ow joining [normal V] Ch Fd Fs W] M) I [join] runnable) (tm.scope-site N scope-close) [] false))

(define tm.scope-abort
  M Task N S Reason -> (tm.scope-abort-rec M Task N (tm.scope S M) Reason))

(define tm.scope-abort-rec
  M [task I | _] N [scope S Ow P R Ch Fd Fs W] Reason ->
    (let Requests (tm.request-all (tm.put-scope [scope S Ow joining Reason Ch Fd Fs W] M) I Ch [])
      (tm.result (tm.continue (hd Requests) I [join] runnable) (tm.scope-site N scope-abort) (hd (tl Requests)) true)))

(define tm.all-terminal?
  M [] -> true
  M [X | Xs] -> (and (tm.terminal? (tm.status (tm.task X M))) (tm.all-terminal? M Xs)))

(define tm.join
  M Task N S -> (tm.join-rec M Task N (tm.scope S M)))

(define tm.normal?
  [normal _] -> true
  _ -> false)

(define tm.join-rec
  M [task I St C E F K O] N [scope S Ow P R Ch Fd Fs W] ->
      (if (and (= K requested) (tm.normal? R))
          (let Requests (tm.request-all (tm.put-scope [scope S Ow P cancelled Ch Fd Fs W] (tm.put-task [task I St C E F delivered O] M)) I Ch [])
            (tm.result (hd Requests) (tm.scope-site N join) [[cancel-effective I] | (hd (tl Requests))] true))
          (if (tm.all-terminal? M Ch)
              (let Exit (tm.exit R Fd)
                (tm.result (tm.put-scope [scope S Ow exited R Ch Fd Fs false] (tm.put-task [task I St (hd Exit) E (tl F) K O] M))
                           (tm.scope-site N join) [[scope-exit I S (hd (tl Exit))]] true))
              (tm.result (tm.put-scope [scope S Ow P R Ch Fd Fs true] (tm.put-task [task I blocked C E F K O] M)) (tm.scope-site N join) [] true))))

\\ [Control ScopeExitOutcome] for a scope's reason and failure latch.
(define tm.exit
  [normal V] false -> [[value V] [ok V]]
  [normal V] true -> [[unwind child-failed] [trap child-failed]]
  [trap C] _ -> [[unwind C] [trap C]]
  cancelled _ -> [[unwind cancelled] cancelled]
  abandon _ -> [[abandon] abandoned])

(define tm.terminate
  M [task I St C E F K O] Outcome ->
    (let M2 (tm.put-task [task I [terminal Outcome] [terminal] E F K O] M)
         Failed (tm.latch M2 I O Outcome)
         Awaited (tm.wake-awaiters (hd Failed) I Outcome)
         Woken (tm.wake-owner (hd Awaited) O)
      (tm.result Woken [machine terminate terminate] (append [[termination I Outcome]] (hd (tl Failed)) (hd (tl Awaited))) true)))

\\ A trap is latched into the owning scope, and the other nonterminal children are
\\ requested cancelled in task-ID order. The root has no owning scope.
(define tm.latch
  M I none _ -> [M []]
  M I S [trap Code] -> (tm.latch-rec M I (tm.scope S M) Code)
  M _ _ _ -> [M []])

(define tm.latch-rec
  M I [scope S Ow P R Ch Fd Fs W] Code ->
    (let Requests (tm.request-all (tm.put-scope [scope S Ow P R Ch true (tm.insert-failure [I Code] Fs) W] M) I Ch [])
      [(hd Requests) [[scope-failure I S Code] | (hd (tl Requests))]]))

(define tm.insert-failure
  F [] -> [F]
  [I C] [[J D] | Fs] -> [[I C] [J D] | Fs] where (< (tc0.i64.compare I J) 0)
  F [G | Fs] -> [G | (tm.insert-failure F Fs)])

(define tm.wake-awaiters
  [tm Ts Ss Cs As N] I Outcome ->
    (let Waiters (tm.waiters-of I As)
         M [tm Ts Ss Cs (tm.not-waiting-on I As) N]
      (tm.commit-all M Waiters (tm.outcome-value Outcome) (/. W [awaited W I Outcome]) [])))

(define tm.waiters-of
  I [] -> []
  I [[W I] | As] -> [W | (tm.waiters-of I As)]
  I [_ | As] -> (tm.waiters-of I As))

(define tm.not-waiting-on
  I [] -> []
  I [[W I] | As] -> (tm.not-waiting-on I As)
  I [A | As] -> [A | (tm.not-waiting-on I As)])

\\ The owner of scope S is woken when it waits on the join and every child is Terminal.
(define tm.wake-owner
  M none -> M
  M S -> (tm.wake-owner-rec M (tm.scope S M)))

(define tm.wake-owner-rec
  M [scope S Ow P R Ch Fd Fs W] ->
    (if (and W (tm.all-terminal? M Ch))
        (tm.update-task Ow (/. T (tm.set-status runnable T)) (tm.put-scope [scope S Ow P R Ch Fd Fs false] M))
        M))

\\ ---------- records and footers ----------

(define tm.after
  [evaluate | _] -> "Eval"
  [value | _] -> "Value"
  [ready | _] -> "Ready"
  [unwind | _] -> "Unwind"
  [abandon | _] -> "Abandon"
  [wait | _] -> "Wait"
  [join] -> "Join"
  [terminal] -> "Terminal")

\\ The root outcome when the root is Terminal, else none.
(define tm.root-outcome
  M -> (let S (tm.status (tm.task "0" M)) (if (tm.terminal? S) (hd (tl S)) none)))

\\ The wait graph: each nonterminal task in ID order with what it waits for.
(define tm.wait-graph
  [tm Ts | _] -> (tm.waits Ts))

(define tm.waits
  [] -> []
  [[task I [terminal _] | _] | Ts] -> (tm.waits Ts)
  [[task I S [wait N K] | _] | Ts] -> [[I K] | (tm.waits Ts)]
  [[task I S [join] E F | _] | Ts] -> [[I [join (tm.top-scope F)]] | (tm.waits Ts)]
  [[task I S C | _] | Ts] -> [[I [running]] | (tm.waits Ts)])
