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
\\ Loads nothing. A member's program and a peer's handler are behind functions two
\\ other files define: remote-tc1-caller.shen (a tc1 program as a caller) and
\\ remote-tc1-peer.shen (a peer's program, run by the tc1 machine for each
\\ request). Load both after this file.
\\
\\ Config  [remote-config Specs Edges Mutant]
\\   Spec    [Name Program Handler]     static description of one member
\\   Edges   [[Caller Peer] ...]        the manifest: directed, declared connections
\\   Mutant  none, or the name of one deliberate defect (see the end of this header)
\\ State   [Members Net Sup Ghost Budget]
\\   Member  [Name Status Durable Volatile]          Status is up or down
\\   Durable [Store Log]       Store: the peer's key-value store, [[Key Value] ...] in
\\                             ascending key order, keys and values decimal strings;
\\                             a key that is absent reads 0 (the business state, which
\\                             only the peer's program gives a meaning);
\\                             Log: [[Caller Rid] [Payload Value]] reply records, a
\\                             sorted set: the operation and argument the request id
\\                             was applied with (their digest; here the payload
\\                             itself) and the value replied
\\   Volatile [Program Pending Inbox]
\\                             Pending: [] or [Tag Peer Rid], the one remote perform
\\                             this image is suspended in; Inbox: requests handed
\\                             over and not yet acted on, oldest first
\\   Net     sorted multiset of messages held by the supervisor:
\\             [req Tag Caller Peer Rid Payload]   [rep Tag Caller Peer Rid Value]
\\   Sup     [Handed Tags Issued]
\\                             Handed: set of [Caller Peer Rid] that count as handed
\\                             over: some copy was handed to the peer, or the request
\\                             id was issued before the supervisor's latest restart;
\\                             Tags: next attempt number per member;
\\                             Issued: set of [Caller Peer Rid] ever accepted
\\   Ghost   [Attempts Applied Sealed Given Old]   history variables, read only by the checker
\\             Attempt [Tag Caller Peer Rid Fate Outcomes Payload], Fate open/closed/orphaned;
\\                     for a read-only request Payload is [read-only Op A Low], Low being
\\                     what the operation would have answered on the peer's store when
\\                     the attempt was issued (a number, or none)
\\             Applied [[Peer Caller Rid] N]   real applications per request id
\\             Sealed  [Caller Peer Rid]       not-delivered reported, not issued since
\\             Given   [Caller Peer Rid]       a copy really was handed to the peer
\\             Old     [Caller Peer Rid]       issued before the supervisor's latest restart
\\   Budget  [Crashes Duplicates Restarts]   how many crash, duplicate and
\\                             supervisor-restart steps remain
\\
\\ Acting, and a crash inside it (owner ruling of 15 November 2026, EFFECTS.md
\\ §12.10 question 10). A peer acts in two parts, in this order: the durable
\\ commit (the application and its reply record, together), then the reply. The
\\ step act is both parts with no crash in between. The step crash-after-commit
\\ is the commit followed by the peer's crash before any reply is emitted: the
\\ store has the record, nothing is in flight for it, and no one outside the
\\ peer has seen the action. It is one step and not two because nothing of the
\\ peer can happen between its commit and its reply but the crash, and every
\\ other member's steps commute with that gap. A later copy of the same request
\\ id is then answered from the record (act ... replayed): whether a request was
\\ applied is read from the durable store and from nothing else.
\\
\\ A request id is (Caller, Rid): Rid is chosen by the caller program and is the
\\ idempotency key. A Tag [Caller N] names one perform (one attempt); the
\\ supervisor assigns it and never reuses it. Outcomes are [reply V], [not-delivered]
\\ and [timed-out]. Rids, and integers inside values, are decimal strings.
\\
\\ A reply value V is what the peer's operation returned, and the refusal of a
\\ reused key is inside it (owner ruling of 16 November 2026, EFFECTS.md §12.10
\\ question 8): [tuple [int "0"] Value] is ok with the recorded value,
\\ [tuple [int "1"] [int "0"]] is conflict: the request id has a record made with
\\ another argument. A conflict changes nothing in the store.
\\
\\ not-delivered (rulings on questions 4 and 5). Reported only for a request id
\\ that does not count as handed over, whether the peer is up or down: the
\\ supervisor destroys every copy it still holds. supervisor-restart is the
\\ supervisor losing what it knew: every message in flight is lost, and every
\\ request id issued so far counts as handed over from then on, so only
\\ timed-out or reply is possible for it. Members, their durable stores, their
\\ pending performs and their inboxes are untouched, and the attempt numbering
\\ and the set of issued request ids survive.
\\
\\ Payloads. A request names its operation, "Effect.operation": the payload of a
\\ keyed request is [Operation Argument], and a reply record keeps the payload,
\\ so a key performed again with another operation or another argument is a
\\ conflict.
\\
\\ Read-only operations (owner ruling of 16 November 2026, EFFECTS.md §12.10
\\ question 7). A request whose payload is [read-only Operation Argument] is a
\\ perform of an operation declared read-only. It has no request key: each perform is its
\\ own request, and the supervisor names it "read-N", N being the number of the
\\ attempt, where a keyed request has its key. A program asks for one with the
\\ symbol read in the place of the Rid. The peer answers from its state and
\\ records nothing: the reply value is the value itself, with no
\\ status, since there is no key to conflict on; a duplicate, or a retry, which
\\ is a new request, is evaluated again. There is no commit, so no crash
\\ between a commit and a reply. A peer with no durable store may serve
\\ read-only operations and nothing else.
\\
\\ Programs. A member's program is behind two functions, remote.next and
\\ remote.resume. [script Entries] is the abstract caller: Entries are
\\ [Peer Rid Payload Retries]; it performs them in order and performs an entry
\\ again, with the same Rid, while it sees timed-out and has retries left.
\\ Handlers. [served Peer] is a peer whose operations are implemented by a
\\ program (EFFECTS.md §12.12; owner ruling of 16 November 2026 on §12.10
\\ question 13): what acting does is defined by running that program on the tc1
\\ machine with the store effects (remote-tc1-peer.shen: remote.served gives
\\ the run's outcome and its writes, with reads seeing the request's own
\\ writes). The peer's runtime is here: it replays its record for a request id
\\ it has applied with the same payload, and replies conflict for one it has
\\ applied with another, without running anything; otherwise it runs the
\\ operation's function on tuple(key, argument) and, when that returns
\\ (status 0, value), commits the run's writes and the reply record together
\\ and replies ok value. It answers a read-only request with the value of the
\\ operation's function on the store as it is, and changes nothing. A function
\\ that traps, or a keyed one that returns another status than 0 (only the
\\ runtime says conflict), commits nothing and sends no reply: the step is
\\ act ... trapped. A peer with no durable store (remote.storeless?) has an
\\ empty store for ever, and a system that hands it a keyed request is not one
\\ that may be assembled (remote.assembly-refusals): acting on it is an error
\\ of the model. [none] ignores requests.
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
\\ for callers. A peer's program is one run of the operation's function for each
\\ inbox entry acted on, with its writes committed in the act step
\\ (remote-tc1-peer.shen).
\\
\\ Mutants (Config's third field), each a defect the checker must catch:
\\   not-delivered-after-handover   not-delivered reported although the request was handed over
\\   forged-reply               the supervisor answers for a peer that is down
\\   non-idempotent-peer        the peer applies a request id it has a record for
\\   undeclared-delivery        the supervisor carries a connection the manifest lacks
\\   late-reply-accepted        the caller takes a reply for a perform that timed out
\\   linked-crash               a crash resets the callers waiting on the crashed member
\\   purge-by-attempt           not-delivered discards only its own attempt's copies
\\   no-timeout                 the timeout never fires
\\   reply-before-commit        the peer sends its reply first and commits afterwards
\\   forgetful-supervisor-restart   a restarted supervisor takes nothing as handed over
\\   replay-on-different-argument   the peer answers a reused key from its record
\\                                  although the argument differs
\\   read-only-writes           before a read-only request is served, the peer's runtime
\\                              adds one to cell 0 of the store and commits it
\\   read-ignores-state         a read-only request is answered 0 whatever the store holds
\\   writes-without-record      the commit of an applied request leaves out its reply record
\\   record-without-writes      the commit of an applied request leaves out the program's writes
\\   torn-commit                a crash of a peer whose next act would commit leaves the
\\                              first of that request's writes in the store, and no record:
\\                              a kill inside a commit that is not atomic
\\   stale-reads                a read of the store does not see what its own request has written

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
  Config Crashes Duplicates -> (remote.initial-with Config Crashes Duplicates 0))

\\ The same, with a budget of supervisor restarts.
(define remote.initial-with
  Config Crashes Duplicates Restarts ->
    [(map (/. Spec [(hd Spec) up [[] []] [(hd (tl Spec)) [] []]]) (remote.specs Config))
     []
     [[] (map (/. Spec [(hd Spec) 1]) (remote.specs Config)) []]
     [[] [] [] [] []]
     [Crashes Duplicates Restarts]])

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
  Tag F [Members Net Sup [Attempts | Ghost] Budget] ->
    [Members Net Sup [(remote.update-attempt Tag F Attempts) | Ghost] Budget])

