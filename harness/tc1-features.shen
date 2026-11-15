\\ Fenrir harness: which handler behaviours a model trace exercises. Load after
\\ common.shen. Used by tc1-generated.shen to state, from the model's own traces and
\\ the program text, what the generated family really covers; a family that never
\\ exercises one of fh.features does not pass, whatever its generator claims.
\\
\\ Facts about a program are lexical, per function body: for each perform, its effect
\\ and operation, the effects of the clauses it lies in, the handles whose bodies it
\\ lies in, and its innermost lambda; for each div, the same contexts; for each lambda,
\\ the handles whose bodies it lies in; for each clause body, its root node, handle,
\\ effect and form. A lambda body starts a fresh context: it runs where it is applied.
\\ The features are then read from the trace, so each is a behaviour that happened.

(define fh.features
  -> ["multi-operation-effect"           \\ two operations of one effect performed in one run
      "nested-handlers"                  \\ a perform executed inside the bodies of two or more handles
      "sequential-handlers"              \\ a handler installed after another one was removed
      "same-effect-forwarding"           \\ a perform in a clause for its own effect, handled further out
      "closure-under-other-handler"      \\ a closure made under a handler for E performs E under another
      "clause-continues-after-resume"    \\ a resume returned to its clause (ResumeReturn)
      "discontinue"                      \\ a resumption discontinued (DiscontinueReturn)
      "trap-in-clause"                   \\ a div trapped in a clause body
      "trap-in-handled-body"             \\ a div trapped in a handle body, outside any clause
      "emits-around-perform"])           \\ an emission before and another after a performed operation

\\ Facts is [Performs Divs Lambdas Roots Handles], association lists keyed by node.
\\ Ctx is [ClauseEffects Bodies Lambda]; Bodies is a list of [HandleNode Effect].
(define fh.f-add
  0 Entry [P D L R H] -> [[Entry | P] D L R H]
  1 Entry [P D L R H] -> [P [Entry | D] L R H]
  2 Entry [P D L R H] -> [P D [Entry | L] R H]
  3 Entry [P D L R H] -> [P D L [Entry | R] H]
  4 Entry [P D L R H] -> [P D L R [Entry | H]])

(define fh.f-all
  [] _ Facts -> Facts
  [E | Es] Ctx Facts -> (fh.f-all Es Ctx (fh.f-walk E Ctx Facts)))

(define fh.f-clauses
  [] _ _ _ Facts -> Facts
  [[_ _ Body] | Cs] Node Effect [Cl Bodies Lambda] Facts ->
    (fh.f-clauses Cs Node Effect [Cl Bodies Lambda]
      (fh.f-walk Body [[Effect | Cl] Bodies Lambda] (fh.f-add 3 [(hd (tl Body)) [Node Effect "op(x)"]] Facts)))
  [[_ _ _ Body] | Cs] Node Effect [Cl Bodies Lambda] Facts ->
    (fh.f-clauses Cs Node Effect [Cl Bodies Lambda]
      (fh.f-walk Body [[Effect | Cl] Bodies Lambda] (fh.f-add 3 [(hd (tl Body)) [Node Effect "op(x,k)"]] Facts))))

(define fh.f-arms
  [] _ Facts -> Facts
  [[_ _ Body] | Arms] Ctx Facts -> (fh.f-arms Arms Ctx (fh.f-walk Body Ctx Facts)))

