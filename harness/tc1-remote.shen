\\ Fenrir harness, in Shen: TC1 remote perform (contract spec/tc1/EFFECTS.md §12,
\\ model models/tc1/remote-system.shen). Explores every schedule of a few small
\\ systems, breadth first over the whole reachable state graph, and checks the
\\ contract's properties on every state and every step. The bounds are the
\\ configuration itself: members, scripts, retries, and budgets for crash and
\\ duplicate steps. Drops, timeouts, restarts and reordering are unbounded.
\\ Then each mutant of the model must violate the property it is aimed at; the
\\ shortest violating schedule is reported. A mutant run that raises an error is
\\ counted as crashed, never as killed.
\\ The properties are checked here, not in the model. They read the model's
\\ history variables (attempts, applications, sealed request ids), which the
\\ model's own steps maintain.
\\ Evidence level: bounded exploration of a model. No supervisor or multi-image
\\ runtime exists. Development evidence only; in no gate.
\\
\\   shen-jit script harness/tc1-remote.shen LIBDIR ROOT check CONTROL
\\   shen-jit script harness/tc1-remote.shen LIBDIR ROOT negative-control
\\
\\ CONTROL is what the runner saw of the negative-control run. In that run the
\\ model is replaced by its non-idempotent mutant, and the report must be a
\\ failure with a failure exit status.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fr.*mode* (hd (tl (tl (tl (value *argv*))))))
(set fr.*control* (if (= (value fr.*mode*) "check") (hd (tl (tl (tl (tl (value *argv*)))))) "none"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "models/tc1/remote-system.shen"))
(load (cn (value fh.*root*) "models/tc1/remote-tc1-caller.shen"))

\\ ---------- counts beyond a fixnum: little-endian limbs of nine digits ----------

(define fr.big-add
  [] [] 0 -> []
  [] [] C -> [C]
  [] Bs C -> (fr.big-add [0] Bs C)
  As [] C -> (fr.big-add As [0] C)
  [A | As] [B | Bs] C -> (let T (+ A (+ B C))
                           (if (>= T 1000000000) [(- T 1000000000) | (fr.big-add As Bs 1)] [T | (fr.big-add As Bs 0)])))

(define fr.pad9
  S -> (if (< (fr.length-of S 0) 9) (fr.pad9 (cn "0" S)) S))

(define fr.length-of
  "" N -> N
  S N -> (fr.length-of (tlstr S) (+ N 1)))

(define fr.big-string
  [] -> "0"
  Limbs -> (fr.big-digits (reverse Limbs)))

(define fr.big-digits
  [Top | Rest] -> (fr.big-rest Rest (str Top)))

(define fr.big-rest
  [] S -> S
  [L | Ls] S -> (fr.big-rest Ls (cn S (fr.pad9 (str L)))))

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

\\ ---------- breadth-first exploration of the reachable state graph ----------

(set fr.*state-limit* 1500000)

(define fr.reset
  -> (do (set fr.*seen* (shen.dict 65536)) (set fr.*succ* (shen.dict 65536))
         (set fr.*states* 0) (set fr.*transitions* 0) (set fr.*terminals* 0)
         (set fr.*kinds* []) (set fr.*found* []) (set fr.*found-count* 0)))

(define fr.kind
  [act _ _ How] -> (concat act- How)
  [Kind | _] -> Kind)

(define fr.note-outcomes
  [] -> done
  [[outcome _ [Kind | _]] | Events] -> (do (set fr.*kinds* (fr.bump (concat outcome- Kind) (value fr.*kinds*))) (fr.note-outcomes Events))
  [_ | Events] -> (fr.note-outcomes Events))

\\ Keep the first few counterexamples of the level they appear at.
(define fr.found
  [] _ -> done
  Violations Path -> (do (set fr.*found-count* (+ 1 (value fr.*found-count*)))
                         (if (< (length (value fr.*found*)) 400) (set fr.*found* [[(reverse Path) Violations] | (value fr.*found*)]) done)))

(define fr.index
  Config S Path -> (let Key (make-string "~S" S)
                        Known (fr.lookup (value fr.*seen*) Key)
                     (if (= Known absent)
                         (let I (set fr.*states* (+ 1 (value fr.*states*)))
                              Limit (if (> I (value fr.*state-limit*)) (error "harness: state limit exceeded") ok)
                              Stored (shen.dict-> (value fr.*seen*) Key I)
                           [I (fr.check-state Config S)])
                         [Known old])))

