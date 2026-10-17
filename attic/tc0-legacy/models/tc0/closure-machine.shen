\\ UNQUALIFIED standalone pure-closure-demo/1. Load arithmetic.shen first.
(define tc0.cl.lookup
  Id [[Id V] | Rest] -> V
  Id [_ | Rest] -> (tc0.cl.lookup Id Rest)
  Id [] -> [invalid unknown-binding])
(define tc0.cl.remove
  Id [] -> []
  Id [Id | Rest] -> (tc0.cl.remove Id Rest)
  Id [X | Rest] -> [X | (tc0.cl.remove Id Rest)])
(define tc0.cl.free
  [int Node N] -> []
  [var Node Id] -> [Id]
  [let Node Id Init Body] -> (append (tc0.cl.free Init) (tc0.cl.remove Id (tc0.cl.free Body)))
  [lambda Node Id Body] -> (tc0.cl.remove Id (tc0.cl.free Body))
  [apply Node A B] -> (append (tc0.cl.free A) (tc0.cl.free B))
  [add Node A B] -> (append (tc0.cl.free A) (tc0.cl.free B)))
(define tc0.cl.insert
  Id [] -> [Id]
  Id [Id | Rest] -> [Id | Rest]
  Id [X | Rest] -> [Id X | Rest] where (< Id X)
  Id [X | Rest] -> [X | (tc0.cl.insert Id Rest)])
(define tc0.cl.ordered
  [] -> []
  [Id | Rest] -> (tc0.cl.insert Id (tc0.cl.ordered Rest)))
(define tc0.cl.capture
  [] Env -> []
  [Id | Rest] Env -> [[Id (tc0.cl.lookup Id Env)] | (tc0.cl.capture Rest Env)])
(define tc0.cl.transition
  C Env Frames Codes Events -> [transition [closure-state C Env Frames Codes] Events])
(define tc0.cl.frame-env
  [bind Node Id Body Env Tail] -> Env
  [collect Node Op Rest Values Env Tail] -> Env
  [return Node Env] -> Env)
(define tc0.cl.dispatch
  [int Node N] Tail Env Frames Codes -> (tc0.cl.transition [value [int N]] Env Frames Codes [])
  [var Node Id] Tail Env Frames Codes -> (tc0.cl.transition [value (tc0.cl.lookup Id Env)] Env Frames Codes [])
  [lambda Node Id Body] Tail Env Frames Codes ->
    (tc0.cl.transition [value [closure Node (tc0.cl.capture (tc0.cl.ordered (tc0.cl.remove Id (tc0.cl.free Body))) Env) []]] Env Frames Codes [])
  [let Node Id Init Body] Tail Env Frames Codes ->
    (tc0.cl.transition [eval Init false] Env [[bind Node Id Body Env Tail] | Frames] Codes [])
  [apply Node A B] Tail Env Frames Codes ->
    (tc0.cl.transition [eval A false] Env [[collect Node apply [B] [] Env Tail] | Frames] Codes [])
  [add Node A B] Tail Env Frames Codes ->
    (tc0.cl.transition [eval A false] Env [[collect Node add [B] [] Env Tail] | Frames] Codes []))
(define tc0.cl.sum
  [ok N] Env Frames Codes -> (tc0.cl.transition [value [int N]] Env Frames Codes [])
  [trap Code] Env Frames Codes -> (tc0.cl.transition [unwind Code] Env Frames Codes []))
(define tc0.cl.enter
  [Id Body] Captures Arg true Node Env Frames Codes ->
    (tc0.cl.transition [eval Body true] [[Id Arg] | Captures] Frames Codes [])
  [Id Body] Captures Arg false Node Env Frames Codes ->
    (tc0.cl.transition [eval Body true] [[Id Arg] | Captures] [[return Node Env] | Frames] Codes []))
(define tc0.cl.step
  [closure-state [eval E Tail] Env Frames Codes] -> (tc0.cl.dispatch E Tail Env Frames Codes)
  [closure-state [value V] Env [[bind Node Id Body OldEnv Tail] | Frames] Codes] ->
    (tc0.cl.transition [eval Body Tail] [[Id V] | OldEnv] Frames Codes [])
  [closure-state [value V] Env [[return Node OldEnv] | Frames] Codes] ->
    (tc0.cl.transition [value V] OldEnv Frames Codes [])
  [closure-state [value V] Env [[collect Node Op [Next] Values OldEnv Tail] | Frames] Codes] ->
    (tc0.cl.transition [eval Next false] OldEnv [[collect Node Op [] [V] OldEnv Tail] | Frames] Codes [])
  [closure-state [value V] Env [[collect Node Op [] [First] OldEnv Tail] | Frames] Codes] ->
    (tc0.cl.transition [ready Node Op [First V] Tail] OldEnv Frames Codes [])
  [closure-state [value V] Env [] Codes] -> (tc0.cl.transition [join [ok V]] Env [] Codes [])
  [closure-state [ready Node add [[int A] [int B]] Tail] Env Frames Codes] ->
    (tc0.cl.sum (tc0.arithmetic add [A B]) Env Frames Codes)
  [closure-state [ready Node apply [[closure Code Captures []] Arg] Tail] Env Frames Codes] ->
    (tc0.cl.enter (tc0.cl.lookup Code Codes) Captures Arg Tail Node Env Frames Codes)
  [closure-state [unwind Code] Env [Frame | Frames] Codes] ->
    (tc0.cl.transition [unwind Code] (tc0.cl.frame-env Frame) Frames Codes [])
  [closure-state [unwind Code] Env [] Codes] -> (tc0.cl.transition [join [trap Code]] Env [] Codes [])
  [closure-state [join Outcome] Env [] Codes] -> (tc0.cl.transition [terminate Outcome] Env [] Codes [[scope-exit Outcome]])
  [closure-state [terminate Outcome] Env [] Codes] -> (tc0.cl.transition [terminal Outcome] Env [] Codes [[task-termination Outcome]]))
(define tc0.cl.site
  [closure-state [eval [Tag Node | Args] Tail] Env Frames Codes] -> [node Node dispatch]
  [closure-state [ready Node Op Values Tail] Env Frames Codes] -> [node Node ready]
  [closure-state [value V] Env [[bind Node | Rest] | Frames] Codes] -> [node Node let-return]
  [closure-state [value V] Env [[collect Node | Rest] | Frames] Codes] -> [node Node collect-return]
  [closure-state [value V] Env [[return Node | Rest] | Frames] Codes] -> [node Node return-return]
  [closure-state [value V] Env [] Codes] -> [machine value value]
  [closure-state [unwind Code] Env [[Tag Node | Rest] | Frames] Codes] -> [node Node unwind]
  [closure-state [unwind Code] Env [] Codes] -> [machine unwind unwind]
  [closure-state [join Outcome] Env [] Codes] -> [machine join join]
  [closure-state [terminate Outcome] Env [] Codes] -> [machine terminate terminate])
(define tc0.cl.sample
  State -> (let T (tc0.cl.step State)
    (let Next (hd (tl T)) [sample (tc0.cl.site State) (hd (hd (tl Next)))
      (length (hd (tl (tl (tl Next))))) (hd (tl (tl T)))])))
