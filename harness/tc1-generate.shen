\\ Fenrir harness, in Shen: a generator of TC1 handler programs driven by a list of
\\ choices, a small deterministic source of such lists, and a shrinker that works on
\\ the list. Load after common.shen. Nothing here runs a machine or compares traces.
\\ Contract: spec/tc1/EFFECTS.md. Development tooling; no qualification verdict.
\\
\\ ---------- the grammar ----------
\\ The grammar is grammar H of tools/tc1/handler-enumerate.mjs without its 7-node
\\ bound, widened in four ways: more literals and arithmetic (so Overflow as well as
\\ DivZero), a second emission form, comparisons other than lt, and a third effect
\\ with two operations, one of which returns Bool. An expression is generated in a
\\ context: S, the effects with a handler in scope; V, the I64 binders in scope; and,
\\ inside a clause that names its resumption, that resumption k with the type its
\\ resume takes.
\\
\\   E ::= n | v                                       n a literal, v in V
\\       | tick(E) | neg(E)
\\       | perform(X, o, E)                            X in S, o an operation of X returning I64
\\       | deep(E)                                     only if Ask is in S
\\       | add(E, E) | sub(E, E) | mul(E, E) | div(E, E)
\\       | let v = E in E[V+v]
\\       | let u = emit("mark", E) in E
\\       | if(B, E, E)
\\       | handle(X, C..., E[S+X])                     one clause per operation of X
\\   B ::= true | false | not(B) | lt, le, gt, ge, eq (E, E)
\\       | perform(Mix, test, E)                       only if Mix is in S
\\   C ::= o(x) => T[V+x]                              tail-resumptive: T is E or B, the operation's result
\\       | o(x, k) => R[V+x, k]                        explicit one-shot resumption
\\   R ::= resume(k, T)                                T is E or B, the type k takes
\\       | let u = discontinue(k) in E
\\       | tick(R) | neg(R) | perform(X, o, R) | deep(R)
\\       | op(R, E) | op(E, R)                         op in add, sub, mul, div
\\       | let v = R in E[V+v] | let v = E in R[V+v]
\\       | if(B, R, R)
\\       | handle(X, C..., R[S+X])
\\
\\ E and B use no resumption. R uses the innermost resumption exactly once on every
\\ path, the one-shot rule of EFFECTS.md section 7, by the same construction as H. A
\\ clause is generated in the S of its handle node (the selected handler is inactive
\\ while its clause runs) and never sees an enclosing clause's k. main starts with S
\\ and V empty, so every program handles every user effect it performs. Every handle
\\ has type I64. So a generated program is valid by construction; the validator is
\\ still asked about every one, and one rejection fails the family check.
\\
\\ Effects: Ask { ask : I64 -> I64 }, Bid { bid : I64 -> I64 },
\\          Mix { get : I64 -> I64, test : I64 -> Bool }.
\\ Helpers, as in H: tick(q) = let u = emit("tick", q) in add(q, 1), and
\\   deep(q) = if(lt(0, q), handle(Ask, ask(x) => q, deep(sub(q, 1))), perform(Ask, ask, q)).
\\ An artifact declares only the effects and helpers its body uses. Its schema is
\\ always tc1-handler-demo/2 (slice TC1-H2), which admits both clause forms.
\\
\\ Not generated: closures, datatypes, tuples and bytes; Unit-typed operations;
\\ a resumption used in a condition; handles of a type other than I64.
\\
\\ ---------- choices ----------
\\ Every decision takes the next choice, reduced modulo the number of options open at
\\ that point; an exhausted list gives 0. Option 0 is always the smallest one (a
\\ literal, true, a tail-resumptive clause, resume(k, .), no spare nodes for a
\\ subterm that others follow), so the all-zero list gives the program whose body is the literal 0. The
\\ first two choices give the node budget of main's body: 1 + the larger of the two,
\\ each taken modulo fh.g-max-nodes, so budgets lean towards the large end.
\\ A decision with one option takes no choice.

(define fh.g-max-nodes -> 40)

(define fh.g-start
  Choices -> (do (set fh.*g-choices* Choices) (set fh.*g-picked* []) (set fh.*g-id* 0)
                 (set fh.*g-nodes* 0) (set fh.*g-locations* []) (set fh.*g-uses* []) skip))