(define fh.f-walk
  ["handle" Node Effect Clauses Body] [Cl Bodies Lambda] Facts ->
    (fh.f-walk Body [Cl [[Node Effect] | Bodies] Lambda]
      (fh.f-clauses Clauses Node Effect [Cl Bodies Lambda] (fh.f-add 4 Node Facts)))
  ["perform" Node Effect Op Arg] [Cl Bodies Lambda] Facts ->
    (fh.f-walk Arg [Cl Bodies Lambda] (fh.f-add 0 [Node [Effect Op Cl Bodies Lambda]] Facts))
  ["prim" Node "div" A B] [Cl Bodies Lambda] Facts ->
    (fh.f-all [A B] [Cl Bodies Lambda] (fh.f-add 1 [Node [Cl Bodies]] Facts))
  ["lambda" Node _ _ _ _ _ Body] [Cl Bodies Lambda] Facts ->
    (fh.f-walk Body [[] [] Node] (fh.f-add 2 [Node Bodies] Facts))
  ["resume" _ _ Arg] Ctx Facts -> (fh.f-walk Arg Ctx Facts)
  ["let" _ _ Init Body] Ctx Facts -> (fh.f-all [Init Body] Ctx Facts)
  ["if" _ C Y N] Ctx Facts -> (fh.f-all [C Y N] Ctx Facts)
  ["match" _ E | Arms] Ctx Facts -> (fh.f-arms Arms Ctx (fh.f-walk E Ctx Facts))
  ["call" _ _ Arg] Ctx Facts -> (fh.f-walk Arg Ctx Facts)
  ["emit" _ _ Arg] Ctx Facts -> (fh.f-walk Arg Ctx Facts)
  ["project" _ E _] Ctx Facts -> (fh.f-walk E Ctx Facts)
  ["apply" _ | Es] Ctx Facts -> (fh.f-all Es Ctx Facts)
  ["tuple" _ | Es] Ctx Facts -> (fh.f-all Es Ctx Facts)
  ["prim" _ _ | Es] Ctx Facts -> (fh.f-all Es Ctx Facts)
  ["construct" _ _ _ | Es] Ctx Facts -> (fh.f-all Es Ctx Facts)
  _ _ Facts -> Facts)

(define fh.f-program
  Program -> (fh.f-functions (fh.field "functions" Program) [[] [] [] [] []]))

(define fh.f-functions
  [] Facts -> Facts
  [F | Fs] Facts -> (fh.f-functions Fs (fh.f-walk (fh.field "body" F) [[] [] none] Facts)))

(define fh.f-find
  _ [] -> none
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.f-find Key Rest))

(define fh.f-node
  Step -> (fh.member "node" (fh.field "site" Step)))

(define fh.f-rule
  Step -> (fh.field "rule" (fh.field "site" Step)))

\\ ---------- features of one trace ----------

\\ [[Index Info NextNode] ...] for every Ready step at a perform node.
(define fh.f-performed
  [] _ _ -> []
  [S | Steps] I Performs ->
    (let Info (if (= (fh.f-rule S) "Ready") (fh.f-find (fh.f-node S) Performs) none)
         Rest (fh.f-performed Steps (+ I 1) Performs)
      (if (= Info none) Rest [[I Info (if (= Steps []) none (fh.f-node (hd Steps)))] | Rest])))

(define fh.f-multi-op?
  Performed -> (fh.f-two-ops? (map (/. P [(hd (nth 2 P)) (hd (tl (nth 2 P)))]) Performed)))

(define fh.f-two-ops?
  [] -> false
  [[E Op] | Rest] -> (or (fh.f-other-op? E Op Rest) (fh.f-two-ops? Rest)))

(define fh.f-other-op?
  _ _ [] -> false
  E Op [[E Op2] | Rest] -> (or (not (= Op Op2)) (fh.f-other-op? E Op Rest))
  E Op [_ | Rest] -> (fh.f-other-op? E Op Rest))

(define fh.f-some?
  _ [] -> false
  F [X | Xs] -> (or (F X) (fh.f-some? F Xs)))

(define fh.f-nested?
  Performed -> (fh.f-some? (/. P (>= (length (nth 4 (nth 2 P))) 2)) Performed))

\\ A perform in a clause for its own effect whose next step enters a clause body.
(define fh.f-forwarding?
  Performed Roots -> (fh.f-some? (/. P (and (element? (hd (nth 2 P)) (nth 3 (nth 2 P)))
                                             (not (= (fh.f-find (nth 3 P) Roots) none)))) Performed))

