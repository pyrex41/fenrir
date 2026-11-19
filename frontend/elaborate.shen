\\ Fenrir frontend, elaborator: the reader's S-expressions to an artifact of schema
\\ tc1-handler-demo/2, or tc1-handler-demo/3 when the program declares a remote
\\ effect, or tc1-handler-demo/4 when it serves one (contract spec/tc1/EFFECTS.md),
\\ in decoded-JSON shape:
\\ strings, lists, and [object [Key Value] ...] with keys in canonical order.
\\ Load after reader.shen. The surface syntax is specified in spec/tc1/SURFACE.md.
\\
\\ This is a translation, not a semantics. It resolves names to binder IDs, gives
\\ every node an ID and a source position, and writes down the types and effect
\\ sets the artifact states explicitly. What a program means is decided by the
\\ model; whether an artifact is well formed is decided, independently and after
\\ the fact, by tools/tc0/pure-call-artifact.mjs. The checks here mirror that
\\ validator so that a wrong program gets a message with a position instead of
\\ the validator's bare reason.
\\
\\ Types are in artifact shape throughout: "I64", ["Tuple" T ...], ["Data" Name],
\\ ["Arrow" A B [EffectName ...]], and ["Remote" B], the outcome of a remote perform.
\\ ["Remote" B] is the type of a remote perform and of nothing else: the must-use
\\ rule (EFFECTS.md section 3) lets such a perform stand only where a match takes
\\ its outcome apart, and the type cannot be written in a program.
\\
\\ Elaborating an expression yields a row [Node Type Effects Uses]:
\\   Node     the artifact expression
\\   Type     its type
\\   Effects  [[EffectName Line Column Cause] ...]: each effect the expression may
\\            perform, with the first place that introduces it, for diagnostics
\\   Uses     [[BinderId Name Count Line Column] ...]: how often each resumption in
\\            scope is used on the path through the expression (the one-shot rule)

\\ ---------- state of one elaboration ----------

\\ Declarations are fixed before any expression is elaborated, and read from
\\ these tables. IDs and source positions accumulate while a pass runs.
(set fe.*datatype-names* [])   \\ declared datatype names
(set fe.*datatypes* [])        \\ [[Name [[Constructor [FieldType ...]] ...]] ...], TrapCode first
(set fe.*effects* [])          \\ [[Name [[Operation ArgumentType ResultType] ...]] ...]
(set fe.*remote* [])           \\ [[Name [ReadOnlyOperation ...]] ...]: the remote effects among them
(set fe.*serving* false)       \\ true when the program has a (serve ...) form: a peer's program
(set fe.*served* [])           \\ [[FunctionName Effect Operation ReadOnly?] ...]: the served operations
(set fe.*functions* [])        \\ [[Name [ArgumentType ResultType]] ...]
(set fe.*table* [])            \\ [[FunctionName Effects] ...], the current estimate
(set fe.*strict* true)         \\ false while effect sets are still being computed
(set fe.*next* 0)              \\ next unused ID
(set fe.*locations* [])        \\ [[Id Line Column] ...], most recent first

(define fe.fresh
  -> (let N (value fe.*next*)
       (do (set fe.*next* (+ N 1)) (str N))))

\\ A fresh ID with a source-map row: for expression nodes and functions.
(define fe.node
  L C -> (let Id (fe.fresh)
           (do (set fe.*locations* [[Id L C] | (value fe.*locations*)]) Id)))

\\ ---------- small helpers ----------

(define fe.line
  [_ L _ | _] -> L)

(define fe.column
  [_ _ C | _] -> C)

(define fe.reject
  Datum Message -> (fe.fail (fe.line Datum) (fe.column Datum) Message))

\\ The value paired with Key, or the symbol none.
(define fe.lookup
  _ [] -> none
  Key [[Key V | _] | _] -> V
  Key [_ | Rest] -> (fe.lookup Key Rest))

(define fe.keys
  Pairs -> (map (/. P (hd P)) Pairs))

(define fe.last
  [X] -> X
  [_ | Xs] -> (fe.last Xs))

(define fe.but-last
  [_] -> []
  [X | Xs] -> [X | (fe.but-last Xs)])

(define fe.spaced
  [] -> ""
  [X | Xs] -> (cn " " (cn X (fe.spaced Xs))))

(define fe.listed
  [X] -> X
  [X Y] -> (cn X (cn " and " Y))
  [X | Xs] -> (cn X (cn ", " (fe.listed Xs))))

(define fe.plural
  1 Word -> (cn "1 " Word)
  N Word -> (make-string "~A ~As" N Word))

(define fe.codes
  "" -> []
  (@s C Cs) -> [(string->n C) | (fe.codes Cs)])

\\ Unsigned UTF-8 byte order. Names are ASCII, so octets and characters agree.
(define fe.name<?
  "" "" -> false
  "" _ -> true
  _ "" -> false
  (@s A As) (@s B Bs) -> (if (= A B) (fe.name<? As Bs) (< (string->n A) (string->n B))))

(define fe.insert-name
  N [] -> [N]
  N [N | Ns] -> [N | Ns]
  N [M | Ns] -> (if (fe.name<? N M) [N M | Ns] [M | (fe.insert-name N Ns)]))

\\ An effect set in its one canonical spelling: sorted, no duplicates.
(define fe.sort-names
  [] -> []
  [N | Ns] -> (fe.insert-name N (fe.sort-names Ns)))

\\ ---------- names ----------

(define fe.upper?
  B -> (and (>= B 65) (<= B 90)))

(define fe.lower-or-underscore?
  B -> (or (and (>= B 97) (<= B 122)) (= B 95)))

(define fe.identifier-rest?
  B -> (or (fe.upper? B) (fe.lower-or-underscore? B) (fe.digit? B)))

\\ Datatypes, constructors and effects: Capitalised artifact identifiers.
(define fe.capital-name?
  Name -> (let Codes (fe.codes Name)
            (and (fe.upper? (hd Codes)) (<= (length Codes) 64)
                 (fe.all? (/. B (fe.identifier-rest? B)) (tl Codes)))))

\\ Operations: lowercase artifact identifiers.
(define fe.operation-name?
  Name -> (let Codes (fe.codes Name)
            (and (fe.lower-or-underscore? (hd Codes)) (<= (length Codes) 64)
                 (fe.all? (/. B (fe.identifier-rest? B)) (tl Codes)))))

\\ Words with a meaning of their own, which no function or variable may take.
(define fe.reserved?
  Name -> (element? Name ["define" "datatype" "effect" "remote-effect" "read-only" "include" "serve" "let" "if" "do" "tuple" "project" "match" "lambda" "type"
                          "emit" "perform" "handle" "resume" "discontinue" "unit" "true" "false"
                          "not" "neg" "bytes-length" "bytes-index" "bytes-concat" "_"]))

\\ Functions and variables: lowercase, and may contain hyphens. Variables never
\\ reach the artifact (they become binder IDs); function names are free text there.
(define fe.value-name?
  Name -> (let Codes (fe.codes Name)
            (and (fe.lower-or-underscore? (hd Codes)) (<= (length Codes) 64)
                 (fe.all? (/. B (or (fe.identifier-rest? B) (= B 45))) (tl Codes))
                 (not (fe.reserved? Name)))))

(define fe.check-capital
  What [sym L C Name] -> (if (fe.capital-name? Name) Name
                             (fe.fail L C (make-string "~A is not a valid ~A name: it must start with an uppercase letter and continue with letters, digits or _" Name What)))
  What D -> (fe.reject D (make-string "a ~A name is expected here" What)))

(define fe.check-value-name
  What [sym L C Name] -> (fe.fail L C (make-string "~A is a reserved word and cannot name a ~A" Name What)) where (fe.reserved? Name)
  What [sym L C Name] -> (if (fe.value-name? Name) Name
                             (fe.fail L C (make-string "~A is not a valid ~A name: it must start with a lowercase letter or _ and continue with letters, digits, _ or -" Name What)))
  What D -> (fe.reject D (make-string "a ~A name is expected here" What)))

\\ ---------- types ----------

(define fe.data-type
  "TrapCode" -> "TrapCode"
  Name -> ["Data" Name])

\\ The constructor table of a type, or none when it is not a datatype.
(define fe.constructors-of
  ["Remote" B] -> [["Reply" [B]] ["NotDelivered" []] ["TimedOut" []]]
  "TrapCode" -> (fe.lookup "TrapCode" (value fe.*datatypes*))
  ["Data" Name] -> (fe.lookup Name (value fe.*datatypes*))
  _ -> none)

\\ [TypeName Fields] for a constructor name, or [].
(define fe.find-constructor
  _ [] -> []
  Name [[Type Constructors] | Rest] -> (let Fields (fe.lookup Name Constructors)
                                         (if (= Fields none) (fe.find-constructor Name Rest) [Type Fields])))

\\ Serializable, which in this slice is also equality-compatible: no function
\\ anywhere inside. Visiting holds the datatypes being traversed (recursive types).
\\ The three outcomes of a remote perform, as the artifact and the machines name them.
(define fe.outcome-name
  "Reply" -> "reply"
  "NotDelivered" -> "not_delivered"
  "TimedOut" -> "timed_out")

(define fe.outcome?
  Name -> (element? Name ["Reply" "NotDelivered" "TimedOut"]))

(define fe.plain?
  ["Arrow" | _] _ -> false
  ["Remote" B] Visiting -> (fe.plain? B Visiting)
  ["Tuple" | Ts] Visiting -> (fe.all? (/. T (fe.plain? T Visiting)) Ts)
  ["Data" Name] Visiting -> true where (element? Name Visiting)
  ["Data" Name] Visiting -> (fe.all? (/. Constructor (fe.all? (/. T (fe.plain? T [Name | Visiting])) (hd (tl Constructor))))
                                     (fe.lookup Name (value fe.*datatypes*)))
  _ _ -> true)

\\ A type in surface syntax, for messages.
(define fe.show-type
  ["Data" Name] -> Name
  ["Remote" B] -> (make-string "(Remote ~A)" (fe.show-type B))
  ["Tuple" | Ts] -> (cn "(Tuple" (cn (fe.spaced (map (/. T (fe.show-type T)) Ts)) ")"))
  ["Arrow" A B []] -> (make-string "(~A --> ~A)" (fe.show-type A) (fe.show-type B))
  ["Arrow" A B Es] -> (make-string "(~A --> ~A !~A)" (fe.show-type A) (fe.show-type B) (fe.spaced Es))
  T -> T)