\\ Expand one state. Next collects the newly discovered states.
(define fr.expand
  Config I S Path [] Succs Next -> (do (shen.dict-> (value fr.*succ*) I Succs) Next)
  Config I S Path [[Label Events S2] | Steps] Succs Next ->
    (let Counted (set fr.*transitions* (+ 1 (value fr.*transitions*)))
         Kinds (set fr.*kinds* (fr.bump (fr.kind Label) (value fr.*kinds*)))
         Outcomes (fr.note-outcomes Events)
         Path2 [Label | Path]
         R (fr.index Config S2 Path2)
         New (not (= (hd (tl R)) old))
         Noted (fr.found (fr.union (fr.check-step Config S Label S2) (if New (hd (tl R)) [])) Path2)
      (fr.expand Config I S Path Steps [(hd R) | Succs] (if New [[(hd R) S2 Path2] | Next] Next))))

(define fr.terminal
  S Path -> (do (set fr.*terminals* (+ 1 (value fr.*terminals*))) (fr.found (fr.check-terminal S) Path)))

\\ One level at a time, so the first level with a violation holds the shortest counterexamples.
(define fr.level
  Config [] [] Depth Stop -> Depth
  Config [] Next Depth Stop -> (if (and Stop (> (value fr.*found-count*) 0)) Depth (fr.level Config Next [] (+ Depth 1) Stop))
  Config [[I S Path] | Frontier] Next Depth Stop ->
    (let Steps (remote.successors Config S)
         Terminal (if (empty? Steps) (fr.terminal S Path) done)
      (fr.level Config Frontier (fr.expand Config I S Path Steps [] Next) Depth Stop)))

\\ Schedules are the maximal paths of the graph. It must be acyclic for the count to exist.
(define fr.paths
  Memo I -> (let M (fr.lookup Memo I)
              (if (= M busy) (error "harness: the state graph has a cycle")
                  (if (= M absent)
                      (let Mark (shen.dict-> Memo I busy)
                           R (fr.paths-over Memo (shen.<-dict (value fr.*succ*) I) [] 0)
                           Store (shen.dict-> Memo I R)
                        R)
                      M))))

\\ Result [Count Longest]: number of maximal paths from here, and the longest.
(define fr.paths-over
  Memo [] [] _ -> [[1] 0]
  Memo [] Count Longest -> [Count (+ Longest 1)]
  Memo [J | Js] Count Longest -> (let R (fr.paths Memo J)
                                   (fr.paths-over Memo Js (fr.big-add Count (hd R) 0) (if (> (hd (tl R)) Longest) (hd (tl R)) Longest))))

\\ Result [States Transitions Terminals Depth Counterexamples ViolationCount Kinds].
(define fr.explore
  Config Crashes Duplicates Stop ->
    (let Fresh (fr.reset)
         S0 (remote.initial Config Crashes Duplicates)
         R0 (fr.index Config S0 [])
         Noted (fr.found (hd (tl R0)) [])
         Depth (fr.level Config [[(hd R0) S0 []]] [] 0 Stop)
      [(value fr.*states*) (value fr.*transitions*) (value fr.*terminals*) Depth
       (reverse (value fr.*found*)) (value fr.*found-count*) (value fr.*kinds*)]))

\\ ---------- the systems explored ----------

\\ A tc1 caller: under a user handler for another effect, perform Ledger.add
\\ with key 7; on timed_out perform it once more with the same key.
(define fr.tc1-attempt
  Base Retry -> (let N (/. K (str (+ Base K)))
    [match (N 0) [perform (N 1) "Ledger" "add" [tuple (N 2) [int (N 3) "7"] [int (N 4) "5"]]]
      [["reply" [(N 5)] [emit (N 6) "got" [var (N 7) (N 5)]]]
       ["peer_down" [] [emit (N 8) "down" [unit (N 9)]]]
       ["timed_out" [] Retry]]]))

(define fr.tc1-program
  -> [tc1 (remote.tc1-initial
            [handle "1" "Note" [["note" "2" [var "3" "2"]]]
              (fr.tc1-attempt 10 (fr.tc1-attempt 30 [emit "50" "unknown" [unit "51"]]))])
          [["Ledger" p]]])

(define fr.payload -> [int "5"])