\\ The next choice among N options. The choice made is recorded, so the list that
\\ reproduces a program holds the choices themselves, already reduced.
(define fh.g-pick
  1 -> 0
  N -> (let Cs (value fh.*g-choices*)
            C (if (empty? Cs) 0 (shen.mod (hd Cs) N))
            Rest (set fh.*g-choices* (if (empty? Cs) [] (tl Cs)))
            Kept (set fh.*g-picked* [C | (value fh.*g-picked*)])
         C))

(define fh.g-choose
  Options -> (nth (+ 1 (fh.g-pick (length Options))) Options))

(define fh.g-id
  -> (let N (value fh.*g-id*)
          Next (set fh.*g-id* (+ N 1))
       (str N)))

\\ A node ID: every node is a source location and counts against the budget.
(define fh.g-node
  -> (let Id (fh.g-id)
          Located (set fh.*g-locations* [Id | (value fh.*g-locations*)])
          Counted (set fh.*g-nodes* (+ 1 (value fh.*g-nodes*)))
       Id))

(define fh.g-use
  Name -> (if (element? Name (value fh.*g-uses*)) skip (set fh.*g-uses* [Name | (value fh.*g-uses*)])))

\\ ---------- effects ----------

(define fh.g-effects -> ["Ask" "Bid" "Mix"])

\\ [Operation ResultKind]: e for I64, b for Bool. Every operation takes an I64.
(define fh.g-operations
  "Ask" -> [["ask" e]]
  "Bid" -> [["bid" e]]
  "Mix" -> [["get" e] ["test" b]])

(define fh.g-result-type
  e -> "I64"
  b -> "Bool")

(define fh.g-declaration
  Effect -> [object ["name" Effect]
                    ["operations" (map (/. O [object ["name" (hd O)] ["argument_type" "I64"] ["result_type" (fh.g-result-type (hd (tl O)))]])
                                       (fh.g-operations Effect))]])

(define fh.g-numeric-operations
  [] -> []
  [[Op e] | Ops] -> [Op | (fh.g-numeric-operations Ops)]
  [_ | Ops] -> (fh.g-numeric-operations Ops))

\\ ---------- expressions ----------
\\ Kinds: e (I64, no resumption), b (Bool, no resumption), r (I64, uses k once).
\\ A context is [S V K]; K is [] or [ResumptionId ResultKind].

(define fh.g-min
  r -> 2
  _ -> 1)

\\ [Form MinimumNodes Available], simplest first. A form listed twice is twice as likely.
(define fh.g-table
  e [S V K] -> [[literal 1 true] [variable 1 (not (empty? V))] [tick 2 true] [perform 2 (not (empty? S))]
                [neg 2 true] [deep 2 (element? "Ask" S)] [arith 3 true] [bind 3 true] [handle 3 true]
                [perform 2 (not (empty? S))] [branch 4 true] [mark 4 true] [handle 3 true]
                [perform 2 (not (empty? S))] [bind 3 true] [handle 3 true] [arith 3 true] [perform 2 (not (empty? S))]]
  b [S V K] -> [[truth 1 true] [negate 2 true] [test 2 (element? "Mix" S)] [compare 3 true]]
  r [S V K] -> [[resume 2 true] [drop 3 true] [tick 3 true] [perform 3 (not (empty? S))] [neg 3 true]
                [deep 3 (element? "Ask" S)] [arith-left 4 true] [arith-right 4 true] [let-left 4 true]
                [let-right 4 true] [handle 4 true] [branch 6 true]
                [resume 2 true] [drop 3 true] [let-left 4 true] [arith-right 4 true] [branch 6 true]])

(define fh.g-fitting
  [] _ -> []
  [[Form Min true] | Rows] Cap -> [Form | (fh.g-fitting Rows Cap)] where (<= Min Cap)
  [_ | Rows] Cap -> (fh.g-fitting Rows Cap))

\\ The rows that are not leaves: with room to grow, a subterm is three times as likely
\\ to take one of them, so a budget is mostly used.
(define fh.g-composite
  [] -> []
  [[_ 1 _] | Rows] -> (fh.g-composite Rows)
  [Row | Rows] -> [Row | (fh.g-composite Rows)])

