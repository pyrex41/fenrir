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

\\ The models: exact integer arithmetic, the TC0-A pure-call machine, and the TC1
\\ handler machine. Which machine runs a program is decided by its schema.
(map (/. F (load (cn (value fh.*root*) F)))
     ["models/tc0/i64.shen" "models/tc0/pure-call-machine.shen" "models/tc1/handler-machine.shen"])

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

\\ I64 literals and every ID stay strings: the model's representation.
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
  \\ TC1: effect and operation names stay strings; a clause is [Operation Binder Body].
  ["handle" Node Effect Clauses Body] -> [handle Node Effect (map (/. C (fh.arm C)) Clauses) (fh.expr Body)]
  ["perform" Node Effect Op Arg] -> [perform Node Effect Op (fh.expr Arg)]
  X -> (error "harness: unsupported expression ~S" X))

\\ One [Id [Parameter Body]] entry per lambda in a translated expression.
(define fh.lambda-codes
  [lambda Node Id Body] -> [[Node [Id Body]] | (fh.lambda-codes Body)]
  [let Node Id Init Body] -> (append (fh.lambda-codes Init) (fh.lambda-codes Body))
  [match Node E Arms] -> (append (fh.lambda-codes E) (fh.arm-codes Arms))
  [handle Node Effect Clauses Body] -> (append (fh.arm-codes Clauses) (fh.lambda-codes Body))
  [perform Node Effect Op Arg] -> (fh.lambda-codes Arg)
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

\\ The machine a program runs on, by its schema.
(define fh.state-tag
  "tc1-handler-demo/1" -> tc1-state
  _ -> pure-call-state)

(define fh.model-step
  [tc1-state | Rest] -> (tc1.step [tc1-state | Rest])
  State -> (tc0.pc.step State))

(define fh.model-site
  [tc1-state | Rest] -> (tc1.site [tc1-state | Rest])
  State -> (tc0.pc.site State))

(define fh.state
  Artifact ->
    (let Rows (map (/. F (fh.function-row F)) (fh.field "functions" Artifact))
         Names (map (/. R [(fh.function-name (hd (tl R))) (hd R)]) Rows)
         Entry (fh.entry-row (fh.field "entry" Artifact) Rows)
      [(fh.state-tag (fh.field "schema_version" Artifact)) [evaluate (hd (tl Entry)) true] [[(hd Entry) [int "0"]]] [] (fh.function-codes Rows) Names]))

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
  [perform Node Effect Op V] -> [object ["kind" "Perform"] ["task" "0"] ["node" Node] ["effect" Effect] ["operation" Op] ["value" (fh.value V)]]
  [resume Node V] -> [object ["kind" "Resume"] ["task" "0"] ["node" Node] ["value" (fh.value V)]]
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
  handle-return -> "HandleReturn"
  clause-return -> "ClauseReturn"
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
    (let T (fh.model-step State)
         Next (hd (tl T))
         Step [object ["after" (fh.after (fh.phase Next))] ["depth" (str (fh.depth Next))] ["epoch" (str Epoch)]
                      ["events" (map (/. E (fh.event E)) (hd (tl (tl T))))] ["site" (fh.site (fh.model-site State))]]
      (fh.run Next (- Fuel 1) (+ Epoch 1) [Step | Acc])))

\\ ---------- launching the JavaScript implementation ----------

\\ Arguments for node to run Script (relative to the repository root) with Args.
\\ Sandboxed: through tools/tc0/sandbox.mjs, which gives the process no network and
\\ no environment, read access to the implementation tree and ExtraReads only
\\ (repository-relative, or absolute when they start with a slash), and
\\ write access to Output only.
(define fh.node-arguments
  Script Args _ _ false -> [(cn (value fh.*root*) Script) | Args]
  Script Args ExtraReads Output true ->
    (append [(cn (value fh.*root*) "tools/tc0/sandbox.mjs") "--read"
             (cn (value fh.*root*) "tools/tc0") (cn (value fh.*root*) "runtime/tc0")]
            (map (/. R (if (= (pos R 0) "/") R (cn (value fh.*root*) R))) ExtraReads)
            ["--write" Output "--" (cn (value fh.*root*) Script)]
            Args))

\\ ---------- closure descriptors the model produced ----------

(define fh.captured
  [closure Code Captures []] -> (fh.descriptor [closure Code Captures []])
  V -> (fh.value V))

(define fh.descriptor
  [closure Code Captures []] ->
    [object ["code_id" Code]
            ["captures" (map (/. Pair [(hd Pair) (fh.captured (hd (tl Pair)))]) Captures)]
            ["capture_support" []]])

\\ Every closure value the model yields, in order, as descriptors.
(define fh.descriptors
  State _ Acc -> (reverse Acc) where (= (fh.phase State) terminal)
  _ 0 Acc -> (reverse Acc)
  State Fuel Acc ->
    (let Next (hd (tl (fh.model-step State)))
      (fh.descriptors Next (- Fuel 1) (fh.note-closure (hd (tl Next)) Acc))))

(define fh.note-closure
  [value [closure Code Captures []]] Acc -> [(fh.canon (fh.descriptor [closure Code Captures []])) | Acc]
  _ Acc -> Acc)

(define fh.model-outcome
  Steps -> (fh.field "outcome" (hd (fh.field "events" (fh.last Steps)))))

(define fh.emit-labels
  [] -> []
  [[object ["kind" "Emit"] | Rest] | Events] -> [(fh.assoc "label" Rest) | (fh.emit-labels Events)]
  [_ | Events] -> (fh.emit-labels Events))

(define fh.emissions
  [] -> []
  [S | Steps] -> (append (fh.emit-labels (fh.field "events" S)) (fh.emissions Steps)))