(define fe.effect-name
  [sym _ _ "Emit"] -> "Emit"
  [sym L C Name] -> (if (= (fe.lookup Name (value fe.*effects*)) none)
                        (fe.fail L C (make-string "unknown effect ~A" Name))
                        Name)
  D -> (fe.reject D "an effect name is expected here"))

(define fe.type
  [sym _ _ T] -> T where (element? T ["Unit" "Bool" "I64" "Bytes" "TrapCode"])
  [sym _ _ T] -> ["Data" T] where (element? T (value fe.*datatype-names*))
  [sym L C T] -> (fe.fail L C (make-string "unknown type ~A" T))
  [list L C [[sym _ _ "Tuple"] | Ts]] ->
    (if (and (> (length Ts) 0) (< (length Ts) 9))
        ["Tuple" | (map (/. T (fe.type T)) Ts)]
        (fe.fail L C "a tuple type has 1 to 8 components"))
  [list L C [[sym _ _ "Remote"] | _]] ->
    (fe.fail L C "(Remote T) cannot be written as a type: the outcome of a remote perform exists only between the perform and the match that takes it apart, (match (perform Effect operation ...) ...), and is never bound, passed, returned or stored")
  [list _ _ [A [sym _ _ "-->"] B]] -> ["Arrow" (fe.type A) (fe.type B) []]
  [list _ _ [A [sym _ _ "-->"] B [sym _ _ "!"] E | Es]] ->
    ["Arrow" (fe.type A) (fe.type B) (fe.sort-names (map (/. X (fe.effect-name X)) [E | Es]))]
  D -> (fe.reject D "a type is a type name, (Tuple T ...), (A --> B) or (A --> B ! Effect ...)"))

\\ ---------- expected types ----------

\\ What the context wants from an expression: any, or [want Type What Why], where
\\ What names the expression's role and Why says where the expectation comes from.
\\ Both only serve the message. A third, scrutinee, is given by a match to a
\\ perform that is written as its scrutinee, and to nothing else (fe.scrutinee):
\\ it wants no type, and it is what allows a remote perform there.
\\
\\ While effect sets are still being computed (fe.*strict* false) a mismatch is
\\ not an error yet: two function types may differ only because an effect set
\\ has not reached its final value. They are joined instead, and the strict
\\ pass that follows judges the program.
(define fe.join
  ["Arrow" A B Es] ["Arrow" A2 B2 Es2] -> ["Arrow" (fe.join A A2) (fe.join B B2) (fe.sort-names (append Es Es2))]
  ["Tuple" | Ts] ["Tuple" | Us] -> ["Tuple" | (fe.join-each Ts Us)] where (= (length Ts) (length Us))
  _ Expected -> Expected)

(define fe.join-each
  [] [] -> []
  [T | Ts] [U | Us] -> [(fe.join T U) | (fe.join-each Ts Us)])

(define fe.conform
  _ _ Found any -> Found
  _ _ Found scrutinee -> Found
  _ _ Found [want Found _ _] -> Found
  L C Found [want Expected What Why] ->
    (if (value fe.*strict*)
        (fe.fail L C (make-string "~A has type ~A, but ~A is expected~A" What (fe.show-type Found) (fe.show-type Expected) Why))
        (fe.join Found Expected)))

\\ ---------- rows ----------

(define fe.row-node [Node _ _ _] -> Node)
(define fe.row-type [_ Type _ _] -> Type)
(define fe.row-effects [_ _ Effects _] -> Effects)
(define fe.row-uses [_ _ _ Uses] -> Uses)

\\ Finish a node whose type was synthesized: hold it against what is wanted.
(define fe.done
  L C Node Type Effects Uses Want -> [Node (fe.conform L C Type Want) Effects Uses])

(define fe.union
  Es [] -> Es
  Es [[Name | Origin] | Rest] -> (fe.union (if (= (fe.lookup Name Es) none) (append Es [[Name | Origin]]) Es) Rest))

(define fe.union-rows
  [] -> []
  [Row | Rows] -> (fe.union (fe.row-effects Row) (fe.union-rows Rows)))

(define fe.without
  _ [] -> []
  Name [[Name | _] | Es] -> Es
  Name [E | Es] -> [E | (fe.without Name Es)])

\\ Uses along one path add up. The position kept is the later one, so that a
\\ second use of a resumption is reported where it is written.
(define fe.add-use
  Use [] -> [Use]
  [K Name N L C] [[K _ M _ _] | Rest] -> [[K Name (+ N M) L C] | Rest]
  Use [Other | Rest] -> [Other | (fe.add-use Use Rest)])

(define fe.sum
  Us [] -> Us
  Us [V | Vs] -> (fe.sum (fe.add-use V Us) Vs))

(define fe.sum-rows
  [] -> []
  [Row | Rows] -> (fe.sum (fe.row-uses Row) (fe.sum-rows Rows)))

(define fe.count
  K Uses -> (let N (fe.lookup K (map (/. U [(hd U) (hd (tl (tl U)))]) Uses))
              (if (= N none) 0 N)))

\\ Branches are alternatives: every one must use each resumption equally often,
\\ and the construct then counts as one of them.
(define fe.agree-uses
  _ _ _ [] _ -> true
  L C What [[K Name N _ _] | Rest] Other ->
    (let M (fe.count K Other)
      (if (= N M)
          (fe.agree-uses L C What Rest Other)
          (fe.fail L C (make-string "the branches of this ~A do not agree on resumption ~A: one uses it ~A, another ~A. Every path through a clause must use its resumption exactly once, by (resume ~A e) or (discontinue ~A)"
                                    What Name (fe.times N) (fe.times M) Name Name)))))

(define fe.times
  0 -> "not at all"
  1 -> "once"
  2 -> "twice"
  N -> (make-string "~A times" N))

(define fe.branch-uses
  L C What First [] -> First
  L C What First [Next | Rest] ->
    (do (fe.agree-uses L C What First Next) (fe.agree-uses L C What Next First)
        (fe.branch-uses L C What First Rest)))

\\ ---------- bindings ----------

\\ An environment entry is [Name var Id Type] or
\\ [Name resumption Id OperationResultType HandleType Scope], Scope being open or
\\ the kind of place (a string) the resumption cannot be used from.
(define fe.bind
  [sym _ _ "_"] _ _ Env -> Env
  Datum Id Type Env -> [[(fe.check-value-name "variable" Datum) var Id Type] | Env])

\\ A lambda body and a handler clause may run any number of times, or after the
\\ enclosing clause is over: the resumptions around them are out of reach there.
(define fe.block
  Where Env -> (map (/. B (fe.block-one Where B)) Env))

(define fe.block-one
  Where [Name resumption Id B T open] -> [Name resumption Id B T Where]
  _ Binding -> Binding)

(define fe.binding
  _ [] -> none
  Name [[Name | Rest] | _] -> [Name | Rest]
  Name [_ | Env] -> (fe.binding Name Env))

\\ No name twice among the binders of one pattern or parameter list.
(define fe.distinct
  [] _ -> true
  [[sym _ _ "_"] | Rest] Seen -> (fe.distinct Rest Seen)
  [[sym L C Name] | Rest] Seen -> (if (element? Name Seen)
                                      (fe.fail L C (make-string "~A is bound twice here" Name))
                                      (fe.distinct Rest [Name | Seen]))
  [_ | Rest] Seen -> (fe.distinct Rest Seen))

\\ ---------- expressions ----------

(define fe.high
  N Q -> Q where (< N 16)
  N Q -> (fe.high (- N 16) (+ Q 1)))

(define fe.hex
  [] -> ""
  [B | Bs] -> (let H (fe.high B 0)
                (cn (pos "0123456789abcdef" H) (cn (pos "0123456789abcdef" (- B (* 16 H))) (fe.hex Bs)))))

\\ Surface operator to [ArtifactPrimitive OperandTypes ResultType]. Equality is
\\ separate: it works at any serializable type.
(define fe.primitive
  "+" -> ["add" ["I64" "I64"] "I64"]
  "-" -> ["sub" ["I64" "I64"] "I64"]
  "*" -> ["mul" ["I64" "I64"] "I64"]
  "/" -> ["div" ["I64" "I64"] "I64"]
  "neg" -> ["neg" ["I64"] "I64"]
  "<" -> ["lt" ["I64" "I64"] "Bool"]
  "<=" -> ["le" ["I64" "I64"] "Bool"]
  ">" -> ["gt" ["I64" "I64"] "Bool"]
  ">=" -> ["ge" ["I64" "I64"] "Bool"]
  "not" -> ["not" ["Bool"] "Bool"]
  "bytes-length" -> ["bytes_length" ["Bytes"] "I64"]
  "bytes-index" -> ["bytes_index" ["Bytes" "I64"] "I64"]
  "bytes-concat" -> ["bytes_concat" ["Bytes" "Bytes"] "Bytes"]
  _ -> none)

(define fe.form?
  K -> (element? K ["let" "if" "do" "tuple" "project" "match" "lambda" "type" "emit" "perform" "handle" "resume" "discontinue" "="]))

(define fe.expr
  [int L C N] _ Want -> (fe.done L C ["int" (fe.node L C) N] "I64" [] [] Want)
  [hex L C Hex] _ Want -> (fe.done L C ["bytes" (fe.node L C) Hex] "Bytes" [] [] Want)
  [str L C Octets] _ Want -> (fe.done L C ["bytes" (fe.node L C) (fe.hex Octets)] "Bytes" [] [] Want)
  [sym L C "unit"] _ Want -> (fe.done L C ["unit" (fe.node L C)] "Unit" [] [] Want)
  [sym L C "true"] _ Want -> (fe.done L C ["bool" (fe.node L C) true] "Bool" [] [] Want)
  [sym L C "false"] _ Want -> (fe.done L C ["bool" (fe.node L C) false] "Bool" [] [] Want)
  [sym L C Name] Env Want -> (fe.name L C Name (fe.binding Name Env) Want)
  [brace L C _] _ _ -> (fe.fail L C "{ } only encloses the signature of a define")
  [list L C []] _ _ -> (fe.fail L C "() is not an expression; the unit value is written unit")
  [list L C [[sym _ _ K] | Args]] Env Want -> (fe.form K L C Args Env Want) where (fe.form? K)
  [list L C [[sym _ _ K] | Args]] Env Want -> (fe.operator K (fe.primitive K) L C Args Env Want) where (not (= (fe.primitive K) none))
  [list L C [[sym HL HC Name] | Args]] Env Want -> (fe.headed L C HL HC Name (fe.binding Name Env) Args Env Want)
  [list L C [Head | Args]] Env Want -> (fe.apply L C (fe.node L C) (fe.expr Head Env any) Args Env Want))