(define fh.g-forms
  Kind Ctx Cap -> (let Table (fh.g-table Kind Ctx)
                       Composite (fh.g-composite Table)
                    (fh.g-fitting (append Table Composite Composite) Cap)))

\\ An expression of Kind with at most Cap nodes; Cap is at least the kind's minimum.
\\ End is the node count this subterm must not pass.
(define fh.g-expr
  Kind Ctx Cap -> (let End (+ (value fh.*g-nodes*) Cap)
                       Form (fh.g-choose (fh.g-forms Kind Ctx Cap))
                    (fh.g-build Form Kind Ctx End (fh.g-node))))

\\ How many of Spare nodes a subterm may take beyond its minimum: a choice of eighths,
\\ 0 for none and 7 for all. The choice does not depend on Spare, so a list keeps its
\\ meaning when a budget above it shrinks.
(define fh.g-share
  0 -> 0
  Spare -> (fh.g-div (* Spare (fh.g-pick 8)) 7))

\\ A subterm that is followed by others needing Rest nodes. What it leaves is passed on.
(define fh.g-sub
  Kind Ctx End Rest -> (let Min (fh.g-min Kind)
                            Spare (- (- (- End Rest) (value fh.*g-nodes*)) Min)
                         (fh.g-expr Kind Ctx (+ Min (fh.g-share Spare)))))

\\ The last subterm takes whatever is left.
(define fh.g-last
  Kind Ctx End -> (fh.g-expr Kind Ctx (- End (value fh.*g-nodes*))))

(define fh.g-plain
  [S V _] -> [S V []])

(define fh.g-bind
  Id [S V K] -> [S [Id | V] K])

(define fh.g-literals -> ["0" "1" "2" "3" "-1" "10" "7" "-2" "5" "4" "6" "8" "-3" "9" "9223372036854775807" "-9223372036854775808"])

\\ The effects in S, each once, in declaration order.
(define fh.g-in-scope
  S -> (fh.g-keep (fh.g-effects) S))

(define fh.g-keep
  [] _ -> []
  [X | Xs] S -> (if (element? X S) [X | (fh.g-keep Xs S)] (fh.g-keep Xs S)))

\\ The effects a handle can be for when Room nodes remain for its clauses and body.
(define fh.g-handleable
  [] _ _ -> []
  [X | Xs] Kind Room -> (if (<= (+ (length (fh.g-operations X)) (fh.g-min Kind)) Room)
                            [X | (fh.g-handleable Xs Kind Room)]
                            (fh.g-handleable Xs Kind Room)))

