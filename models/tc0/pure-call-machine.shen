\\ UNQUALIFIED integrated pure-call demo. Load arithmetic.shen first.
\\ Explicit target continuations; names/codes are ordered host-validated tables.
\\ The evaluation phase is tagged `evaluate`, not `eval`: a literal `eval` symbol
\\ makes Yggdrasil keep the whole compiler, since a symbol may be applied.
\\ Schema /2 data values: [bytes Octets] with Octets a list of integers 0-255,
\\ [tuple V ...] and [data Type Constructor V ...] (TrapCode is a built-in enum).
(define tc0.pc.lookup
 Id [[Id V] | Rest] -> V
 Id [_ | Rest] -> (tc0.pc.lookup Id Rest)
 Id [] -> [invalid unknown-binding])
(define tc0.pc.remove
 Id [] -> []
 Id [Id | Rest] -> (tc0.pc.remove Id Rest)
 Id [X | Rest] -> [X | (tc0.pc.remove Id Rest)])
(define tc0.pc.free-list
 [] -> []
 [E | Rest] -> (append (tc0.pc.free E) (tc0.pc.free-list Rest)))
(define tc0.pc.free
 [unit Node] -> []
 [bool Node B] -> []
 [int Node N] -> []
 [var Node Id] -> [Id]
 [let Node Id Init Body] -> (append (tc0.pc.free Init) (tc0.pc.remove Id (tc0.pc.free Body)))
 [lambda Node Id Body] -> (tc0.pc.remove Id (tc0.pc.free Body))
 [call Node Name Arg] -> (tc0.pc.free Arg)
 [emit Node Label Arg] -> (tc0.pc.free Arg)
 [prim Node Op | Args] -> (tc0.pc.free-list Args)
 [bytes Node Octets] -> []
 [tuple Node | Args] -> (tc0.pc.free-list Args)
 [project Node E I] -> (tc0.pc.free E)
 [construct Node Type Ctor | Args] -> (tc0.pc.free-list Args)
 [match Node E Arms] -> (append (tc0.pc.free E) (tc0.pc.free-arms Arms))
 [if Node | Args] -> (tc0.pc.free-list Args)
 [apply Node | Args] -> (tc0.pc.free-list Args))
(define tc0.pc.remove-all
 [] Ids -> Ids
 [B | Bs] Ids -> (tc0.pc.remove-all Bs (tc0.pc.remove B Ids)))
(define tc0.pc.free-arms
 [] -> []
 [[Ctor Binders Body] | Arms] -> (append (tc0.pc.remove-all Binders (tc0.pc.free Body)) (tc0.pc.free-arms Arms)))
(define tc0.pc.insert
 Id [] -> [Id]
 Id [Id | Rest] -> [Id | Rest]
 Id [X | Rest] -> [Id X | Rest] where (< Id X)
 Id [X | Rest] -> [X | (tc0.pc.insert Id Rest)])
(define tc0.pc.ordered
 [] -> []
 [Id | Rest] -> (tc0.pc.insert Id (tc0.pc.ordered Rest)))
(define tc0.pc.capture
 [] Env -> []
 [Id | Rest] Env -> [[Id (tc0.pc.lookup Id Env)] | (tc0.pc.capture Rest Env)])
(define tc0.pc.transition
 C Env Frames Codes Names Events -> [transition [pure-call-state C Env Frames Codes Names] Events])
(define tc0.pc.frame-env
 [bind Node Id Body Env Tail] -> Env
 [branch Node Yes No Env Tail] -> Env
 [select Node Arms Env Tail] -> Env
 [collect Node Op Meta Rest Values Env Tail] -> Env
 [return Node Env] -> Env)
(define tc0.pc.collect
 Node Op Meta [First | Rest] Tail Env Frames Codes Names ->
 (tc0.pc.transition [evaluate First false] Env [[collect Node Op Meta Rest [] Env Tail] | Frames] Codes Names [])
 Node Op Meta [] Tail Env Frames Codes Names ->
 (tc0.pc.transition [ready Node Op Meta [] Tail] Env Frames Codes Names []))