(define remote.note-outcome
  Outcome [Tag Caller Peer Rid _ Outcomes Arg] -> [Tag Caller Peer Rid closed (append Outcomes [Outcome]) Arg])

(define remote.note-orphan
  [Tag Caller Peer Rid _ Outcomes Arg] -> [Tag Caller Peer Rid orphaned Outcomes Arg])

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
  Config S Name Durable Inbox [request Peer Asked Payload Program Events] ->
    (let Fresh (remote.next-tag Name (hd (tl (remote.sup S))))
         Rid (remote.request-id Asked (hd Fresh))
      [(if (remote.declared? Config Name Peer)
           (remote.issue Config S Name Durable Inbox Peer Rid Payload Program Events (hd Fresh) (hd (tl Fresh)))
           (remote.refuse Config S Name Durable Inbox Peer Rid Payload Program Events (hd Fresh) (hd (tl Fresh))))]))

\\ A keyed request is named by its key. A read-only request has none: it is
\\ this one attempt, and is named after the attempt's number.
(define remote.request-id
  read [_ N] -> (cn "read-" (str N))
  Rid _ -> Rid)

(define remote.read-only?
  [read-only | _] -> true
  _ -> false)

\\ What the checker keeps of an attempt's payload: for a read-only request,
\\ also what the operation would answer on the peer's store at the time of issue.
(define remote.ghost-argument
  Config [read-only Op Arg] Peer Members -> [read-only Op Arg (remote.reading Config Peer Op Arg (remote.find-member Peer Members))]
  _ Payload _ _ -> Payload)

