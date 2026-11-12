\\ Fenrir harness, in Shen: run a batch of TC0-A pure-call programs inside a
\\ Solo5 guest and compare every reference step with the Shen model, which runs
\\ in this same process. Development evidence only; no qualification verdict.
\\
\\ Host: Shen/JIT 0.7 with its JSON, buffer and subprocess libraries.
\\   shen-jit script harness/solo5-pure-call.shen LIBDIR ROOT BATCHDIR
\\ LIBDIR   Shen/JIT lib directory (with shen-process.so built)
\\ ROOT     repository root
\\ BATCHDIR directory holding batch.json, programs.json and the guest image,
\\          as written by tools/solo5/freerun-pure-call.mjs --build-only
\\
\\ What is NOT in Shen yet: generating the programs, validating them, and
\\ lowering them into the guest image. Those are still the JavaScript tools.
\\ Nothing here trusts the guest: its output is parsed strictly and compared
\\ with what the model computes; the model never sees guest output.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*batch* (cn (hd (tl (tl (tl (value *argv*))))) "/"))

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

\\ ---------- guest output: strict frames ----------

\\ "FGRUN/1 " then a decimal length, a newline, exactly that many payload bytes, a newline.
\\ Lines that do not start with FG are tender diagnostics and are skipped.
(define fh.prefix?
  V I End -> (and (<= (+ I 8) End)
                  (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71) (= (buffer.u8 V (+ I 2)) 82)
                  (= (buffer.u8 V (+ I 3)) 85) (= (buffer.u8 V (+ I 4)) 78) (= (buffer.u8 V (+ I 5)) 47)
                  (= (buffer.u8 V (+ I 6)) 49) (= (buffer.u8 V (+ I 7)) 32)))

(define fh.fg-line?
  V I End -> (and (<= (+ I 2) End) (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71)))

(define fh.next-line
  V I End -> End where (>= I End)
  V I End -> (+ I 1) where (= (buffer.u8 V I) 10)
  V I End -> (fh.next-line V (+ I 1) End))

\\ Returns [Length IndexAfterNewline].
(define fh.length-field
  V I End N Digits -> (error "harness: truncated frame header") where (>= I End)
  V I End N Digits -> (if (> Digits 0) [N (+ I 1)] (error "harness: empty frame length")) where (= (buffer.u8 V I) 10)
  V I End N Digits ->
    (let B (buffer.u8 V I)
      (if (and (>= B 48) (<= B 57) (< Digits 9))
          (fh.length-field V (+ I 1) End (+ (* N 10) (- B 48)) (+ Digits 1))
          (error "harness: invalid frame length"))))

(define fh.scan
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (if (fh.prefix? V I End)
        (let Header (fh.length-field V (+ I 8) End 0 0)
             N (hd Header)
             Start (hd (tl Header))
          (if (and (< (+ Start N) End) (= (buffer.u8 V (+ Start N)) 10))
              (fh.scan V (+ Start (+ N 1)) End
                       [(json.decode (buffer.slice V Start N) [[byte-limit 1048576]]) | Acc])
              (error "harness: frame length does not match its payload")))
        (if (fh.fg-line? V I End)
            (error "harness: unknown FG frame")
            (fh.scan V (fh.next-line V I End) End Acc))))

(define fh.frames
  V -> (fh.scan V 0 (buffer.length V) []))

\\ Hello, then per program: Program, its steps, End; then Terminal.
(define fh.steps
  [[object ["execution" X] ["kind" "End"]] | Frames] Steps Acc -> (fh.programs Frames [[X (reverse Steps)] | Acc])
  [Step | Frames] Steps Acc -> (fh.steps Frames [Step | Steps] Acc)
  [] _ _ -> (error "harness: guest output ends inside a program"))

(define fh.programs
  [[object ["kind" "Terminal"]]] Acc -> (reverse Acc)
  [[object ["index" _] ["kind" "Program"]] | Frames] Acc -> (fh.steps Frames [] Acc)
  _ _ -> (error "harness: guest program framing"))