(define fh.g-build
  literal _ _ _ Node -> ["int" Node (fh.g-choose (fh.g-literals))]
  variable _ [_ V _] _ Node -> ["var" Node (fh.g-choose V)]
  truth _ _ _ Node -> ["bool" Node (= (fh.g-pick 2) 0)]
  tick Kind Ctx End Node -> (do (fh.g-use "tick") ["call" Node "tick" (fh.g-last Kind Ctx End)])
  neg Kind Ctx End Node -> ["prim" Node "neg" (fh.g-last Kind Ctx End)]
  negate _ Ctx End Node -> ["prim" Node "not" (fh.g-last b Ctx End)]
  deep Kind Ctx End Node -> (do (fh.g-use "deep") (fh.g-use "Ask") ["call" Node "deep" (fh.g-last Kind Ctx End)])
  perform Kind [S V K] End Node ->
    (let Effect (fh.g-choose (fh.g-in-scope S))
         Op (fh.g-choose (fh.g-numeric-operations (fh.g-operations Effect)))
      ["perform" Node Effect Op (fh.g-last Kind [S V K] End)])
  test _ Ctx End Node -> ["perform" Node "Mix" "test" (fh.g-last e Ctx End)]
  arith _ Ctx End Node ->
    (let Op (fh.g-choose ["add" "sub" "mul" "div"])
         A (fh.g-sub e Ctx End 1)
      ["prim" Node Op A (fh.g-last e Ctx End)])
  compare _ Ctx End Node ->
    (let Op (fh.g-choose ["lt" "le" "eq" "gt" "ge"])
         A (fh.g-sub e Ctx End 1)
      ["prim" Node Op A (fh.g-last e Ctx End)])
  arith-left _ Ctx End Node ->
    (let Op (fh.g-choose ["add" "sub" "mul" "div"])
         A (fh.g-sub r Ctx End 1)
      ["prim" Node Op A (fh.g-last e (fh.g-plain Ctx) End)])
  arith-right _ Ctx End Node ->
    (let Op (fh.g-choose ["add" "sub" "mul" "div"])
         A (fh.g-sub e (fh.g-plain Ctx) End 2)
      ["prim" Node Op A (fh.g-last r Ctx End)])
  bind _ Ctx End Node ->
    (let Init (fh.g-sub e Ctx End 1)
         Id (fh.g-id)
      ["let" Node Id Init (fh.g-last e (fh.g-bind Id Ctx) End)])
  let-left _ Ctx End Node ->
    (let Init (fh.g-sub r Ctx End 1)
         Id (fh.g-id)
      ["let" Node Id Init (fh.g-last e (fh.g-bind Id (fh.g-plain Ctx)) End)])
  let-right _ Ctx End Node ->
    (let Init (fh.g-sub e (fh.g-plain Ctx) End 2)
         Id (fh.g-id)
      ["let" Node Id Init (fh.g-last r (fh.g-bind Id Ctx) End)])
  \\ let u = emit("mark", A) in B: u has type Unit and is not in V.
  mark _ Ctx End Node ->
    (let Emit (fh.g-node)
         A (fh.g-sub e Ctx End 1)
         Id (fh.g-id)
      ["let" Node Id ["emit" Emit "mark" A] (fh.g-last e Ctx End)])
  branch e Ctx End Node ->
    (let C (fh.g-sub b Ctx End 2)
         Y (fh.g-sub e Ctx End 1)
      ["if" Node C Y (fh.g-last e Ctx End)])
  branch r Ctx End Node ->
    (let C (fh.g-sub b (fh.g-plain Ctx) End 4)
         Y (fh.g-sub r Ctx End 2)
      ["if" Node C Y (fh.g-last r Ctx End)])
  resume _ [S V [K Takes]] End Node -> ["resume" Node K (fh.g-last Takes [S V []] End)]
  \\ let u = discontinue(k) in E
  drop _ [S V [K _]] End Node ->
    (let Discontinue (fh.g-node)
         Id (fh.g-id)
      ["let" Node Id ["discontinue" Discontinue K] (fh.g-last e [S V []] End)])
  handle Kind [S V K] End Node ->
    (let Effect (fh.g-choose (fh.g-handleable (fh.g-effects) Kind (- End (value fh.*g-nodes*))))
         Used (fh.g-use Effect)
         Clauses (fh.g-clauses (fh.g-operations Effect) [S V []] End (fh.g-min Kind))
      ["handle" Node Effect Clauses (fh.g-last Kind [[Effect | S] V K] End)]))

\\ One clause per operation, in declaration order. Rest is what the handle's body needs.
(define fh.g-clauses
  [] _ _ _ -> []
  [[Op Result] | Ops] Ctx End Rest ->
    (let Clause (fh.g-clause Op Result Ctx End (+ (length Ops) Rest))
      [Clause | (fh.g-clauses Ops Ctx End Rest)]))

\\ Choice 0 is the tail-resumptive form; the explicit form needs two nodes.
(define fh.g-clause
  Op Result Ctx End Rest ->
    (let Room (- (- End Rest) (value fh.*g-nodes*))
         Explicit (if (< Room 2) false (= (fh.g-pick 2) 1))
         X (fh.g-id)
      (if Explicit
          (let K (fh.g-id)
               Cap (+ 2 (fh.g-share (- Room 2)))
            [Op X K (fh.g-expr r [(hd Ctx) [X | (hd (tl Ctx))] [K Result]] Cap)])
          [Op X (fh.g-expr Result (fh.g-bind X Ctx) (+ 1 (fh.g-share (- Room 1))))])))

\\ ---------- the artifact ----------

(define fh.g-function
  Id Name Parameter Effects Body ->
    [object ["id" Id] ["name" Name] ["parameter_id" Parameter] ["argument_type" "I64"] ["result_type" "I64"]
            ["effects" Effects] ["body" Body]])