\\ What a read-only operation answers on a member's store as it is: a number,
\\ or none when it has no number to give (no such peer, a trap, another type).
(define remote.reading
  Config Peer Op Arg [[_ _ [Store _] _]] -> (remote.reading-of (remote.handler Config Peer) Op Arg Store)
  _ _ _ _ _ -> none)

(define remote.reading-of
  [served Program] Op Arg Store -> (remote.number-of (hd (remote.served false Program Op Arg Store)))
  _ _ _ _ -> none)

(define remote.number-of
  [ok [int N]] -> (remote.small N)
  _ -> none)

\\ The supervisor accepts the request: one copy is in flight and the image waits.
(define remote.issue
  Config [Members Net [Handed _ Issued] [Attempts Applied Sealed Given Old] Budget] Name Durable Inbox Peer Rid Payload Program Events Tag Tags ->
    [[issue Name Peer Rid]
     (append (remote.member-events Name Events) [[issued Tag Name Peer Rid]])
     [(remote.replace-member [Name up Durable [Program [Tag Peer Rid] Inbox]] Members)
      (remote.insert [req Tag Name Peer Rid Payload] Net)
      [Handed Tags (remote.insert-set [Name Peer Rid] Issued)]
      [(remote.insert [Tag Name Peer Rid open [] (remote.ghost-argument Config Payload Peer Members)] Attempts) Applied (remote.remove-all [Name Peer Rid] Sealed) Given Old]
      Budget]])

