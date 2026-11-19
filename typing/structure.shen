\\ Fenrir typing: the structural checks of spec/tc1/TYPING.md §2, in Shen. These are
\\ the conditions the artifact validator (tools/tc0/pure-call-artifact.mjs) enforces
\\ that are not typing judgments: transport, the closed shape of every object and
\\ expression, the identity fields, declaration tables, globally unique IDs, the
\\ source map, and the validator's size and work caps.
\\
\\   (st.check Text)  [ok A]                     A decoded, object members in key order
\\                    [invalid Check Message]    a structural check failed
\\                    [limit Check Message]      a cap: not a judgement of the program
\\
\\ Needs harness/common.shen (Shen/JIT JSON, fh.canon). The caps are the validator's
\\ defaults: 200 expression nodes, depth 64, 256 octets per bytes value, 1000 value
\\ nodes, type depth 16; transport 1 MiB, JSON depth 128, 100000 JSON values.

(set st.*ids* [])
(set st.*locations* [])
(set st.*nodes* 0)
(set st.*values* 0)
(set st.*schema* "")

(define st.fail
  Check Message -> (simple-error (cn "st:invalid " (cn Check (cn " " Message)))))

(define st.cap
  Check Message -> (simple-error (cn "st:limit " (cn Check (cn " " Message)))))

(define st.check
  Text -> (trap-error (st.schema-check (st.transport Text)) (/. E (st.verdict (error-to-string E)))))

(define st.verdict
  (@s "st:invalid " Rest) -> [invalid (st.word Rest) (st.after-word Rest)]
  (@s "st:limit " Rest) -> [limit (st.word Rest) (st.after-word Rest)]
  Message -> [invalid "S-Transport" Message])

(define st.word
  (@s " " _) -> ""
  (@s C S) -> (cn C (st.word S))
  "" -> "")

(define st.after-word
  (@s " " S) -> S
  (@s _ S) -> (st.after-word S)
  "" -> "")

\\ ---------- S-Transport ----------

(define st.transport
  Text -> (let Reset (set st.*values* 0)
               A (trap-error (json.parse Text [[byte-limit 1048576] [depth-limit 129]])
                             (/. E (st.transport-error (error-to-string E))))
               Shape (st.json A 0)
            (fh.canon A)))

(define st.transport-error
  Message -> (st.cap "L-Encoding" Message) where (st.contains? "limit" Message)
  Message -> (st.fail "S-Transport" Message))

(define st.contains?
  _ "" -> false
  Word S -> true where (fh.starts? Word S)
  Word (@s _ S) -> (st.contains? Word S))

\\ No numeric token, object keys [A-Za-z_][A-Za-z0-9_]*, JSON depth and size.
(define st.json
  _ Depth -> (st.cap "L-Encoding" "Work/depth limit") where (> Depth 128)
  [number _] _ -> (st.fail "S-Transport" "Numeric token")
  [object | Ms] Depth -> (st.members Ms Depth)
  [X | Xs] Depth -> (do (st.value-count) (st.json X (+ Depth 1)) (st.json-list Xs Depth))
  _ _ -> (st.value-count))

(define st.json-list
  [X | Xs] Depth -> (do (st.json X (+ Depth 1)) (st.json-list Xs Depth))
  _ _ -> true)

(define st.members
  [] _ -> (st.value-count)
  [[K V] | Ms] Depth -> (if (st.key? K) (do (st.json V (+ Depth 1)) (st.members Ms Depth)) (st.fail "S-Transport" "Invalid object key"))
  _ _ -> (st.fail "S-Transport" "Object"))

(define st.value-count
  -> (do (set st.*values* (+ (value st.*values*) 1))
         (if (> (value st.*values*) 100000) (st.cap "L-Encoding" "Work/depth limit") true)))

(define st.key?
  (@s C S) -> (and (st.letter? C) (fh.all-members? (explode S) (explode "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789")))
  _ -> false)

(define st.letter?
  C -> (element? C (explode "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")))

\\ ---------- S-Shape: closed objects, field kinds ----------

(define st.object
  [object | Ms] Keys -> (if (= (map (/. M (hd M)) Ms) Keys) (map (/. M (hd (tl M))) Ms) (st.fail "S-Shape" "Closed object fields"))
  _ _ -> (st.fail "S-Shape" "Closed object fields"))

(define st.array
  [object | _] -> (st.fail "S-Shape" "Array required")
  X -> X where (or (= X []) (cons? X))
  _ -> (st.fail "S-Shape" "Array required"))

\\ An effect set's shape: an array of strings. What it names is a typing matter.
(define st.effect-set
  Ef -> (map (/. E (st.text E)) (st.array Ef)))

(define st.text
  X -> X where (string? X)
  _ -> (st.fail "S-Shape" "String required"))

