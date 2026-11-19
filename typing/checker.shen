\\ Fenrir typing: the small fixed checker. Rules: spec/tc1/TYPING.md.
\\
\\   (tc.check A V D)   true when D is a derivation, by the rules of TYPING.md, that
\\                      artifact A with entry input V is well typed; false otherwise.
\\
\\ A is the decoded artifact with every object's members in key order (the transport
\\ of typing/structure.shen gives it that form); V is the input value. A derivation
\\ is [Rule Conclusion Premises]. Each node must be an instance of the rule it names:
\\ one clause of tc.rule below per rule of TYPING.md, whose pattern is the rule's
\\ conclusion and the conclusions of its premises, and whose body is the rule's side
\\ conditions. There is no search and no inference. tc.node recurses only into the
\\ premises of the node in hand, which are parts of D, and every side condition
\\ recurses only into parts of a type, a value, a context or a list it is given, so
\\ the design does not depend on any proof-search machinery. An unknown rule name, a node that is not a triple, premises of
\\ the wrong number or shape, a failed side condition, and any run-time error
\\ (caught below) all reject. A derivation must be JSON data (strings, booleans,
\\ lists, objects) before anything else is looked at, so a search that leaves a
\\ variable or another foreign object in what it builds is rejected.
\\
\\ The checker knows nothing of structure (IDs, caps, source map): Shen-side
\\ validation is typing/structure.shen and then this checker on a derivation.

(define tc.check
  A V D -> (trap-error (and (tc.identity? A) (tc.json? D) (= (tc.conclusion D) ["well-typed" A V]) (tc.node A D)) (/. E false)))

(define tc.malformed
  -> (simple-error "tc: not a shape the rules have"))

(define tc.json?
  X -> true where (or (string? X) (boolean? X))
  [object | Ms] -> (tc.json-members? Ms)
  Xs -> (tc.json-list? Xs))

(define tc.json-list?
  [] -> true
  [X | Xs] -> (and (tc.json? X) (tc.json-list? Xs))
  _ -> false)

(define tc.json-members?
  [] -> true
  [[K V] | Ms] -> (and (string? K) (tc.json? V) (tc.json-members? Ms))
  _ -> false)

(define tc.node
  A [R C Ps] -> (and (tc.nodes A Ps) (tc.rule A R C (map (/. P (tc.conclusion P)) Ps)))
  _ _ -> false)

(define tc.nodes
  _ [] -> true
  A [P | Ps] -> (and (tc.node A P) (tc.nodes A Ps))
  _ _ -> false)

(define tc.conclusion
  [_ C _] -> C
  _ -> [])

\\ ---------- the rules: tc.rule Artifact Name Conclusion PremiseConclusions ----------
\\ A repeated variable in a pattern must stand for equal values: that is how a
\\ premise is tied to its conclusion.

