\\ TC1 remote perform: a system of images under one supervisor.
\\ Contract: spec/tc1/EFFECTS.md §12. UNQUALIFIED. A model only. The first
\\ implementation (supervisor/, backends/solo5/remote/) is judged against it by
\\ harness/tc1-remote-run.shen.
\\
\\ A system is a fixed set of members (images), a supervisor that carries every
\\ message between them, and a manifest of the connections it will carry. This
\\ file gives the nondeterministic step relation: remote.successors returns every
\\ enabled step of a state as [Label Events State]. Nothing here checks a
\\ property; harness/tc1-remote.shen explores the relation and checks them.
\\ Self-contained: loads nothing. The tc1 caller plug is remote-tc1-caller.shen.
\\
\\ Config  [remote-config Specs Edges Mutant]
\\   Spec    [Name Program Handler]     static description of one member
\\   Edges   [[Caller Peer] ...]        the manifest: directed, declared connections
\\   Mutant  none, or the name of one deliberate defect (see the end of this header)
\\ State   [Members Net Sup Ghost Budget]
\\   Member  [Name Status Durable Volatile]          Status is up or down
\\   Durable [Count Log]       Count: applications so far (the business state);
\\                             Log: [[Caller Rid] Value] reply records, a sorted set
\\   Volatile [Program Pending Inbox]
\\                             Pending: [] or [Tag Peer Rid], the one remote perform
\\                             this image is suspended in; Inbox: requests handed
\\                             over and not yet acted on, oldest first
\\   Net     sorted multiset of messages held by the supervisor:
\\             [req Tag Caller Peer Rid Payload]   [rep Tag Caller Peer Rid Value]
\\   Sup     [Handed Tags]     Handed: set of [Caller Peer Rid] of which some copy
\\                             was ever handed to the peer; Tags: next attempt
\\                             number per member
\\   Ghost   [Attempts Applied Sealed]   history variables, read only by the checker
\\             Attempt [Tag Caller Peer Rid Fate Outcomes], Fate open/closed/orphaned
\\             Applied [[Peer Caller Rid] N]   real applications per request id
\\             Sealed  [Caller Peer Rid]       peer-down reported, not issued since
\\   Budget  [Crashes Duplicates]   how many crash and duplicate steps remain
\\
\\ A request id is (Caller, Rid): Rid is chosen by the caller program and is the
\\ idempotency key. A Tag [Caller N] names one perform (one attempt); the
\\ supervisor assigns it and never reuses it. Outcomes are [reply V], [peer-down]
\\ and [timed-out]. Rids, and integers inside values, are decimal strings.
\\
\\ Programs. A member's program is behind two functions, remote.next and
\\ remote.resume. [script Entries] is the abstract caller: Entries are
\\ [Peer Rid Payload Retries]; it performs them in order and performs an entry
\\ again, with the same Rid, while it sees timed-out and has retries left.
\\ Handlers. [counter] applies a request by adding one to Count and replies with
\\ the new Count; [none] ignores requests.
\\
\\ How a tc1 machine plugs in. A remote operation is a runtime effect: no user
\\ handler discharges it, the system does. The image runs tc1.step from one
\\ scheduling point to the next (amendment §14: its steps in between commute with
\\ every other image's). When its state is Ready at a perform of an effect that no
\\ frame handles and that the image's bindings map to a peer, remote.next reports
\\ the request and the tc1 state is kept as it is, in this image: the suspended
\\ computation is the frame list, and it never leaves the member. An outcome is
\\ delivered by remote.resume as the value of that perform, which is exactly a
\\ tail-resumptive clause run by the supervisor. remote-tc1-caller.shen does this
\\ for callers. A peer written in tc1 would be one run of a handler function per
\\ inbox entry with its durable effects committed in the act step; not done here.
\\
\\ Mutants (Config's third field), each a defect the checker must catch:
\\   peer-down-after-handover   peer-down reported although the request was handed over
\\   forged-reply               the supervisor answers for a peer that is down
\\   non-idempotent-peer        the peer applies a request id it has a record for
\\   undeclared-delivery        the supervisor carries a connection the manifest lacks
\\   late-reply-accepted        the caller takes a reply for a perform that timed out
\\   linked-crash               a crash resets the callers waiting on the crashed member
\\   purge-by-attempt           peer-down discards only its own attempt's copies
\\   no-timeout                 the timeout never fires

\\ ---------- a total order on terms, for canonical sets ----------

(define remote.rank
  X -> 0 where (number? X)
  X -> 1 where (string? X)
  X -> 2 where (boolean? X)
  X -> 4 where (empty? X)
  X -> 5 where (cons? X)
  _ -> 3)

\\ 0 equal, 1 first is smaller, 2 first is larger.
(define remote.compare-strings
  "" "" -> 0
  "" _ -> 1
  _ "" -> 2
  A B -> (let X (string->n (pos A 0))
              Y (string->n (pos B 0))
           (if (= X Y) (remote.compare-strings (tlstr A) (tlstr B)) (if (< X Y) 1 2))))

(define remote.compare-same
  0 A B -> (if (< A B) 1 2)
  1 A B -> (remote.compare-strings A B)
  5 [A | As] [B | Bs] -> (let C (remote.compare A B) (if (= C 0) (remote.compare As Bs) C))
  _ A B -> (remote.compare-strings (str A) (str B)))

(define remote.compare
  A B -> 0 where (= A B)
  A B -> (let Ra (remote.rank A)
              Rb (remote.rank B)
           (if (= Ra Rb) (remote.compare-same Ra A B) (if (< Ra Rb) 1 2))))

(define remote.insert
  X [] -> [X]
  X [Y | Ys] -> [X Y | Ys] where (not (= (remote.compare X Y) 2))
  X [Y | Ys] -> [Y | (remote.insert X Ys)])

(define remote.insert-set
  X Set -> Set where (element? X Set)
  X Set -> (remote.insert X Set))

(define remote.remove-one
  _ [] -> []
  X [X | Ys] -> Ys
  X [Y | Ys] -> [Y | (remote.remove-one X Ys)])

(define remote.remove-all
  _ [] -> []
  X [X | Ys] -> (remote.remove-all X Ys)
  X [Y | Ys] -> [Y | (remote.remove-all X Ys)])

(define remote.distinct
  [] -> []
  [X X | Xs] -> (remote.distinct [X | Xs])
  [X | Xs] -> [X | (remote.distinct Xs)])

(define remote.concat
  [] -> []
  [L | Ls] -> (append L (remote.concat Ls)))

(define remote.assoc
  _ [] -> []
  K [[K V] | _] -> [V]
  K [_ | Rest] -> (remote.assoc K Rest))

\\ ---------- configuration and state access ----------

(define remote.specs [remote-config Specs _ _] -> Specs)
(define remote.edges [remote-config _ Edges _] -> Edges)
(define remote.mutant [remote-config _ _ Mutant] -> Mutant)
(define remote.mutant? Config Name -> (= (remote.mutant Config) Name))

(define remote.spec
  Name [[Name Program Handler] | _] -> [Name Program Handler]
  Name [_ | Specs] -> (remote.spec Name Specs)
  Name [] -> (error "remote: ~A is not a member" Name))

(define remote.program0 Config Name -> (hd (tl (remote.spec Name (remote.specs Config)))))
(define remote.handler Config Name -> (hd (tl (tl (remote.spec Name (remote.specs Config))))))

(define remote.members [Members _ _ _ _] -> Members)
(define remote.net [_ Net _ _ _] -> Net)
(define remote.sup [_ _ Sup _ _] -> Sup)
(define remote.ghost [_ _ _ Ghost _] -> Ghost)
(define remote.budget [_ _ _ _ Budget] -> Budget)

(define remote.find-member
  Name [[Name | Rest] | _] -> [[Name | Rest]]
  Name [_ | Members] -> (remote.find-member Name Members)
  _ [] -> [])

(define remote.status
  Name S -> (remote.status-of (remote.find-member Name (remote.members S))))

(define remote.status-of
  [[_ Status _ _]] -> Status
  [] -> absent)

(define remote.replace-member
  M [] -> []
  [Name | New] [[Name | _] | Members] -> [[Name | New] | Members]
  M [Other | Members] -> [Other | (remote.replace-member M Members)])

(define remote.set-member
  M [Members Net Sup Ghost Budget] -> [(remote.replace-member M Members) Net Sup Ghost Budget])

(define remote.set-net
  Net [Members _ Sup Ghost Budget] -> [Members Net Sup Ghost Budget])

\\ The state every run starts in: all members up, nothing in flight.
(define remote.initial
  Config Crashes Duplicates ->
    [(map (/. Spec [(hd Spec) up [0 []] [(hd (tl Spec)) [] []]]) (remote.specs Config))
     []
     [[] (map (/. Spec [(hd Spec) 1]) (remote.specs Config))]
     [[] [] []]
     [Crashes Duplicates]])

\\ ---------- programs ----------

\\ remote.next: what the program does when its image is next run.
\\   [halted]                               nothing: it has finished
\\   [halt Program Events]                  it runs to its end, emitting Events
\\   [request Peer Rid Payload Program Events]   it reaches a remote perform
(define remote.next
  [script []] -> [halted]
  [script [[Peer Rid Payload Retries] | Rest]] -> [request Peer Rid Payload [script [[Peer Rid Payload Retries] | Rest]] []]
  [tc1 State Bindings] -> (remote.tc1-next State Bindings))

\\ remote.resume: the program, suspended in a remote perform, given its outcome.
(define remote.resume
  [script [[Peer Rid Payload Retries] | Rest]] [timed-out] -> [script [[Peer Rid Payload (- Retries 1)] | Rest]] where (> Retries 0)
  [script [_ | Rest]] _ -> [script Rest]
  [tc1 State Bindings] Outcome -> (remote.tc1-resume State Bindings Outcome))

(define remote.member-events
  _ [] -> []
  Name [E | Es] -> [[member Name E] | (remote.member-events Name Es)])

\\ ---------- ghost bookkeeping ----------

(define remote.attempt
  Tag [[Tag | Rest] | _] -> [Tag | Rest]
  Tag [_ | Attempts] -> (remote.attempt Tag Attempts)
  Tag [] -> (error "remote: no attempt ~A" Tag))

(define remote.update-attempt
  _ _ [] -> []
  Tag F [[Tag | Rest] | Attempts] -> [(F [Tag | Rest]) | Attempts]
  Tag F [A | Attempts] -> [A | (remote.update-attempt Tag F Attempts)])

(define remote.ghost-attempt
  Tag F [Members Net Sup [Attempts Applied Sealed] Budget] ->
    [Members Net Sup [(remote.update-attempt Tag F Attempts) Applied Sealed] Budget])

(define remote.note-outcome
  Outcome [Tag Caller Peer Rid _ Outcomes] -> [Tag Caller Peer Rid closed (append Outcomes [Outcome])])

(define remote.note-orphan
  [Tag Caller Peer Rid _ Outcomes] -> [Tag Caller Peer Rid orphaned Outcomes])

(define remote.count-application
  Key Applied -> (remote.count-from Key Applied (remote.assoc Key Applied)))

(define remote.count-from
  Key Applied [] -> (remote.insert [Key 1] Applied)
  Key Applied [N] -> (remote.insert [Key (+ N 1)] (remote.remove-one [Key N] Applied)))

\\ ---------- the caller observes an outcome ----------

\\ The image leaves its perform with Outcome as the result. Exactly here the
\\ suspended computation continues, in the image it never left.
(define remote.observe
  Name Tag Outcome S -> (remote.observe-member (remote.find-member Name (remote.members S)) Tag Outcome S))

(define remote.observe-member
  [[Name up Durable [Program _ Inbox]]] Tag Outcome S ->
    (remote.ghost-attempt Tag (/. A (remote.note-outcome Outcome A))
      (remote.set-member [Name up Durable [(remote.resume Program Outcome) [] Inbox]] S)))

\\ ---------- steps of a program: issue, refuse, finish ----------

(define remote.next-tag
  Name [[Name N] | Rest] -> [[Name N] [[Name (+ N 1)] | Rest]]
  Name [Other | Rest] -> (let R (remote.next-tag Name Rest) [(hd R) [Other | (hd (tl R))]]))

(define remote.declared?
  Config Caller Peer -> (or (remote.mutant? Config undeclared-delivery) (element? [Caller Peer] (remote.edges Config))))

(define remote.program-steps
  Config S -> (remote.concat (map (/. M (remote.program-step Config S M)) (remote.members S))))

(define remote.program-step
  Config S [Name up Durable [Program [] Inbox]] -> (remote.perform Config S Name Durable Inbox (remote.next Program))
  _ _ _ -> [])

(define remote.perform
  _ _ _ _ _ [halted] -> []
  Config S Name Durable Inbox [halt Program Events] ->
    [[[finish Name] (remote.member-events Name Events) (remote.set-member [Name up Durable [Program [] Inbox]] S)]]
  Config S Name Durable Inbox [request Peer Rid Payload Program Events] ->
    (let Fresh (remote.next-tag Name (hd (tl (remote.sup S))))
      [(if (remote.declared? Config Name Peer)
           (remote.issue S Name Durable Inbox Peer Rid Payload Program Events (hd Fresh) (hd (tl Fresh)))
           (remote.refuse S Name Durable Inbox Peer Rid Program Events (hd Fresh) (hd (tl Fresh))))]))

\\ The supervisor accepts the request: one copy is in flight and the image waits.
(define remote.issue
  [Members Net [Handed _] [Attempts Applied Sealed] Budget] Name Durable Inbox Peer Rid Payload Program Events Tag Tags ->
    [[issue Name Peer Rid]
     (append (remote.member-events Name Events) [[issued Tag Name Peer Rid]])
     [(remote.replace-member [Name up Durable [Program [Tag Peer Rid] Inbox]] Members)
      (remote.insert [req Tag Name Peer Rid Payload] Net)
      [Handed Tags]
      [(remote.insert [Tag Name Peer Rid open []] Attempts) Applied (remote.remove-all [Name Peer Rid] Sealed)]
      Budget]])

\\ The connection is not in the manifest: nothing is put in flight and the perform
\\ returns peer-down at once.
(define remote.refuse
  [Members Net [Handed _] [Attempts Applied Sealed] Budget] Name Durable Inbox Peer Rid Program Events Tag Tags ->
    [[refuse Name Peer Rid]
     (append (remote.member-events Name Events) [[refused Tag Name Peer Rid] [outcome Tag [peer-down]]])
     [(remote.replace-member [Name up Durable [(remote.resume Program [peer-down]) [] Inbox]] Members)
      Net
      [Handed Tags]
      [(remote.insert [Tag Name Peer Rid closed [[peer-down]]] Attempts) Applied Sealed]
      Budget]])

\\ ---------- steps of the link: deliver, drop, duplicate ----------

(define remote.net-steps
  Config S -> (remote.concat (map (/. M (remote.message-steps Config S M)) (remote.distinct (remote.net S)))))

(define remote.message-steps
  Config S M -> (remote.concat [(remote.deliver Config S M) (remote.drop S M) (remote.duplicate S M)]))

(define remote.message-label
  [req Tag | _] -> [request Tag]
  [rep Tag _ _ _ Value] -> [reply Tag Value])

(define remote.drop
  S M -> [[[drop | (remote.message-label M)] [[dropped | (remote.message-label M)]]
           (remote.set-net (remote.remove-one M (remote.net S)) S)]])

(define remote.duplicate
  [Members Net Sup Ghost [Crashes Duplicates]] M ->
    [[[duplicate | (remote.message-label M)] [[duplicated | (remote.message-label M)]]
      [Members (remote.insert M Net) Sup Ghost [Crashes (- Duplicates 1)]]]] where (> Duplicates 0)
  _ _ -> [])

(define remote.deliver
  Config S [req Tag Caller Peer Rid Payload] ->
    (remote.deliver-request S [req Tag Caller Peer Rid Payload] (remote.find-member Peer (remote.members S)))
  Config S [rep Tag Caller Peer Rid Value] ->
    (remote.deliver-reply Config S [rep Tag Caller Peer Rid Value] (remote.find-member Caller (remote.members S))))

\\ Hand a request to its peer. From here on the supervisor cannot know whether
\\ the peer acted on it, so the request id is recorded as handed over, for good.
(define remote.deliver-request
  [Members Net [Handed Tags] Ghost Budget] [req Tag Caller Peer Rid Payload] [[Peer up Durable [Program Pending Inbox]]] ->
    [[[deliver-request Tag] [[handed Tag Caller Peer Rid]]
      [(remote.replace-member [Peer up Durable [Program Pending (append Inbox [[Tag Caller Rid Payload]])]] Members)
       (remote.remove-one [req Tag Caller Peer Rid Payload] Net)
       [(remote.insert-set [Caller Peer Rid] Handed) Tags]
       Ghost Budget]]]
  _ _ _ -> [])

\\ Give a reply to the caller. It is the outcome of the perform it carries the
\\ tag of, if the caller is still suspended in that perform; otherwise it is stale.
(define remote.deliver-reply
  Config S [rep Tag Caller Peer Rid Value] [[Caller up Durable [Program [Tag | Pending] Inbox]]] ->
    [[[deliver-reply Tag Value] [[outcome Tag [reply Value]]]
      (remote.observe Caller Tag [reply Value] (remote.set-net (remote.remove-one [rep Tag Caller Peer Rid Value] (remote.net S)) S))]]
  Config S [rep Tag Caller Peer Rid Value] [[Caller up | _]] ->
    [[[deliver-reply Tag Value] [[outcome Tag [reply Value]]]
      (remote.ghost-attempt Tag (/. A (remote.note-outcome [reply Value] A))
        (remote.set-net (remote.remove-one [rep Tag Caller Peer Rid Value] (remote.net S)) S))]]
    where (and (remote.mutant? Config late-reply-accepted) (remote.timed-out? (remote.attempt Tag (hd (remote.ghost S)))))
  Config S [rep Tag Caller Peer Rid Value] [[Caller up | _]] ->
    [[[discard-reply Tag Value] [[stale-reply Tag]]
      (remote.set-net (remote.remove-one [rep Tag Caller Peer Rid Value] (remote.net S)) S)]]
  _ _ _ _ -> [])

(define remote.timed-out?
  [_ _ _ _ _ Outcomes] -> (= Outcomes [[timed-out]]))

\\ ---------- the peer acts ----------

(define remote.act-steps
  Config S -> (remote.concat (map (/. M (remote.act Config S M)) (remote.members S))))

(define remote.act
  Config S [Name up [Count Log] [Program Pending [[Tag Caller Rid Payload] | Inbox]]] ->
    (remote.act-on Config S Name Count Log [Program Pending Inbox] Tag Caller Rid Payload
                   (remote.handler Config Name) (remote.assoc [Caller Rid] Log))
  _ _ _ -> [])

(define remote.record
  Key Value Log -> (remote.insert [Key Value] (remote.unrecord Key Log)))

(define remote.unrecord
  _ [] -> []
  Key [[Key _] | Rest] -> Rest
  Key [R | Rest] -> [R | (remote.unrecord Key Rest)])

\\ One atomic step: either the request id has a reply record, which is sent again
\\ and nothing else changes; or the request is applied, its reply recorded, and
\\ the reply sent. Application and record are durable together.
(define remote.act-on
  Config S Name Count Log Volatile Tag Caller Rid Payload [none] _ ->
    [[[act Name Tag ignored] [[acted Tag Name ignored]] (remote.set-member [Name up [Count Log] Volatile] S)]]
  Config S Name Count Log Volatile Tag Caller Rid Payload [counter] [Value] ->
    [[[act Name Tag replayed] [[acted Tag Name replayed Value]]
      (remote.send-reply [rep Tag Caller Name Rid Value] (remote.set-member [Name up [Count Log] Volatile] S))]]
    where (not (remote.mutant? Config non-idempotent-peer))
  Config S Name Count Log Volatile Tag Caller Rid Payload [counter] _ ->
    (let Value [int (str (+ Count 1))]
      [[[act Name Tag applied] [[acted Tag Name applied Value]]
        (remote.applied [Name Caller Rid]
          (remote.send-reply [rep Tag Caller Name Rid Value]
            (remote.set-member [Name up [(+ Count 1) (remote.record [Caller Rid] Value Log)] Volatile] S)))]]))

(define remote.send-reply
  M S -> (remote.set-net (remote.insert M (remote.net S)) S))

(define remote.applied
  Key [Members Net Sup [Attempts Applied Sealed] Budget] ->
    [Members Net Sup [Attempts (remote.count-application Key Applied) Sealed] Budget])

\\ ---------- timeout and peer-down ----------

(define remote.waiting-steps
  Config S -> (remote.concat (map (/. M (remote.waiting Config S M)) (remote.members S))))

(define remote.waiting
  Config S [Name up _ [_ [Tag Peer Rid] _]] ->
    (remote.concat [(remote.timeout Config S Name Tag) (remote.peer-down Config S Name Tag Peer Rid) (remote.forge Config S Name Tag Peer)])
  _ _ _ -> [])

\\ May fire whenever the image is waiting. It says nothing about the peer.
(define remote.timeout
  Config S Name Tag -> [] where (remote.mutant? Config no-timeout)
  Config S Name Tag -> [[[timeout Tag] [[outcome Tag [timed-out]]] (remote.observe Name Tag [timed-out] S)]])

(define remote.request-for?
  Caller Peer Rid [req _ Caller Peer Rid _] -> true
  _ _ _ _ -> false)

(define remote.own-request?
  Tag [req Tag | _] -> true
  _ _ -> false)

(define remote.purge
  _ [] -> []
  F [M | Net] -> (if (F M) (remote.purge F Net) [M | (remote.purge F Net)]))

\\ Enabled only while the peer is down and no copy of this request id was ever
\\ handed to it. The supervisor destroys every copy it still holds, of every
\\ attempt, so the request cannot reach the peer later.
(define remote.peer-down
  Config S Name Tag Peer Rid ->
    [[[peer-down Tag] [[outcome Tag [peer-down]]]
      (remote.seal [Name Peer Rid]
        (remote.observe Name Tag [peer-down]
          (remote.set-net (remote.purge (if (remote.mutant? Config purge-by-attempt)
                                            (/. M (remote.own-request? Tag M))
                                            (/. M (remote.request-for? Name Peer Rid M)))
                                        (remote.net S)) S)))]]
    where (and (= (remote.status Peer S) down)
               (or (remote.mutant? Config peer-down-after-handover)
                   (not (element? [Name Peer Rid] (hd (remote.sup S))))))
  _ _ _ _ _ _ -> [])

(define remote.seal
  Key [Members Net Sup [Attempts Applied Sealed] Budget] ->
    [Members Net Sup [Attempts Applied (remote.insert-set Key Sealed)] Budget])

\\ Mutant only: the supervisor makes up an answer for a peer that is down.
(define remote.forge
  Config S Name Tag Peer ->
    [[[forge-reply Tag] [[outcome Tag [reply [unit]]]] (remote.observe Name Tag [reply [unit]] S)]]
    where (and (remote.mutant? Config forged-reply) (= (remote.status Peer S) down))
  _ _ _ _ _ -> [])

\\ ---------- crash and restart ----------

(define remote.orphan
  [Tag | _] S -> (remote.ghost-attempt Tag (/. A (remote.note-orphan A)) S)
  [] S -> S)

\\ A crash loses the image: its program position, its pending perform and its
\\ inbox. Its durable store, and everything outside the member, is untouched.
(define remote.reset
  Config [Name _ Durable [_ Pending _]] Status S ->
    (remote.orphan Pending (remote.set-member [Name Status Durable [(remote.program0 Config Name) [] []]] S)))

(define remote.crash-steps
  Config S -> (remote.concat (map (/. M (remote.crash Config S M)) (remote.members S))))

(define remote.spend-crash
  [Members Net Sup Ghost [Crashes Duplicates]] -> [Members Net Sup Ghost [(- Crashes 1) Duplicates]])

(define remote.crash
  Config S [Name up Durable Volatile] ->
    [[[crash Name] [[crashed Name]]
      (remote.linked Config Name (remote.members S)
        (remote.spend-crash (remote.reset Config [Name up Durable Volatile] down S)))]]
    where (> (hd (remote.budget S)) 0)
  _ _ _ -> [])

\\ Mutant only: the callers waiting on the crashed member are reset with it.
(define remote.linked
  Config Name [] S -> S
  Config Name [[Other up Durable [Program [Tag Name Rid] Inbox]] | Members] S ->
    (remote.linked Config Name Members (remote.reset Config [Other up Durable [Program [Tag Name Rid] Inbox]] up S))
    where (remote.mutant? Config linked-crash)
  Config Name [_ | Members] S -> (remote.linked Config Name Members S))

\\ The restarted member has its durable store as the crash left it and the
\\ volatile state of a fresh image: its program starts from the beginning.
(define remote.restart-steps
  Config S -> (remote.concat (map (/. M (remote.restart S M)) (remote.members S))))

(define remote.restart
  S [Name down Durable Volatile] -> [[[restart Name] [[restarted Name]] (remote.set-member [Name up Durable Volatile] S)]]
  _ _ -> [])

\\ ---------- the step relation ----------

(define remote.successors
  Config S -> (remote.concat [(remote.program-steps Config S) (remote.net-steps Config S) (remote.act-steps Config S)
                              (remote.waiting-steps Config S) (remote.crash-steps Config S) (remote.restart-steps Config S)]))

\\ Follow a schedule, a list of labels, from S. Result [State Trace]: the state
\\ reached and the observable events in order. A label that is not enabled is an error.
(define remote.run
  Config S Labels -> (remote.run-from Config S Labels []))

(define remote.run-from
  _ S [] Trace -> [S Trace]
  Config S [Label | Labels] Trace -> (remote.take Config Label Labels Trace (remote.successors Config S)))

(define remote.take
  Config Label Labels Trace [[Label Events S] | _] -> (remote.run-from Config S Labels (append Trace Events))
  Config Label Labels Trace [_ | Steps] -> (remote.take Config Label Labels Trace Steps)
  _ Label _ _ [] -> (error "remote: step ~A is not enabled" Label))
