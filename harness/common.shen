\\ Fenrir harness, shared definitions. Load after setting fh.*lib* (Shen/JIT lib
\\ directory, with trailing slash) and fh.*root* (repository root, with trailing
\\ slash). Loads the Shen/JIT libraries and the model, then defines: decoded-JSON
\\ helpers, artifact-to-model-state translation as data, the model's
\\ observations in JSON shape, and line scanning over byte views.
\\ Transport and comparison support only: no transition logic lives here.

(set process.*adapter-files* [(cn (value fh.*lib*) "shen-process.so")])
(map (/. F (load (cn (value fh.*lib*) F)))
     ["ffi.shen" "buffer.shen" "cursor.shen" "grammar.shen" "json.shen" "io.shen" "io-file.shen"
      "deadline.shen" "clock.shen" "process.shen" "process-io.shen"])

\\ The model: registered machine plus the width-independent integer layer.
(map (/. F (load (cn (value fh.*root*) F)))
     ["models/tc0/arithmetic.shen" "models/tc0/pure-call-machine.shen"
      "models/tc0/portable/i64.shen" "models/tc0/portable/pure-call-overrides.shen"])

\\ ---------- decoded JSON helpers ----------

(define fh.assoc
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.assoc Key Rest)
  Key [] -> (error "harness: missing field ~A" Key))

(define fh.field
  Key [object | Members] -> (fh.assoc Key Members)
  Key _ -> (error "harness: expected an object with field ~A" Key))

\\ ---------- artifact (decoded JSON) to model state, as data ----------

(define fh.hex-value
  N -> (- N 48) where (and (>= N 48) (<= N 57))
  N -> (- N 87) where (and (>= N 97) (<= N 102))
  _ -> (error "harness: bytes literal is not lowercase hex"))

(define fh.octets
  "" -> []
  S -> [(+ (* 16 (fh.hex-value (string->n (pos S 0)))) (fh.hex-value (string->n (pos S 1))))
        | (fh.octets (tlstr (tlstr S)))])

(define fh.op
  Op -> (intern Op) where (element? Op ["add" "sub" "mul" "div" "neg" "lt" "le" "gt" "ge" "not" "eq"
                                        "bytes_length" "bytes_index" "bytes_concat"])
  Op -> (error "harness: unsupported primitive ~A" Op))

\\ Function names travel to the model as fn-NAME symbols.
(define fh.function-name
  Name -> (intern (cn "fn-" Name)))

(define fh.arm
  [Ctor Binders Body] -> [Ctor Binders (fh.expr Body)])

(define fh.exprs
  Es -> (map (/. E (fh.expr E)) Es))

\\ I64 literals and every ID stay strings: the portable model's representation.
(define fh.expr
  ["unit" Node] -> [unit Node]
  ["bool" Node B] -> [bool Node B]
  ["int" Node N] -> [int Node N]
  ["bytes" Node Hex] -> [bytes Node (fh.octets Hex)]
  ["var" Node Id] -> [var Node Id]
  ["let" Node Id Init Body] -> [let Node Id (fh.expr Init) (fh.expr Body)]
  ["if" Node C Y N] -> [if Node (fh.expr C) (fh.expr Y) (fh.expr N)]
  ["lambda" Node Id _ _ _ _ Body] -> [lambda Node Id (fh.expr Body)]
  ["apply" Node F A] -> [apply Node (fh.expr F) (fh.expr A)]
  ["call" Node Name Arg] -> [call Node (fh.function-name Name) (fh.expr Arg)]
  ["prim" Node Op | Args] -> [prim Node (fh.op Op) | (fh.exprs Args)]
  ["emit" Node Label Arg] -> [emit Node Label (fh.expr Arg)]
  ["tuple" Node | Args] -> [tuple Node | (fh.exprs Args)]
  ["project" Node E I] -> [project Node (fh.expr E) (tc0.i64.small I)]
  ["construct" Node Type Ctor | Args] -> [construct Node Type Ctor | (fh.exprs Args)]
  ["match" Node E | Arms] -> [match Node (fh.expr E) (map (/. A (fh.arm A)) Arms)]
  X -> (error "harness: unsupported expression ~S" X))