\\ A name on its own: a variable, or a constructor without fields.
(define fe.name
  L C _ [_ var Id Type] Want -> (fe.done L C ["var" (fe.node L C) Id] Type [] [] Want)
  L C Name [_ resumption | _] _ ->
    (fe.fail L C (make-string "~A is a resumption, not a value: it can only be used as (resume ~A e) or (discontinue ~A)" Name Name Name))
  L C Name none Want -> (fe.global L C Name (fe.find-constructor Name (value fe.*datatypes*)) Want))

(define fe.global
  L C Name [Type []] Want -> (fe.done L C ["construct" (fe.node L C) Type Name] (fe.data-type Type) [] [] Want)
  L C Name [Type Fields] _ ->
    (fe.fail L C (make-string "constructor ~A of ~A takes ~A: write (~A ...)" Name Type (fe.plural (length Fields) "field") Name))
  L C Name [] _ -> (fe.fail L C (make-string "~A is a function, not a value: to pass it, wrap it in a lambda that calls it" Name))
    where (not (= (fe.lookup Name (value fe.*functions*)) none))
  L C Name [] _ -> (fe.fail L C (make-string "~A is a keyword and needs its operands: write (~A ...)" Name Name))
    where (or (fe.form? Name) (fe.reserved? Name) (not (= (fe.primitive Name) none)))
  L C Name [] _ -> (fe.fail L C (make-string "~A is an outcome of a remote perform: a program takes outcomes apart with match and cannot make one" Name))
    where (fe.outcome? Name)
  L C Name [] _ -> (fe.fail L C (make-string "unknown name ~A: no variable, function or constructor of that name is in scope" Name)))

\\ (Name Arg ...): application of a local function value, a constructor, or a call.
(define fe.headed
  L C HL HC _ [_ var Id Type] Args Env Want ->
    (let Node (fe.node L C)
      (fe.apply L C Node [["var" (fe.node HL HC) Id] Type [] []] Args Env Want))
  _ _ HL HC Name [_ resumption | _] _ _ _ ->
    (fe.fail HL HC (make-string "~A is a resumption, not a function: write (resume ~A e) or (discontinue ~A)" Name Name Name))
  L C HL HC Name none Args Env Want ->
    (fe.global-headed L C HL HC Name (fe.find-constructor Name (value fe.*datatypes*)) (fe.lookup Name (value fe.*functions*)) Args Env Want))

(define fe.global-headed
  L C _ _ Name [Type Fields] _ Args Env Want ->
    (if (= (length Args) (length Fields))
        (let Node (fe.node L C)
             Rows (fe.operands Args Env (fe.field-wants Name Fields 1))
          (fe.done L C ["construct" Node Type Name | (map (/. R (fe.row-node R)) Rows)] (fe.data-type Type)
                   (fe.union-rows Rows) (fe.sum-rows Rows) Want))
        (fe.fail L C (make-string "constructor ~A of ~A takes ~A, but ~A given here" Name Type
                                  (fe.plural (length Fields) "field") (fe.given (length Args)))))
  _ _ HL HC Name [] none _ _ _ ->
    (fe.fail HL HC (make-string "~A is an outcome of a remote perform: a program takes outcomes apart with match and cannot make one" Name))
    where (fe.outcome? Name)
  _ _ HL HC Name [] none _ _ _ ->
    (fe.fail HL HC (make-string "unknown name ~A: no function, constructor or variable of that name is in scope" Name))
  L C _ _ Name [] [ArgumentType ResultType] Args Env Want ->
    (let Node (fe.node L C)
         Arg (fe.argument L C Args Env [want ArgumentType (cn "the argument of " Name) ""])
         Latent (map (/. E [(hd E) L C (cn "the call to " Name)]) (fe.lookup Name (value fe.*table*)))
      (fe.done L C ["call" Node Name (fe.row-node Arg)] ResultType (fe.union (fe.row-effects Arg) Latent) (fe.row-uses Arg) Want)))

(define fe.given
  1 -> "1 is"
  N -> (make-string "~A are" N))

(define fe.field-wants
  _ [] _ -> []
  Name [T | Ts] I -> [[want T (make-string "field ~A of ~A" I Name) ""] | (fe.field-wants Name Ts (+ I 1))])

\\ Operands are elaborated strictly left to right, the order they are evaluated in,
\\ so IDs follow source order.
(define fe.operands
  [] _ _ -> []
  [A | As] Env [W | Ws] -> (let Row (fe.expr A Env W)
                             [Row | (fe.operands As Env Ws)]))

(define fe.anys
  [] -> []
  [_ | Xs] -> [any | (fe.anys Xs)])

\\ Calls, applications and performs take one argument. Several are passed as their tuple.
(define fe.argument
  L C [] _ _ -> (fe.fail L C "exactly one argument is passed here: write unit when there is nothing to pass")
  _ _ [A] Env Want -> (fe.expr A Env Want)
  L C Args Env Want -> (fe.tuple L C Args Env Want))

(define fe.apply
  L C Node Function Args Env Want ->
    (fe.apply-typed L C Node Function (fe.row-type Function) Args Env Want))

(define fe.apply-typed
  L C Node Function ["Arrow" A B Es] Args Env Want ->
    (let Arg (fe.argument L C Args Env [want A "the argument of this application" ""])
         Latent (map (/. E [E L C "this application"]) Es)
      (fe.done L C ["apply" Node (fe.row-node Function) (fe.row-node Arg)] B
               (fe.union (fe.union (fe.row-effects Function) (fe.row-effects Arg)) Latent)
               (fe.sum (fe.row-uses Function) (fe.row-uses Arg)) Want))
  L C _ _ Type _ _ _ ->
    (fe.fail L C (make-string "this applies a value of type ~A, which is not a function" (fe.show-type Type))))

(define fe.operand-wants
  _ [] _ -> []
  K [T | Ts] I -> [[want T (make-string "operand ~A of ~A" I K) ""] | (fe.operand-wants K Ts (+ I 1))])

(define fe.operator
  K [Op Types Result] L C Args Env Want ->
    (if (= (length Args) (length Types))
        (let Node (fe.node L C)
             Rows (fe.operands Args Env (fe.operand-wants K Types 1))
          (fe.done L C ["prim" Node Op | (map (/. R (fe.row-node R)) Rows)] Result (fe.union-rows Rows) (fe.sum-rows Rows) Want))
        (fe.fail L C (make-string "~A takes ~A, but ~A given here" K (fe.plural (length Types) "operand") (fe.given (length Args))))))

(define fe.tuple
  L C Args Env Want ->
    (if (and (> (length Args) 0) (< (length Args) 9))
        (let Node (fe.node L C)
             Rows (fe.operands Args Env (fe.tuple-wants Args Want))
          (fe.done L C ["tuple" Node | (map (/. R (fe.row-node R)) Rows)] ["Tuple" | (map (/. R (fe.row-type R)) Rows)]
                   (fe.union-rows Rows) (fe.sum-rows Rows) Want))
        (fe.fail L C "a tuple has 1 to 8 components")))

\\ When a tuple of the right size is wanted, each component is held against its own type.
(define fe.tuple-wants
  Args [want ["Tuple" | Ts] What Why] -> (map (/. T [want T What Why]) Ts) where (= (length Ts) (length Args))
  Args _ -> (fe.anys Args))

(define fe.form
  "let" L C Args Env Want -> (fe.let L C Args Env Want) where (and (> (length Args) 2) (fe.pairs? (tl Args)))
  "let" L C _ _ _ -> (fe.fail L C "let is written (let name value body), or with several bindings (let name value name value ... body)")
  "if" L C [Condition Then Else] Env Want -> (fe.if L C (fe.node L C) Condition Then Else Env Want)
  "if" L C _ _ _ -> (fe.fail L C "if is written (if condition then else)")
  "do" L C [E | Es] Env Want -> (fe.do [E | Es] Env Want)
  "do" L C _ _ _ -> (fe.fail L C "do is written (do e ... result), with at least one expression")
  "tuple" L C Args Env Want -> (fe.tuple L C Args Env Want)
  "project" L C [E [int IL IC Index]] Env Want -> (fe.project L C (fe.node L C) (fe.expr E Env any) IL IC Index Want)
  "project" L C _ _ _ -> (fe.fail L C "project is written (project tuple index), the index a literal counted from 0")
  "match" L C [Scrutinee | Arms] Env Want -> (fe.match L C (fe.node L C) (fe.scrutinee Scrutinee Env) Scrutinee Arms Env Want)
  "match" L C _ _ _ -> (fe.fail L C "match is written (match value (Constructor -> e) ((Constructor x ...) -> e) ...)")
  "lambda" L C [[list _ _ [X [sym _ _ ":"] T]] Body] Env Want -> (fe.lambda L C X (fe.type T) Body Env Want)
  "lambda" L C _ _ _ -> (fe.fail L C "lambda is written (lambda (x : Type) body)")
  "type" L C [E T] Env Want ->
    (let Type (fe.type T)
         Row (fe.expr E Env [want Type "this expression" " (the type it is annotated with)"])
      (fe.done L C (fe.row-node Row) (fe.row-type Row) (fe.row-effects Row) (fe.row-uses Row) Want))
  "type" L C _ _ _ -> (fe.fail L C "a type annotation is written (type e Type)")
  "emit" L C [[str LL LC Octets] E] Env Want -> (fe.emit L C (fe.node L C) (fe.label LL LC Octets) E Env Want)
  "emit" L C _ _ _ -> (fe.fail L C "emit is written (emit c#34;labelc#34; value)")
  "perform" L C [[sym EL EC Effect] [sym OL OC Op] | Args] Env Want ->
    (fe.perform L C Effect Op (fe.operation EL EC Effect OL OC Op) Args Env Want)
  "perform" L C _ _ _ -> (fe.fail L C "perform is written (perform Effect operation argument)")
  "handle" L C [Effect Clause | Rest] Env Want -> (fe.handle L C Effect [Clause | Rest] Env Want)
  "handle" L C _ _ _ -> (fe.fail L C "handle is written (handle Effect ((operation x) -> e) ... body)")
  "resume" L C [[sym KL KC K] E] Env Want -> (fe.resume L C K (fe.resumption KL KC K (fe.binding K Env)) E Env Want)
  "resume" L C _ _ _ -> (fe.fail L C "resume is written (resume k value), k the resumption a handler clause names")
  "discontinue" L C [[sym KL KC K]] Env Want ->
    (let Binding (fe.resumption KL KC K (fe.binding K Env))
      (fe.done L C ["discontinue" (fe.node L C) (hd Binding)] "Unit" [] [[(hd Binding) K 1 L C]] Want))
  "discontinue" L C _ _ _ -> (fe.fail L C "discontinue is written (discontinue k), k the resumption a handler clause names")
  "=" L C [A B] Env Want -> (fe.equal L C (fe.node L C) (fe.expr A Env any) A B Env Want)
  "=" L C _ _ _ -> (fe.fail L C "= takes 2 operands"))

