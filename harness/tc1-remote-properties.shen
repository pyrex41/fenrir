\\ Fenrir harness, in Shen: the properties of remote perform (contract
\\ spec/tc1/EFFECTS.md §12.8), as checks on states and steps of the model
\\ models/tc1/remote-system.shen. Load that model first.
\\ Used by harness/tc1-remote.shen, which explores the model, and by
\\ harness/tc1-remote-run.shen, which replays the event log of a real run
\\ through the model. The properties read the model's history variables
\\ (attempts, applications, sealed request ids), which the model's own steps
\\ maintain. Whether a copy of a request id was handed over, and whether it was
\\ issued before a supervisor restart, are read from those history variables and
\\ not from the supervisor's own record, which a defective supervisor loses.
\\   fr.check-state Config State            violations in a state
\\   fr.check-step Config Pre Label Post    violations of one step
\\   fr.check-terminal State                violations when no step is enabled

\\ ---------- small helpers ----------

(define fr.lookup
  Dict Key -> (trap-error (shen.<-dict Dict Key) (/. E absent)))

(define fr.add-new
  X Xs -> (if (element? X Xs) Xs [X | Xs]))

(define fr.union
  [] Ys -> Ys
  [X | Xs] Ys -> (fr.union Xs (fr.add-new X Ys)))

(define fr.bump
  Key [] -> [[Key 1]]
  Key [[Key N] | Rest] -> [[Key (+ N 1)] | Rest]
  Key [Other | Rest] -> [Other | (fr.bump Key Rest)])

(define fr.tally
  Key [] -> 0
  Key [[Key N] | _] -> N
  Key [_ | Rest] -> (fr.tally Key Rest))

(define fr.any?
  _ [] -> false
  F [X | Xs] -> (if (F X) true (fr.any? F Xs)))

(define fr.member-of
  Name S -> (hd (remote.find-member Name (remote.members S))))

(define fr.durable [_ _ Durable _] -> Durable)
(define fr.log [_ _ [_ Log] _] -> Log)
(define fr.inbox [_ _ _ [_ _ Inbox]] -> Inbox)

\\ History: request ids of which a copy really was handed to the peer, and
\\ request ids issued before the supervisor's latest restart.
(define fr.given S -> (nth 4 (remote.ghost S)))
(define fr.old S -> (nth 5 (remote.ghost S)))

\\ ---------- properties of a state ----------