\\ A perform of E in lambda L, answered by handle H, where L was made in the body of a
\\ handle for E other than H.
(define fh.f-closure-other?
  Performed Lambdas Roots ->
    (fh.f-some? (/. P (let Info (nth 2 P)
                           Lambda (nth 5 Info)
                           Selected (fh.f-find (nth 3 P) Roots)
                        (and (not (= Lambda none)) (not (= Selected none))
                             (fh.f-made-under-other? (hd Info) (hd Selected) (fh.f-find Lambda Lambdas)))))
                Performed))

(define fh.f-made-under-other?
  _ _ none -> false
  _ _ [] -> false
  E H [[H2 E] | Rest] -> (or (not (= H H2)) (fh.f-made-under-other? E H Rest))
  E H [_ | Rest] -> (fh.f-made-under-other? E H Rest))

(define fh.f-rule?
  Rule Steps -> (fh.f-some? (/. S (= (fh.f-rule S) Rule)) Steps))

\\ A Ready step at a div node that unwinds, in a clause (InClause true) or in a handle
\\ body outside any clause (InClause false).
(define fh.f-trap?
  InClause Steps Divs ->
    (fh.f-some? (/. S (and (= (fh.f-rule S) "Ready") (= (fh.field "after" S) "Unwind")
                           (let Info (fh.f-find (fh.f-node S) Divs)
                             (and (not (= Info none))
                                  (if InClause (not (= (hd Info) [])) (and (= (hd Info) []) (not (= (hd (tl Info)) []))))))))
                Steps))

\\ Some handler removed, then a different handle node entered.
(define fh.f-sequential?
  [] _ _ -> false
  [S | Steps] Returned Handles ->
    (let Node (fh.f-node S)
         Rule (fh.f-rule S)
      (if (and (= Rule "Dispatch") (element? Node Handles) (fh.f-some? (/. H (not (= H Node))) Returned))
          true
          (fh.f-sequential? Steps (if (= Rule "HandleReturn") [Node | Returned] Returned) Handles))))

(define fh.f-emits?
  S -> (fh.f-some? (/. E (= (fh.field "kind" E) "Emit")) (fh.field "events" S)))

(define fh.f-emit-indices
  [] _ -> []
  [S | Steps] I -> (if (fh.f-emits? S) [I | (fh.f-emit-indices Steps (+ I 1))] (fh.f-emit-indices Steps (+ I 1))))

(define fh.f-around?
  Performed Emits -> (fh.f-some? (/. P (and (fh.f-some? (/. I (< I (hd P))) Emits) (fh.f-some? (/. I (> I (hd P))) Emits))) Performed))

\\ The features of fh.features that one model trace of Program exercises.
(define fh.trace-features
  Program Steps ->
    (let Facts (fh.f-program Program)
         Performed (fh.f-performed Steps 0 (hd Facts))
         Roots (nth 4 Facts)
         Checks [(fh.f-multi-op? Performed)
                 (fh.f-nested? Performed)
                 (fh.f-sequential? Steps [] (nth 5 Facts))
                 (fh.f-forwarding? Performed Roots)
                 (fh.f-closure-other? Performed (nth 3 Facts) Roots)
                 (fh.f-rule? "ResumeReturn" Steps)
                 (fh.f-rule? "DiscontinueReturn" Steps)
                 (fh.f-trap? true Steps (nth 2 Facts))
                 (fh.f-trap? false Steps (nth 2 Facts))
                 (fh.f-around? Performed (fh.f-emit-indices Steps 0))]
      (fh.f-selected (fh.features) Checks)))

(define fh.f-selected
  [] [] -> []
  [F | Fs] [true | Cs] -> [F | (fh.f-selected Fs Cs)]
  [_ | Fs] [_ | Cs] -> (fh.f-selected Fs Cs))
