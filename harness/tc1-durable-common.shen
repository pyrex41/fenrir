\\ Fenrir harness, shared by the TC1-D1 programs (tc1-durable.shen, solo5-durable.shen,
\\ service-fenrir.shen): an artifact of schema tc1-durable-demo/1 and an entry input to
\\ the durable model's state, values between JSON and the model, and the model's step
\\ records in JSON shape. Load after common.shen. Contract: spec/tc1/DURABLE.md.
\\ Transport and comparison only: no transition logic lives here.

(load (cn (value fh.*root*) "models/tc1/durable-machine.shen"))

\\ ---------- JSON values to model values ----------

\\ The model value of a decoded JSON value in the artifact's value encoding, or
\\ [malformed] when it is not one (a host reply is checked here first, then typed).
(define dh.value
  ["unit"] -> [unit]
  ["bool" B] -> [bool B] where (boolean? B)
  ["int" N] -> [int N] where (string? N)
  ["bytes" Hex] -> (let Os (dh.octets Hex) (if (= Os malformed) [malformed] [bytes Os])) where (string? Hex)
  ["tuple" | Vs] -> (dh.compound [tuple] Vs) where (cons? Vs)
  ["data" Type C | Vs] -> (dh.compound [data Type C] Vs) where (and (string? Type) (string? C))
  _ -> [malformed])

(define dh.compound
  Head Vs -> (let Xs (map (/. V (dh.value V)) Vs)
               (if (element? [malformed] Xs) [malformed] (append Head Xs))))

(define dh.hex-digit
  C -> (let N (string->n C)
         (cond ((and (>= N 48) (<= N 57)) (- N 48))
               ((and (>= N 97) (<= N 102)) (- N 87))
               (true malformed))))

(define dh.octets
  "" -> []
  (@s A B Rest) -> (let H (dh.hex-digit A) L (dh.hex-digit B) Os (dh.octets Rest)
                     (if (or (= H malformed) (= L malformed) (= Os malformed)) malformed [(+ (* 16 H) L) | Os]))
  _ -> malformed)

\\ ---------- artifact to model state ----------

\\ [dm-context Durables Results Datatypes] of a decoded artifact.
(define dh.context
  Artifact ->
    (let Effects (fh.field "effects" Artifact)
         Durable (dh.keep (/. E (= (fh.member "class" E) "durable")) Effects)
      [dm-context (map (/. E (fh.field "name" E)) Durable)
                  (mapcan (/. E (map (/. O [(fh.field "name" E) (fh.field "name" O) (fh.field "result_type" O)]) (fh.field "operations" E))) Durable)
                  (map (/. D [(fh.field "name" D) (map (/. C [(fh.field "name" C) (fh.field "fields" C)]) (fh.field "constructors" D))])
                       (fh.field "datatypes" Artifact))]))

(define dh.keep
  F [] -> []
  F [X | Xs] -> (if (F X) [X | (dh.keep F Xs)] (dh.keep F Xs)))

\\ The durable model's initial state for a decoded artifact and a decoded JSON input.
(define dh.state
  Artifact Input ->
    (let Rows (map (/. F (fh.function-row F)) (fh.field "functions" Artifact))
         Names (map (/. R [(fh.function-name (hd (tl R))) (hd R)]) Rows)
         Entry (fh.entry-row (fh.field "entry" Artifact) Rows)
      (dm.initial [tc1-state [evaluate (hd (tl Entry)) true] [[(hd Entry) (dh.value Input)]] [] (fh.function-codes Rows) Names]
                  (dh.context Artifact))))

\\ ---------- model observations in JSON shape (DURABLE.md section 7) ----------

(define dh.event
  [host-request Node Seq Effect Op V] ->
    [object ["kind" "HostRequest"] ["task" "0"] ["node" Node] ["seq" (str Seq)] ["effect" Effect] ["operation" Op] ["value" (fh.value V)]]
  [host-reply Node Seq V] -> [object ["kind" "HostReply"] ["task" "0"] ["node" Node] ["seq" (str Seq)] ["value" (fh.value V)]]
  E -> (fh.event E))

(define dh.after
  host-wait -> "HostWait"
  P -> (fh.after P))

(define dh.site
  [node Node host-reply] -> [object ["node" Node] ["rule" "HostReply"]]
  Site -> (fh.site Site))

(define dh.depth
  State -> (length (dm.frames State)))

\\ The step record of [Site Next Events] at Epoch, in the shape of the other machines.
(define dh.record
  Epoch [Site Next Events] ->
    [object ["after" (dh.after (dm.phase Next))] ["depth" (str (dh.depth Next))] ["epoch" (str Epoch)]
            ["events" (map (/. E (dh.event E)) Events)] ["site" (dh.site Site)]])

(define dh.records
  _ [] -> []
  Epoch [R | Rs] -> [(dh.record Epoch R) | (dh.records (+ Epoch 1) Rs)])

(define dh.execution
  completed -> "Completed"
  budget-exhausted -> "BudgetExhausted"
  awaiting-host -> "AwaitingHost"
  [host-violation _] -> "HostViolation")

\\ A run of a decoded artifact on a decoded input under a host, in JSON shape:
\\ [Execution Records FinalState]. Replies given as JSON values are decoded here.
(define dh.run
  Artifact Input Host Fuel ->
    (let R (dm.run (dh.state Artifact Input) Host Fuel)
      [(dh.execution (hd R)) (dh.records 0 (nth 2 R)) (nth 3 R)]))

(define dh.json-replies
  Replies -> [replies | (map (/. V (dh.value V)) Replies)])

\\ The outcome of a Completed run, from its last record, or none.
(define dh.outcome
  "Completed" Records -> (fh.model-outcome Records)
  _ _ -> none)