(define tc.rule
  \\ Program and functions (TYPING.md §4)
  A "Program" ["well-typed" A V] Ps ->
    (let Entry (tc.function-named (tc.f "entry" A) (tc.f "functions" A))
      (and (tc.declarations? A)
           (tc.entry? A Entry V)
           (= Ps (append (tc.operation-premises (tc.f "effects" A))
                         (map (/. F ["function" F]) (tc.f "functions" A))
                         [["plain" [] (tc.f "argument_type" Entry)] ["plain" [] (tc.f "result_type" Entry)]]))))
  A "Function" ["function" [object ["argument_type" Ta] ["body" B] ["effects" Ef] ["id" _] ["name" _] ["parameter_id" X] ["result_type" Tr]]]
               [["expr" [[X Ta]] B Tr F []]] ->
    (and (tc.type? A Ta) (tc.type? A Tr) (tc.effects? A Ef) (tc.subset? F Ef))

  \\ Serializable and equality-compatible types (§5)
  A "P-Base" ["plain" _ T] [] -> (element? T ["Unit" "Bool" "I64" "Bytes" "TrapCode"])
  A "P-Tuple" ["plain" Ds ["Tuple" | Ts]] Ps -> (= Ps (map (/. T ["plain" Ds T]) Ts))
  A "P-Data" ["plain" Ds ["Data" D]] Ps ->
    (and (tc.datatype? A D) (not (element? D Ds)) (= Ps (map (/. T ["plain" [D | Ds] T]) (tc.all-fields A D))))
  A "P-Assumed" ["plain" Ds ["Data" D]] [] -> (element? D Ds)

  \\ Expressions: ["expr" Context Expression Type Effects Uses] (§6)
  A "T-Unit" ["expr" _ ["unit" _] "Unit" [] []] [] -> true
  A "T-Bool" ["expr" _ ["bool" _ B] "Bool" [] []] [] -> (boolean? B)
  A "T-Int" ["expr" _ ["int" _ I] "I64" [] []] [] -> (tc.i64? I)
  A "T-Bytes" ["expr" _ ["bytes" _ H] "Bytes" [] []] [] -> (and (tc.data? A) (tc.hex? H))
  A "T-Var" ["expr" G ["var" _ X] T [] []] [] -> (and (tc.binds? X T G) (not (tc.resumption? T)))
  A "T-Let" ["expr" G ["let" _ X E1 E2] T F K]
            [["expr" G E1 T1 F1 K1] ["expr" [[X T1] | G] E2 T F2 K2]] ->
    (and (= F (tc.union F1 F2)) (= K (append K1 K2)))
  A "T-If" ["expr" G ["if" _ C E1 E2] T F K]
           [["expr" G C "Bool" F0 K0] ["expr" G E1 T F1 K1] ["expr" G E2 T F2 K2]] ->
    (and (= (length K1) (length K2)) (= F (tc.union F0 (tc.union F1 F2))) (= K (append K0 K1)))
  A "T-Prim" ["expr" G ["prim" _ Op | Es] T F K] Ps ->
    (and (tc.primitive? A Op Es T Ps G) (= F (tc.effects-of Ps)) (= K (tc.uses-of Ps)))
  A "T-Eq" ["expr" G ["prim" _ "eq" E1 E2] "Bool" F K]
           [["expr" G E1 T F1 K1] ["expr" G E2 T F2 K2] ["plain" [] T]] ->
    (and (tc.data? A) (= F (tc.union F1 F2)) (= K (append K1 K2)))
  A "T-Tuple" ["expr" G ["tuple" _ | Es] ["Tuple" | Ts] F K] Ps ->
    (and (tc.data? A) (tc.between? 1 8 (length Es)) (tc.operands? G Es Ts Ps) (= F (tc.effects-of Ps)) (= K (tc.uses-of Ps)))
  A "T-Project" ["expr" G ["project" _ E I] T F K] [["expr" G E ["Tuple" | Ts] F K]] ->
    (and (tc.data? A) (tc.nth? I T Ts ["0" "1" "2" "3" "4" "5" "6" "7"]))
  A "T-Construct" ["expr" G ["construct" _ D C | Es] T F K] Ps ->
    (and (tc.data? A) (tc.named-type? A D T) (tc.operands? G Es (tc.fields A T C) Ps)
         (= F (tc.effects-of Ps)) (= K (tc.uses-of Ps)))
  A "T-Match" ["expr" G ["match" _ E | Arms] T F K] [["expr" G E S F0 K0] | Ps] ->
    (let Table (tc.constructors A S)
      (and (tc.data? A) (cons? Table) (= (length Arms) (length Table)) (tc.distinct? (map (/. Arm (hd Arm)) Arms))
           (tc.arms? G Table Arms T Ps) (tc.same-lengths? (tc.uses-each Ps))
           (= F (tc.union F0 (tc.effects-of Ps))) (= K (append K0 (tc.conclusion-uses (hd Ps))))))
  A "T-Emit" ["expr" G ["emit" _ L E] "Unit" F K] [["expr" G E T F1 K] ["plain" [] T]] ->
    (and (string? L) (= F (tc.union F1 ["Emit"])))
  A "T-Lambda" ["expr" G ["lambda" _ X Ta Tr Ef [] B] ["Arrow" Ta Tr Ef] [] []] [["expr" [[X Ta] | G1] B Tr F []]] ->
    (and (tc.type? A Ta) (tc.type? A Tr) (tc.effects? A Ef) (= G1 (tc.values G)) (tc.subset? F Ef))
  A "T-Apply" ["expr" G ["apply" _ E1 E2] Tr F K]
              [["expr" G E1 ["Arrow" Ta Tr Ef] F1 K1] ["expr" G E2 Ta F2 K2]] ->
    (and (= F (tc.union (tc.union F1 F2) Ef)) (= K (append K1 K2)))
  A "T-Call" ["expr" G ["call" _ Name E] Tr F K] [["expr" G E Ta F1 K]] ->
    (tc.call? (tc.function-named Name (tc.f "functions" A)) Ta Tr F1 F)
  A "T-Perform" ["expr" G ["perform" _ Eff Op E] Tr F K] [["expr" G E Ta F1 K]] ->
    (and (tc.handlers? A) (element? [Op Ta Tr] (tc.operations A Eff)) (= F (tc.union F1 [Eff])))
  A "T-Handle" ["expr" G ["handle" _ Eff Clauses B] T F K] [["expr" G B T F0 K] | Ps] ->
    (let Ops (tc.operations A Eff)
      (and (tc.handlers? A) (cons? Ops) (= (length Clauses) (length Ops)) (tc.distinct? (map (/. C (hd C)) Clauses))
           (tc.clauses? A (tc.values G) T Ops Clauses Ps)
           (= F (tc.union (tc.remove Eff F0) (tc.effects-of Ps)))))
  A "T-Resume" ["expr" G ["resume" N Kv E] T F K] [["expr" G E Tb F K1]] ->
    (and (tc.resumptions? A) (tc.binds? Kv ["Resumption" Tb T] G) (= K (append K1 [N])))
  A "T-Discontinue" ["expr" G ["discontinue" N Kv] "Unit" [] [N]] [] ->
    (and (tc.resumptions? A) (tc.binds-resumption? Kv G))
  _ _ _ _ -> false)