(define fh.all-members?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (fh.all-members? Xs Ys)))

\\ ---------- strict replay of the implementation against model traces ----------

\\ Cases is a list of [Name Program ReferenceSteps Mutant], Mutant a string or null.
\\ Writes the request, runs tools/tc0/replay-reference.mjs (sandboxed when asked),
\\ and returns its decoded result rows, or [] when the run failed.
(define fh.replay-lines
  [] -> ""
  [[Name Program Reference Mutant] | Cases] ->
    (cn (json.stringify [object ["name" Name] ["program" Program] ["reference" Reference] ["mutant" Mutant]] [[byte-limit 16777216]])
        (cn "c#10;" (fh.replay-lines Cases))))

(define fh.first-line
  V I End -> (buffer.string (buffer.slice V 0 (- (fh.next-line V 0 End) (if (> End 0) 1 0)))))

(define fh.node-path
  -> (let R (process.run "node" ["-p" "process.execPath"] (buffer.from-string "") [[timeout 30000]])
          V (if (and (= (hd R) ok) (process.success? (hd (tl R)))) (process.output-bytes (hd (tl R))) (error "harness: node is not available"))
       (fh.first-line V 0 (buffer.length V))))

(define fh.replay
  Cases Dir Sandbox ->
    (let In (cn Dir "replay-input.jsonl")
         Out (cn Dir "replay-output.jsonl")
         Identity (json.stringify [object ["identity" [object ["evaluator" "Shen harness"]
                                    ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]]]] [])
         Written (write-to-file In (cn Identity (cn "c#10;" (fh.replay-lines Cases))))
         \\ The tape header binds the node executable's identity, so the sandbox must let it be read.
         Node (if Sandbox (fh.node-path) "")
         R (process.run "node" (fh.node-arguments "tools/tc0/replay-reference.mjs" [In Out] (if Sandbox ["spec/tc0" In Node] []) Out Sandbox)
                        (buffer.from-string "") [[timeout 300000]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (let View (buffer.from-string (read-file-as-string Out)) (fh.json-lines View 0 (buffer.length View) []))
          [])))

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

\\ ---------- processes and text ----------

(define fh.exit-code
  [exited N] -> N
  _ -> -1)

\\ [ExitCode Stdout Stderr]; -1 when the process did not exit normally in time.
(define fh.exec
  Program Args Seconds ->
    (let R (process.run Program Args (buffer.from-string "")
                        [[cwd (value fh.*root*)] [timeout (* Seconds 1000)] [stdout-limit 67108864] [stderr-limit 4194304]])
      (if (= (hd R) ok)
          [(fh.exit-code (process.status (hd (tl R))))
           (buffer.string (process.output-bytes (hd (tl R))))
           (buffer.string (process.error-bytes (hd (tl R))))]
          [-1 "" "process did not complete within its time or output limits"])))

(define fh.view-lines
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (let Next (fh.next-line V I End)
         Count (- (- Next I) (if (and (> Next I) (= (buffer.u8 V (- Next 1)) 10)) 1 0))
      (fh.view-lines V Next End [(buffer.string (buffer.slice V I Count)) | Acc])))

(define fh.lines
  S -> (let V (buffer.from-string S) (fh.view-lines V 0 (buffer.length V) [])))

(define fh.starts?
  "" _ -> true
  _ "" -> false
  (@s A As) (@s B Bs) -> (and (= A B) (fh.starts? As Bs)))

(define fh.drop
  "" S -> S
  (@s _ Ps) (@s _ Ss) -> (fh.drop Ps Ss))

\\ The text after Prefix on the last line that starts with it, or [].
(define fh.last-after
  Prefix [] Found -> Found
  Prefix [L | Ls] Found -> (fh.last-after Prefix Ls (if (fh.starts? Prefix L) (fh.drop Prefix L) Found)))

(define fh.last-nonempty
  [] Found -> Found
  ["" | Ls] Found -> (fh.last-nonempty Ls Found)
  [L | Ls] _ -> (fh.last-nonempty Ls L))

\\ The last line that is a JSON object, decoded, or [].
(define fh.last-report
  Text -> (let Line (fh.last-after "{" (fh.lines Text) [])
            (if (= Line []) [] (trap-error (json.parse (cn "{" Line) [[byte-limit 4194304]]) (/. E [])))))

(define fh.member
  Key [object | Members] -> (fh.member-in Key Members)
  _ _ -> [])

(define fh.member-in
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.member-in Key Rest)
  _ [] -> [])

(define fh.trim
  S -> (fh.last-nonempty (fh.lines S) ""))

\\ Run one harness program and decode its report.
\\ Tree is the source tree whose harness, model and implementation are used (with a
\\ trailing slash); the Shen/JIT executable is fh.*jit*.
(define fh.harness-in
  Tree Script Args Seconds ->
    (fh.last-report (hd (tl (fh.exec (value fh.*jit*) (append ["script" (cn Tree (cn "harness/" Script)) (value fh.*lib*) Tree] Args) Seconds)))))

(define fh.harness
  Script Args Seconds -> (fh.harness-in (value fh.*root*) Script Args Seconds))

(define fh.subdir
  Name -> (let Dir (cn (value fh.*out*) Name)
               Made (fh.exec "mkdir" ["-p" Dir] 30)
            Dir))

(define fh.sha256
  Path -> (let R (fh.exec "sha256sum" [Path] 60)
            (if (= (hd R) 0) (fh.take-string 64 (hd (tl R))) "")))

(define fh.take-string
  0 _ -> ""
  _ "" -> ""
  N (@s C Cs) -> (cn C (fh.take-string (- N 1) Cs)))

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