\\ One [Id [Parameter Body]] entry per lambda in a translated expression.
(define fh.lambda-codes
  [lambda Node Id Body] -> [[Node [Id Body]] | (fh.lambda-codes Body)]
  [let Node Id Init Body] -> (append (fh.lambda-codes Init) (fh.lambda-codes Body))
  [match Node E Arms] -> (append (fh.lambda-codes E) (fh.arm-codes Arms))
  [Tag Node | Rest] -> (fh.codes-in Rest)
  _ -> [])

(define fh.codes-in
  [] -> []
  [X | Xs] -> (append (fh.lambda-codes X) (fh.codes-in Xs))
  _ -> [])

(define fh.arm-codes
  [] -> []
  [[_ _ Body] | Arms] -> (append (fh.lambda-codes Body) (fh.arm-codes Arms)))

\\ A function row is [Id Name Parameter Body].
(define fh.function-row
  F -> [(fh.field "id" F) (fh.field "name" F) (fh.field "parameter_id" F) (fh.expr (fh.field "body" F))])

(define fh.function-codes
  [] -> []
  [[Id _ Parameter Body] | Rows] -> (append (fh.lambda-codes Body) [[Id [Parameter Body]] | (fh.function-codes Rows)]))

(define fh.entry-row
  Name [[Id Name Parameter Body] | _] -> [Parameter Body]
  Name [_ | Rows] -> (fh.entry-row Name Rows)
  Name [] -> (error "harness: entry function ~A is not defined" Name))

(define fh.state
  Artifact ->
    (let Rows (map (/. F (fh.function-row F)) (fh.field "functions" Artifact))
         Names (map (/. R [(fh.function-name (hd (tl R))) (hd R)]) Rows)
         Entry (fh.entry-row (fh.field "entry" Artifact) Rows)
      [pure-call-state [evaluate (hd (tl Entry)) true] [[(hd Entry) [int "0"]]] [] (fh.function-codes Rows) Names]))

\\ ---------- model observations in the guest's JSON shape ----------

(define fh.high
  N Q -> Q where (< N 16)
  N Q -> (fh.high (- N 16) (+ Q 1)))

(define fh.hex-octet
  N -> (let H (fh.high N 0)
         (cn (pos "0123456789abcdef" H) (pos "0123456789abcdef" (- N (* 16 H))))))

(define fh.hex
  [] -> ""
  [O | Os] -> (cn (fh.hex-octet O) (fh.hex Os)))

(define fh.value
  [unit] -> ["unit"]
  [int N] -> ["int" N]
  [bool B] -> ["bool" B]
  [bytes Os] -> ["bytes" (fh.hex Os)]
  [tuple | Vs] -> ["tuple" | (map (/. V (fh.value V)) Vs)]
  [data Type Ctor | Vs] -> ["data" Type Ctor | (map (/. V (fh.value V)) Vs)]
  V -> (error "harness: value is not an observation ~S" V))

(define fh.trap-name
  overflow -> "Overflow"
  div-zero -> "DivZero"
  bounds -> "Bounds")

(define fh.outcome
  [ok V] -> ["Ok" (fh.value V)]
  [trap Code] -> ["Trap" (fh.trap-name Code)])

(define fh.event
  [invoke Node Label V] -> [object ["kind" "Invoke"] ["task" "0"] ["node" Node] ["operation" "emit"] ["label" Label] ["value" (fh.value V)]]
  [emit Node Label V] -> [object ["kind" "Emit"] ["task" "0"] ["node" Node] ["label" Label] ["value" (fh.value V)]]
  [commit Node V] -> [object ["kind" "Commit"] ["task" "0"] ["node" Node] ["operation" "emit"] ["value" (fh.value V)]]
  [scope-exit O] -> [object ["kind" "ScopeExit"] ["task" "0"] ["scope" "0"] ["outcome" (fh.outcome O)]]
  [task-termination O] -> [object ["kind" "TaskTermination"] ["task" "0"] ["outcome" (fh.outcome O)]])

