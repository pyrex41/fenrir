\\ Fenrir harness, in Shen: catalog coverage. Maps every step of the model's
\\ traces to a transition key of the reference-step catalog
\\ (spec/tc0/pure-call-demo.json), using only the program and the step records,
\\ and compares the keys exercised with the keys the catalog defines.
\\ A measure, not a verdict: it does not decide which traces are evidence.
\\
\\   shen-jit script harness/coverage.shen LIBDIR ROOT HAND.jsonl EXHAUSTIVE.jsonl
\\
\\ The two files are the ones the hand-case and model-vs-implementation
\\ programs wrote in the same run; their programs are re-run on the model here.
\\ Shen version of tools/tc0/pure-call-coverage.mjs.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*hand* (hd (tl (tl (tl (value *argv*))))))
(set fh.*exhaustive* (hd (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ ---------- the catalog's transition keys ----------

(define fh.prims -> ["add" "sub" "mul" "div" "neg" "lt" "le" "gt" "ge" "not" "bytes_length" "bytes_index" "bytes_concat" "eq"])

(define fh.collecting
  -> (append (map (/. P (cn "prim." P)) (fh.prims)) ["tuple" "project" "construct" "apply" "call" "emit"]))

\\ Operand count of a collecting form, as the catalog counts it.
(define fh.operands
  "prim.neg" -> 1
  "prim.not" -> 1
  "prim.bytes_length" -> 1
  "project" -> 1
  "call" -> 1
  "emit" -> 1
  _ -> 2)

(define fh.collect-keys
  [] -> []
  [T | Ts] -> (append [(make-string "CollectReturn ~A -> Ready" T)]
                      (if (> (fh.operands T) 1) [(make-string "CollectReturn ~A -> Eval" T)] [])
                      (fh.collect-keys Ts)))

(define fh.catalog-keys
  -> (append
       (map (/. T (make-string "Dispatch ~A -> Value" T)) ["unit" "bool" "int" "bytes" "var" "lambda"])
       (map (/. T (make-string "Dispatch ~A -> Eval" T)) (append ["let" "if" "match"] (fh.collecting)))
       ["Dispatch construct -> Ready"]
       (fh.collect-keys (fh.collecting))
       (map (/. P (make-string "Ready prim.~A -> Value" P)) (fh.prims))
       (map (/. P (make-string "Ready prim.~A -> Unwind Overflow" P)) ["add" "sub" "mul" "neg" "div"])
       ["Ready prim.div -> Unwind DivZero" "Ready prim.bytes_index -> Unwind Bounds"]
       (map (/. T (make-string "Ready ~A -> Value" T)) ["tuple" "construct" "project"])
       ["Ready emit -> Value [Invoke,Emit,Commit]"
        "Ready call -> Eval tail" "Ready call -> Eval non-tail" "Ready apply -> Eval tail" "Ready apply -> Eval non-tail"
        "LetReturn -> Eval" "IfReturn -> Eval then" "IfReturn -> Eval else" "MatchReturn -> Eval" "ReturnReturn -> Value"]
       (map (/. F (cn "UnwindFrame " F)) ["let" "if" "match" "collect" "return"])
       (map (/. P (cn "Tail call in " P)) ["function body" "let body" "if branch" "match arm" "lambda body"])
       ["RootJoinEntry Value -> Join" "RootJoinEntry Unwind -> Join"
        "Join -> Terminate [ScopeExit]" "Terminate -> Terminal [TaskTermination]"]))

\\ ---------- the program's shape, from the decoded artifact ----------

(define fh.kids
  ["let" _ _ Init Body] -> [Init Body]
  ["lambda" _ _ _ _ _ _ Body] -> [Body]
  ["if" _ | Es] -> Es
  ["apply" _ | Es] -> Es
  ["tuple" _ | Es] -> Es
  ["prim" _ _ | Es] -> Es
  ["call" _ _ E] -> [E]
  ["emit" _ _ E] -> [E]
  ["project" _ E _] -> [E]
  ["construct" _ _ _ | Es] -> Es
  ["match" _ E | Arms] -> [E | (map (/. A (hd (tl (tl A)))) Arms)]
  _ -> [])

\\ Tables are association lists keyed by node ID. Walk gives [Nodes Parents].
(define fh.walk
  E Parent [Nodes Parents] ->
    (fh.walk-all (fh.kids E) E [[[(hd (tl E)) E] | Nodes] (if (= Parent none) Parents [[(hd (tl E)) Parent] | Parents])]))

(define fh.walk-all
  [] _ Tables -> Tables
  [K | Ks] Parent Tables -> (fh.walk-all Ks Parent (fh.walk K Parent Tables)))

(define fh.shape
  [] Tables Bodies -> [Tables Bodies]
  [F | Fs] Tables Bodies ->
    (let Body (fh.field "body" F)
      (fh.shape Fs (fh.walk Body none Tables) [(hd (tl Body)) | Bodies])))

(define fh.find
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.find Key Rest)
  _ [] -> none)

(define fh.tag
  ["prim" _ Op | _] -> (cn "prim." Op)
  [Tag | _] -> Tag)

(define fh.id
  E -> (hd (tl E)))

\\ Why a node's position is a tail position, or none.
(define fh.context
  Id Nodes Parents Bodies ->
    (fh.context-in Id (fh.find Id Parents) Nodes Parents Bodies))

(define fh.context-in
  Id none _ _ Bodies -> (if (element? Id Bodies) "function body" none)
  Id ["let" P _ _ Body] Nodes Parents Bodies ->
    (if (and (= (fh.id Body) Id) (not (= (fh.context P Nodes Parents Bodies) none))) "let body" none)
  Id ["if" P Cond | _] Nodes Parents Bodies ->
    (if (and (not (= (fh.id Cond) Id)) (not (= (fh.context P Nodes Parents Bodies) none))) "if branch" none)
  Id ["match" P Scrutinee | _] Nodes Parents Bodies ->
    (if (and (not (= (fh.id Scrutinee) Id)) (not (= (fh.context P Nodes Parents Bodies) none))) "match arm" none)
  _ ["lambda" | _] _ _ _ -> "lambda body"
  _ _ _ _ _ -> none)

\\ ---------- keys exercised by one trace ----------

(define fh.kinds
  [] -> ""
  [E] -> (fh.field "kind" E)
  [E | Es] -> (cn (fh.field "kind" E) (cn "," (fh.kinds Es))))

(define fh.node-of
  Step Nodes -> (let Id (fh.member-of "node" (fh.field "site" Step))
                  (if (= Id none) none (fh.find Id Nodes))))

(define fh.member-of
  Key [object | Members] -> (fh.find Key Members))

(define fh.next-node
  [] -> none
  [Step | _] -> (fh.member-of "node" (fh.field "site" Step)))

\\ One step: returns [Keys Stack]. Stack is the simulated frame stack, innermost first.
(define fh.step-keys
  "Dispatch" E After Step Rest Trap Stack Shape ->
    [[(make-string "Dispatch ~A -> ~A" (fh.tag E) After)]
     (if (element? (hd E) ["let" "if" "match"]) [(hd E) | Stack] (if (= After "Eval") ["collect" | Stack] Stack))]
  "CollectReturn" E After _ _ _ Stack _ ->
    [[(make-string "CollectReturn ~A -> ~A" (fh.tag E) After)] (if (= After "Ready") (tl Stack) Stack)]
  "Ready" E After Step _ Trap Stack [Nodes Parents Bodies] ->
    (if (element? (hd E) ["call" "apply"])
        (let Tail (= (tc0.i64.small (fh.field "depth" Step)) (length Stack))
             Context (if Tail (fh.context (fh.id E) Nodes Parents Bodies) none)
          [(append [(make-string "Ready ~A -> Eval ~A" (hd E) (if Tail "tail" "non-tail"))]
                   (if (= Context none) [] [(cn "Tail call in " Context)]))
           (if Tail Stack ["return" | Stack])])
        (if (= (hd E) "emit")
            [[(make-string "Ready emit -> ~A [~A]" After (fh.kinds (fh.field "events" Step)))] Stack]
            [[(make-string "Ready ~A -> ~A~A" (fh.tag E) After (if (= After "Unwind") (cn " " Trap) ""))] Stack]))
  "LetReturn" _ After _ _ _ Stack _ -> [[(cn "LetReturn -> " After)] (tl Stack)]
  "IfReturn" E After _ Rest _ Stack _ ->
    [[(make-string "IfReturn -> ~A ~A" After (if (= (fh.next-node Rest) (fh.id (nth 4 E))) "then" "else"))] (tl Stack)]
  "MatchReturn" _ After _ _ _ Stack _ -> [[(cn "MatchReturn -> " After)] (tl Stack)]
  "ReturnReturn" _ After _ _ _ Stack _ -> [[(cn "ReturnReturn -> " After)] (tl Stack)]
  "UnwindFrame" _ _ _ _ _ Stack _ -> [[(cn "UnwindFrame " (hd Stack))] (tl Stack)]
  "Value" _ After _ _ _ Stack _ -> [[(cn "RootJoinEntry Value -> " After)] Stack]
  "Unwind" _ After _ _ _ Stack _ -> [[(cn "RootJoinEntry Unwind -> " After)] Stack]
  "Join" _ After Step _ _ Stack _ -> [[(make-string "Join -> ~A [~A]" After (fh.kinds (fh.field "events" Step)))] Stack]
  "Terminate" _ After Step _ _ Stack _ -> [[(make-string "Terminate -> ~A [~A]" After (fh.kinds (fh.field "events" Step)))] Stack])

(define fh.adjoin-all
  [] Set -> Set
  [K | Ks] Set -> (fh.adjoin-all Ks (if (element? K Set) Set [K | Set])))

\\ The frame simulation must stay in step with each record's depth, or the mapping is wrong.
(define fh.trace-keys
  [] _ _ _ Keys -> Keys
  [Step | Rest] Trap Stack Shape Keys ->
    (let R (fh.step-keys (fh.field "rule" (fh.field "site" Step)) (fh.node-of Step (hd Shape))
                         (fh.field "after" Step) Step Rest Trap Stack Shape)
         Stack2 (hd (tl R))
      (if (= (length Stack2) (tc0.i64.small (fh.field "depth" Step)))
          (fh.trace-keys Rest Trap Stack2 Shape (fh.adjoin-all (hd R) Keys))
          (error "coverage: frame simulation lost sync at epoch ~A" (fh.field "epoch" Step)))))

(define fh.trap-of
  ["Trap" Code] -> Code
  _ -> "")

(define fh.program-keys
  Program Keys ->
    (let S (fh.shape (fh.field "functions" Program) [[] []] [])
         Shape [(hd (hd S)) (hd (tl (hd S))) (hd (tl S))]
         Steps (hd (tl (fh.run (fh.state Program) 200 0 [])))
         Trap (fh.trap-of (fh.field "outcome" (hd (fh.field "events" (fh.last Steps)))))
      (fh.trace-keys Steps Trap [] Shape Keys)))

(define fh.rows-keys
  [] Keys -> Keys
  [Row | Rows] Keys -> (fh.rows-keys Rows (fh.program-keys (fh.field "program" Row) Keys)))

(define fh.without
  [] _ -> []
  [X | Xs] Ys -> (if (element? X Ys) (fh.without Xs Ys) [X | (fh.without Xs Ys)]))

(define fh.file-rows
  Path -> (let View (buffer.from-string (read-file-as-string Path))
            (fh.json-lines View 0 (buffer.length View) [])))

(define fh.main
  -> (let Hand (fh.file-rows (value fh.*hand*))
          Exhaustive (tl (fh.file-rows (value fh.*exhaustive*)))
          Catalog (fh.catalog-keys)
          Covered (fh.rows-keys Exhaustive (fh.rows-keys Hand []))
          Missing (fh.without Catalog Covered)
          Outside (fh.without Covered Catalog)
          Status (if (not (empty? Outside)) "outside-catalog" (if (empty? Missing) "complete" "incomplete"))
          Report [object ["schema" "fenrir.harness.coverage/1"]
                         ["status" Status]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["traces" (make-string "~A hand cases and ~A exhaustive programs, re-run on the model" (length Hand) (length Exhaustive))]
                         ["catalog_keys" (str (length Catalog))]
                         ["covered" (str (- (length Catalog) (length Missing)))]
                         ["missing" Missing]
                         ["unknown_observed" Outside]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if (= Status "complete") 0 1)))))

(fh.main)