(define fh.g-located
  -> (let Id (fh.g-id)
          Located (set fh.*g-locations* [Id | (value fh.*g-locations*)])
       Id))

\\ tick(q) = let u = emit("tick", q) in add(q, 1)
(define fh.g-tick
  -> (let Id (fh.g-located) Q (fh.g-id) U (fh.g-id)
          N1 (fh.g-node) N2 (fh.g-node) N3 (fh.g-node) N4 (fh.g-node) N5 (fh.g-node) N6 (fh.g-node)
       (fh.g-function Id "tick" Q ["Emit"]
         ["let" N1 U ["emit" N2 "tick" ["var" N3 Q]] ["prim" N4 "add" ["var" N5 Q] ["int" N6 "1"]]])))

\\ deep(q) = if(lt(0, q), handle(Ask, ask(x) => q, deep(sub(q, 1))), perform(Ask, ask, q))
(define fh.g-deep
  -> (let Id (fh.g-located) Q (fh.g-id) X (fh.g-id)
          N1 (fh.g-node) N2 (fh.g-node) N3 (fh.g-node) N4 (fh.g-node) N5 (fh.g-node) N6 (fh.g-node)
          N7 (fh.g-node) N8 (fh.g-node) N9 (fh.g-node) N10 (fh.g-node) N11 (fh.g-node) N12 (fh.g-node)
       (fh.g-function Id "deep" Q ["Ask"]
         ["if" N1 ["prim" N2 "lt" ["int" N3 "0"] ["var" N4 Q]]
               ["handle" N5 "Ask" [["ask" X ["var" N6 Q]]] ["call" N7 "deep" ["prim" N8 "sub" ["var" N9 Q] ["int" N10 "1"]]]]
               ["perform" N11 "Ask" "ask" ["var" N12 Q]]])))

\\ AST nodes of the helpers' bodies, to check a generated size against the validator's count.
(define fh.g-helper-nodes
  Uses -> (+ (if (element? "tick" Uses) 6 0) (if (element? "deep" Uses) 12 0)))

(define fh.g-strip
  [0 | Cs] -> (fh.g-strip Cs)
  Cs -> Cs)

\\ The program a choice list stands for: [Artifact Nodes Choices HelperNodes]. Nodes
\\ counts the nodes of main's body. Choices is the list in normal form: the choices
\\ as they were taken, without trailing zeros; it generates the same program.
(define fh.generate
  Name Choices ->
    (let Started (fh.g-start Choices)
         Budget (+ 1 (fh.g-max (fh.g-pick (fh.g-max-nodes)) (fh.g-pick (fh.g-max-nodes))))
         Main (fh.g-located)
         Parameter (fh.g-id)
         Body (fh.g-expr e [[] [] []] Budget)
         Nodes (value fh.*g-nodes*)
         Normal (reverse (fh.g-strip (value fh.*g-picked*)))
         Uses (value fh.*g-uses*)
         Tick (if (element? "tick" Uses) [(fh.g-tick)] [])
         Deep (if (element? "deep" Uses) [(fh.g-deep)] [])
      [[object ["contract_version" "tc1-draft-1"] ["schema_version" "tc1-handler-demo/2"] ["slice" "TC1-H2"] ["module" Name]
               ["datatypes" []]
               ["effects" (map (/. X (fh.g-declaration X)) (fh.g-keep (fh.g-effects) Uses))]
               ["functions" [(fh.g-function Main "main" Parameter ["Emit"] Body) | (append Tick Deep)]]
               ["entry" "main"]
               ["input_schema" [object ["type" "I64"]]]
               ["source_map" (map (/. Id [object ["id" Id] ["file" "tc1-generated"] ["line" "0"] ["column" "0"]])
                                  (reverse (value fh.*g-locations*)))]]
       Nodes Normal (fh.g-helper-nodes Uses)]))

\\ ---------- choice lists from fixed seeds ----------
\\ The Lehmer generator x' = 48271 x mod (2^31 - 1): every product is below 2^47, well
\\ inside a 62-bit fixnum. A seed is an integer in 1 .. 2^31 - 2. A choice is x mod 1000.

(define fh.g-next
  X -> (shen.mod (* X 48271) 2147483647))