\\ ---------- side conditions used by more than one rule ----------

\\ Premises [["expr" G E1 T1 ..] ...] for operands Es of types Ts, in order.
(define tc.operands?
  _ [] [] [] -> true
  G [E | Es] [T | Ts] [["expr" G E T _ _] | Ps] -> (tc.operands? G Es Ts Ps)
  _ _ _ _ -> false)

(define tc.effects-of
  [] -> []
  [[_ _ _ _ F _] | Ps] -> (tc.union F (tc.effects-of Ps))
  _ -> (tc.malformed))

(define tc.uses-of
  [] -> []
  [[_ _ _ _ _ K] | Ps] -> (append K (tc.uses-of Ps))
  _ -> (tc.malformed))

(define tc.uses-each
  Ps -> (map (/. P (tc.conclusion-uses P)) Ps))

(define tc.conclusion-uses
  [_ _ _ _ _ K] -> K
  _ -> (tc.malformed))

(define tc.same-lengths?
  [K1 K2 | Ks] -> (and (= (length K1) (length K2)) (tc.same-lengths? [K2 | Ks]))
  [_] -> true
  [] -> true
  _ -> (tc.malformed))

\\ Prim: one row per primitive other than eq, [Name Data? Operand-types Result].
(define tc.primitive?
  A Op Es T Ps G -> (tc.signature? A [Op Es T] Ps G
                       [["add" false ["I64" "I64"] "I64"] ["sub" false ["I64" "I64"] "I64"] ["mul" false ["I64" "I64"] "I64"]
                        ["div" false ["I64" "I64"] "I64"] ["neg" false ["I64"] "I64"] ["lt" false ["I64" "I64"] "Bool"]
                        ["le" false ["I64" "I64"] "Bool"] ["gt" false ["I64" "I64"] "Bool"] ["ge" false ["I64" "I64"] "Bool"]
                        ["not" false ["Bool"] "Bool"] ["bytes_length" true ["Bytes"] "I64"]
                        ["bytes_index" true ["Bytes" "I64"] "I64"] ["bytes_concat" true ["Bytes" "Bytes"] "Bytes"]]))

(define tc.signature?
  A [Op Es T] Ps G [[Op Data Ts T] | _] -> (and (or (not Data) (tc.data? A)) (tc.operands? G Es Ts Ps))
  A Use Ps G [_ | Rows] -> (tc.signature? A Use Ps G Rows)
  _ _ _ _ _ -> false)

(define tc.call?
  [object ["argument_type" Ta] _ ["effects" Ef] _ _ _ ["result_type" Tr]] Ta Tr F1 F -> (= F (tc.union F1 Ef))
  _ _ _ _ _ -> false)

\\ Match arms, in the artifact's order, against premises; Table is [[C Fields] ...].
(define tc.arms?
  _ _ [] _ [] -> true
  G Table [[C Xs B] | Arms] T [["expr" G1 B T _ _] | Ps] ->
    (and (tc.arm? Xs (tc.lookup C Table) G G1) (tc.arms? G Table Arms T Ps))
  _ _ _ _ _ -> false)

(define tc.arm?
  Xs [found Fs] G G1 -> (and (= (length Xs) (length Fs)) (= G1 (append (tc.zip Xs Fs) G)))
  _ _ _ _ -> false)