\\ single-outcome: a perform never has two outcomes.
\\ reply-implies-acted: an observed reply is one of the operation's two values,
\\ and the peer's durable log has a record for that request id; if the reply is
\\ ok v, the record's value is v.
\\ key-bound-to-argument: if the reply is ok, the record was made with this
\\ attempt's argument; if it is conflict, the record was made with another.
\\ Both are judged against the store, not against any record of who saw the peer act.
\\ read-reply-from-state: an observed reply to a read-only perform is a value the
\\ peer's state had at some time between the issue of that attempt and the
\\ reply. What the operation answers is read by running the peer's program on
\\ the store (remote.reading). For the peers checked here that answer never
\\ decreases (a ledger's total with amounts that are not negative, a constant),
\\ so: not less than the answer when the attempt was issued (kept with the
\\ attempt), and not more than the answer now. There is no record to judge it
\\ against, and none is asked for.
(define fr.attempt-violations
  Config S [] -> []
  Config S [[Tag Caller Peer Rid Fate Outcomes [read-only Op A Low]] | Attempts] ->
    (append (if (> (length Outcomes) 1) ["single-outcome"] [])
            (fr.read-violations Low (remote.reading Config Peer Op A (remote.find-member Peer (remote.members S))) Outcomes)
            (fr.attempt-violations Config S Attempts))
  Config S [[Tag Caller Peer Rid Fate Outcomes Arg] | Attempts] ->
    (append (if (> (length Outcomes) 1) ["single-outcome"] [])
            (fr.reply-violations (fr.record-of S Caller Peer Rid) Arg Outcomes)
            (fr.attempt-violations Config S Attempts)))

(define fr.read-violations
  _ _ [] -> []
  Low High [[reply V] | Outcomes] -> (append (fr.read-check Low High V) (fr.read-violations Low High Outcomes))
  Low High [_ | Outcomes] -> (fr.read-violations Low High Outcomes))

(define fr.read-check
  Low High [int N] -> (let Value (remote.small N)
                        (if (and (>= Value Low) (<= Value High)) [] ["read-reply-from-state"]))
    where (and (number? Low) (number? High))
  _ _ _ -> ["read-reply-from-state"])

(define fr.reply-violations
  _ _ [] -> []
  Record Arg [[reply V] | Outcomes] -> (append (fr.reply-check V Arg Record) (fr.reply-violations Record Arg Outcomes))
  Record Arg [_ | Outcomes] -> (fr.reply-violations Record Arg Outcomes))

\\ Record is [] or [[RecordedPayload Value]]; a payload is the operation and its argument.
(define fr.reply-check
  [tuple [int "0"] V] Arg [[Arg V]] -> []
  [tuple [int "0"] V] _ [[_ V]] -> ["key-bound-to-argument"]
  [tuple [int "1"] [int "0"]] Arg [[Arg _]] -> ["key-bound-to-argument"]
  [tuple [int "1"] [int "0"]] _ [[_ _]] -> []
  _ _ _ -> ["reply-implies-acted"])

(define fr.record-of
  S Caller Peer Rid -> (fr.record-in (remote.find-member Peer (remote.members S)) [Caller Rid]))

(define fr.record-in
  [] _ -> []
  [M] Key -> (remote.assoc Key (fr.log M)))

(define fr.recorded?
  S Caller Peer Rid Expected -> (fr.recorded-in? (remote.find-member Peer (remote.members S)) [Caller Rid] Expected))

(define fr.recorded-in?
  [] _ _ -> false
  [M] Key Expected -> (= (remote.assoc Key (fr.log M)) Expected))

\\ applied-at-most-once: no request id has been applied twice.
(define fr.applied-violations
  [] -> []
  [[_ N] | Rest] -> (append (if (> N 1) ["applied-at-most-once"] []) (fr.applied-violations Rest)))

\\ declared-edges-only: everything a member has been handed, and everything it
\\ has a record of, came along a declared connection.
(define fr.edge-violations
  Edges [] -> []
  Edges [[Name _ [_ Log] [_ _ Inbox]] | Members] ->
    (append (if (fr.any? (/. Entry (not (element? [(hd (tl Entry)) Name] Edges))) Inbox) ["declared-edges-only"] [])
            (if (fr.any? (/. Record (not (element? [(hd (hd Record)) Name] Edges))) Log) ["declared-edges-only"] [])
            (fr.edge-violations Edges Members)))

\\ not-delivered-sealed: after not-delivered for a request id, until the caller issues it
\\ again, the peer has no record of it, has not been handed it, and no copy is in flight.
(define fr.sealed-violations
  S [] -> []
  S [[Caller Peer Rid] | Sealed] ->
    (append (if (or (fr.any? (/. M (remote.request-for? Caller Peer Rid M)) (remote.net S))
                    (not (fr.recorded? S Caller Peer Rid []))
                    (fr.any? (/. Entry (and (= (hd (tl Entry)) Caller) (= (hd (tl (tl Entry))) Rid))) (fr.inbox (fr.member-of Peer S)))
                    (element? [Caller Peer Rid] (fr.given S)))
                ["not-delivered-sealed"] [])
            (fr.sealed-violations S Sealed)))

\\ commit-atomic: the business state and the reply records were committed
\\ together, every time. Read for the ledger peer (examples/remote/ledger-peer.fen,
\\ a peer whose program has the tag "ledger-peer"), whose program gives the store
\\ a meaning the checker can state without running it: cell 0, the total, is the
\\ sum of the arguments of the reply records, and cell 1 is their number. A
\\ commit of the writes without the record, of the record without the writes,
\\ or of a part of the writes breaks it, and so does anything that changes the
\\ store outside a commit. Sums are of small numbers here.
(define fr.atomic-violations
  Config [] -> []
  Config [[Name _ [Store Log] _] | Members] ->
    (append (if (and (= (remote.program-tag (remote.handler Config Name)) "ledger-peer")
                     (not (and (= (remote.small (remote.store-get "0" Store)) (fr.recorded-sum Log))
                               (= (remote.small (remote.store-get "1" Store)) (length Log)))))
                ["commit-atomic"] [])
            (fr.atomic-violations Config Members)))

(define fr.recorded-sum
  [] -> 0
  [[_ [[_ [int A]] _]] | Log] -> (+ (remote.small A) (fr.recorded-sum Log))
  [_ | Log] -> (fr.recorded-sum Log))

(define fr.check-state
  Config S -> (fr.union (append (fr.attempt-violations Config S (hd (remote.ghost S)))
                                (fr.atomic-violations Config (remote.members S))
                                (fr.applied-violations (hd (tl (remote.ghost S))))
                                (fr.edge-violations (remote.edges Config) (remote.members S))
                                (fr.sealed-violations S (hd (tl (tl (remote.ghost S))))))
                        []))

\\ ---------- properties of a step ----------

\\ crash-isolation: a crash or restart of M changes no other member, not M's
\\ durable store, and nothing in flight.
(define fr.others-changed?
  _ [] [] -> false
  Name [[Name _ D _] | Pre] [[Name _ D _] | Post] -> (fr.others-changed? Name Pre Post)
  Name [[Name | _] | _] _ -> true
  Name [M | Pre] [M | Post] -> (fr.others-changed? Name Pre Post)
  _ _ _ -> true)

\\ applied-at-most-once, at the step: acting on a request id that has a reply
\\ record leaves the durable store as it was.
\\ key-bound-to-argument, at the step: the peer says conflict only where the
\\ request id has a record made with another argument, and then the store is
\\ left as it was; and it replays only a record made with this argument.
\\ commit-atomic, at the step: a request whose function trapped commits nothing.
\\ reads-see-own-writes, at the step: what an applied request replies was
\\ computed with its own writes in view. Read for the ledger peer, whose add
\\ writes the total and then replies with what it reads back: the value replied
\\ is the total before plus the argument, not the total before.
(define fr.act-violations
  Config M How Post ->
    (let Entry (hd (fr.inbox M))
         Record (remote.assoc [(hd (tl Entry)) (hd (tl (tl Entry)))] (fr.log M))
         Same (= (fr.durable M) (fr.durable (fr.member-of (hd M) Post)))
         Other (and (cons? Record) (not (= (hd (hd Record)) (nth 4 Entry))))
      (append (if (and (cons? Record) (not Same)) [(if (= How conflict) "key-bound-to-argument" "applied-at-most-once")] [])
              (if (and (= How conflict) (not Other)) ["key-bound-to-argument"] [])
              (if (and (= How replayed) Other) ["key-bound-to-argument"] [])
              (if (and (= How trapped) (not Same)) ["commit-atomic"] [])
              (if (and (= How applied) (= (remote.program-tag (remote.handler Config (hd M))) "ledger-peer"))
                  (fr.own-writes-violations (hd (fr.durable M)) Entry (remote.net Post))
                  []))))

\\ Entry is [Tag Caller Rid [Operation [int Amount]]]; the reply is in flight in Net.
(define fr.own-writes-violations
  Store [Tag Caller Rid [_ [int Amount]]] Net ->
    (if (fr.any? (/. M (fr.reply-of? Tag (remote.ok [int (str (+ (remote.small (remote.store-get "0" Store)) (remote.small Amount)))]) M)) Net)
        [] ["reads-see-own-writes"])
  _ _ _ -> [])

(define fr.reply-of?
  Tag Value [rep Tag _ _ _ Value] -> true
  _ _ _ -> false)

\\ A crash between the commit and the reply (EFFECTS.md §12.3, §12.7). Judged
\\ against the durable store, which is all that survives it:
\\   applied-at-most-once  the request id had no reply record, and the store
\\                         afterwards is the store before plus exactly that one
\\                         application, which is the writes of one run of the
\\                         operation's function on the store before, and its record;
\\   crash-isolation       no other member changes and nothing in flight changes:
\\                         in particular no reply is emitted.
(define fr.rest-changed?
  _ [] [] -> false
  Name [[Name | _] | Pre] [[Name | _] | Post] -> (fr.rest-changed? Name Pre Post)
  Name [M | Pre] [M | Post] -> (fr.rest-changed? Name Pre Post)
  _ _ _ -> true)

\\ The store after one application of a keyed request to Store: the writes of
\\ one run of its function, by the model without any mutant; or the symbol
\\ none where the function does not return status 0.
(define fr.one-application
  [served Program] [Tag Caller Rid [Op Arg]] Store ->
    (fr.applied-store (remote.applied-by (remote.served false Program Op [tuple [int Rid] Arg] Store)) Store)
  _ _ _ -> none)

(define fr.applied-store
  [applied _ Writes] Store -> (remote.store-apply Writes Store)
  _ _ -> none)

(define fr.commit-crash-violations
  Config Name M Pre Post ->
    (let Entry (hd (fr.inbox M))
         Key [(hd (tl Entry)) (hd (tl (tl Entry)))]
         After (fr.member-of Name Post)
      (append (if (or (fr.rest-changed? Name (remote.members Pre) (remote.members Post))
                      (not (= (remote.net Pre) (remote.net Post))))
                  ["crash-isolation"] [])
              (if (and (= (remote.assoc Key (fr.log M)) [])
                       (= (hd (fr.durable After)) (fr.one-application (remote.handler Config Name) Entry (hd (fr.durable M))))
                       (= (remote.unrecord Key (fr.log After)) (fr.log M))
                       (cons? (remote.assoc Key (fr.log After)))
                       (= (hd (hd (remote.assoc Key (fr.log After)))) (nth 4 Entry)))
                  [] ["applied-at-most-once"]))))

\\ not-delivered-not-handed: not-delivered is reported only for a request id of
\\ which no copy was ever handed to the peer, and which was not issued before
\\ the supervisor's latest restart; so the peer has no record of it. The peer
\\ may be up or down.
(define fr.not-delivered-violations
  [Tag Caller Peer Rid | _] Pre ->
    (if (and (not (element? [Caller Peer Rid] (fr.given Pre)))
             (not (element? [Caller Peer Rid] (fr.old Pre)))
             (fr.recorded? Pre Caller Peer Rid []))
        [] ["not-delivered-not-handed"]))

\\ crash-isolation, for the supervisor's own restart: no member changes, not
\\ even its volatile state, and nothing is put in flight.
(define fr.supervisor-restart-violations
  Pre Post -> (if (and (= (remote.members Pre) (remote.members Post))
                       (fr.every-in? (remote.net Post) (remote.net Pre)))
                  [] ["crash-isolation"]))

(define fr.every-in?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (fr.every-in? Xs Ys)))