(define fh.guest-traces
  [[object ["batch_sha256" B] ["kind" "Hello"]] | Frames] B -> (fh.programs Frames [])
  _ _ -> (error "harness: guest identity mismatch"))

(define fh.guest-range
  Tender Guest Batch Mode First End ->
    (let R (process.run Tender ["--mem=32" Guest (make-string "~A ~A ~A" Mode First End)] (buffer.from-string "")
                        [[timeout 120000] [stdout-limit 134217728]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (fh.guest-traces (fh.frames (process.output-bytes (hd (tl R)))) Batch)
          (error "harness: guest run failed for ~A ~A..~A" Mode First End))))

(define fh.guest-all
  Tender Guest Batch Mode First Count -> [] where (>= First Count)
  Tender Guest Batch Mode First Count ->
    (let End (if (> (+ First 250) Count) Count (+ First 250))
      (append (fh.guest-range Tender Guest Batch Mode First End)
              (fh.guest-all Tender Guest Batch Mode End Count))))

\\ ---------- comparison ----------

(define fh.step-count
  [] N -> N
  [[_ Steps] | Rest] N -> (fh.step-count Rest (+ N (length Steps))))

\\ Indices of programs whose guest trace differs from the model trace.
(define fh.differing
  [] [] _ Acc -> (reverse Acc)
  [M | Ms] [G | Gs] I Acc -> (fh.differing Ms Gs (+ I 1) (if (= M G) Acc [I | Acc]))
  _ _ _ _ -> (error "harness: trace counts differ"))

(define fh.first-divergence
  [] [] _ -> "none"
  [S | Ms] [S | Gs] I -> (fh.first-divergence Ms Gs (+ I 1))
  _ _ I -> (str I))

(define fh.describe
  [] _ _ -> []
  [I | Is] Model Guest ->
    [[object ["program" (str I)]
             ["model_execution" (hd (nth (+ I 1) Model))] ["guest_execution" (hd (nth (+ I 1) Guest))]
             ["first_divergent_epoch" (fh.first-divergence (hd (tl (nth (+ I 1) Model))) (hd (tl (nth (+ I 1) Guest))) 0)]]
     | (fh.describe Is Model Guest)])

(define fh.take
  0 _ -> []
  _ [] -> []
  N [X | Xs] -> [X | (fh.take (- N 1) Xs)])

(define fh.main
  -> (let Batch (json.parse (read-file-as-string (cn (value fh.*batch*) "batch.json")) [])
          Sha (fh.field "batch_sha256" Batch)
          Tender (fh.field "tender" Batch)
          Guest (fh.field "guest" Batch)
          Programs (json.parse (read-file-as-string (fh.field "programs" Batch)) [[byte-limit 268435456]])
          Count (length Programs)
          Model (map (/. P (fh.run (fh.state P) 200 0 [])) Programs)
          Normal (fh.guest-all Tender Guest Sha "normal" 0 Count)
          Failures (fh.differing Model Normal 0 [])
          Reversed (length (fh.differing Model (fh.guest-all Tender Guest Sha "reverse-operands" 0 Count) 0 []))
          Wrapped (length (fh.differing Model (fh.guest-all Tender Guest Sha "wrap-overflow" 0 Count) 0 []))
          Pass (and (empty? Failures) (> Reversed 0) (> Wrapped 0))
          Report [object ["schema" "fenrir.harness.solo5-pure-call/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["model" "registered pure-call machine with models/tc0/portable integer layer, run in this process"]
                         ["batch_sha256" Sha]
                         ["programs" (str Count)]
                         ["model_steps" (str (fh.step-count Model 0))]
                         ["guest_steps" (str (fh.step-count Normal 0))]
                         ["programs_differing" (str (length Failures))]
                         ["defects_detected" [object ["reverse-operands" (str Reversed)] ["wrap-overflow" (str Wrapped)]]]
                         ["failures" (fh.describe (fh.take 10 Failures) Model Normal)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