\\ Clauses against premises; Ops is [[Op A B] ...], G the context without resumptions.
\\ op(x) => c : c has B with x : A.  op(x,k) => c : c has the handle's type T, with
\\ k : Resumption(B, T), and uses k once.
(define tc.clauses?
  _ _ _ _ [] [] -> true
  A G T Ops [[Op X C] | Cs] [["expr" [[X Ta] | G] C Tr _ []] | Ps] ->
    (and (element? [Op Ta Tr] Ops) (tc.clauses? A G T Ops Cs Ps))
  A G T Ops [[Op X Kv C] | Cs] [["expr" [[Kv ["Resumption" Tr T]] [X Ta] | G] C T _ [_]] | Ps] ->
    (and (tc.resumptions? A) (element? [Op Ta Tr] Ops) (tc.clauses? A G T Ops Cs Ps))
  _ _ _ _ _ _ -> false)

\\ ---------- contexts ----------

\\ X is bound to T: the first binding of X in G is [X T].
(define tc.binds?
  X T [[X T] | _] -> true
  X _ [[X _] | _] -> false
  X T [_ | G] -> (tc.binds? X T G)
  _ _ _ -> false)

(define tc.binds-resumption?
  X [[X T] | _] -> (tc.resumption? T)
  X [_ | G] -> (tc.binds-resumption? X G)
  _ _ -> false)

(define tc.resumption?
  ["Resumption" _ _] -> true
  _ -> false)

\\ The context without its resumptions: what a lambda body or a clause sees.
(define tc.values
  [] -> []
  [[_ ["Resumption" _ _]] | G] -> (tc.values G)
  [B | G] -> [B | (tc.values G)]
  _ -> (tc.malformed))

(define tc.zip
  [X | Xs] [T | Ts] -> [[X T] | (tc.zip Xs Ts)]
  _ _ -> [])

\\ ---------- the artifact's declarations ----------

(define tc.f
  K [object | Ms] -> (tc.member K Ms)
  _ _ -> (tc.malformed))

(define tc.member
  K [[K V] | _] -> V
  K [_ | Ms] -> (tc.member K Ms)
  _ _ -> (tc.malformed))

(define tc.schema
  A -> (tc.f "schema_version" A))

\\ Closed support list. In particular, R1 and P1 are not H2 with extra fields.
(define tc.identity
  "tc0-a-pure-call-demo/1" -> ["0.2" "TC0-A"]
  "tc0-a-pure-call-demo/2" -> ["0.2" "TC0-A"]
  "tc1-handler-demo/1" -> ["tc1-draft-1" "TC1-H1"]
  "tc1-handler-demo/2" -> ["tc1-draft-1" "TC1-H2"]
  "tc1-durable-demo/1" -> ["tc1-draft-1" "TC1-D1"]
  _ -> none)

(define tc.identity?
  A -> (= (tc.identity (tc.schema A)) [(tc.f "contract_version" A) (tc.f "slice" A)]))

(define tc.data?
  A -> (element? (tc.schema A) ["tc0-a-pure-call-demo/2" "tc1-handler-demo/1" "tc1-handler-demo/2" "tc1-durable-demo/1"]))

(define tc.handlers?
  A -> (or (tc.resumptions? A) (= (tc.schema A) "tc1-handler-demo/1")))

(define tc.resumptions?
  A -> (or (tc.durable? A) (= (tc.schema A) "tc1-handler-demo/2")))

(define tc.durable?
  A -> (= (tc.schema A) "tc1-durable-demo/1"))

(define tc.function-named
  Name [F | Fs] -> (if (= (tc.f "name" F) Name) F (tc.function-named Name Fs))
  _ _ -> none)

(define tc.datatype?
  A D -> (element? D (map (/. Decl (tc.f "name" Decl)) (tc.f "datatypes" A))))

\\ [[C Fields] ...] of a datatype's constructors, or of TrapCode; [] for other types.
(define tc.constructors
  A "TrapCode" -> (map (/. C [C []]) ["Overflow" "DivZero" "Bounds" "InvalidDuration" "TaskLimit" "ChildFailed"])
  A ["Data" D] -> (tc.table D (tc.f "datatypes" A))
  _ _ -> [])

(define tc.table
  D [Decl | Decls] -> (if (= (tc.f "name" Decl) D)
                          (map (/. C [(tc.f "name" C) (tc.f "fields" C)]) (tc.f "constructors" Decl))
                          (tc.table D Decls))
  _ _ -> [])