\\ N choices from state X: [Choices NextState].
(define fh.g-draw
  0 X Acc -> [(reverse Acc) X]
  N X Acc -> (let Y (fh.g-next X) (fh.g-draw (- N 1) Y [(shen.mod Y 1000) | Acc])))

\\ Choices per program: more than a 40-node program takes (about three per node).
(define fh.g-choices-per-program -> 160)

\\ ---------- shrinking, on the choice list ----------
\\ A candidate is a list that is shorter than the current one, or as long and smaller
\\ at the first place they differ. A quick round proposes: a chunk deleted (sizes
\\ halving from the whole list, at multiples of the size), an entry set to 0, an
\\ entry halved, an entry decremented. When no quick candidate is kept, thorough
\\ rounds follow: one to four entries deleted at every offset, and every entry
\\ lowered to every smaller value. Every candidate is regenerated, so it is a valid
\\ program.
\\ Evaluate is given the candidates of one round and returns the choice list (in
\\ normal form) of one for which the failure still holds, or [] when there is none;
\\ the caller decides what "still holds" means. Each accepted list is smaller in
\\ that order than the one before, so the loop ends; Rounds bounds it as well.
\\ Result: [Choices RoundsUsed CandidatesTried].

(define fh.g-drop
  0 Xs -> Xs
  _ [] -> []
  N [_ | Xs] -> (fh.g-drop (- N 1) Xs))

\\ The lists with one chunk of Size removed, at offsets 0, Size, 2 Size, ...
(define fh.g-deletions
  Size Before [] -> []
  Size Before After -> [(append Before (fh.g-drop Size After))
                        | (fh.g-deletions Size (append Before (fh.take Size After)) (fh.g-drop Size After))])

(define fh.g-half
  N -> (/ (- N (shen.mod N 2)) 2))

(define fh.g-all-deletions
  0 _ -> []
  Size Cs -> (append (fh.g-deletions Size [] Cs) (fh.g-all-deletions (fh.g-half Size) Cs)))

\\ The lists with one entry replaced by (F entry), where that is smaller.
(define fh.g-replacements
  F Before [] -> []
  F Before [C | After] ->
    (let Rest (fh.g-replacements F (append Before [C]) After)
         New (F C)
      (if (< New C) [(append Before [New | After]) | Rest] Rest)))

\\ The lists with Size consecutive entries removed, at every offset.
(define fh.g-windows
  Size Before After -> [] where (< (length After) Size)
  Size Before [A | After] -> [(append Before (fh.g-drop Size [A | After])) | (fh.g-windows Size (append Before [A]) After)])

\\ The lists with one entry lowered, to every smaller value.
(define fh.g-lowerings
  Before [] -> []
  Before [C | After] -> (append (fh.g-values 0 C Before After) (fh.g-lowerings (append Before [C]) After)))

(define fh.g-values
  V C _ _ -> [] where (>= V C)
  V C Before After -> [(append Before [V | After]) | (fh.g-values (+ V 1) C Before After)])

(define fh.g-candidates
  quick Cs -> (append (fh.g-all-deletions (length Cs) Cs)
                      (fh.g-replacements (/. C 0) [] Cs)
                      (fh.g-replacements (/. C (if (> C 1) (fh.g-half C) C)) [] Cs)
                      (fh.g-replacements (/. C (if (> C 2) (- C 1) C)) [] Cs))
  thorough Cs -> (append (fh.g-windows 4 [] Cs) (fh.g-windows 3 [] Cs) (fh.g-windows 2 [] Cs) (fh.g-windows 1 [] Cs)
                         (fh.g-lowerings [] Cs)))

(define fh.shrink
  Choices Evaluate Rounds -> (fh.g-shrink quick Choices Evaluate Rounds 0 0))

(define fh.g-shrink
  _ Choices _ Rounds Rounds Tried -> [Choices Rounds Tried]
  Level Choices Evaluate Rounds Round Tried ->
    (let Candidates (fh.g-candidates Level Choices)
         Next (if (empty? Candidates) [] (Evaluate Candidates))
         Total (+ Tried (length Candidates))
      (if (or (= Next []) (not (fh.g-smaller? Next Choices)))
          (if (= Level quick)
              (fh.g-shrink thorough Choices Evaluate Rounds (+ Round 1) Total)
              [Choices (+ Round 1) Total])
          (fh.g-shrink Level Next Evaluate Rounds (+ Round 1) Total))))