\\ Items are name value ... body. L C place the let node for the first binding;
\\ each later binding's node is placed at its name.
(define fe.let
  _ _ [Body] Env Want -> (fe.expr Body Env Want)
  L C [Name Value | Rest] Env Want ->
    (let Node (fe.node L C)
         Id (fe.fresh)
         Init (fe.expr Value Env any)
         Body (fe.let (fe.line (hd Rest)) (fe.column (hd Rest)) Rest (fe.bind Name Id (fe.row-type Init) Env) Want)
      [["let" Node Id (fe.row-node Init) (fe.row-node Body)] (fe.row-type Body)
       (fe.union (fe.row-effects Init) (fe.row-effects Body)) (fe.sum (fe.row-uses Init) (fe.row-uses Body))]))

\\ (do a b c) is let _ = a in let _ = b in c: the artifact has no other sequencing.
(define fe.do
  [E] Env Want -> (fe.expr E Env Want)
  [E | Es] Env Want ->
    (let Node (fe.node (fe.line E) (fe.column E))
         Id (fe.fresh)
         First (fe.expr E Env any)
         Rest (fe.do Es Env Want)
      [["let" Node Id (fe.row-node First) (fe.row-node Rest)] (fe.row-type Rest)
       (fe.union (fe.row-effects First) (fe.row-effects Rest)) (fe.sum (fe.row-uses First) (fe.row-uses Rest))]))

(define fe.if
  L C Node Condition Then Else Env Want ->
    (let Test (fe.expr Condition Env [want "Bool" "the condition of if" ""])
         Yes (fe.expr Then Env Want)
         No (fe.expr Else Env (if (= Want any) [want (fe.row-type Yes) "the else branch" " (the type of the then branch)"] Want))
         Uses (fe.branch-uses L C "if" (fe.row-uses Yes) [(fe.row-uses No)])
      [["if" Node (fe.row-node Test) (fe.row-node Yes) (fe.row-node No)] (fe.row-type No)
       (fe.union-rows [Test Yes No]) (fe.sum (fe.row-uses Test) Uses)]))

\\ The 0-based index, a decimal string, as a position in Types.
(define fe.component
  _ [] _ -> none
  Index [T | _] I -> T where (= Index (str I))
  Index [_ | Ts] I -> (fe.component Index Ts (+ I 1)))

(define fe.project
  L C Node Row IL IC Index Want -> (fe.project-typed L C Node Row (fe.row-type Row) IL IC Index Want))

(define fe.project-typed
  L C Node Row ["Tuple" | Ts] IL IC Index Want ->
    (let T (fe.component Index Ts 0)
      (if (= T none)
          (fe.fail IL IC (make-string "index ~A is out of range for ~A, whose components are numbered 0 to ~A" Index (fe.show-type ["Tuple" | Ts]) (- (length Ts) 1)))
          (fe.done L C ["project" Node (fe.row-node Row) Index] T (fe.row-effects Row) (fe.row-uses Row) Want)))
  L C _ _ Type _ _ _ _ -> (fe.fail L C (make-string "project needs a tuple, but this has type ~A" (fe.show-type Type))))

(define fe.equal
  L C Node Left A B Env Want ->
    (let Right (fe.expr B Env [want (fe.row-type Left) "the second operand of =" " (the type of the first operand)"])
      (if (fe.plain? (fe.row-type Left) [])
          (fe.done L C ["prim" Node "eq" (fe.row-node Left) (fe.row-node Right)] "Bool"
                   (fe.union-rows [Left Right]) (fe.sum-rows [Left Right]) Want)
          (fe.reject A (make-string "= compares serializable values only, but this operand has type ~A, which contains a function" (fe.show-type (fe.row-type Left)))))))

\\ Emit labels are restricted to printable ASCII here: a label is copied into the
\\ artifact as text, and the reader keeps strings as octets.
(define fe.label
  L C Octets -> (if (fe.all? (/. B (and (>= B 32) (< B 127))) Octets)
                    (fe.string-of Octets)
                    (fe.fail L C "an emit label may only contain printable ASCII characters")))

(define fe.emit
  L C Node Label E Env Want ->
    (let Row (fe.expr E Env any)
      (if (fe.plain? (fe.row-type Row) [])
          (fe.done L C ["emit" Node Label (fe.row-node Row)] "Unit" (fe.union (fe.row-effects Row) [["Emit" L C "this emit"]]) (fe.row-uses Row) Want)
          (fe.reject E (make-string "emit needs a serializable value, but this has type ~A, which contains a function" (fe.show-type (fe.row-type Row)))))))

\\ ---------- match ----------

\\ The scrutinee of a match. A perform written there, itself and not inside
\\ another expression, is told so: that is the one place a remote perform may stand.
(define fe.scrutinee
  [list L C [[sym _ _ "perform"] [sym EL EC Effect] [sym OL OC Op] | Args]] Env ->
    (fe.perform L C Effect Op (fe.operation EL EC Effect OL OC Op) Args Env scrutinee)
  Scrutinee Env -> (fe.expr Scrutinee Env any))

\\ An arm is (Constructor -> e) or ((Constructor x ...) -> e): [Line Column Name Binders Body].
(define fe.arm
  [list L C [[sym _ _ Name] [sym _ _ "->"] Body]] -> [L C Name [] Body]
  [list L C [[list _ _ [[sym _ _ Name] | Binders]] [sym _ _ "->"] Body]] -> [L C Name Binders Body]
  D -> (fe.reject D "a match arm is written (Constructor -> e) or ((Constructor x ...) -> e)"))

(define fe.bind-fields
  [] [] Env Ids -> [Env (reverse Ids)]
  [B | Bs] [T | Ts] Env Ids -> (let Id (fe.fresh)
                                 (fe.bind-fields Bs Ts (fe.bind B Id T Env) [Id | Ids])))

\\ Rows are [ArmNode Row], most recent first. Each arm after the first is held
\\ against the type the arms before it settled on.
(define fe.arms
  [] _ _ _ _ _ Rows -> (reverse Rows)
  [Arm | Arms] Table TypeName Env Want Seen Rows ->
    (let Parsed (fe.arm Arm)
         Row (fe.arm-row Parsed (fe.lookup (hd (tl (tl Parsed))) Table) Table TypeName Env Seen
                         (if (or (not (= Want any)) (empty? Rows)) Want
                             [want (fe.row-type (hd (tl (hd Rows)))) "this match arm" " (the type of the arms before it)"]))
      (fe.arms Arms Table TypeName Env Want [(hd (tl (tl Parsed))) | Seen] [Row | Rows])))

(define fe.arm-row
  [L C Name _ _] none _ TypeName _ _ _ -> (fe.fail L C (make-string "~A is not a constructor of ~A" Name TypeName))
  [L C Name _ _] _ _ _ _ Seen _ -> (fe.fail L C (make-string "this match has two arms for ~A" Name)) where (element? Name Seen)
  [L C Name Binders Body] Fields _ TypeName Env _ Want ->
    (if (= (length Binders) (length Fields))
        (let Distinct (fe.distinct Binders [])
             Bound (fe.bind-fields Binders Fields Env [])
             Row (fe.expr Body (hd Bound) Want)
          [[Name (hd (tl Bound)) (fe.row-node Row)] Row])
        (fe.fail L C (make-string "constructor ~A of ~A has ~A, but this arm binds ~A" Name TypeName
                                  (fe.plural (length Fields) "field") (length Binders)))))

(define fe.missing
  [] _ -> []
  [[Name | _] | Rest] Seen -> (if (element? Name Seen) (fe.missing Rest Seen) [Name | (fe.missing Rest Seen)]))

\\ An arm as the artifact has it. The outcomes of a remote perform are written
\\ Reply, NotDelivered and TimedOut, and are reply, not_delivered and timed_out there.
(define fe.arm-node
  ["Remote" _] [Name Ids Body] -> [(fe.outcome-name Name) Ids Body]
  _ Arm -> Arm)

(define fe.match
  L C Node Subject Scrutinee Arms Env Want ->
    (let Table (fe.constructors-of (fe.row-type Subject))
         TypeName (fe.show-type (fe.row-type Subject))
         Checked (if (= Table none)
                     (fe.reject Scrutinee (make-string "match needs a value of a datatype, but this has type ~A" TypeName))
                     true)
         Rows (fe.arms Arms Table TypeName Env Want [] [])
         Missing (fe.missing Table (map (/. R (hd (hd R))) Rows))
         Exhaustive (if (empty? Missing) true
                        (fe.fail L C (make-string "this match on ~A is not exhaustive: there is no arm for ~A" TypeName (fe.listed Missing))))
         Bodies (map (/. R (hd (tl R))) Rows)
         Uses (fe.branch-uses L C "match" (fe.row-uses (hd Bodies)) (map (/. B (fe.row-uses B)) (tl Bodies)))
      [["match" Node (fe.row-node Subject) | (map (/. R (fe.arm-node (fe.row-type Subject) (hd R))) Rows)] (fe.row-type (fe.last Bodies))
       (fe.union-rows [Subject | Bodies]) (fe.sum (fe.row-uses Subject) Uses)]))

\\ ---------- lambda ----------