(define tc0.pc.dispatch
 [unit Node] Tail Env Frames Codes Names -> (tc0.pc.transition [value [unit]] Env Frames Codes Names [])
 [int Node N] Tail Env Frames Codes Names -> (tc0.pc.transition [value [int N]] Env Frames Codes Names [])
 [bool Node B] Tail Env Frames Codes Names -> (tc0.pc.transition [value [bool B]] Env Frames Codes Names [])
 [bytes Node Octets] Tail Env Frames Codes Names -> (tc0.pc.transition [value [bytes Octets]] Env Frames Codes Names [])
 [var Node Id] Tail Env Frames Codes Names -> (tc0.pc.transition [value (tc0.pc.lookup Id Env)] Env Frames Codes Names [])
 [lambda Node Id Body] Tail Env Frames Codes Names ->
 (tc0.pc.transition [value [closure Node (tc0.pc.capture (tc0.pc.ordered (tc0.pc.remove Id (tc0.pc.free Body))) Env) []]] Env Frames Codes Names [])
 [let Node Id Init Body] Tail Env Frames Codes Names ->
 (tc0.pc.transition [evaluate Init false] Env [[bind Node Id Body Env Tail] | Frames] Codes Names [])
 [if Node Cond Yes No] Tail Env Frames Codes Names ->
 (tc0.pc.transition [evaluate Cond false] Env [[branch Node Yes No Env Tail] | Frames] Codes Names [])
 [match Node E Arms] Tail Env Frames Codes Names ->
 (tc0.pc.transition [evaluate E false] Env [[select Node Arms Env Tail] | Frames] Codes Names [])
 [prim Node Op | Args] Tail Env Frames Codes Names -> (tc0.pc.collect Node Op none Args Tail Env Frames Codes Names)
 [tuple Node | Args] Tail Env Frames Codes Names -> (tc0.pc.collect Node tuple none Args Tail Env Frames Codes Names)
 [project Node E I] Tail Env Frames Codes Names -> (tc0.pc.collect Node project I [E] Tail Env Frames Codes Names)
 [construct Node Type Ctor | Args] Tail Env Frames Codes Names -> (tc0.pc.collect Node construct [Type Ctor] Args Tail Env Frames Codes Names)
 [apply Node A B] Tail Env Frames Codes Names -> (tc0.pc.collect Node apply none [A B] Tail Env Frames Codes Names)
 [call Node Name Arg] Tail Env Frames Codes Names -> (tc0.pc.collect Node call Name [Arg] Tail Env Frames Codes Names)
 [emit Node Label Arg] Tail Env Frames Codes Names -> (tc0.pc.collect Node emit Label [Arg] Tail Env Frames Codes Names))
(define tc0.pc.numbers
 [] -> []
 [[int N] | Rest] -> [N | (tc0.pc.numbers Rest)])
(define tc0.pc.pure
 not [[bool B]] -> [ok-bool (not B)]
 lt [[int A] [int B]] -> [ok-bool (< A B)]
 le [[int A] [int B]] -> [ok-bool (<= A B)]
 gt [[int A] [int B]] -> [ok-bool (> A B)]
 ge [[int A] [int B]] -> [ok-bool (>= A B)]
 eq [A B] -> [ok-bool (= A B)]
 bytes_length [[bytes Os]] -> [ok (length Os)]
 bytes_concat [[bytes A] [bytes B]] -> [ok-value [bytes (append A B)]]
 bytes_index [[bytes Os] [int I]] -> [ok (nth (+ I 1) Os)] where (and (>= I 0) (< I (length Os)))
 bytes_index [[bytes Os] [int I]] -> [trap bounds]
 Op Values -> (tc0.arithmetic Op (tc0.pc.numbers Values)))
(define tc0.pc.pure-return
 [ok N] Env Frames Codes Names -> (tc0.pc.transition [value [int N]] Env Frames Codes Names [])
 [ok-bool B] Env Frames Codes Names -> (tc0.pc.transition [value [bool B]] Env Frames Codes Names [])
 [ok-value V] Env Frames Codes Names -> (tc0.pc.transition [value V] Env Frames Codes Names [])
 [trap Code] Env Frames Codes Names -> (tc0.pc.transition [unwind Code] Env Frames Codes Names []))
(define tc0.pc.arm
 Ctor [[Ctor Binders Body] | Arms] -> [Binders Body]
 Ctor [Arm | Arms] -> (tc0.pc.arm Ctor Arms)
 Ctor [] -> [invalid no-match-arm])
(define tc0.pc.bind
 [] [] Env -> Env
 [B | Bs] [V | Vs] Env -> (tc0.pc.bind Bs Vs [[B V] | Env]))
(define tc0.pc.select
 [Binders Body] Fields Env Tail Frames Codes Names ->
 (tc0.pc.transition [evaluate Body Tail] (tc0.pc.bind Binders Fields Env) Frames Codes Names []))
(define tc0.pc.enter
 [Id Body] Captures Arg true Node Env Frames Codes Names ->
 (tc0.pc.transition [evaluate Body true] [[Id Arg] | Captures] Frames Codes Names [])
 [Id Body] Captures Arg false Node Env Frames Codes Names ->
 (tc0.pc.transition [evaluate Body true] [[Id Arg] | Captures] [[return Node Env] | Frames] Codes Names []))