(define st.unsigned
  "0" -> "0"
  (@s D S) -> (@s D S) where (and (tc.among? D "123456789") (tc.every? (/. C (tc.among? C "0123456789")) (explode S)))
  _ -> (st.fail "S-Shape" "Unsigned ID"))

(define st.identifier
  X -> X where (and (st.key? X) (<= (length (explode X)) 64))
  _ -> (st.fail "S-Shape" "Identifier"))

\\ A fresh ID: unsigned and not used anywhere else in the artifact.
(define st.fresh
  Id Location -> (do (st.unsigned Id)
                     (if (element? Id (value st.*ids*)) (st.fail "S-Unique-IDs" "Duplicate ID") (set st.*ids* [Id | (value st.*ids*)]))
                     (if Location (set st.*locations* [Id | (value st.*locations*)]) true)))

(define st.count
  Max Check Message L -> (if (> (length L) Max) (st.fail Check Message) L))

\\ ---------- the artifact ----------

(define st.data? -> (element? (value st.*schema*) ["tc0-a-pure-call-demo/2" "tc1-handler-demo/1" "tc1-handler-demo/2" "tc1-durable-demo/1"]))
(define st.handlers? -> (or (st.resumptions?) (= (value st.*schema*) "tc1-handler-demo/1")))
(define st.resumptions? -> (or (st.durable?) (= (value st.*schema*) "tc1-handler-demo/2")))
(define st.durable? -> (= (value st.*schema*) "tc1-durable-demo/1"))

\\ Do not try an H2 structure or typing rule on a remote, serving, task or
\\ unknown schema. Use an explicit verdict distinct from invalid/limit.
(define st.schema-check
  A -> (let Schema (st.text (fh.member "schema_version" A))
         (if (= (tc.identity Schema) none) [unsupported Schema] (st.artifact A))))

(define st.artifact
  A -> (let Reset (do (set st.*ids* []) (set st.*locations* []) (set st.*nodes* 0) (set st.*values* 0))
            Fields (st.object A ["contract_version" "datatypes" "effects" "entry" "functions" "input_schema" "module" "schema_version" "slice" "source_map"])
            Identity (st.identity A)
            Module (st.text (tc.f "module" A))
            Datatypes (st.datatypes (st.array (tc.f "datatypes" A)))
            Effects (st.effects (st.array (tc.f "effects" A)))
            Functions (st.functions (st.array (tc.f "functions" A)))
            Input (st.object (tc.f "input_schema" A) ["type"])
            Bodies (map (/. F (st.expr (tc.f "body" F) 0)) (tc.f "functions" A))
            Map (st.source-map (st.array (tc.f "source_map" A)))
         [ok A]))

\\ S-Identity: contract, schema and slice name one supported identity.
(define st.identity
  A -> (if (tc.identity? A) (set st.*schema* (tc.schema A)) (st.fail "S-Identity" "Identity")))

\\ S-Declarations: datatype, effect and function tables.
(define st.datatypes
  Ds -> (st.fail "S-Features" "Declarations unsupported") where (and (cons? Ds) (not (st.data?)))
  Ds -> (do (st.count 16 "S-Declarations" "Datatype count" Ds) (st.datatypes-in Ds [])))

(define st.datatypes-in
  [] _ -> true
  [D | Ds] Seen ->
    (let Fields (st.object D ["constructors" "name"])
         Name (st.identifier (tc.f "name" D))
         Unique (if (or (element? Name ["Unit" "Bool" "I64" "Bytes" "TrapCode"]) (element? Name Seen)) (st.fail "S-Declarations" "Datatype name") true)
         Cs (st.array (tc.f "constructors" D))
         Count (if (or (= Cs []) (> (length Cs) 16)) (st.fail "S-Declarations" "Constructor count") true)
         Ctors (st.constructors Cs [])
      (st.datatypes-in Ds [Name | Seen])))

(define st.constructors
  [] _ -> true
  [C | Cs] Seen ->
    (let Fields (st.object C ["fields" "name"])
         Name (st.identifier (tc.f "name" C))
         Unique (if (element? Name Seen) (st.fail "S-Declarations" "Duplicate constructor") true)
         Types (st.count 8 "S-Declarations" "Field count" (st.array (tc.f "fields" C)))
         Depth (map (/. T (st.type-depth T 0)) Types)
      (st.constructors Cs [Name | Seen])))

(define st.effects
  Es -> (st.fail "S-Features" "Effect declarations unsupported") where (and (cons? Es) (not (st.handlers?)))
  Es -> (do (st.count 8 "S-Declarations" "Effect count" Es) (st.effects-in Es [])))

