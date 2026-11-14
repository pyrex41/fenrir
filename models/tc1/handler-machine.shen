\\ TC1 handler machine, slice H1: the TC0-A pure-call machine plus user effects with
\\ tail-resumptive handlers. Contract: spec/tc1/EFFECTS.md. UNQUALIFIED.
\\ Load ../tc0/i64.shen first. The TC0-A rules are those of
\\ ../tc0/pure-call-machine.shen, restated under the tc1. prefix so that file and
\\ its gate stay untouched; the additions are marked "H1".
\\ I64 values and every ID are canonical decimal strings.
\\
\\ H1 representation. The continuation is the frame list. A handler is a frame
\\ [handler Node Effect Clauses Env], installed when its handle node is entered and
\\ removed when its body returns. While a clause runs, the frames from the perform
\\ site through the selected handler (the suspended segment) are held inside one
\\ frame [clause-return Node Segment Env] on top of the frames outside the handler.
\\ So the clause's active handlers are exactly the ones outside the selected
\\ handler: the selected handler and any handlers between it and the perform site
\\ are inactive, and a perform of the same effect in a clause forwards outward.
\\ Clauses are [Operation Binder Body].
(define tc1.lookup
 Id [[Id V] | Rest] -> V
 Id [_ | Rest] -> (tc1.lookup Id Rest)
 Id [] -> [invalid unknown-binding])
(define tc1.remove
 Id [] -> []
 Id [Id | Rest] -> (tc1.remove Id Rest)
 Id [X | Rest] -> [X | (tc1.remove Id Rest)])
(define tc1.free-list
 [] -> []
 [E | Rest] -> (append (tc1.free E) (tc1.free-list Rest)))
(define tc1.free
 [unit Node] -> []
 [bool Node B] -> []
 [int Node N] -> []
 [var Node Id] -> [Id]
 [let Node Id Init Body] -> (append (tc1.free Init) (tc1.remove Id (tc1.free Body)))
 [lambda Node Id Body] -> (tc1.remove Id (tc1.free Body))
 [call Node Name Arg] -> (tc1.free Arg)
 [emit Node Label Arg] -> (tc1.free Arg)
 [prim Node Op | Args] -> (tc1.free-list Args)
 [bytes Node Octets] -> []
 [tuple Node | Args] -> (tc1.free-list Args)
 [project Node E I] -> (tc1.free E)
 [construct Node Type Ctor | Args] -> (tc1.free-list Args)
 [match Node E Arms] -> (append (tc1.free E) (tc1.free-arms Arms))
 [handle Node Effect Clauses Body] -> (append (tc1.free-clauses Clauses) (tc1.free Body))
 [perform Node Effect Op Arg] -> (tc1.free Arg)
 [if Node | Args] -> (tc1.free-list Args)
 [apply Node | Args] -> (tc1.free-list Args))
(define tc1.remove-all
 [] Ids -> Ids
 [B | Bs] Ids -> (tc1.remove-all Bs (tc1.remove B Ids)))
\\ H1: a clause's binder is bound in its body.
(define tc1.free-clauses
 [] -> []
 [[Op Binder Body] | Clauses] -> (append (tc1.remove Binder (tc1.free Body)) (tc1.free-clauses Clauses)))
(define tc1.free-arms
 [] -> []
 [[Ctor Binders Body] | Arms] -> (append (tc1.remove-all Binders (tc1.free Body)) (tc1.free-arms Arms)))
\\ Capture order: IDs are unsigned canonical decimal strings, ordered numerically.
(define tc1.insert
 Id [] -> [Id]
 Id [Id | Rest] -> [Id | Rest]
 Id [X | Rest] -> [Id X | Rest] where (< (tc0.i64.compare Id X) 0)
 Id [X | Rest] -> [X | (tc1.insert Id Rest)])
(define tc1.ordered
 [] -> []
 [Id | Rest] -> (tc1.insert Id (tc1.ordered Rest)))
(define tc1.capture
 [] Env -> []
 [Id | Rest] Env -> [[Id (tc1.lookup Id Env)] | (tc1.capture Rest Env)])
(define tc1.transition
 C Env Frames Codes Names Events -> [transition [tc1-state C Env Frames Codes Names] Events])
(define tc1.frame-env
 [bind Node Id Body Env Tail] -> Env
 [branch Node Yes No Env Tail] -> Env
 [select Node Arms Env Tail] -> Env
 [collect Node Op Meta Rest Values Env Tail] -> Env
 [return Node Env] -> Env
 [handler Node Effect Clauses Env] -> Env
 [clause-return Node Segment Env] -> Env)
