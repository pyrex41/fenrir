\\ UNQUALIFIED arithmetic-demo frame proposal. Explicit data continuations.
\\ Load arithmetic.shen first. No host I/O, scheduling or target host recursion.
(define tc0.demo.lookup
  Id [[Id V] | Rest] -> V
  Id [_ | Rest] -> (tc0.demo.lookup Id Rest)
  Id [] -> [invalid unknown-binding])

(define tc0.demo.frame-env
  [collect Node Op Label Rest Values Env] -> Env
  [bind Node Id Body Env] -> Env
  [branch Node Yes No Env] -> Env)

(define tc0.demo.transition
  Control Env Frames Events -> [transition [state Control Env Frames] Events])

(define tc0.demo.dispatch
  [unit Node] Env Frames -> (tc0.demo.transition [value [unit]] Env Frames [])
  [int Node N] Env Frames -> (tc0.demo.transition [value [int N]] Env Frames [])
  [bool Node B] Env Frames -> (tc0.demo.transition [value [bool B]] Env Frames [])
  [var Node Id] Env Frames -> (tc0.demo.transition [value (tc0.demo.lookup Id Env)] Env Frames [])
  [let Node Id Init Body] Env Frames ->
    (tc0.demo.transition [eval Init] Env [[bind Node Id Body Env] | Frames] [])
  [if Node Cond Yes No] Env Frames ->
    (tc0.demo.transition [eval Cond] Env [[branch Node Yes No Env] | Frames] [])
  [prim Node Op First | Rest] Env Frames ->
    (tc0.demo.transition [eval First] Env [[collect Node Op none Rest [] Env] | Frames] [])
  [emit Node Label Body] Env Frames ->
    (tc0.demo.transition [eval Body] Env [[collect Node emit Label [] [] Env] | Frames] []))

(define tc0.demo.numbers
  [] -> []
  [[int N] | Rest] -> [N | (tc0.demo.numbers Rest)])

(define tc0.demo.pure
  not [[bool B]] -> [ok-bool (not B)]
  lt [[int A] [int B]] -> [ok-bool (< A B)]
  le [[int A] [int B]] -> [ok-bool (<= A B)]
  gt [[int A] [int B]] -> [ok-bool (> A B)]
  ge [[int A] [int B]] -> [ok-bool (>= A B)]
  Op Values -> (tc0.arithmetic Op (tc0.demo.numbers Values)))

(define tc0.demo.pure-return
  [ok N] Env Frames -> (tc0.demo.transition [value [int N]] Env Frames [])
  [ok-bool B] Env Frames -> (tc0.demo.transition [value [bool B]] Env Frames [])
  [trap Code] Env Frames -> (tc0.demo.transition [unwind Code] Env Frames []))

(define tc0.demo.step
  [state [eval E] Env Frames] -> (tc0.demo.dispatch E Env Frames)
  [state [value V] Env [[bind Node Id Body OldEnv] | Frames]] ->
    (tc0.demo.transition [eval Body] [[Id V] | OldEnv] Frames [])
  [state [value [bool B]] Env [[branch Node Yes No OldEnv] | Frames]] ->
    (tc0.demo.transition [eval (if B Yes No)] OldEnv Frames [])
  [state [value V] Env [[collect Node Op Label [Next | Rest] Values OldEnv] | Frames]] ->
    (tc0.demo.transition [eval Next] OldEnv [[collect Node Op Label Rest [V | Values] OldEnv] | Frames] [])
  [state [value V] Env [[collect Node Op Label [] Values OldEnv] | Frames]] ->
    (tc0.demo.transition [ready Node Op (reverse [V | Values]) Label] OldEnv Frames [])
  [state [value V] Env []] -> (tc0.demo.transition [join [ok V]] Env [] [])
  [state [ready Node emit [V] Label] Env Frames] ->
    (tc0.demo.transition [value [unit]] Env Frames
      [[invoke Node Label V] [emit Node Label V] [commit Node [unit]]])
  [state [ready Node Op Values Label] Env Frames] ->
    (tc0.demo.pure-return (tc0.demo.pure Op Values) Env Frames)
  [state [unwind Code] Env [Frame | Frames]] ->
    (tc0.demo.transition [unwind Code] (tc0.demo.frame-env Frame) Frames [])
  [state [unwind Code] Env []] -> (tc0.demo.transition [join [trap Code]] Env [] [])
  [state [join Outcome] Env []] ->
    (tc0.demo.transition [terminate Outcome] Env [] [[scope-exit Outcome]])
  [state [terminate Outcome] Env []] ->
    (tc0.demo.transition [terminal Outcome] Env [] [[task-termination Outcome]]))

(define tc0.demo.site
  [state [eval [Tag Node | Args]] Env Frames] -> [node Node dispatch]
  [state [ready Node Op Values Label] Env Frames] -> [node Node ready]
  [state [value V] Env [[collect Node | Rest] | Frames]] -> [node Node collect-return]
  [state [value V] Env [[bind Node | Rest] | Frames]] -> [node Node let-return]
  [state [value V] Env [[branch Node | Rest] | Frames]] -> [node Node if-return]
  [state [unwind Code] Env [[Tag Node | Rest] | Frames]] -> [node Node unwind-frame]
  [state [value V] Env []] -> [machine root-join-entry value]
  [state [unwind Code] Env []] -> [machine root-join-entry unwind]
  [state [join Outcome] Env []] -> [machine join join]
  [state [terminate Outcome] Env []] -> [machine terminate terminate])

(define tc0.demo.sample
  State ->
    (let T (tc0.demo.step State)
      (let Next (hd (tl T))
        [sample (tc0.demo.site State) (hd (hd (tl Next)))
          (length (hd (tl (tl (tl Next))))) (hd (tl (tl T))) ])))

\\ Convenience finite development driver. Each recursion advances ONE model step.
\\ Target calls are not implemented in this sublanguage; this is not target recursion.
(define tc0.demo.run
  [state [terminal Outcome] Env []] Fuel -> [completed Outcome]
  State 0 -> [budget-exhausted State]
  State Fuel -> (tc0.demo.run (hd (tl (tc0.demo.step State))) (- Fuel 1)))