(define tc.lookup
  C [[C Fs] | _] -> [found Fs]
  C [_ | Table] -> (tc.lookup C Table)
  _ _ -> none)

(define tc.named-type?
  _ "TrapCode" "TrapCode" -> true
  A D ["Data" D] -> (tc.datatype? A D)
  _ _ _ -> false)

(define tc.fields
  A T C -> (tc.found (tc.lookup C (tc.constructors A T))))

(define tc.found
  [found Fs] -> Fs
  _ -> none)

(define tc.all-fields
  A D -> (tc.concat (map (/. Row (hd (tl Row))) (tc.constructors A ["Data" D]))))

(define tc.concat
  [] -> []
  [X | Xs] -> (append X (tc.concat Xs))
  _ -> (tc.malformed))

\\ [[Op A B] ...] of a declared effect; [] for anything else.
(define tc.operations
  A Eff -> (tc.operations-in Eff (tc.f "effects" A)))

(define tc.operations-in
  Eff [D | Ds] -> (if (= (tc.f "name" D) Eff)
                      (map (/. O [(tc.f "name" O) (tc.f "argument_type" O) (tc.f "result_type" O)]) (tc.f "operations" D))
                      (tc.operations-in Eff Ds))
  _ _ -> [])

(define tc.operation-premises
  Ds -> (tc.concat (map (/. D (tc.concat (map (/. O [["plain" [] (tc.f "argument_type" O)] ["plain" [] (tc.f "result_type" O)]])
                                              (tc.f "operations" D))))
                        Ds)))

\\ Every declared field and operation type is a type.
(define tc.declarations?
  A -> (let Fields (tc.concat (map (/. D (tc.all-fields A (tc.f "name" D))) (tc.f "datatypes" A)))
         (and (tc.types? A Fields)
              (or (tc.durable? A) (tc.every? (/. T (tc.legacy-field? T)) Fields))
              (tc.types? A (tc.concat (map (/. D (tc.concat (map (/. O [(tc.f "argument_type" O) (tc.f "result_type" O)]) (tc.f "operations" D))))
                                           (tc.f "effects" A)))))))

\\ Preserve PR10 validation: the early effect-name table was added only to D1.
(define tc.legacy-field?
  ["Arrow" A B Es] -> (and (tc.subset? Es ["Emit"]) (tc.legacy-field? A) (tc.legacy-field? B))
  ["Tuple" | Ts] -> (tc.every? (/. T (tc.legacy-field? T)) Ts)
  _ -> true)

\\ The entry function accepts its declared input; only Emit and (in D1) durable
\\ effects may remain unhandled.
(define tc.entry?
  A none _ -> false
  A F V -> (and (tc.subset? (tc.f "effects" F) (tc.entry-row A))
                (= (tc.f "input_schema" A) [object ["type" (tc.f "argument_type" F)]])
                (tc.value? A V (tc.f "argument_type" F))))

(define tc.entry-row
  A -> ["Emit" | (tc.durable-names (tc.f "effects" A))] where (tc.durable? A)
  _ -> ["Emit"])

(define tc.durable-names
  [] -> []
  [D | Ds] -> [(tc.f "name" D) | (tc.durable-names Ds)] where (= (tc.f "class" D) "durable")
  [_ | Ds] -> (tc.durable-names Ds))

\\ ---------- types, effect sets and values (§3) ----------

(define tc.type?
  A T -> true where (element? T ["Unit" "Bool" "I64"])
  A T -> (tc.data? A) where (element? T ["Bytes" "TrapCode"])
  A ["Arrow" Ta Tr Ef] -> (and (tc.type? A Ta) (tc.type? A Tr) (tc.effects? A Ef))
  A ["Tuple" | Ts] -> (and (tc.data? A) (tc.between? 1 8 (length Ts)) (tc.types? A Ts))
  A ["Data" D] -> (and (tc.data? A) (tc.datatype? A D))
  _ _ -> false)

(define tc.types?
  _ [] -> true
  A [T | Ts] -> (and (tc.type? A T) (tc.types? A Ts))
  _ _ -> false)

\\ An effect set: before TC1 empty or [Emit]; in TC1 Emit and declared effects, in
\\ byte order, no duplicates.
(define tc.effects?
  A Ef -> (or (= Ef []) (= Ef ["Emit"])) where (not (tc.handlers? A))
  A Ef -> (and (tc.ordered? Ef) (tc.names? Ef ["Emit" | (map (/. D (tc.f "name" D)) (tc.f "effects" A))])))