\\ A lambda's result type and effect set are written into the artifact but not
\\ into the source. Held against a function type with its parameter type, the
\\ lambda takes that type's result and effect set (its body may perform fewer
\\ effects, never more). Otherwise it gets its body's type and exactly its
\\ body's effects.
(define fe.lambda
  L C X ParameterType Body Env [want ["Arrow" ParameterType B Es] What Why] ->
    (let Node (fe.node L C)
         Id (fe.fresh)
         Row (fe.expr Body (fe.bind X Id ParameterType (fe.block "a lambda" Env)) [want B "the body of this lambda" " (the result of the function type wanted here)"])
         Performed (fe.keys (fe.row-effects Row))
         Extra (fe.missing (fe.row-effects Row) Es)
         Allowed (if (or (empty? Extra) (not (value fe.*strict*))) true
                     (fe.effect-escapes (fe.binding (hd Extra) (fe.row-effects Row)) ["Arrow" ParameterType B Es]))
         Effects (if (value fe.*strict*) Es (fe.sort-names (append Es Performed)))
      [["lambda" Node Id ParameterType (fe.row-type Row) Effects [] (fe.row-node Row)] ["Arrow" ParameterType (fe.row-type Row) Effects] [] []])
  L C X ParameterType Body Env Want ->
    (let Node (fe.node L C)
         Id (fe.fresh)
         Row (fe.expr Body (fe.bind X Id ParameterType (fe.block "a lambda" Env)) any)
         Effects (fe.sort-names (fe.keys (fe.row-effects Row)))
      (fe.done L C ["lambda" Node Id ParameterType (fe.row-type Row) Effects [] (fe.row-node Row)]
               ["Arrow" ParameterType (fe.row-type Row) Effects] [] [] Want)))

(define fe.effect-escapes
  [Name L C Cause] Type ->
    (fe.fail L C (make-string "effect ~A, which comes from ~A, is not allowed in a lambda that must have type ~A" Name Cause (fe.show-type Type))))

\\ ---------- effects ----------

\\ [ArgumentType ResultType] of Effect.Op.
(define fe.operation
  EL EC Effect OL OC Op ->
    (let Ops (fe.lookup Effect (value fe.*effects*))
         Known (if (= Ops none) (fe.fail EL EC (make-string "unknown effect ~A" Effect)) true)
         Types (fe.binding Op Ops)
      (if (= Types none)
          (fe.fail OL OC (make-string "effect ~A has no operation ~A: its operations are ~A" Effect Op (fe.listed (fe.keys Ops))))
          (tl Types))))

\\ ordinary, or for an operation of a remote effect keyed or read-only.
(define fe.remote-mode
  Effect Op -> (let ReadOnly (fe.lookup Effect (value fe.*remote*))
                 (if (= ReadOnly none) ordinary (if (element? Op ReadOnly) read-only keyed))))

\\ A remote operation op : A --> B is declared with the peer's types. It is
\\ performed with its request key first, (perform Effect op key a), which is the
\\ one argument (tuple key a); a read-only operation has no key and takes a alone.
\\ Either way the perform has the type (Remote B): one of the three outcomes.
\\ Must-use: a remote perform is the scrutinee of a match, and nothing else.
(define fe.perform
  L C Effect Op [A B] Args Env Want ->
    (let Mode (fe.remote-mode Effect Op)
         Local (if (and (value fe.*serving*) (not (= Mode ordinary)))
                   (fe.fail L C (make-string "a program that serves does not perform remote operations: ~A.~A would be a request to another member from inside a request, which is not supported" Effect Op))
                   true)
         Examined (if (or (= Mode ordinary) (= Want scrutinee)) true
                      (fe.fail L C (make-string "the outcome of this remote perform is not examined: a perform of ~A.~A may only be written as the value a match takes apart, (match (perform ~A ~A ...) ((Reply x) -> e) (NotDelivered -> e) (TimedOut -> e)). An outcome cannot be bound, passed, returned, stored or dropped"
                                                Effect Op Effect Op)))
         Node (fe.node L C)
         Arg (fe.argument L C Args Env
               [want (if (= Mode keyed) ["Tuple" "I64" A] A) (make-string "the argument of ~A.~A" Effect Op)
                     (if (= Mode keyed)
                         (make-string " (~A is a remote effect and ~A is not read-only, so it is performed with its request key first: (perform ~A ~A key argument))" Effect Op Effect Op)
                         (if (= Mode read-only) (make-string " (~A.~A is read-only: it is performed without a request key)" Effect Op) ""))])
      (fe.done L C ["perform" Node Effect Op (fe.row-node Arg)] (if (= Mode ordinary) B ["Remote" B])
               (fe.union (fe.row-effects Arg) [[Effect L C "this perform"]]) (fe.row-uses Arg) Want)))

\\ [Id OperationResultType HandleType] of a usable resumption.
(define fe.resumption
  _ _ _ [_ resumption Id B T open] -> [Id B T]
  L C K [_ resumption _ _ _ Where] ->
    (fe.fail L C (make-string "resumption ~A cannot be used inside ~A: it may run more than once, or after the clause that owns ~A has finished" K Where K))
  L C K [_ var | _] -> (fe.fail L C (make-string "~A is a variable, not a resumption: a resumption is the second name of a handler clause, ((operation x k) -> ...)" K))
  L C K none -> (fe.fail L C (make-string "unknown resumption ~A: a resumption is the second name of a handler clause, ((operation x k) -> ...)" K)))

(define fe.resume
  L C K [Id B T] E Env Want ->
    (let Node (fe.node L C)
         Row (fe.expr E Env [want B "the value resumed with" " (the result type of the operation)"])
      (fe.done L C ["resume" Node Id (fe.row-node Row)] T (fe.row-effects Row) (fe.sum (fe.row-uses Row) [[Id K 1 L C]]) Want)))

\\ A clause is ((operation x) -> e) or ((operation x k) -> e):
\\ [Line Column Operation ArgumentBinder ResumptionBinderOrNone Body].
(define fe.clause
  [list L C [[list _ _ [[sym _ _ Op] X]] [sym _ _ "->"] Body]] -> [L C Op X none Body]
  [list L C [[list _ _ [[sym _ _ Op] X K]] [sym _ _ "->"] Body]] -> [L C Op X K Body]
  D -> (fe.reject D "a handler clause is written ((operation x) -> e) or, naming the resumption, ((operation x k) -> e)"))

\\ Rows are [ClauseNode Row], most recent first. Env is the handle node's
\\ environment with the resumptions around it out of reach; T is the handle's type.
(define fe.clauses
  [] _ _ _ _ _ Rows -> (reverse Rows)
  [Clause | Clauses] Effect Ops T Env Seen Rows ->
    (let Parsed (fe.clause Clause)
         Op (hd (tl (tl Parsed)))
         Row (fe.clause-row Parsed (fe.binding Op Ops) Effect Ops T Env Seen)
      (fe.clauses Clauses Effect Ops T Env [Op | Seen] [Row | Rows])))

(define fe.clause-row
  [L C Op _ _ _] none Effect Ops _ _ _ ->
    (fe.fail L C (make-string "effect ~A has no operation ~A: its operations are ~A" Effect Op (fe.listed (fe.keys Ops))))
  [L C Op _ _ _] _ Effect _ _ _ Seen -> (fe.fail L C (make-string "this handler has two clauses for ~A.~A" Effect Op)) where (element? Op Seen)
  \\ Tail-resumptive: the clause's value is the result of the perform.
  [L C Op X none Body] [_ A B] Effect _ _ Env _ ->
    (let Id (fe.fresh)
         Row (fe.expr Body (fe.bind X Id A Env)
                      [want B (make-string "the clause for ~A.~A" Effect Op) " (the result type of the operation; a clause that names its resumption, ((operation x k) -> ...), has the type of the handle instead)"])
      [[Op Id (fe.row-node Row)] Row])
  \\ Explicit: the clause's value is the value of the handle, and k is used once.
  [L C Op X K Body] [_ A B] Effect _ T Env _ ->
    (let Distinct (fe.distinct [X K] [])
         Id (fe.fresh)
         KId (fe.fresh)
         KName (if (= K [sym (fe.line K) (fe.column K) "_"])
                   (fe.reject K "a resumption needs a name: it must be used exactly once")
                   (fe.check-value-name "resumption" K))
         Inner [[KName resumption KId B T open] | (fe.bind X Id A Env)]
         Row (fe.expr Body Inner [want T (make-string "the clause for ~A.~A" Effect Op) " (the type of the handle, since the clause names its resumption)"])
         Used (fe.one-shot L C Effect Op KName KId (fe.row-uses Row))
      [[Op Id KId (fe.row-node Row)] [(fe.row-node Row) (fe.row-type Row) (fe.row-effects Row) Used]]))

\\ The clause's uses with its own resumption checked and removed.
(define fe.one-shot
  L C Effect Op K KId [] ->
    (fe.fail L C (make-string "the clause for ~A.~A names its resumption ~A but never uses it: every path must use it exactly once, by (resume ~A e) or (discontinue ~A)" Effect Op K K K))
  _ _ _ _ _ KId [[KId _ 1 _ _] | Rest] -> Rest
  _ _ Effect Op K KId [[KId _ N UL UC] | _] ->
    (fe.fail UL UC (make-string "resumption ~A is used ~A on one path through the clause for ~A.~A: a resumption is one-shot and must be used exactly once" K (fe.times N) Effect Op))
  L C Effect Op K KId [Other | Rest] -> [Other | (fe.one-shot L C Effect Op K KId Rest)])

(define fe.handle
  L C [sym EL EC Effect] Items Env Want ->
    (let Ops (fe.lookup Effect (value fe.*effects*))
         Known (if (= Ops none) (fe.fail EL EC (make-string "unknown effect ~A" Effect)) true)
         Local (if (= (fe.lookup Effect (value fe.*remote*)) none) true
                   (fe.fail EL EC (make-string "effect ~A is remote and cannot be handled: its operations are carried out by the member the system's manifest binds it to, and no handler in the program takes their place" Effect)))
         Provided (if (and (value fe.*serving*) (fe.store-effect? Effect))
                      (fe.fail EL EC (make-string "effect ~A is the peer's store and cannot be handled: its operations are carried out by the peer's runtime, inside the request's transaction" Effect))
                      true)
         Node (fe.node L C)
         Body (fe.expr (fe.last Items) Env Want)
         Rows (fe.clauses (fe.but-last Items) Effect Ops (fe.row-type Body) (fe.block "a clause of another handler" Env) [] [])
         Missing (fe.missing Ops (map (/. R (hd (hd R))) Rows))
         Complete (if (empty? Missing) true
                      (fe.fail L C (make-string "this handler for ~A has no clause for ~A: a handler gives one clause for each operation of its effect" Effect (fe.listed Missing))))
         Clauses (map (/. R (hd (tl R))) Rows)
      [["handle" Node Effect (map (/. R (hd R)) Rows) (fe.row-node Body)] (fe.row-type Body)
       (fe.union (fe.without Effect (fe.row-effects Body)) (fe.union-rows Clauses))
       (fe.sum (fe.row-uses Body) (fe.sum-rows Clauses))])
  L C D _ _ _ -> (fe.reject D "handle is written (handle Effect ((operation x) -> e) ... body)"))