\\ The connection is not in the manifest: nothing is put in flight and the perform
\\ returns not-delivered at once.
(define remote.refuse
  Config [Members Net [Handed _ Issued] [Attempts | Ghost] Budget] Name Durable Inbox Peer Rid Payload Program Events Tag Tags ->
    [[refuse Name Peer Rid]
     (append (remote.member-events Name Events) [[refused Tag Name Peer Rid] [outcome Tag [not-delivered]]])
     [(remote.replace-member [Name up Durable [(remote.resume Program [not-delivered]) [] Inbox]] Members)
      Net
      [Handed Tags Issued]
      [(remote.insert [Tag Name Peer Rid closed [[not-delivered]] (remote.ghost-argument Config Payload Peer Members)] Attempts) | Ghost]
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
  [Members Net Sup Ghost [Crashes Duplicates Restarts]] M ->
    [[[duplicate | (remote.message-label M)] [[duplicated | (remote.message-label M)]]
      [Members (remote.insert M Net) Sup Ghost [Crashes (- Duplicates 1) Restarts]]]] where (> Duplicates 0)
  _ _ -> [])

(define remote.deliver
  Config S [req Tag Caller Peer Rid Payload] ->
    (remote.deliver-request S [req Tag Caller Peer Rid Payload] (remote.find-member Peer (remote.members S)))
  Config S [rep Tag Caller Peer Rid Value] ->
    (remote.deliver-reply Config S [rep Tag Caller Peer Rid Value] (remote.find-member Caller (remote.members S))))

\\ Hand a request to its peer. From here on the supervisor cannot know whether
\\ the peer acted on it, so the request id is recorded as handed over, for good.
(define remote.deliver-request
  [Members Net [Handed Tags Issued] [Attempts Applied Sealed Given Old] Budget] [req Tag Caller Peer Rid Payload] [[Peer up Durable [Program Pending Inbox]]] ->
    [[[deliver-request Tag] [[handed Tag Caller Peer Rid]]
      [(remote.replace-member [Peer up Durable [Program Pending (append Inbox [[Tag Caller Rid Payload]])]] Members)
       (remote.remove-one [req Tag Caller Peer Rid Payload] Net)
       [(remote.insert-set [Caller Peer Rid] Handed) Tags Issued]
       [Attempts Applied Sealed (remote.insert-set [Caller Peer Rid] Given) Old] Budget]]]
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
  [_ _ _ _ _ Outcomes _] -> (= Outcomes [[timed-out]]))

\\ ---------- the peer acts ----------

(define remote.act-steps
  Config S -> (remote.concat (map (/. M (remote.act Config S M)) (remote.members S))))

(define remote.act
  Config S [Name up [Store Log] [Program Pending [[Tag Caller Rid Payload] | Inbox]]] ->
    (remote.act-on Config S Name Store Log [Program Pending Inbox] Tag Caller Rid Payload
                   (remote.handler Config Name) (remote.assoc [Caller Rid] Log))
  _ _ _ -> [])

\\ A reply record: the payload the request id was applied with, and the value.
(define remote.record
  Key Payload Value Log -> (remote.insert [Key [Payload Value]] (remote.unrecord Key Log)))

\\ The two reply values of a keyed operation.
(define remote.ok Value -> [tuple [int "0"] Value])
(define remote.conflict -> [tuple [int "1"] [int "0"]])

(define remote.unrecord
  _ [] -> []
  Key [[Key _] | Rest] -> Rest
  Key [R | Rest] -> [R | (remote.unrecord Key Rest)])

\\ ---------- the store ----------

\\ A decimal string as a number: for the checker's sums and bounds, on values
\\ that are small. Nothing the model itself does converts a value: an I64 does
\\ not fit a fixnum.
(define remote.small
  (@s "-" Digits) -> (- 0 (remote.digits Digits 0))
  Digits -> (remote.digits Digits 0))

(define remote.digits
  "" N -> N
  (@s D Ds) N -> (remote.digits Ds (+ (* N 10) (- (string->n D) 48))))

\\ Keys in ascending numeric order, decided on their canonical decimal text
\\ (no leading zeros, no negative zero): by sign, then by length, then by digits.
(define remote.negative?
  (@s "-" _) -> true
  _ -> false)

(define remote.magnitude
  (@s "-" Digits) -> Digits
  Digits -> Digits)

(define remote.text-length
  "" N -> N
  S N -> (remote.text-length (tlstr S) (+ N 1)))

(define remote.magnitude<?
  A B -> (let X (remote.text-length A 0)
              Y (remote.text-length B 0)
           (if (= X Y) (= (remote.compare-strings A B) 1) (< X Y))))

(define remote.key<?
  A B -> (if (remote.negative? A)
             (if (remote.negative? B) (remote.magnitude<? (remote.magnitude B) (remote.magnitude A)) true)
             (if (remote.negative? B) false (remote.magnitude<? A B))))

(define remote.store-put
  K V [] -> [[K V]]
  K V [[K _] | Rest] -> [[K V] | Rest]
  K V [[J W] | Rest] -> [[K V] [J W] | Rest] where (remote.key<? K J)
  K V [Cell | Rest] -> [Cell | (remote.store-put K V Rest)])

(define remote.store-get
  K [] -> "0"
  K [[K V] | _] -> V
  K [_ | Rest] -> (remote.store-get K Rest))

\\ A request's writes, [[Key Value] ...], put into the store.
(define remote.store-apply
  [] Store -> Store
  [[K V] | Writes] Store -> (remote.store-apply Writes (remote.store-put K V Store)))

\\ Only the first of them: what a commit that is not atomic can leave behind.
(define remote.first-write
  [] -> []
  [W | _] -> [W])

\\ ---------- the peer's runtime: one request ----------

\\ What a peer's program is, behind remote.served (remote-tc1-peer.shen):
\\ [Tag HasStore Table Codes Names]. Tag names the program, for the checker.
(define remote.storeless?
  [served [_ false | _]] -> true
  _ -> false)

(define remote.program-tag
  [served [Tag | _]] -> Tag
  _ -> none)

\\ What a keyed operation's function made of a request: [applied Value Writes]
\\ when it returned (status 0, Value), [trapped] otherwise. Only the runtime
\\ says conflict, so another status is no reply at all.
(define remote.applied-by
  [[ok [tuple [int "0"] Value]] Writes] -> [applied Value Writes]
  _ -> [trapped])

\\ One step. If the request id has a reply record made with this payload, the
\\ recorded value is sent again and nothing else changes. If it has a record
\\ made with another payload, conflict is sent and nothing changes. Otherwise
\\ the operation's function is run; its writes and the reply record are
\\ committed together (the commit: one atomic durable step), and then the reply
\\ is sent. The commit comes first. remote.commit-crash is the same commit with
\\ a crash in place of the reply.
(define remote.act-on
  Config S Name Store Log Volatile Tag Caller Rid Payload [none] _ ->
    [[[act Name Tag ignored] [[acted Tag Name ignored]] (remote.set-member [Name up [Store Log] Volatile] S)]]
  \\ A read-only request: the operation's function on the store as it is now.
  \\ Nothing is committed and nothing recorded, with or without a durable store.
  Config S Name Store Log Volatile Tag Caller Rid [read-only Op Arg] [served Program] _ ->
    (let Found (if (remote.mutant? Config read-only-writes)
                   (remote.store-put "0" (str (+ 1 (remote.small (remote.store-get "0" Store)))) Store)
                   Store)
      (remote.act-read Config S Name Found Log Volatile Tag Caller Rid
                       (hd (remote.served (remote.mutant? Config stale-reads) Program Op Arg Found))))
  Config S Name Store Log Volatile Tag Caller Rid Payload Handler _ ->
    (error "remote: ~A has no durable store and was handed a request that is not read-only" Name)
    where (remote.storeless? Handler)
  \\ Mutant only: the second half of a reply sent before its commit.
  Config S Name Store Log Volatile Tag Caller Rid [uncommitted Value Payload Writes] [served _] _ ->
    [[[act Name Tag committed] [[acted Tag Name committed (remote.ok Value)]]
      (remote.applied [Name Caller Rid]
        (remote.set-member [Name up [(remote.store-apply Writes Store) (remote.record [Caller Rid] Payload Value Log)] Volatile] S))]]
  Config S Name Store Log Volatile Tag Caller Rid Payload [served _] [[Payload Value]] ->
    [[[act Name Tag replayed] [[acted Tag Name replayed (remote.ok Value)]]
      (remote.send-reply [rep Tag Caller Name Rid (remote.ok Value)] (remote.set-member [Name up [Store Log] Volatile] S))]]
    where (not (remote.mutant? Config non-idempotent-peer))
  \\ Mutant only: the key has a record made with another payload, and the peer replays it.
  Config S Name Store Log Volatile Tag Caller Rid Payload [served _] [[_ Value]] ->
    [[[act Name Tag replayed] [[acted Tag Name replayed (remote.ok Value)]]
      (remote.send-reply [rep Tag Caller Name Rid (remote.ok Value)] (remote.set-member [Name up [Store Log] Volatile] S))]]
    where (remote.mutant? Config replay-on-different-argument)
  \\ The key was applied with another payload: refused, inside the reply. Nothing changes.
  Config S Name Store Log Volatile Tag Caller Rid Payload [served _] [[_ _]] ->
    [[[act Name Tag conflict] [[acted Tag Name conflict (remote.conflict)]]
      (remote.send-reply [rep Tag Caller Name Rid (remote.conflict)] (remote.set-member [Name up [Store Log] Volatile] S))]]
    where (not (remote.mutant? Config non-idempotent-peer))
  Config S Name Store Log Volatile Tag Caller Rid [Op Arg] [served Program] _ ->
    (remote.act-keyed Config S Name Store Log Volatile Tag Caller Rid [Op Arg]
                      (remote.applied-by (remote.served (remote.mutant? Config stale-reads) Program Op [tuple [int Rid] Arg] Store))))

(define remote.act-read
  Config S Name Store Log Volatile Tag Caller Rid [ok Value] ->
    (let Said (if (remote.mutant? Config read-ignores-state) [int "0"] Value)
      [[[act Name Tag read] [[acted Tag Name read Said]]
        (remote.send-reply [rep Tag Caller Name Rid Said] (remote.set-member [Name up [Store Log] Volatile] S))]])
  \\ The function trapped: nothing to reply.
  Config S Name Store Log Volatile Tag Caller Rid _ ->
    [[[act Name Tag trapped] [[acted Tag Name trapped [unit]]] (remote.set-member [Name up [Store Log] Volatile] S)]])

(define remote.act-keyed
  \\ The function trapped, or did not return status 0: nothing is committed and nothing replied.
  Config S Name Store Log Volatile Tag Caller Rid Payload [trapped] ->
    [[[act Name Tag trapped] [[acted Tag Name trapped [unit]]] (remote.set-member [Name up [Store Log] Volatile] S)]]
  \\ Mutant only: the reply goes out and the commit is left for the peer's next
  \\ step, as the head of its inbox. A crash in between loses the commit.
  Config S Name Store Log [Program Pending Inbox] Tag Caller Rid Payload [applied Value Writes] ->
    [[[act Name Tag applied] [[acted Tag Name applied (remote.ok Value)]]
      (remote.send-reply [rep Tag Caller Name Rid (remote.ok Value)]
        (remote.set-member [Name up [Store Log] [Program Pending [[Tag Caller Rid [uncommitted Value Payload Writes]] | Inbox]]] S))]]
    where (remote.mutant? Config reply-before-commit)
  Config S Name Store Log Volatile Tag Caller Rid Payload [applied Value Writes] ->
    [[[act Name Tag applied] [[acted Tag Name applied (remote.ok Value)]]
      (remote.applied [Name Caller Rid]
        (remote.send-reply [rep Tag Caller Name Rid (remote.ok Value)]
          (remote.set-member [Name up (remote.committed Config Store Log [Caller Rid] Payload Value Writes) Volatile] S)))]])

\\ The durable store after the commit of one applied request: the request's
\\ writes and its reply record, together.
(define remote.committed
  Config Store Log Key Payload Value Writes ->
    [(if (remote.mutant? Config record-without-writes) Store (remote.store-apply Writes Store))
     (if (remote.mutant? Config writes-without-record) Log (remote.record Key Payload Value Log))])

(define remote.send-reply
  M S -> (remote.set-net (remote.insert M (remote.net S)) S))

(define remote.applied
  Key [Members Net Sup [Attempts Applied | Ghost] Budget] ->
    [Members Net Sup [Attempts (remote.count-application Key Applied) | Ghost] Budget])

\\ ---------- a crash between the commit and the reply ----------

(define remote.commit-crash-steps
  Config S -> (remote.concat (map (/. M (remote.commit-crash Config S M)) (remote.members S))))

\\ The peer commits the oldest request in its inbox and crashes before it
\\ replies. Enabled where act would apply (no reply record for the request id,
\\ and the operation's function returns status 0) and a crash is left in the
\\ budget. Where act would replay, refuse or trap, a crash before the reply
\\ changes nothing durable and is the step crash. The store keeps the commit,
\\ all of it; the image, with the rest of its inbox, is lost; no reply is in
\\ flight. A crash inside the commit, before it is durable, has committed
\\ nothing: that too is the step crash.
(define remote.commit-crash
  Config S [Name up [Store Log] [Program Pending [[Tag Caller Rid [Op Arg]] | Inbox]]] ->
    (remote.commit-crash-of Config S Name Store Log [Program Pending Inbox] Tag Caller Rid [Op Arg]
                            (remote.applied-by (remote.served (remote.mutant? Config stale-reads) (hd (tl (remote.handler Config Name))) Op [tuple [int Rid] Arg] Store)))
    where (and (> (hd (remote.budget S)) 0)
               (= (hd (remote.handler Config Name)) served)
               (not (remote.storeless? (remote.handler Config Name)))
               (not (= Op read-only)) (not (= Op uncommitted))
               (not (remote.mutant? Config reply-before-commit))
               (= (remote.assoc [Caller Rid] Log) []))
  _ _ _ -> [])

(define remote.commit-crash-of
  Config S Name Store Log Volatile Tag Caller Rid Payload [applied Value Writes] ->
    [[[crash-after-commit Name Tag] [[acted Tag Name committed (remote.ok Value)] [crashed Name]]
      (remote.linked Config Name (remote.members S)
        (remote.spend-crash
          (remote.reset Config [Name up (remote.committed Config Store Log [Caller Rid] Payload Value Writes) Volatile] down
            (remote.applied [Name Caller Rid] S))))]]
  _ _ _ _ _ _ _ _ _ _ _ -> [])

\\ ---------- timeout and not-delivered ----------

(define remote.waiting-steps
  Config S -> (remote.concat (map (/. M (remote.waiting Config S M)) (remote.members S))))

(define remote.waiting
  Config S [Name up _ [_ [Tag Peer Rid] _]] ->
    (remote.concat [(remote.timeout Config S Name Tag) (remote.not-delivered Config S Name Tag Peer Rid) (remote.forge Config S Name Tag Peer)])
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

\\ Enabled only for a request id that does not count as handed over: no copy of
\\ it was ever handed to the peer, and it was not issued before the supervisor's
\\ latest restart. The peer may be up or down. The supervisor destroys every
\\ copy it still holds, of every attempt, so the request cannot reach the peer
\\ later.
(define remote.not-delivered
  Config S Name Tag Peer Rid ->
    [[[not-delivered Tag] [[outcome Tag [not-delivered]]]
      (remote.seal [Name Peer Rid]
        (remote.observe Name Tag [not-delivered]
          (remote.set-net (remote.purge (if (remote.mutant? Config purge-by-attempt)
                                            (/. M (remote.own-request? Tag M))
                                            (/. M (remote.request-for? Name Peer Rid M)))
                                        (remote.net S)) S)))]]
    where (or (remote.mutant? Config not-delivered-after-handover)
              (not (element? [Name Peer Rid] (hd (remote.sup S)))))
  _ _ _ _ _ _ -> [])

(define remote.seal
  Key [Members Net Sup [Attempts Applied Sealed | Ghost] Budget] ->
    [Members Net Sup [Attempts Applied (remote.insert-set Key Sealed) | Ghost] Budget])

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
  [Members Net Sup Ghost [Crashes Duplicates Restarts]] -> [Members Net Sup Ghost [(- Crashes 1) Duplicates Restarts]])

(define remote.crash
  Config S [Name up Durable Volatile] ->
    [[[crash Name] [[crashed Name]]
      (remote.linked Config Name (remote.members S)
        (remote.spend-crash (remote.reset Config [Name up (remote.torn Config Name Durable Volatile) Volatile] down S)))]]
    where (> (hd (remote.budget S)) 0)
  _ _ _ -> [])

\\ A crash leaves the durable store as it is: a commit is durable whole or not
\\ at all, so a kill inside one has committed nothing. Mutant only (torn-commit):
\\ where the peer's next act would commit, the first of that request's writes
\\ is left behind.
(define remote.torn
  Config Name [Store Log] [_ _ [[Tag Caller Rid [Op Arg]] | _]] ->
    (remote.torn-by Store Log (remote.applied-by (remote.served false (hd (tl (remote.handler Config Name))) Op [tuple [int Rid] Arg] Store)))
    where (and (remote.mutant? Config torn-commit)
               (= (hd (remote.handler Config Name)) served)
               (not (remote.storeless? (remote.handler Config Name)))
               (= (remote.assoc [Caller Rid] Log) []))
  _ _ Durable _ -> Durable)

(define remote.torn-by
  Store Log [applied _ Writes] -> [(remote.store-apply (remote.first-write Writes) Store) Log]
  Store Log _ -> [Store Log])

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

\\ ---------- the supervisor restarts ----------

\\ The supervisor loses what it knew (owner ruling of 16 November 2026,
\\ EFFECTS.md §12.10 question 5). Every message in flight is lost. Its record of
\\ hand-overs is lost, so every request id issued so far counts as handed over
\\ from here on: not-delivered is never reported for it again, in this attempt
\\ or a later one. No member changes: not its status, its durable store, the
\\ perform it is suspended in, or its inbox. A pending perform can still be
\\ given a reply (from a request already in the peer's inbox) or timed-out. The
\\ attempt numbering and the set of issued request ids survive.
(define remote.supervisor-restart
  Config [Members Net [Handed Tags Issued] [Attempts Applied Sealed Given Old] [Crashes Duplicates Restarts]] ->
    [[[supervisor-restart] [[supervisor-restarted]]
      [Members []
       [(if (remote.mutant? Config forgetful-supervisor-restart) [] Issued) Tags Issued]
       [Attempts Applied Sealed Given Issued]
       [Crashes Duplicates (- Restarts 1)]]]]
    where (> Restarts 0)
  _ _ -> [])

\\ ---------- assembly ----------

\\ What must hold of a system before any member is started (EFFECTS.md §12.6),
\\ as far as a configuration of abstract callers shows it. Result: the refusals,
\\ [] when the system may be assembled.
\\   [Caller Peer]            a script performs on a connection the manifest lacks
\\   [Peer no-store Caller]   a script sends a request that is not read-only to a
\\                            peer with no durable store
\\ A tc1 caller's requests are not listed here: its image's declaration is
\\ derived from its program by the build, and checked by the real supervisor.
(define remote.assembly-refusals
  Config -> (remote.concat (map (/. Spec (remote.script-refusals Config (hd Spec) (hd (tl Spec)))) (remote.specs Config))))

(define remote.script-refusals
  Config Name [script Entries] -> (remote.distinct-list (remote.concat (map (/. E (remote.entry-refusals Config Name E)) Entries)) [])
  _ _ _ -> [])

(define remote.entry-refusals
  Config Name [Peer _ Payload _] ->
    (append (if (element? [Name Peer] (remote.edges Config)) [] [[Name Peer]])
            (if (and (remote.storeless? (remote.handler Config Peer)) (not (remote.read-only? Payload))) [[Peer no-store Name]] [])))

(define remote.distinct-list
  [] Acc -> (reverse Acc)
  [X | Xs] Acc -> (remote.distinct-list Xs (if (element? X Acc) Acc [X | Acc])))

\\ ---------- the step relation ----------

(define remote.successors
  Config S -> (remote.concat [(remote.program-steps Config S) (remote.net-steps Config S) (remote.act-steps Config S)
                              (remote.waiting-steps Config S) (remote.crash-steps Config S) (remote.commit-crash-steps Config S)
                              (remote.restart-steps Config S) (remote.supervisor-restart Config S)]))

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