\\ read-only-changes-nothing: acting on a read-only request leaves the peer's
\\ durable store exactly as it was, every cell and every record; and the peer
\\ says read of a read-only request and of no other (or trapped, when its
\\ function trapped: that changes nothing either).
(define fr.read-act-violations
  M How Post -> (let ReadOnly (remote.read-only? (nth 4 (hd (fr.inbox M))))
                     Same (= (fr.durable M) (fr.durable (fr.member-of (hd M) Post)))
                  (if (and ReadOnly (element? How [read trapped]) Same) [] ["read-only-changes-nothing"])))

(define fr.read-act?
  M How -> (or (= How read) (remote.read-only? (nth 4 (hd (fr.inbox M))))))

\\ read-reply-from-state, at the step that gives the caller the reply: the value
\\ is not more than what the operation answers on the peer's store at that moment.
(define fr.read-delivery-violations
  Config [Tag Caller Peer Rid Fate Outcomes [read-only Op A Low]] V Pre ->
    (fr.read-check Low (remote.reading Config Peer Op A (remote.find-member Peer (remote.members Pre))) V)
  _ _ _ _ -> [])

(define fr.check-step
  Config Pre [crash Name] Post -> (fr.isolation Name Pre Post)
  Config Pre [restart Name] Post -> (fr.isolation Name Pre Post)
  Config Pre [act Name _ How] Post -> (fr.read-act-violations (fr.member-of Name Pre) How Post)
    where (fr.read-act? (fr.member-of Name Pre) How)
  Config Pre [deliver-reply Tag V] Post -> (fr.read-delivery-violations Config (remote.attempt Tag (hd (remote.ghost Pre))) V Pre)
  Config Pre [act Name _ How] Post -> (fr.act-violations Config (fr.member-of Name Pre) How Post)
  Config Pre [supervisor-restart] Post -> (fr.supervisor-restart-violations Pre Post)
  Config Pre [crash-after-commit Name _] Post -> (fr.commit-crash-violations Config Name (fr.member-of Name Pre) Pre Post)
  Config Pre [not-delivered Tag] Post -> (fr.not-delivered-violations (remote.attempt Tag (hd (remote.ghost Pre))) Pre)
  _ _ _ _ -> [])

(define fr.isolation
  Name Pre Post -> (if (or (fr.others-changed? Name (remote.members Pre) (remote.members Post))
                           (not (= (remote.net Pre) (remote.net Post))))
                       ["crash-isolation"] []))

\\ resolved-at-termination: when nothing more can happen, every perform has
\\ exactly one outcome, except those whose caller crashed while waiting, which have none.
(define fr.check-terminal
  S -> (if (fr.any? (/. A (fr.unresolved? A)) (hd (remote.ghost S))) ["resolved-at-termination"] []))

(define fr.unresolved?
  [_ _ _ _ closed [_] _] -> false
  [_ _ _ _ orphaned [] _] -> false
  _ -> true)