(define tc1.collect
 Node Op Meta [First | Rest] Tail Env Frames Codes Names ->
 (tc1.transition [evaluate First false] Env [[collect Node Op Meta Rest [] Env Tail] | Frames] Codes Names [])
 Node Op Meta [] Tail Env Frames Codes Names ->
 (tc1.transition [ready Node Op Meta [] Tail] Env Frames Codes Names []))
(define tc1.dispatch
 [unit Node] Tail Env Frames Codes Names -> (tc1.transition [value [unit]] Env Frames Codes Names [])
 [int Node N] Tail Env Frames Codes Names -> (tc1.transition [value [int N]] Env Frames Codes Names [])
 [bool Node B] Tail Env Frames Codes Names -> (tc1.transition [value [bool B]] Env Frames Codes Names [])
 [bytes Node Octets] Tail Env Frames Codes Names -> (tc1.transition [value [bytes Octets]] Env Frames Codes Names [])
 [var Node Id] Tail Env Frames Codes Names -> (tc1.transition [value (tc1.lookup Id Env)] Env Frames Codes Names [])
 [lambda Node Id Body] Tail Env Frames Codes Names ->
 (tc1.transition [value [closure Node (tc1.capture (tc1.ordered (tc1.remove Id (tc1.free Body))) Env) []]] Env Frames Codes Names [])
 [let Node Id Init Body] Tail Env Frames Codes Names ->
 (tc1.transition [evaluate Init false] Env [[bind Node Id Body Env Tail] | Frames] Codes Names [])
 [if Node Cond Yes No] Tail Env Frames Codes Names ->
 (tc1.transition [evaluate Cond false] Env [[branch Node Yes No Env Tail] | Frames] Codes Names [])
 [match Node E Arms] Tail Env Frames Codes Names ->
 (tc1.transition [evaluate E false] Env [[select Node Arms Env Tail] | Frames] Codes Names [])
 [prim Node Op | Args] Tail Env Frames Codes Names -> (tc1.collect Node Op none Args Tail Env Frames Codes Names)
 [tuple Node | Args] Tail Env Frames Codes Names -> (tc1.collect Node tuple none Args Tail Env Frames Codes Names)
 [project Node E I] Tail Env Frames Codes Names -> (tc1.collect Node project I [E] Tail Env Frames Codes Names)
 [construct Node Type Ctor | Args] Tail Env Frames Codes Names -> (tc1.collect Node construct [Type Ctor] Args Tail Env Frames Codes Names)
 [apply Node A B] Tail Env Frames Codes Names -> (tc1.collect Node apply none [A B] Tail Env Frames Codes Names)
 [call Node Name Arg] Tail Env Frames Codes Names -> (tc1.collect Node call Name [Arg] Tail Env Frames Codes Names)
 [emit Node Label Arg] Tail Env Frames Codes Names -> (tc1.collect Node emit Label [Arg] Tail Env Frames Codes Names)
 \\ H1: install the handler and enter the body. The handler frame is the body's return
 \\ destination, so a call in the body's tail position needs no return frame of its own.
 [handle Node Effect Clauses Body] Tail Env Frames Codes Names ->
 (tc1.transition [evaluate Body true] Env [[handler Node Effect Clauses Env] | Frames] Codes Names [])
 \\ H1: perform collects its one argument, like a call.
 [perform Node Effect Op Arg] Tail Env Frames Codes Names -> (tc1.collect Node perform [Effect Op] [Arg] Tail Env Frames Codes Names))
(define tc1.numbers
 [] -> []
 [[int N] | Rest] -> [N | (tc1.numbers Rest)])
(define tc1.index
 Os N -> [ok (str (nth (+ N 1) Os))] where (and (>= N 0) (< N (length Os)))
 _ _ -> [trap bounds])
(define tc1.pure
 not [[bool B]] -> [ok-bool (not B)]
 lt [[int A] [int B]] -> [ok-bool (< (tc0.i64.compare A B) 0)]
 le [[int A] [int B]] -> [ok-bool (<= (tc0.i64.compare A B) 0)]
 gt [[int A] [int B]] -> [ok-bool (> (tc0.i64.compare A B) 0)]
 ge [[int A] [int B]] -> [ok-bool (>= (tc0.i64.compare A B) 0)]
 eq [A B] -> [ok-bool (= A B)]
 bytes_length [[bytes Os]] -> [ok (str (length Os))]
 bytes_concat [[bytes A] [bytes B]] -> [ok-value [bytes (append A B)]]
 bytes_index [[bytes Os] [int I]] -> (tc1.index Os (tc0.i64.small I))
 Op Values -> (tc0.arithmetic Op (tc1.numbers Values)))
(define tc1.pure-return
 [ok N] Env Frames Codes Names -> (tc1.transition [value [int N]] Env Frames Codes Names [])
 [ok-bool B] Env Frames Codes Names -> (tc1.transition [value [bool B]] Env Frames Codes Names [])
 [ok-value V] Env Frames Codes Names -> (tc1.transition [value V] Env Frames Codes Names [])
 [trap Code] Env Frames Codes Names -> (tc1.transition [unwind Code] Env Frames Codes Names []))