\\ ---------- declarations ----------

(define fe.kind
  [list _ _ [[sym _ _ K] | _]] -> K where (element? K ["datatype" "effect" "remote-effect" "define" "serve"])
  D -> (fe.reject D "a program is a sequence of (include ...), (datatype ...), (effect ...), (remote-effect ...), (define ...) and (serve ...) forms"))

\\ ---------- include ----------

\\ (include "file") splices the declarations of another file in at that place
\\ (EFFECTS.md section 12.6, owner ruling of 16 November 2026 on question 15:
\\ include, not import). The file is named relative to the directory of the
\\ file the include is written in, with / between components; it may not be
\\ absolute and may not have a component . or .. . An included file may contain
\\ only declarations, (datatype ...), (effect ...) and (remote-effect ...), and
\\ includes of its own. A file that includes itself, directly or through
\\ others, is rejected. Every position inside an included file carries the
\\ file, so a problem there is reported there.

\\ File up to and including its last /, or "".
(define fe.directory
  File -> (fe.directory-of (fe.codes File) [] []))

(define fe.directory-of
  [] _ Kept -> (fe.string-of (reverse Kept))
  [47 | Bs] Word Kept -> (fe.directory-of Bs [] (append [47 | Word] Kept))
  [B | Bs] Word Kept -> (fe.directory-of Bs [B | Word] Kept))

\\ The components of a path, split at /.
(define fe.components
  [] Word Acc -> (reverse [(reverse Word) | Acc])
  [47 | Bs] Word Acc -> (fe.components Bs [] [(reverse Word) | Acc])
  [B | Bs] Word Acc -> (fe.components Bs [B | Word] Acc))

(define fe.include-path
  L C Octets File ->
    (if (and (cons? Octets) (fe.all? (/. B (and (> B 32) (< B 127) (not (= B 92)))) Octets)
             (fe.all? (/. Part (not (element? Part [[] [46] [46 46]]))) (fe.components Octets [] [])))
        (cn (fe.directory File) (fe.string-of Octets))
        (fe.fail L C "an included file is named relative to the directory of this file, with / between components: no absolute path, no . or .. component, no spaces")))

(define fe.retag
  File [list L C Items] -> [list [at-file File L] C (map (/. I (fe.retag File I)) Items)]
  File [brace L C Items] -> [brace [at-file File L] C (map (/. I (fe.retag File I)) Items)]
  File [Kind L C X] -> [Kind [at-file File L] C X])

\\ The data of an included file. A problem the reader finds is reported at that file.
(define fe.read-included
  Path Octets ->
    (map (/. D (fe.retag Path D))
         (trap-error (fe.read Octets)
                     (/. E (let D (value fe.*diagnostic*)
                             (if (= (length D) 3)
                                 (do (set fe.*diagnostic* (append D [Path])) (error "fenrir diagnostic"))
                                 (error (error-to-string E))))))))

\\ Stack: the files being read, innermost first; the program's own file is the last.
(define fe.included
  Path L C Stack ->
    (if (element? Path Stack)
        (fe.fail L C (make-string "include cycle: ~A is already being read (~A)" Path (fe.listed (reverse Stack))))
        (let Octets (trap-error (read-file-as-bytelist Path)
                                (/. E (fe.fail L C (make-string "the included file ~A cannot be read" Path))))
          (fe.expand (map (/. F (fe.declaration-only Path F)) (fe.read-included Path Octets)) Path [Path | Stack]))))

(define fe.declaration-only
  Path [list L C [[sym SL SC K] | Rest]] -> [list L C [[sym SL SC K] | Rest]] where (element? K ["datatype" "effect" "remote-effect" "include"])
  Path D -> (fe.reject D "an included file may contain only declarations: (datatype ...), (effect ...), (remote-effect ...) and (include ...). Functions and (serve ...) belong to a program"))

\\ The forms of File with every include replaced by the declarations it names.
(define fe.expand
  [] _ _ -> []
  [[list L C [[sym _ _ "include"] [str SL SC Octets]]] | Forms] File Stack ->
    (append (fe.included (fe.include-path SL SC Octets File) L C Stack) (fe.expand Forms File Stack))
  [[list L C [[sym _ _ "include"] | _]] | _] _ _ -> (fe.fail L C "include is written (include c#34;file.fenc#34;), the file named relative to the directory of this one")
  [F | Forms] File Stack -> [F | (fe.expand Forms File Stack)])

\\ ---------- the store, and serving ----------

\\ A program that serves a remote effect is a peer's program (EFFECTS.md
\\ section 12.12). It reaches the peer's durable store through two effects that
\\ the peer's runtime provides, of the durable class of section 8: they are not
\\ declared, cannot be declared and cannot be handled.
(define fe.store-effects
  -> [["StoreRead" [["get" "I64" "I64"]]] ["StoreWrite" [["put" ["Tuple" "I64" "I64"] "Unit"]]]])

(define fe.store-effect?
  Name -> (element? Name ["StoreRead" "StoreWrite"]))

\\ (serve Effect ((operation x ...) -> e) ...): one implementation for each
\\ operation of the remote effect. Each becomes a function named
\\ Effect.operation, which no program can call: the peer's runtime runs it once
\\ for each request. An operation op : A --> B that is not read-only is written
\\ ((op key a) -> e), key being the request key the caller performed it with,
\\ and is the function {(Tuple I64 A) --> B}; a read-only one is ((op a) -> e),
\\ the function {A --> B}.
\\ Result: signatures as fe.signature gives them, [Name A B Line Column Parameters Body].
(define fe.serve-clause
  Effect Ops ReadOnly Seen [list L C [[list _ _ [[sym OL OC Op] | Binders]] [sym _ _ "->"] Body]] ->
    (let Declared (fe.binding Op Ops)
         Known (if (= Declared none)
                   (fe.fail OL OC (make-string "effect ~A has no operation ~A: its operations are ~A" Effect Op (fe.listed (fe.keys Ops))))
                   true)
         Once (if (element? Op Seen) (fe.fail L C (make-string "this serve has two implementations of ~A.~A" Effect Op)) true)
         Quiet (element? Op ReadOnly)
         Wanted (if Quiet 1 2)
         Counted (if (= (length Binders) Wanted) true
                     (fe.fail L C (if Quiet
                                      (make-string "~A.~A is read-only and has no request key: its implementation is written ((~A argument) -> e)" Effect Op Op)
                                      (make-string "~A.~A is not read-only, so its implementation takes the request key and then the argument: ((~A key argument) -> e)" Effect Op Op))))
      [(cn Effect (cn "." Op)) (if Quiet (nth 2 Declared) ["Tuple" "I64" (nth 2 Declared)]) (nth 3 Declared) L C Binders Body Effect Op Quiet])
  _ _ _ _ D -> (fe.reject D "an implementation is written ((operation key argument) -> e), or ((operation argument) -> e) for a read-only operation"))

(define fe.serve-clauses
  _ _ _ [] Acc -> (reverse Acc)
  Effect Ops ReadOnly [Clause | Clauses] Acc ->
    (fe.serve-clauses Effect Ops ReadOnly Clauses [(fe.serve-clause Effect Ops ReadOnly (map (/. S (nth 9 S)) Acc) Clause) | Acc]))

(define fe.serve
  [list L C [_ [sym EL EC Effect] Clause | Clauses]] ->
    (let Ops (fe.lookup Effect (value fe.*effects*))
         Known (if (= Ops none) (fe.fail EL EC (make-string "unknown effect ~A" Effect)) true)
         ReadOnly (fe.lookup Effect (value fe.*remote*))
         Far (if (= ReadOnly none)
                 (fe.fail EL EC (make-string "~A is not a remote effect: serve gives the implementations of the operations of a remote-effect, for other members to perform; an ordinary effect is handled with (handle ~A ...)" Effect Effect))
                 true)
         Rows (fe.serve-clauses Effect Ops ReadOnly [Clause | Clauses] [])
         Missing (fe.missing Ops (map (/. S (nth 9 S)) Rows))
         Complete (if (empty? Missing) true
                      (fe.fail L C (make-string "this serve of ~A has no implementation of ~A: a program that serves an effect implements each of its operations" Effect (fe.listed Missing))))
      Rows)
  D -> (fe.reject D "serve is written (serve Effect ((operation key argument) -> e) ... ), with ((operation argument) -> e) for a read-only operation"))

\\ The signatures of every function of the program, in source order: each
\\ define, and each implementation of each serve.
(define fe.signatures
  [] -> []
  [F | Forms] -> (let K (fe.kind F)
                   (if (= K "define")
                       [(fe.signature F) | (fe.signatures Forms)]
                       (if (= K "serve")
                           (append (fe.serve F) (fe.signatures Forms))
                           (fe.signatures Forms)))))

(define fe.served-twice
  [] _ -> true
  [[list _ _ [_ [sym L C Effect] | _]] | Forms] Seen ->
    (if (element? Effect Seen)
        (fe.fail L C (make-string "effect ~A is served twice: one (serve ~A ...) holds all its implementations" Effect Effect))
        (fe.served-twice Forms [Effect | Seen]))
  [_ | Forms] Seen -> (fe.served-twice Forms Seen))