(define tc0.pc.step
 [pure-call-state [evaluate E Tail] Env Frames Codes Names] -> (tc0.pc.dispatch E Tail Env Frames Codes Names)
 [pure-call-state [value V] Env [[bind Node Id Body OldEnv Tail] | Frames] Codes Names] ->
 (tc0.pc.transition [evaluate Body Tail] [[Id V] | OldEnv] Frames Codes Names [])
 [pure-call-state [value [bool B]] Env [[branch Node Yes No OldEnv Tail] | Frames] Codes Names] ->
 (tc0.pc.transition [evaluate (if B Yes No) Tail] OldEnv Frames Codes Names [])
 [pure-call-state [value [data Type Ctor | Fields]] Env [[select Node Arms OldEnv Tail] | Frames] Codes Names] ->
 (tc0.pc.select (tc0.pc.arm Ctor Arms) Fields OldEnv Tail Frames Codes Names)
 [pure-call-state [value V] Env [[return Node OldEnv] | Frames] Codes Names] ->
 (tc0.pc.transition [value V] OldEnv Frames Codes Names [])
 [pure-call-state [value V] Env [[collect Node Op Meta [Next | Rest] Values OldEnv Tail] | Frames] Codes Names] ->
 (tc0.pc.transition [evaluate Next false] OldEnv [[collect Node Op Meta Rest [V | Values] OldEnv Tail] | Frames] Codes Names [])
 [pure-call-state [value V] Env [[collect Node Op Meta [] Values OldEnv Tail] | Frames] Codes Names] ->
 (tc0.pc.transition [ready Node Op Meta (reverse [V | Values]) Tail] OldEnv Frames Codes Names [])
 [pure-call-state [value V] Env [] Codes Names] -> (tc0.pc.transition [join [ok V]] Env [] Codes Names [])
 [pure-call-state [ready Node call Name [Arg] Tail] Env Frames Codes Names] ->
 (tc0.pc.enter (tc0.pc.lookup (tc0.pc.lookup Name Names) Codes) [] Arg Tail Node Env Frames Codes Names)
 [pure-call-state [ready Node apply Meta [[closure Code Captures []] Arg] Tail] Env Frames Codes Names] ->
 (tc0.pc.enter (tc0.pc.lookup Code Codes) Captures Arg Tail Node Env Frames Codes Names)
 [pure-call-state [ready Node emit Label [V] Tail] Env Frames Codes Names] ->
 (tc0.pc.transition [value [unit]] Env Frames Codes Names [[invoke Node Label V] [emit Node Label V] [commit Node [unit]]])
 [pure-call-state [ready Node tuple Meta Values Tail] Env Frames Codes Names] ->
 (tc0.pc.transition [value [tuple | Values]] Env Frames Codes Names [])
 [pure-call-state [ready Node construct [Type Ctor] Values Tail] Env Frames Codes Names] ->
 (tc0.pc.transition [value [data Type Ctor | Values]] Env Frames Codes Names [])
 [pure-call-state [ready Node project I [[tuple | Fields]] Tail] Env Frames Codes Names] ->
 (tc0.pc.transition [value (nth (+ I 1) Fields)] Env Frames Codes Names [])
 [pure-call-state [ready Node Op Meta Values Tail] Env Frames Codes Names] ->
 (tc0.pc.pure-return (tc0.pc.pure Op Values) Env Frames Codes Names)
 [pure-call-state [unwind Code] Env [Frame | Frames] Codes Names] ->
 (tc0.pc.transition [unwind Code] (tc0.pc.frame-env Frame) Frames Codes Names [])
 [pure-call-state [unwind Code] Env [] Codes Names] -> (tc0.pc.transition [join [trap Code]] Env [] Codes Names [])
 [pure-call-state [join Outcome] Env [] Codes Names] -> (tc0.pc.transition [terminate Outcome] Env [] Codes Names [[scope-exit Outcome]])
 [pure-call-state [terminate Outcome] Env [] Codes Names] -> (tc0.pc.transition [terminal Outcome] Env [] Codes Names [[task-termination Outcome]]))
(define tc0.pc.site
 [pure-call-state [evaluate [Tag Node | Args] Tail] Env Frames Codes Names] -> [node Node dispatch]
 [pure-call-state [ready Node Op Meta Values Tail] Env Frames Codes Names] -> [node Node ready]
 [pure-call-state [value V] Env [[bind Node | Rest] | Frames] Codes Names] -> [node Node let-return]
 [pure-call-state [value V] Env [[branch Node | Rest] | Frames] Codes Names] -> [node Node if-return]
 [pure-call-state [value V] Env [[select Node | Rest] | Frames] Codes Names] -> [node Node match-return]
 [pure-call-state [value V] Env [[collect Node | Rest] | Frames] Codes Names] -> [node Node collect-return]
 [pure-call-state [value V] Env [[return Node | Rest] | Frames] Codes Names] -> [node Node return-return]
 [pure-call-state [unwind Code] Env [[Tag Node | Rest] | Frames] Codes Names] -> [node Node unwind-frame]
 [pure-call-state [value V] Env [] Codes Names] -> [machine root-join-entry value]
 [pure-call-state [unwind Code] Env [] Codes Names] -> [machine root-join-entry unwind]
 [pure-call-state [join Outcome] Env [] Codes Names] -> [machine join join]
 [pure-call-state [terminate Outcome] Env [] Codes Names] -> [machine terminate terminate])
(define tc0.pc.sample
 State -> (let T (tc0.pc.step State) (let Next (hd (tl T))
 [sample (tc0.pc.site State) (hd (hd (tl Next))) (length (hd (tl (tl (tl Next))))) (hd (tl (tl T)))])))