(define tc1.arm
 Ctor [[Ctor Binders Body] | Arms] -> [Binders Body]
 Ctor [Arm | Arms] -> (tc1.arm Ctor Arms)
 Ctor [] -> [invalid no-match-arm])
(define tc1.bind
 [] [] Env -> Env
 [B | Bs] [V | Vs] Env -> (tc1.bind Bs Vs [[B V] | Env]))
(define tc1.select
 [Binders Body] Fields Env Tail Frames Codes Names ->
 (tc1.transition [evaluate Body Tail] (tc1.bind Binders Fields Env) Frames Codes Names []))
(define tc1.enter
 [Id Body] Captures Arg true Node Env Frames Codes Names ->
 (tc1.transition [evaluate Body true] [[Id Arg] | Captures] Frames Codes Names [])
 [Id Body] Captures Arg false Node Env Frames Codes Names ->
 (tc1.transition [evaluate Body true] [[Id Arg] | Captures] [[return Node Env] | Frames] Codes Names []))
\\ H1: split the frames at the innermost handler for Effect.
\\ Result [Segment Outer HandlerEnv Clauses]; Segment includes the handler frame.
(define tc1.split
 Effect [] Acc -> [invalid unhandled-effect]
 Effect [[handler Node Effect Clauses HEnv] | Outer] Acc -> [(reverse [[handler Node Effect Clauses HEnv] | Acc]) Outer HEnv Clauses]
 Effect [Frame | Frames] Acc -> (tc1.split Effect Frames [Frame | Acc]))
(define tc1.clause
 Op [[Op Binder Body] | _] -> [Binder Body]
 Op [_ | Clauses] -> (tc1.clause Op Clauses)
 Op [] -> [invalid no-clause])
\\ H1: enter the clause in the handler's definition environment plus its binder, with
\\ the suspended segment held in a clause-return frame over the outer frames.
(define tc1.enter-clause
 Node Effect Op V Env [Segment Outer HEnv Clauses] Codes Names ->
 (tc1.run-clause Node Effect Op V Env Segment Outer HEnv (tc1.clause Op Clauses) Codes Names))
(define tc1.run-clause
 Node Effect Op V Env Segment Outer HEnv [Binder Body] Codes Names ->
 (tc1.transition [evaluate Body true] [[Binder V] | HEnv] [[clause-return Node Segment Env] | Outer] Codes Names [[perform Node Effect Op V]]))