(define fh.rule
  dispatch -> "Dispatch"
  ready -> "Ready"
  let-return -> "LetReturn"
  if-return -> "IfReturn"
  match-return -> "MatchReturn"
  return-return -> "ReturnReturn"
  collect-return -> "CollectReturn"
  unwind-frame -> "UnwindFrame"
  value -> "Value"
  unwind -> "Unwind"
  join -> "Join"
  terminate -> "Terminate")

(define fh.machine-site
  root-join-entry -> "RootJoinEntry"
  join -> "Join"
  terminate -> "Terminate")

(define fh.site
  [node Node Rule] -> [object ["node" Node] ["rule" (fh.rule Rule)]]
  [machine Site Rule] -> [object ["machine" (fh.machine-site Site)] ["rule" (fh.rule Rule)]])

(define fh.after
  evaluate -> "Eval"
  value -> "Value"
  ready -> "Ready"
  unwind -> "Unwind"
  join -> "Join"
  terminate -> "Terminate"
  terminal -> "Terminal")

(define fh.phase
  State -> (hd (hd (tl State))))

(define fh.depth
  State -> (length (hd (tl (tl (tl State))))))

\\ Step the model to its terminal state or the fuel bound: [Execution Steps].
(define fh.run
  State _ _ Acc -> ["Completed" (reverse Acc)] where (= (fh.phase State) terminal)
  _ 0 _ Acc -> ["BudgetExhausted" (reverse Acc)]
  State Fuel Epoch Acc ->
    (let T (tc0.pc.step State)
         Next (hd (tl T))
         Step [object ["after" (fh.after (fh.phase Next))] ["depth" (str (fh.depth Next))] ["epoch" (str Epoch)]
                      ["events" (map (/. E (fh.event E)) (hd (tl (tl T))))] ["site" (fh.site (tc0.pc.site State))]]
      (fh.run Next (- Fuel 1) (+ Epoch 1) [Step | Acc])))

\\ ---------- byte views ----------

(define fh.next-line
  V I End -> End where (>= I End)
  V I End -> (+ I 1) where (= (buffer.u8 V I) 10)
  V I End -> (fh.next-line V (+ I 1) End))

\\ One decoded JSON value per nonempty line of a byte view.
(define fh.json-lines
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (let Next (fh.next-line V I End)
         Count (- (- Next I) (if (and (> Next I) (= (buffer.u8 V (- Next 1)) 10)) 1 0))
      (fh.json-lines V Next End
        (if (= Count 0) Acc [(json.decode (buffer.slice V I Count) [[byte-limit 16777216]]) | Acc]))))

(define fh.last
  [X] -> X
  [_ | Xs] -> (fh.last Xs))

\\ ---------- order-insensitive JSON comparison ----------

(define fh.string<?
  "" "" -> false
  "" _ -> true
  _ "" -> false
  (@s A As) (@s B Bs) -> (if (= A B) (fh.string<? As Bs) (< (string->n A) (string->n B))))

(define fh.insert-member
  M [] -> [M]
  M [N | Ns] -> [M N | Ns] where (fh.string<? (hd M) (hd N))
  M [N | Ns] -> [N | (fh.insert-member M Ns)])

(define fh.sort-members
  [] -> []
  [M | Ms] -> (fh.insert-member M (fh.sort-members Ms)))

\\ Objects with their members sorted by key, recursively, so two decoded JSON
\\ values are equal exactly when they are equal as JSON.
(define fh.canon
  [object | Ms] -> [object | (fh.sort-members (map (/. M [(hd M) (fh.canon (hd (tl M)))]) Ms))]
  [X | Xs] -> [(fh.canon X) | (fh.canon Xs)]
  X -> X)

(define fh.take
  0 _ -> []
  _ [] -> []
  N [X | Xs] -> [X | (fh.take (- N 1) Xs)])