\\ What a served operation's implementation may leave unhandled: Emit and the
\\ store. A read-only operation may not write (EFFECTS.md section 12.3; owner
\\ ruling of 16 November 2026 on section 12.10 question 13: the type checker
\\ vouches for read-only): StoreWrite may not be among its effects, whether it
\\ comes from a perform, a call or an application.
(define fe.check-served
  _ _ [] -> true
  Served Quiet [["Emit" | _] | Rest] -> (fe.check-served Served Quiet Rest)
  Served Quiet [["StoreRead" | _] | Rest] -> (fe.check-served Served Quiet Rest)
  Served false [["StoreWrite" | _] | Rest] -> (fe.check-served Served false Rest)
  Served true [["StoreWrite" L C Cause] | _] ->
    (fe.fail L C (make-string "~A is declared read-only, but its implementation can write the store: effect StoreWrite comes from ~A. A read-only operation changes nothing the peer keeps" Served Cause))
  Served _ [[Name L C Cause] | _] ->
    (fe.fail L C (make-string "effect ~A is not handled: it comes from ~A, and no (handle ~A ...) encloses that on the way from the served operation ~A" Name Cause Name Served)))

(define fe.check-serving
  [] [] -> true
  [["main" _ _ L C | _] | _] _ ->
    (fe.fail L C "a program that serves has no main: it does not run from an entry, it runs one implementation for each request")
  [[Name _ _ _ _ _ _ Effect Op Quiet] | Fs] [[_ Effects] | Rs] -> (do (fe.check-served Name Quiet Effects) (fe.check-serving Fs Rs))
  [_ | Fs] [_ | Rs] -> (fe.check-serving Fs Rs))

\\ The artifact's record of what is served: for each served effect, the function
\\ of each operation, in the order of the effect's declaration.
(define fe.serves-object
  Functions [Effect Ops] ->
    [object ["effect" Effect]
            ["operations" (map (/. O [object ["function" (cn Effect (cn "." (hd O)))] ["name" (hd O)]]) Ops)]])

(define fe.served-effects
  [] Acc -> (reverse Acc)
  [[_ _ _ _ _ _ _ Effect _ _] | Fs] Acc -> (fe.served-effects Fs (if (element? Effect Acc) Acc [Effect | Acc]))
  [_ | Fs] Acc -> (fe.served-effects Fs Acc))

(define fe.of-kind
  _ [] -> []
  K [F | Fs] -> (if (= (fe.kind F) K) [F | (fe.of-kind K Fs)] (fe.of-kind K Fs)))

\\ Effect declarations of both classes, in source order.
(define fe.effect-forms
  [] -> []
  [F | Fs] -> (if (element? (fe.kind F) ["effect" "remote-effect"]) [F | (fe.effect-forms Fs)] (fe.effect-forms Fs)))

\\ The declared name of each form, checked, with no name twice.
(define fe.declared
  _ _ [] Seen -> (reverse Seen)
  What Check [[list _ _ [_ [sym L C Name] | _]] | Forms] Seen ->
    (let Checked (Check [sym L C Name])
      (if (element? Name Seen)
          (fe.fail L C (make-string "~A ~A is declared twice" What Name))
          (fe.declared What Check Forms [Name | Seen])))
  What _ [F | _] _ -> (fe.reject F (make-string "this ~A declaration has no name" What)))

(define fe.declared-name
  [list _ _ [_ [sym _ _ Name] | _]] -> Name)

(define fe.datatype-name
  [sym L C Name] -> (fe.fail L C (make-string "~A is a built-in type and cannot be declared" Name))
    where (element? Name ["Unit" "Bool" "I64" "Bytes" "TrapCode"])
  D -> (fe.check-capital "datatype" D))

(define fe.user-effect-name
  [sym L C Name] -> (fe.fail L C (make-string "~A is a reserved runtime effect and cannot be declared" Name))
    where (element? Name ["Emit" "Task" "Channel" "Time" "Resource"])
  [sym L C Name] -> (fe.fail L C (make-string "~A is the peer's store, which the runtime provides to a program that serves, and cannot be declared there" Name))
    where (and (value fe.*serving*) (fe.store-effect? Name))
  D -> (fe.check-capital "effect" D))

\\ Constructor names are unique across the whole program, TrapCode's included:
\\ a constructor is written without its datatype, so its name must identify it.
\\ Owners is [[Constructor Datatype] ...] for everything declared so far.
(define fe.constructor
  Type Owners [sym L C Name] -> (fe.constructor Type Owners [list L C [[sym L C Name]]])
  Type Owners [list _ _ [[sym L C Name] | Fields]] ->
    (let Checked (fe.check-capital "constructor" [sym L C Name])
         Owner (fe.lookup Name Owners)
      (if (= Owner none)
          (if (< (length Fields) 9)
              [Name (map (/. F (fe.type F)) Fields)]
              (fe.fail L C (make-string "constructor ~A has more than 8 fields" Name)))
          (fe.fail L C (make-string "constructor ~A is already declared by ~A: constructor names must be unique in a program" Name Owner))))
  _ _ D -> (fe.reject D "a constructor is written Name, or (Name FieldType ...) when it has fields"))

(define fe.constructors
  _ [] _ Acc -> (reverse Acc)
  Type [D | Ds] Owners Acc -> (let Constructor (fe.constructor Type Owners D)
                                (fe.constructors Type Ds [[(hd Constructor) Type] | Owners] [Constructor | Acc])))

(define fe.owners
  [] -> []
  [[Type Constructors] | Rest] -> (append (map (/. K [(hd K) Type]) Constructors) (fe.owners Rest)))

\\ Tables is the datatype table so far, most recent first.
(define fe.datatypes
  [] Tables -> (reverse Tables)
  [[list L C [_ [sym _ _ Name] | Constructors]] | Forms] Tables ->
    (if (and (> (length Constructors) 0) (< (length Constructors) 17))
        (fe.datatypes Forms [[Name (fe.constructors Name Constructors (fe.owners Tables) [])] | Tables])
        (fe.fail L C (make-string "datatype ~A must declare 1 to 16 constructors" Name))))

(define fe.operation-declaration
  Effect _ [list L C [[sym _ _ "read-only"] | _]] ->
    (fe.fail L C (make-string "read-only marks an operation of a remote-effect, and ~A is an ordinary effect" Effect))
    where (= (fe.lookup Effect (value fe.*remote*)) none)
  Effect Seen [list _ _ [[sym L C Op] A [sym _ _ "-->"] B]] ->
    (let Named (if (fe.operation-name? Op) true
                   (fe.fail L C (make-string "~A is not a valid operation name: it must start with a lowercase letter or _ and continue with letters, digits or _" Op)))
         Once (if (element? Op Seen) (fe.fail L C (make-string "effect ~A declares operation ~A twice" Effect Op)) true)
      [Op (fe.serializable A "argument" Effect Op) (fe.serializable B "result" Effect Op)])
  Effect _ D -> (fe.reject D (if (= (fe.lookup Effect (value fe.*remote*)) none)
                                 "an operation is written (name ArgumentType --> ResultType)"
                                 "an operation of a remote-effect is written (name ArgumentType --> ResultType), or (read-only name ArgumentType --> ResultType) when it changes nothing")))

\\ An operation of a remote effect: [Declaration ReadOnly?].
(define fe.remote-operation
  Effect Seen [list L C [[sym _ _ "read-only"] Op | Rest]] -> [(fe.operation-declaration Effect Seen [list L C [Op | Rest]]) true]
  Effect Seen D -> [(fe.operation-declaration Effect Seen D) false])

(define fe.remote-operations
  _ [] Acc -> (reverse Acc)
  Effect [D | Ds] Acc -> (fe.remote-operations Effect Ds [(fe.remote-operation Effect (map (/. O (hd (hd O))) Acc) D) | Acc]))

(define fe.serializable
  D Role Effect Op -> (let T (fe.type D)
                        (if (fe.plain? T []) T
                            (fe.reject D (make-string "the ~A type of ~A.~A must be serializable, but ~A contains a function" Role Effect Op (fe.show-type T))))))

(define fe.operations
  _ [] Acc -> (reverse Acc)
  Effect [D | Ds] Acc -> (fe.operations Effect Ds [(fe.operation-declaration Effect (fe.keys Acc) D) | Acc]))

\\ [Name Operations Class ReadOnlyOperationNames].
(define fe.effect
  [list L C [[sym _ _ Kind] [sym _ _ Name] | Operations]] ->
    (if (and (> (length Operations) 0) (< (length Operations) 9))
        (if (= Kind "effect")
            [Name (fe.operations Name Operations []) "ordinary" []]
            (let Ops (fe.remote-operations Name Operations [])
              [Name (map (/. O (hd O)) Ops) "remote" (map (/. O (hd (hd O))) (fe.keep-if (/. O (hd (tl O))) Ops))]))
        (fe.fail L C (make-string "effect ~A must declare 1 to 8 operations" Name))))

(define fe.keep-if
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (fe.keep-if F Xs)] (fe.keep-if F Xs)))

\\ (define name {A --> B} parameter ... -> body): [Name A B Line Column Parameters Body].
(define fe.parameters
  [[sym _ _ "->"] Body] Acc -> [(reverse Acc) Body]
  [[sym L C "->"] | _] _ -> (fe.fail L C "a define has exactly one body expression after ->")
  [[sym L C Name] | Rest] Acc -> (fe.parameters Rest [[sym L C Name] | Acc])
  _ _ -> none)

(define fe.signature
  [list L C [_ Name [brace _ _ [A [sym _ _ "-->"] B]] | Rest]] ->
    (let Split (fe.parameters Rest [])
      (if (or (= Split none) (empty? (hd Split)))
          (fe.fail L C "a function is written (define name {ArgumentType --> ResultType} parameter -> body)")
          [(fe.check-value-name "function" Name) (fe.type A) (fe.type B) L C (hd Split) (hd (tl Split))]))
  D -> (fe.reject D "a function is written (define name {ArgumentType --> ResultType} parameter -> body)"))

\\ Several parameters name the components of a tuple argument.
(define fe.check-parameters
  [Name A _ L C Parameters _ | _] ->
    (let Distinct (fe.distinct Parameters [])
         N (length Parameters)
      (if (or (= N 1) (and (cons? A) (= (hd A) "Tuple") (= (length (tl A)) N)))
          true
          (fe.fail L C (make-string "~A has ~A parameters, so its argument type must be a Tuple of ~A types, but it is ~A" Name N N (fe.show-type A))))))

\\ ---------- functions ----------