(define tc.names?
  [] _ -> true
  [E | Es] Names -> (and (element? E Names) (tc.names? Es Names))
  _ _ -> false)

(define tc.ordered?
  [E1 E2 | Es] -> (and (tc.before? E1 E2) (tc.ordered? [E2 | Es]))
  [E] -> (string? E)
  [] -> true
  _ -> false)

\\ V is a value of type T.
(define tc.value?
  _ ["unit"] "Unit" -> true
  _ ["bool" B] "Bool" -> (boolean? B)
  _ ["int" I] "I64" -> (tc.i64? I)
  A ["bytes" H] "Bytes" -> (and (tc.data? A) (tc.hex? H))
  A ["tuple" | Vs] ["Tuple" | Ts] -> (tc.values? A Vs Ts)
  A ["data" "TrapCode" C] "TrapCode" -> (cons? (tc.lookup C (tc.constructors A "TrapCode")))
  A ["data" D C | Vs] ["Data" D] -> (tc.values? A Vs (tc.fields A ["Data" D] C))
  _ _ _ -> false)

(define tc.values?
  _ [] [] -> true
  A [V | Vs] [T | Ts] -> (and (tc.value? A V T) (tc.values? A Vs Ts))
  _ _ _ -> false)

\\ ---------- literals, sets and lists ----------

\\ A canonical decimal integer in the I64 range: no plus sign, leading zero or -0.
(define tc.i64?
  "0" -> true
  (@s "-" S) -> (and (tc.digits? S) (tc.at-most? (explode S) (explode "9223372036854775808")))
  S -> (and (string? S) (tc.digits? S) (tc.at-most? (explode S) (explode "9223372036854775807"))))

(define tc.digits?
  (@s D S) -> (and (tc.among? D "123456789") (tc.every? (/. C (tc.among? C "0123456789")) (explode S)))
  _ -> false)

\\ Digit lists: A has fewer digits than B, or as many and is not greater.
(define tc.at-most?
  A B -> (or (< (length A) (length B)) (and (= (length A) (length B)) (tc.not-after? A B))))

(define tc.not-after?
  [] [] -> true
  [X | Xs] [X | Ys] -> (tc.not-after? Xs Ys)
  [X | _] [Y | _] -> (< (string->n X) (string->n Y))
  _ _ -> false)

\\ Lowercase hexadecimal of an even length.
(define tc.hex?
  "" -> true
  (@s A B S) -> (and (tc.among? A "0123456789abcdef") (tc.among? B "0123456789abcdef") (tc.hex? S))
  _ -> false)

(define tc.among?
  C Digits -> (element? C (explode Digits)))

\\ Unsigned byte order of ASCII names (effect names are identifiers or Emit).
(define tc.before?
  "" (@s _ _) -> true
  (@s C S1) (@s C S2) -> (tc.before? S1 S2)
  (@s C1 _) (@s C2 _) -> (< (string->n C1) (string->n C2))
  _ _ -> false)

\\ Effect sets are ordered lists; union keeps the order.
(define tc.union
  [] F -> F
  F [] -> F
  [E | F1] [E | F2] -> [E | (tc.union F1 F2)]
  [E1 | F1] [E2 | F2] -> (if (tc.before? E1 E2) [E1 | (tc.union F1 [E2 | F2])] [E2 | (tc.union [E1 | F1] F2)])
  _ _ -> (tc.malformed))

(define tc.unions
  [] -> []
  [F | Fs] -> (tc.union F (tc.unions Fs))
  _ -> (tc.malformed))

(define tc.remove
  _ [] -> []
  E [E | F] -> (tc.remove E F)
  E [X | F] -> [X | (tc.remove E F)]
  _ _ -> (tc.malformed))

(define tc.subset?
  F1 F2 -> (tc.every? (/. E (element? E F2)) F1))

(define tc.distinct?
  [] -> true
  [X | Xs] -> (and (not (element? X Xs)) (tc.distinct? Xs))
  _ -> (tc.malformed))

(define tc.between?
  Lo Hi N -> (and (>= N Lo) (<= N Hi)))

(define tc.nth?
  I T [T | _] [I | _] -> true
  I T [_ | Ts] [_ | Is] -> (tc.nth? I T Ts Is)
  _ _ _ _ -> false)

(define tc.every?
  _ [] -> true
  P [X | Xs] -> (and (P X) (tc.every? P Xs))
  _ _ -> (tc.malformed))