(define st.effects-in
  [] _ -> true
  [E | Es] Seen ->
    (let Fields (st.object E (if (st.durable?) ["class" "name" "operations"] ["name" "operations"]))
         Name (st.identifier (tc.f "name" E))
         Class (if (and (st.durable?) (not (element? (tc.f "class" E) ["ordinary" "durable"])))
                   (st.fail "S-Declarations" "Effect class") true)
         Unique (if (or (element? Name ["Emit" "Task" "Channel" "Time" "Resource"]) (element? Name Seen)) (st.fail "S-Declarations" "Effect name") true)
         Os (st.array (tc.f "operations" E))
         Count (if (or (= Os []) (> (length Os) 8)) (st.fail "S-Declarations" "Operation count") true)
         Ops (st.operations Os [])
      (st.effects-in Es [Name | Seen])))

(define st.operations
  [] _ -> true
  [O | Os] Seen ->
    (let Fields (st.object O ["argument_type" "name" "result_type"])
         Name (st.identifier (tc.f "name" O))
         Unique (if (element? Name Seen) (st.fail "S-Declarations" "Duplicate operation") true)
         Depth (map (/. T (st.type-depth T 0)) [(tc.f "argument_type" O) (tc.f "result_type" O)])
      (st.operations Os [Name | Seen])))

(define st.functions
  Fs -> (st.fail "S-Declarations" "Function count") where (or (= Fs []) (> (length Fs) 32))
  Fs -> (st.functions-in Fs []))

(define st.functions-in
  [] _ -> true
  [F | Fs] Seen ->
    (let Fields (st.object F ["argument_type" "body" "effects" "id" "name" "parameter_id" "result_type"])
         Id (st.fresh (tc.f "id" F) true)
         Parameter (st.fresh (tc.f "parameter_id" F) false)
         Name (st.text (tc.f "name" F))
         Unique (if (element? Name Seen) (st.fail "S-Declarations" "Duplicate function name") true)
         Depth (map (/. T (st.type-depth T 0)) [(tc.f "argument_type" F) (tc.f "result_type" F)])
         Effects (st.effect-set (tc.f "effects" F))
      (st.functions-in Fs [Name | Seen])))

\\ L-Type-Depth: the validator stops at type nesting 16 (Arrow, and Tuple with data).
(define st.type-depth
  _ Depth -> (st.cap "L-Type-Depth" "Type depth") where (> Depth 16)
  ["Arrow" A B Ef] Depth -> (do (st.type-depth A (+ Depth 1)) (st.type-depth B (+ Depth 1)) (st.effect-set Ef))
  ["Tuple" | Ts] Depth -> (map (/. T (st.type-depth T (+ Depth 1))) Ts) where (st.data?)
  _ _ -> true)

\\ ---------- expressions: S-Shape, S-Unique-IDs, L-Nodes, L-Depth ----------

(define st.arity
  Xs N -> (if (= (length Xs) N) true (st.fail "S-Shape" "Arity")))

(define st.exprs
  Es Depth -> (map (/. E (st.expr E Depth)) Es))

(define st.literal
  -> (do (set st.*values* (+ (value st.*values*) 1))
          (if (> (value st.*values*) 1000) (st.cap "L-Values" "Value cap") true)))

\\ The caller supplies the value, not an AST. Count it together with literal
\\ nodes already visited; tc.entry? then checks its type against the entry.
(define st.with-input
  [ok A] V -> (trap-error (do (st.input-value V 0) [ok A]) (/. E (st.verdict (error-to-string E))))
  Verdict _ -> Verdict)

(define st.input-value
  V Depth -> (do (if (> Depth 64) (st.cap "L-Values" "Value cap") true)
                 (st.literal)
                 (st.input-fields V Depth)))

(define st.input-fields
  ["bytes" H] _ -> (st.bytes-cap H)
  ["tuple" | Vs] D -> (map (/. V (st.input-value V (+ D 1))) Vs)
  ["data" _ _ | Vs] D -> (map (/. V (st.input-value V (+ D 1))) Vs)
  _ _ -> true)

(define st.expr
  E Depth ->
    (do (set st.*nodes* (+ (value st.*nodes*) 1))
        (if (or (> (value st.*nodes*) 200) (> Depth 64)) (st.cap "L-Nodes" "AST cap") true)
        (if (and (cons? E) (cons? (tl E))) true (st.fail "S-Shape" "Expression"))
        (st.fresh (hd (tl E)) true)
        (st.form (hd E) (tl (tl E)) (+ Depth 1))))