\\ let x = project(p, I) in ... for each parameter of a several-parameter
\\ function, then the body. P is the function's one real parameter.
(define fe.destructure
  [] _ _ _ Env Body Want -> (fe.expr Body Env Want)
  [X | Xs] P [T | Ts] I Env Body Want ->
    (let L (fe.line X)
         C (fe.column X)
         Node (fe.node L C)
         Id (fe.fresh)
         Project (fe.node L C)
         Variable (fe.node L C)
         Row (fe.destructure Xs P Ts (+ I 1) (fe.bind X Id T Env) Body Want)
      [["let" Node Id ["project" Project ["var" Variable P] (str I)] (fe.row-node Row)]
       (fe.row-type Row) (fe.row-effects Row) (fe.row-uses Row)]))

\\ [FunctionObject Effects], the effects being what the body may perform.
(define fe.function
  [Name A B L C Parameters Body | _] ->
    (let Id (fe.node L C)
         P (fe.fresh)
         Want [want B (cn "the body of " Name) " (its declared result type)"]
         Row (if (= (length Parameters) 1)
                 (fe.expr Body (fe.bind (hd Parameters) P A []) Want)
                 (fe.destructure Parameters P (tl A) 0 [] Body Want))
      [[object ["argument_type" A] ["body" (fe.row-node Row)]
               ["effects" (fe.sort-names (fe.keys (fe.lookup Name (value fe.*table*))))]
               ["id" Id] ["name" Name] ["parameter_id" P] ["result_type" B]]
       (fe.row-effects Row)]))

\\ One pass over every function, in source order, against the current table:
\\ [[FunctionObject Effects] ...].
(define fe.pass
  [] -> []
  [F | Fs] -> (let Result (fe.function F)
                [Result | (fe.pass Fs)]))

\\ While effect sets are being computed a function that cannot be elaborated
\\ keeps its estimate; the strict pass afterwards reports what is wrong with it.
(define fe.estimate
  [] -> []
  [F | Fs] -> (let Old (fe.lookup (hd F) (value fe.*table*))
                   New (trap-error (hd (tl (fe.function F))) (/. E Old))
                [[(hd F) New] | (fe.estimate Fs)]))

(define fe.same-sets?
  [] [] -> true
  [[_ Es] | As] [[_ Fs] | Bs] -> (and (= (fe.sort-names (fe.keys Es)) (fe.sort-names (fe.keys Fs))) (fe.same-sets? As Bs)))

\\ Least fixed point of the functions' effect sets: start from empty sets and
\\ re-elaborate until nothing changes. A pass can only add effects and there are
\\ finitely many, so this ends. Recursive and mutually recursive functions get
\\ exactly the effects their bodies can reach.
(define fe.fixed-point
  Functions -> (let New (fe.estimate Functions)
                 (if (fe.same-sets? New (value fe.*table*))
                     true
                     (do (set fe.*table* New) (fe.fixed-point Functions)))))

\\ ---------- the program ----------

(define fe.check-entry
  Functions Results ->
    (let Main (fe.binding "main" Functions)
         Present (if (= Main none)
                     (fe.fail 1 1 "the program has no entry function: define main, written (define main {I64 --> ResultType} input -> body)")
                     true)
         L (nth 4 Main)
         C (nth 5 Main)
         Input (if (= (nth 2 Main) "I64") true
                   (fe.fail L C (make-string "the entry function main must take I64 (it is run with input 0), but it takes ~A" (fe.show-type (nth 2 Main)))))
         Output (if (fe.plain? (nth 3 Main) []) true
                    (fe.fail L C (make-string "the entry function main must return a serializable value, but its result type ~A contains a function" (fe.show-type (nth 3 Main)))))
      (fe.check-handled (fe.entry-effects Functions Results))))

(define fe.entry-effects
  [["main" | _] | _] [[_ Effects] | _] -> Effects
  [_ | Fs] [_ | Rs] -> (fe.entry-effects Fs Rs))

\\ Only Emit and remote effects may remain at the entry: every ordinary effect is
\\ handled inside the program, and a remote effect is discharged by the system.
(define fe.check-handled
  [] -> true
  [["Emit" | _] | Rest] -> (fe.check-handled Rest)
  [[Name | _] | Rest] -> (fe.check-handled Rest) where (not (= (fe.lookup Name (value fe.*remote*)) none))
  [[Name L C Cause] | _] ->
    (fe.fail L C (make-string "effect ~A is not handled: it comes from ~A, and no (handle ~A ...) encloses that on the way from the entry function main" Name Cause Name)))

(define fe.source-map
  File [] Acc -> Acc
  File [[Id L C] | Rest] Acc ->
    (fe.source-map File Rest [[object ["column" (str C)] ["file" File] ["id" Id] ["line" (str L)]] | Acc]))

(define fe.datatype-object
  [Name Constructors] -> [object ["constructors" (map (/. K [object ["fields" (hd (tl K))] ["name" (hd K)]]) Constructors)] ["name" Name]])

\\ Schema /2: a name and operations. Schema /3 (Remote true): the class as well,
\\ and read_only on each operation of a remote effect.
(define fe.effect-object
  false [Name Ops _ _] -> [object ["name" Name]
                                  ["operations" (map (/. O [object ["argument_type" (nth 2 O)] ["name" (hd O)] ["result_type" (nth 3 O)]]) Ops)]]
  true [Name Ops "ordinary" _] -> [object ["class" "ordinary"] ["name" Name]
                                          ["operations" (map (/. O [object ["argument_type" (nth 2 O)] ["name" (hd O)] ["result_type" (nth 3 O)]]) Ops)]]
  true [Name Ops "remote" ReadOnly] ->
    [object ["class" "remote"] ["name" Name]
            ["operations" (map (/. O [object ["argument_type" (nth 2 O)] ["name" (hd O)] ["read_only" (element? (hd O) ReadOnly)] ["result_type" (nth 3 O)]]) Ops)]])

(define fe.limit
  Forms What Max -> (if (> (length Forms) Max)
                        (fe.reject (nth (+ Max 1) Forms) (make-string "a program declares at most ~A ~A" Max What))
                        true))

\\ File names the source in the source map; Module is the artifact's module
\\ name; Octets are the source. Returns the artifact.
(define fe.elaborate
  File Module Octets ->
    (let Forms (fe.expand (fe.read Octets) File [File])
         Serving (set fe.*serving* (cons? (fe.of-kind "serve" Forms)))
         DatatypeForms (fe.of-kind "datatype" Forms)
         EffectForms (fe.effect-forms Forms)
         RemoteForms (fe.of-kind "remote-effect" Forms)
         FunctionForms (fe.of-kind "define" Forms)
         Limits [(fe.limit DatatypeForms "datatypes" 16) (fe.limit EffectForms "effects" 8) (fe.limit FunctionForms "functions" 32)]
         \\ Names first, so that declarations may refer to each other in any order.
         Reset (set fe.*datatypes* [["TrapCode" (map (/. K [K []]) ["Overflow" "DivZero" "Bounds" "InvalidDuration" "TaskLimit" "ChildFailed"])]])
         Names (set fe.*datatype-names* (fe.declared "datatype" (/. D (fe.datatype-name D)) DatatypeForms []))
         EffectNames (set fe.*effects* (map (/. N [N []]) (fe.declared "effect" (/. D (fe.user-effect-name D)) EffectForms [])))
         RemoteNames (set fe.*remote* (map (/. F [(fe.declared-name F) []]) RemoteForms))
         Datatypes (fe.datatypes DatatypeForms (value fe.*datatypes*))
         SetDatatypes (set fe.*datatypes* Datatypes)
         Declared (map (/. F (fe.effect F)) EffectForms)
         Effects (set fe.*effects* (map (/. E [(hd E) (hd (tl E))]) Declared))
         Remote (set fe.*remote* (map (/. E [(hd E) (nth 4 E)]) (fe.keep-if (/. E (= (nth 3 E) "remote")) Declared)))
         Far (cons? Remote)
         Clash (map (/. F (if (and Far (= (fe.declared-name F) "RemoteResult"))
                              (fe.reject F "RemoteResult names the outcomes of a remote perform and cannot be declared in a program that has a remote-effect")
                              true))
                    DatatypeForms)
         Store (if Serving (set fe.*effects* (append Effects (fe.store-effects))) Effects)
         Once (fe.served-twice (fe.of-kind "serve" Forms) [])
         Functions (fe.signatures Forms)
         Unique (fe.declared "function" (/. D true) FunctionForms [])
         Parameters (map (/. F (fe.check-parameters F)) Functions)
         \\ Only a define can be called: an implementation of a served operation is run by the peer's runtime.
         SetFunctions (set fe.*functions* (map (/. F [(hd F) [(nth 2 F) (nth 3 F)]]) (fe.keep-if (/. F (= (length F) 7)) Functions)))
         \\ Effect sets, then the pass that produces the artifact.
         Start (do (set fe.*strict* false) (set fe.*table* (map (/. F [(hd F) []]) Functions)))
         Settled (fe.fixed-point Functions)
         Strict (do (set fe.*strict* true) (set fe.*next* 0) (set fe.*locations* []))
         Results (fe.pass Functions)
         Entry (if Serving (fe.check-serving Functions Results) (fe.check-entry Functions Results))
      (if Serving
          [object ["contract_version" "tc1-draft-1"]
                  ["datatypes" (map (/. D (fe.datatype-object D)) (tl Datatypes))]
                  ["effects" (map (/. E (fe.effect-object Far E)) Declared)]
                  ["functions" (map (/. R (hd R)) Results)]
                  ["module" Module]
                  ["schema_version" "tc1-handler-demo/4"]
                  ["serves" (map (/. Name (fe.serves-object Functions [Name (fe.lookup Name Effects)])) (fe.served-effects Functions []))]
                  ["slice" "TC1-P1"]
                  ["source_map" (fe.source-map File (value fe.*locations*) [])]]
      [object ["contract_version" "tc1-draft-1"]
              ["datatypes" (map (/. D (fe.datatype-object D)) (tl Datatypes))]
              ["effects" (map (/. E (fe.effect-object Far E)) Declared)]
              ["entry" "main"]
              ["functions" (map (/. R (hd R)) Results)]
              ["input_schema" [object ["type" "I64"]]]
              ["module" Module]
              ["schema_version" (if Far "tc1-handler-demo/3" "tc1-handler-demo/2")]
              ["slice" (if Far "TC1-R1" "TC1-H2")]
              ["source_map" (fe.source-map File (value fe.*locations*) [])]])))
