\\ Fenrir harness, in Shen: the properties of remote perform (contract
\\ spec/tc1/EFFECTS.md §12.8), as checks on states and steps of the model
\\ models/tc1/remote-system.shen. Load that model first.
\\ Used by harness/tc1-remote.shen, which explores the model, and by
\\ harness/tc1-remote-run.shen, which replays the event log of a real run
\\ through the model. The properties read the model's history variables
\\ (attempts, applications, sealed request ids), which the model's own steps
\\ maintain.
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

\\ ---------- properties of a state ----------

\\ single-outcome: a perform never has two outcomes.
\\ reply-implies-acted: an observed reply v means the peer's durable log records v for that request id.
(define fr.attempt-violations
  S [] -> []
  S [[Tag Caller Peer Rid Fate Outcomes] | Attempts] ->
    (append (if (> (length Outcomes) 1) ["single-outcome"] [])
            (fr.reply-violations S Caller Peer Rid Outcomes)
            (fr.attempt-violations S Attempts)))

(define fr.reply-violations
  _ _ _ _ [] -> []
  S Caller Peer Rid [[reply V] | Outcomes] ->
    (append (if (fr.recorded? S Caller Peer Rid [V]) [] ["reply-implies-acted"]) (fr.reply-violations S Caller Peer Rid Outcomes))
  S Caller Peer Rid [_ | Outcomes] -> (fr.reply-violations S Caller Peer Rid Outcomes))

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

\\ peer-down-sealed: after peer-down for a request id, until the caller issues it
\\ again, the peer has no record of it, has not been handed it, and no copy is in flight.
(define fr.sealed-violations
  S [] -> []
  S [[Caller Peer Rid] | Sealed] ->
    (append (if (or (fr.any? (/. M (remote.request-for? Caller Peer Rid M)) (remote.net S))
                    (not (fr.recorded? S Caller Peer Rid []))
                    (fr.any? (/. Entry (and (= (hd (tl Entry)) Caller) (= (hd (tl (tl Entry))) Rid))) (fr.inbox (fr.member-of Peer S)))
                    (element? [Caller Peer Rid] (hd (remote.sup S))))
                ["peer-down-sealed"] [])
            (fr.sealed-violations S Sealed)))

(define fr.check-state
  Config S -> (fr.union (append (fr.attempt-violations S (hd (remote.ghost S)))
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
(define fr.act-violations
  M Post -> (if (and (not (= (remote.assoc [(hd (tl (hd (fr.inbox M)))) (hd (tl (tl (hd (fr.inbox M)))))] (fr.log M)) []))
                     (not (= (fr.durable M) (fr.durable (fr.member-of (hd M) Post)))))
                ["applied-at-most-once"] []))

\\ peer-down-not-handed: peer-down is reported only while the peer is down and
\\ only for a request id of which no copy was ever handed to it; so the peer has
\\ no record of it.
(define fr.peer-down-violations
  [Tag Caller Peer Rid | _] Pre ->
    (if (and (= (remote.status Peer Pre) down)
             (not (element? [Caller Peer Rid] (hd (remote.sup Pre))))
             (fr.recorded? Pre Caller Peer Rid []))
        [] ["peer-down-not-handed"]))

(define fr.check-step
  Config Pre [crash Name] Post -> (fr.isolation Name Pre Post)
  Config Pre [restart Name] Post -> (fr.isolation Name Pre Post)
  Config Pre [act Name | _] Post -> (fr.act-violations (fr.member-of Name Pre) Post)
  Config Pre [peer-down Tag] Post -> (fr.peer-down-violations (remote.attempt Tag (hd (remote.ghost Pre))) Pre)
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
  [_ _ _ _ closed [_]] -> false
  [_ _ _ _ orphaned []] -> false
  _ -> true)