\\ [Name Config Crashes Duplicates Description]
(define fr.systems
  -> [["two-members-one-request"
       [remote-config [[c [script [[p "1" (fr.payload) 1]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 1
       "caller c, peer p; one request, retried once after timed-out; 1 crash, 1 duplicate"]
      ["two-members-one-request-two-crashes"
       [remote-config [[c [script [[p "1" (fr.payload) 1]]] [none]] [p [script []] [counter]]] [[c p]] none] 2 0
       "the same system; 2 crashes, no duplicate"]
      ["two-members-two-requests"
       [remote-config [[c [script [[p "1" (fr.payload) 1] [p "2" (fr.payload) 0]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 0
       "caller c, peer p; two requests, the first retried once; 1 crash, no duplicate"]
      ["three-members-undeclared-edge"
       [remote-config [[c [script [[p "1" (fr.payload) 0] [q "2" (fr.payload) 0]]] [none]] [p [script []] [counter]] [q [script []] [counter]]]
                      [[c p]] none] 2 1
       "caller c, peers p and q; c to p declared, c to q not; one request to each; 2 crashes, 1 duplicate"]
      ["two-callers-one-peer"
       [remote-config [[c [script [[p "1" (fr.payload) 0]]] [none]] [d [script [[p "1" (fr.payload) 0]]] [none]] [p [script []] [counter]]]
                      [[c p] [d p]] none] 1 1
       "callers c and d, peer p; both use request key 1; 1 crash, 1 duplicate"]
      ["tc1-caller"
       [remote-config [[c (fr.tc1-program) [none]] [p [script []] [counter]]] [[c p]] none] 1 1
       "caller c is a tc1 handler-machine program with one retry; peer p; 1 crash, 1 duplicate"]])

(define fr.system
  Name [[Name | Rest] | _] -> [Name | Rest]
  Name [_ | Systems] -> (fr.system Name Systems))

(define fr.with-mutant
  [remote-config Specs Edges _] Mutant -> [remote-config Specs Edges Mutant])

\\ ---------- reports ----------

(define fr.show
  X -> (make-string "~A" X))

(define fr.counterexample
  [Schedule Violations] -> [object ["properties" Violations] ["length" (str (length Schedule))] ["schedule" (map (/. L (fr.show L)) Schedule)]])

(define fr.kinds-json
  Kinds -> [object | (map (/. K [(str (hd K)) (str (hd (tl K)))]) Kinds)])

(define fr.take-first
  0 _ -> []
  _ [] -> []
  N [X | Xs] -> [X | (fr.take-first (- N 1) Xs)])

\\ Result [Json Passed Kinds].
(define fr.baseline
  Mutant [Name Config Crashes Duplicates Description] ->
    (let R (fr.explore (fr.with-mutant Config Mutant) Crashes Duplicates false)
         Paths (fr.paths (shen.dict 65536) 1)
         Passed (and (= (nth 6 R) 0) (> (nth 3 R) 0))
      [[object ["system" Name] ["description" Description]
               ["members" (str (length (remote.specs Config)))]
               ["crash_budget" (str Crashes)] ["duplicate_budget" (str Duplicates)]
               ["states" (str (nth 1 R))] ["transitions" (str (nth 2 R))] ["terminal_states" (str (nth 3 R))]
               ["schedules" (fr.big-string (hd Paths))] ["longest_schedule" (str (hd (tl Paths)))]
               ["violations" (str (nth 6 R))]
               ["counterexamples" (map (/. C (fr.counterexample C)) (fr.take-first 2 (nth 5 R)))]
               ["steps" (fr.kinds-json (nth 7 R))]]
       Passed (nth 7 R)]))

\\ [Mutant System ExpectedProperty]
(define fr.mutants
  -> [[peer-down-after-handover "two-members-one-request" "peer-down-not-handed"]
      [forged-reply "two-members-one-request" "reply-implies-acted"]
      [non-idempotent-peer "two-members-one-request" "applied-at-most-once"]
      [undeclared-delivery "three-members-undeclared-edge" "declared-edges-only"]
      [late-reply-accepted "two-members-one-request" "single-outcome"]
      [linked-crash "two-members-one-request" "crash-isolation"]
      [purge-by-attempt "two-members-one-request" "peer-down-sealed"]
      [no-timeout "two-members-one-request" "resolved-at-termination"]])

(define fr.aimed
  Expected [] -> []
  Expected [[Schedule Violations] | Rest] -> (if (element? Expected Violations) [[Schedule Violations]] (fr.aimed Expected Rest)))

\\ Killed means: no error, and at the first level with any violation there is a
\\ schedule violating the property the mutant is aimed at.
(define fr.mutant-verdict
  Expected [] -> ["survived" []]
  Expected Found -> (let Aimed (fr.aimed Expected Found)
                      (if (empty? Aimed) ["killed-by-another-property" [(hd Found)]] ["killed" Aimed])))

(define fr.run-mutant
  [Mutant System Expected] ->
    (let Sys (fr.system System (fr.systems))
      (trap-error
        (let R (fr.explore (fr.with-mutant (nth 2 Sys) Mutant) (nth 3 Sys) (nth 4 Sys) true)
             V (fr.mutant-verdict Expected (nth 5 R))
          [(hd V) [object ["mutant" (str Mutant)] ["system" System] ["aimed_at" Expected] ["verdict" (hd V)]
                          ["states_explored" (str (nth 1 R))]
                          ["shortest_counterexample" (map (/. C (fr.counterexample C)) (hd (tl V)))]]])
        (/. E ["crashed" [object ["mutant" (str Mutant)] ["system" System] ["aimed_at" Expected] ["verdict" "crashed"]
                                 ["error" (error-to-string E)]]]))))

\\ ---------- hand schedules: expectations written from the contract ----------

(define fr.labels
  Config S -> (map (/. Step (hd Step)) (remote.successors Config S)))

(define fr.hand
  Name Thunk -> (trap-error (if (thaw Thunk) [] [Name]) (/. E [(cn Name (cn ": " (error-to-string E)))])))

(define fr.hand-schedules
  -> (let A (nth 2 (fr.system "two-members-one-request" (fr.systems)))
          U (nth 2 (fr.system "three-members-undeclared-edge" (fr.systems)))
          T (nth 2 (fr.system "tc1-caller" (fr.systems)))
       (append
         \\ peer down before anything was handed over: peer-down, and the copy in flight is destroyed
         (fr.hand "peer-down-before-handover"
           (freeze (let R (remote.run A (remote.initial A 1 0) [[crash p] [issue c p "1"] [peer-down [c 1]]])
                     (and (= (remote.net (hd R)) [])
                          (element? [outcome [c 1] [peer-down]] (hd (tl R)))
                          (= (fr.log (fr.member-of p (hd R))) [])))))
         \\ after hand-over a dead peer gives timed-out only
         (fr.hand "no-peer-down-after-handover"
           (freeze (let R (remote.run A (remote.initial A 1 0) [[issue c p "1"] [deliver-request [c 1]] [crash p]])
                        Ls (fr.labels A (hd R))
                     (and (element? [timeout [c 1]] Ls) (not (element? [peer-down [c 1]] Ls))))))
         \\ a retry after timed-out is answered from the record and applied once
         (fr.hand "retry-is-replayed"
           (freeze (let R (remote.run A (remote.initial A 0 0)
                            [[issue c p "1"] [deliver-request [c 1]] [act p [c 1] applied] [timeout [c 1]] [issue c p "1"]
                             [deliver-request [c 2]] [act p [c 2] replayed] [deliver-reply [c 2] [int "1"]]])
                     (and (= (fr.durable (fr.member-of p (hd R))) [1 [[[c "1"] [int "1"]]]])
                          (element? [outcome [c 2] [reply [int "1"]]] (hd (tl R)))))))
         \\ the peer's record survives its restart; the caller's position does not survive its own
         (fr.hand "durable-record-survives-restart"
           (freeze (let R (remote.run A (remote.initial A 2 0)
                            [[issue c p "1"] [deliver-request [c 1]] [act p [c 1] applied] [crash p] [restart p] [crash c] [restart c]
                             [issue c p "1"] [deliver-request [c 2]] [act p [c 2] replayed]])
                     (= (fr.durable (fr.member-of p (hd R))) [1 [[[c "1"] [int "1"]]]]))))
         \\ an undeclared connection: nothing in flight, peer-down at once
         (fr.hand "undeclared-is-refused"
           (freeze (let R (remote.run U (remote.initial U 0 0) [[issue c p "1"] [timeout [c 1]] [refuse c q "2"]])
                     (and (= (length (remote.net (hd R))) 1)
                          (element? [refused [c 2] c q "2"] (hd (tl R)))
                          (element? [outcome [c 2] [peer-down]] (hd (tl R)))))))
         \\ the tc1 program: reply is matched and its value emitted, then the task ends
         (fr.hand "tc1-reply"
           (freeze (let R (remote.run T (remote.initial T 0 0)
                            [[issue c p "7"] [deliver-request [c 1]] [act p [c 1] applied] [deliver-reply [c 1] [int "1"]] [finish c]])
                     (and (element? [member c [emit "16" "got" [int "1"]]] (hd (tl R)))
                          (= (hd (reverse (hd (tl R)))) [member c [task-termination [ok [unit]]]])))))
         \\ the tc1 program retries with the same key and gets the recorded value
         (fr.hand "tc1-retry"
           (freeze (let R (remote.run T (remote.initial T 0 0)
                            [[issue c p "7"] [deliver-request [c 1]] [act p [c 1] applied] [timeout [c 1]] [issue c p "7"]
                             [deliver-request [c 2]] [act p [c 2] replayed] [deliver-reply [c 2] [int "1"]] [finish c]])
                     (and (element? [member c [emit "36" "got" [int "1"]]] (hd (tl R)))
                          (= (hd (fr.durable (fr.member-of p (hd R)))) 1)))))
         \\ the tc1 program: two timeouts end in "unknown"
         (fr.hand "tc1-unknown"
           (freeze (let R (remote.run T (remote.initial T 0 0)
                            [[issue c p "7"] [timeout [c 1]] [issue c p "7"] [timeout [c 2]] [finish c]])
                     (element? [member c [emit "50" "unknown" [unit]]] (hd (tl R)))))))))

\\ ---------- main ----------

(define fr.required-kinds
  -> [issue refuse finish deliver-request deliver-reply discard-reply drop duplicate act-applied act-replayed
      timeout peer-down crash restart outcome-reply outcome-peer-down outcome-timed-out])

(define fr.merge-kinds
  [] Acc -> Acc
  [[K N] | Rest] Acc -> (fr.merge-kinds Rest (fr.merge-one K N Acc)))

(define fr.merge-one
  K N [] -> [[K N]]
  K N [[K M] | Rest] -> [[K (+ N M)] | Rest]
  K N [Other | Rest] -> [Other | (fr.merge-one K N Rest)])

(define fr.missing-kinds
  Kinds -> (map (/. K (str K)) (fr.remove-if (/. K (> (fr.tally K Kinds) 0)) (fr.required-kinds))))

(define fr.remove-if
  _ [] -> []
  F [X | Xs] -> (if (F X) (fr.remove-if F Xs) [X | (fr.remove-if F Xs)]))

(define fr.all-kinds
  [] Acc -> Acc
  [[_ _ Kinds] | Rest] Acc -> (fr.all-kinds Rest (fr.merge-kinds Kinds Acc)))

(define fr.every?
  _ [] -> true
  F [X | Xs] -> (if (F X) (fr.every? F Xs) false))

(define fr.main
  -> (let Control (= (value fr.*mode*) "negative-control")
          Baselines (map (/. Sys (fr.baseline (if Control non-idempotent-peer none) Sys)) (if Control [(hd (fr.systems))] (fr.systems)))
          Kinds (fr.all-kinds Baselines [])
          Missing (fr.missing-kinds Kinds)
          Hand (if Control [] (fr.hand-schedules))
          Mutants (if Control [] (map (/. M (fr.run-mutant M)) (fr.mutants)))
          NotKilled (map (/. M (hd (tl M))) (fr.remove-if (/. M (= (hd M) "killed")) Mutants))
          ControlOk (= (value fr.*control*) "failed-as-required")
          Pass (and (not Control) (fr.every? (/. B (hd (tl B))) Baselines) (empty? Missing) (empty? Hand)
                    (empty? NotKilled) ControlOk)
          Report [object ["schema" "fenrir.harness.tc1-remote/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["evidence" "bounded exploration of a model; no implementation exists"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["mode" (value fr.*mode*)]
                         ["model_under_check" (if Control "mutant non-idempotent-peer in place of the model" "models/tc1/remote-system.shen")]
                         ["bounds" "whole reachable graph of each system; bounded by its scripts, retries and its crash and duplicate budgets; drop, timeout, restart and reordering unbounded"]
                         ["properties" ["single-outcome" "resolved-at-termination" "reply-implies-acted" "peer-down-not-handed" "peer-down-sealed"
                                        "applied-at-most-once" "declared-edges-only" "crash-isolation"]]
                         ["systems" (map (/. B (hd B)) Baselines)]
                         ["step_kinds_not_exercised" Missing]
                         ["hand_schedules_failed" Hand]
                         ["hand_schedules" (if Control "0" "8")]
                         ["mutants" (map (/. M (hd (tl M))) Mutants)]
                         ["mutants_not_killed" (map (/. M (fh.field "mutant" M)) NotKilled)]
                         ["negative_control" (value fr.*control*)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fr.main)