\\ Shorter, or as long and smaller at the first difference.
(define fh.g-smaller?
  A B -> (let La (length A) Lb (length B)
           (if (= La Lb) (fh.g-before? A B) (< La Lb))))

(define fh.g-before?
  [] [] -> false
  [A | As] [B | Bs] -> (if (= A B) (fh.g-before? As Bs) (< A B)))

\\ ---------- the shape of a generated program ----------

(define fh.g-main-body
  Program -> (fh.field "body" (hd (fh.field "functions" Program))))

(define fh.g-max
  A B -> (if (> A B) A B))

(define fh.g-depths
  [] -> 0
  [E | Es] -> (fh.g-max (fh.g-handler-depth E) (fh.g-depths Es)))

\\ The deepest nesting of handle nodes in an expression: a handle inside the body or
\\ inside a clause of another counts one deeper.
(define fh.g-handler-depth
  ["handle" _ _ Clauses Body] -> (+ 1 (fh.g-max (fh.g-handler-depth Body) (fh.g-depths (map (/. C (fh.last C)) Clauses))))
  [Tag _ | Rest] -> (fh.g-depths Rest) where (string? Tag)
  _ -> 0)

\\ ---------- transport: programs out, implementation runs back ----------

\\ The I-th fixed seed. Any I gives a seed in range.
(define fh.g-seed
  I -> (+ 20261115 (* 7919 I)))

(define fh.g-div
  A B -> (/ (- A (shen.mod A B)) B))

\\ Count programs from Lehmer state X, named Prefix-0, Prefix-1, ...:
\\ [Generated NextState], Generated a list of [Name Artifact Nodes Choices HelperNodes].
(define fh.g-programs
  Prefix I Count X Acc -> [(reverse Acc) X] where (>= I Count)
  Prefix I Count X Acc ->
    (let Drawn (fh.g-draw (fh.g-choices-per-program) X [])
         Name (cn Prefix (str I))
      (fh.g-programs Prefix (+ I 1) Count (hd (tl Drawn)) [[Name | (fh.generate Name (hd Drawn))] | Acc])))

\\ One JSON line {name, program} per program, the format of the JavaScript peer
\\ (tools/tc1/run-handler-generated.mjs) and of the guest builder's --programs.
(define fh.g-write-lines
  [] Stream -> (close Stream)
  [[Name Artifact | _] | Rest] Stream ->
    (do (pr (cn (json.stringify [object ["name" Name] ["program" Artifact]] [[byte-limit 4194304]]) "c#10;") Stream)
        (fh.g-write-lines Rest Stream)))

(define fh.g-write
  Generated File -> (fh.g-write-lines Generated (open File out)))

\\ Run the JavaScript peer on File in Mode, into the fresh directory Out (with a
\\ trailing slash): its header, or an error when it did not complete.
(define fh.g-implementation
  File Out Fuel Mode Sandbox ->
    (let Made (fh.exec "mkdir" ["-p" Out] 30)
         R (process.run "node" (fh.node-arguments "tools/tc1/run-handler-generated.mjs" [File Out (str Fuel) Mode]
                                                  ["runtime/tc1" "tools/tc1" File] Out Sandbox)
                        (buffer.from-string "") [[timeout 600000]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (json.parse (read-file-as-string (cn Out "family.json")) [[byte-limit 1048576]])
          (error "harness: the JavaScript batch did not complete for ~A" File))))

(define fh.g-chunk
  Out I -> (let View (buffer.from-string (read-file-as-string (cn Out (cn "chunk-" (cn (str I) ".jsonl")))))
             (fh.json-lines View 0 (buffer.length View) [])))

(define fh.g-all-chunks
  Out I Chunks -> [] where (>= I Chunks)
  Out I Chunks -> (append (fh.g-chunk Out I) (fh.g-all-chunks Out (+ I 1) Chunks)))

\\ The rows the peer wrote, all chunks. For small batches only.
(define fh.g-rows
  Out Header -> (fh.g-all-chunks Out 0 (tc0.i64.small (fh.field "chunks" Header))))