(define st.form
  Tag X _ -> (st.fail "S-Shape" "Unsupported tag") where (and (element? Tag ["bytes" "tuple" "project" "construct" "match"]) (not (st.data?)))
  "unit" X _ -> (do (st.arity X 0) (st.literal))
  "bool" X _ -> (do (st.arity X 1) (st.literal))
  "int" X _ -> (do (st.arity X 1) (st.literal))
  "bytes" X _ -> (do (st.arity X 1) (st.literal) (st.bytes-cap (hd X)))
  "var" X _ -> (do (st.arity X 1) (st.unsigned (hd X)))
  "let" [B E1 E2] D -> (do (st.fresh B false) (st.exprs [E1 E2] D))
  "if" [C E1 E2] D -> (st.exprs [C E1 E2] D)
  "prim" [Op | Es] D -> (do (st.primitive Op Es) (st.exprs Es D))
  "tuple" Es D -> (if (tc.between? 1 8 (length Es)) (st.exprs Es D) (st.fail "S-Shape" "Tuple arity"))
  "project" [E I] D -> (do (st.unsigned I) (st.expr E D))
  "construct" [Name C | Es] D -> (do (st.text Name) (st.text C) (st.exprs Es D))
  "match" [E | Arms] D -> (do (st.expr E D) (map (/. Arm (st.arm Arm D)) Arms)) where (cons? Arms)
  "emit" [L E] D -> (do (st.text L) (st.expr E D))
  "lambda" [B Ta Tr Ef Caps Body] D ->
    (do (st.fresh B false) (st.type-depth Ta 0) (st.type-depth Tr 0) (st.effect-set Ef)
        (if (= (st.array Caps) []) true (st.fail "S-Shape" "Empty capture support required"))
        (st.expr Body D))
  "apply" [E1 E2] D -> (st.exprs [E1 E2] D)
  "call" [Name E] D -> (do (st.text Name) (st.expr E D))
  "perform" [Eff Op E] D -> (do (st.text Eff) (st.text Op) (st.expr E D)) where (st.handlers?)
  "handle" [Eff Clauses Body] D -> (do (st.text Eff) (st.expr Body D) (map (/. C (st.clause C D)) (st.array Clauses))) where (st.handlers?)
  "resume" [K E] D -> (do (st.unsigned K) (st.expr E D)) where (st.resumptions?)
  "discontinue" [K] _ -> (st.unsigned K) where (st.resumptions?)
  Tag X _ -> (st.fail "S-Shape" "Arity") where (element? Tag (st.tags))
  _ _ _ -> (st.fail "S-Shape" "Unsupported tag"))

\\ Tags of this schema: a known tag with the wrong number of operands is an arity error.
(define st.tags
  -> (append ["unit" "bool" "int" "var" "let" "if" "prim" "emit" "lambda" "apply" "call"]
             (if (st.data?) ["bytes" "tuple" "project" "construct" "match"] [])
             (if (st.handlers?) ["perform" "handle"] [])
             (if (st.resumptions?) ["resume" "discontinue"] [])))

(define st.primitive
  Op Es -> (if (and (element? [Op (length Es)] [["add" 2] ["sub" 2] ["mul" 2] ["div" 2] ["neg" 1] ["lt" 2] ["le" 2] ["gt" 2] ["ge" 2] ["not" 1]
                                                 ["bytes_length" 1] ["bytes_index" 2] ["bytes_concat" 2] ["eq" 2]])
                    (or (st.data?) (not (element? Op ["bytes_length" "bytes_index" "bytes_concat" "eq"]))))
               true
               (st.fail "S-Shape" "Primitive")))

\\ L-Bytes: a well-formed bytes literal over 256 octets is a cap, not an error.
(define st.bytes-cap
  H -> (st.cap "L-Bytes" "Bytes cap") where (and (tc.hex? H) (> (length (explode H)) 512))
  _ -> true)

(define st.arm
  [C Xs B] D -> (do (st.text C) (map (/. X (st.fresh X false)) (st.array Xs)) (st.expr B D))
  _ _ -> (st.fail "S-Shape" "Match arm"))

(define st.clause
  [Op X B] D -> (do (st.text Op) (st.fresh X false) (st.expr B D))
  [Op X K B] D -> (do (st.text Op) (st.fresh X false) (st.fresh K false) (st.expr B D)) where (st.resumptions?)
  _ _ -> (st.fail "S-Shape" "Handler clause"))

\\ ---------- S-Source-Map: one row for every function and expression node ----------

(define st.source-map
  Rows -> (let Mapped (st.rows Rows [])
            (if (= (length Mapped) (length (value st.*locations*))) true (st.fail "S-Source-Map" "Source map incomplete"))))

(define st.rows
  [] Mapped -> Mapped
  [R | Rs] Mapped ->
    (let Fields (st.object R ["column" "file" "id" "line"])
         Id (st.unsigned (tc.f "id" R))
         File (st.text (tc.f "file" R))
         Line (st.unsigned (tc.f "line" R))
         Column (st.unsigned (tc.f "column" R))
      (if (and (element? Id (value st.*locations*)) (not (element? Id Mapped)))
          (st.rows Rs [Id | Mapped])
          (st.fail "S-Source-Map" "Source map location"))))