(define tc1.step
 [tc1-state [evaluate E Tail] Env Frames Codes Names] -> (tc1.dispatch E Tail Env Frames Codes Names)
 [tc1-state [value V] Env [[bind Node Id Body OldEnv Tail] | Frames] Codes Names] ->
 (tc1.transition [evaluate Body Tail] [[Id V] | OldEnv] Frames Codes Names [])
 [tc1-state [value [bool B]] Env [[branch Node Yes No OldEnv Tail] | Frames] Codes Names] ->
 (tc1.transition [evaluate (if B Yes No) Tail] OldEnv Frames Codes Names [])
 [tc1-state [value [data Type Ctor | Fields]] Env [[select Node Arms OldEnv Tail] | Frames] Codes Names] ->
 (tc1.select (tc1.arm Ctor Arms) Fields OldEnv Tail Frames Codes Names)
 [tc1-state [value V] Env [[return Node OldEnv] | Frames] Codes Names] ->
 (tc1.transition [value V] OldEnv Frames Codes Names [])
 [tc1-state [value V] Env [[collect Node Op Meta [Next | Rest] Values OldEnv Tail] | Frames] Codes Names] ->
 (tc1.transition [evaluate Next false] OldEnv [[collect Node Op Meta Rest [V | Values] OldEnv Tail] | Frames] Codes Names [])
 [tc1-state [value V] Env [[collect Node Op Meta [] Values OldEnv Tail] | Frames] Codes Names] ->
 (tc1.transition [ready Node Op Meta (reverse [V | Values]) Tail] OldEnv Frames Codes Names [])
 \\ H1: the body returned; remove the handler and pass the value through unchanged.
 [tc1-state [value V] Env [[handler Node Effect Clauses OldEnv] | Frames] Codes Names] ->
 (tc1.transition [value V] OldEnv Frames Codes Names [])
 \\ H1: the clause returned; restore the suspended segment and supply the value at the
 \\ perform site. The handler is active again in the resumed body.
 [tc1-state [value V] Env [[clause-return Node Segment OldEnv] | Outer] Codes Names] ->
 (tc1.transition [value V] OldEnv (append Segment Outer) Codes Names [[resume Node V]])
 [tc1-state [value V] Env [] Codes Names] -> (tc1.transition [join [ok V]] Env [] Codes Names [])
 [tc1-state [ready Node call Name [Arg] Tail] Env Frames Codes Names] ->
 (tc1.enter (tc1.lookup (tc1.lookup Name Names) Codes) [] Arg Tail Node Env Frames Codes Names)
 [tc1-state [ready Node apply Meta [[closure Code Captures []] Arg] Tail] Env Frames Codes Names] ->
 (tc1.enter (tc1.lookup Code Codes) Captures Arg Tail Node Env Frames Codes Names)
 \\ H1: select the innermost active handler for the effect and enter its clause.
 [tc1-state [ready Node perform [Effect Op] [V] Tail] Env Frames Codes Names] ->
 (tc1.enter-clause Node Effect Op V Env (tc1.split Effect Frames []) Codes Names)
 [tc1-state [ready Node emit Label [V] Tail] Env Frames Codes Names] ->
 (tc1.transition [value [unit]] Env Frames Codes Names [[invoke Node Label V] [emit Node Label V] [commit Node [unit]]])
 [tc1-state [ready Node tuple Meta Values Tail] Env Frames Codes Names] ->
 (tc1.transition [value [tuple | Values]] Env Frames Codes Names [])
 [tc1-state [ready Node construct [Type Ctor] Values Tail] Env Frames Codes Names] ->
 (tc1.transition [value [data Type Ctor | Values]] Env Frames Codes Names [])
 [tc1-state [ready Node project I [[tuple | Fields]] Tail] Env Frames Codes Names] ->
 (tc1.transition [value (nth (+ I 1) Fields)] Env Frames Codes Names [])
 [tc1-state [ready Node Op Meta Values Tail] Env Frames Codes Names] ->
 (tc1.pure-return (tc1.pure Op Values) Env Frames Codes Names)
 \\ H1: a trap in a clause aborts instead of resuming. The clause's own frames are
 \\ already discarded; this step discards the clause-return frame and exposes the
 \\ suspended segment, which then unwinds one frame per step like any other.
 [tc1-state [unwind Code] Env [[clause-return Node Segment OldEnv] | Outer] Codes Names] ->
 (tc1.transition [unwind Code] OldEnv (append Segment Outer) Codes Names [])
 [tc1-state [unwind Code] Env [Frame | Frames] Codes Names] ->
 (tc1.transition [unwind Code] (tc1.frame-env Frame) Frames Codes Names [])
 [tc1-state [unwind Code] Env [] Codes Names] -> (tc1.transition [join [trap Code]] Env [] Codes Names [])
 [tc1-state [join Outcome] Env [] Codes Names] -> (tc1.transition [terminate Outcome] Env [] Codes Names [[scope-exit Outcome]])
 [tc1-state [terminate Outcome] Env [] Codes Names] -> (tc1.transition [terminal Outcome] Env [] Codes Names [[task-termination Outcome]]))
(define tc1.site
 [tc1-state [evaluate [Tag Node | Args] Tail] Env Frames Codes Names] -> [node Node dispatch]
 [tc1-state [ready Node Op Meta Values Tail] Env Frames Codes Names] -> [node Node ready]
 [tc1-state [value V] Env [[bind Node | Rest] | Frames] Codes Names] -> [node Node let-return]
 [tc1-state [value V] Env [[branch Node | Rest] | Frames] Codes Names] -> [node Node if-return]
 [tc1-state [value V] Env [[select Node | Rest] | Frames] Codes Names] -> [node Node match-return]
 [tc1-state [value V] Env [[collect Node | Rest] | Frames] Codes Names] -> [node Node collect-return]
 [tc1-state [value V] Env [[return Node | Rest] | Frames] Codes Names] -> [node Node return-return]
 [tc1-state [value V] Env [[handler Node | Rest] | Frames] Codes Names] -> [node Node handle-return]
 [tc1-state [value V] Env [[clause-return Node | Rest] | Frames] Codes Names] -> [node Node clause-return]
 [tc1-state [unwind Code] Env [[Tag Node | Rest] | Frames] Codes Names] -> [node Node unwind-frame]
 [tc1-state [value V] Env [] Codes Names] -> [machine root-join-entry value]
 [tc1-state [unwind Code] Env [] Codes Names] -> [machine root-join-entry unwind]
 [tc1-state [join Outcome] Env [] Codes Names] -> [machine join join]
 [tc1-state [terminate Outcome] Env [] Codes Names] -> [machine terminate terminate])
(define tc1.sample
 State -> (let T (tc1.step State) (let Next (hd (tl T))
 [sample (tc1.site State) (hd (hd (tl Next))) (length (hd (tl (tl (tl Next))))) (hd (tl (tl T)))])))
