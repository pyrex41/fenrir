\\ Fenrir harness, in Shen: TC1 remote perform (contract spec/tc1/EFFECTS.md §12,
\\ model models/tc1/remote-system.shen). Explores every schedule of a few small
\\ systems, breadth first over the whole reachable state graph, and checks the
\\ contract's properties on every state and every step. The bounds are the
\\ configuration itself: members, scripts, retries, and budgets for crash,
\\ duplicate and supervisor-restart steps. Drops, timeouts, not-delivered,
\\ member restarts and reordering are unbounded.
\\ Then each mutant of the model must violate the property it is aimed at; the
\\ shortest violating schedule is reported. A mutant run that raises an error is
\\ counted as crashed, never as killed.
\\ The properties are checked here, not in the model. They read the model's
\\ history variables (attempts, applications, sealed request ids), which the
\\ model's own steps maintain.
\\ Evidence level: bounded exploration of a model. This file runs no
\\ implementation; harness/tc1-remote-run.shen does. Its report is the remote-model row
\\ of the TC1 gate (harness/tc1-gate.shen).
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

\\ The properties themselves: fr.check-state, fr.check-step, fr.check-terminal.
(load (cn (value fh.*root*) "harness/tc1-remote-properties.shen"))

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
  Config Crashes Duplicates Restarts Stop ->
    (let Fresh (fr.reset)
         S0 (remote.initial-with Config Crashes Duplicates Restarts)
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
       ["not_delivered" [] [emit (N 8) "undelivered" [unit (N 9)]]]
       ["timed_out" [] Retry]]]))

(define fr.tc1-program
  -> [tc1 (remote.tc1-initial
            [handle "1" "Note" [["note" "2" [var "3" "2"]]]
              (fr.tc1-attempt 10 (fr.tc1-attempt 30 [emit "50" "unknown" [unit "51"]]))])
          [["Ledger" "add" p "keyed"]]])

(define fr.payload -> [int "5"])
(define fr.other-payload -> [int "6"])
\\ The payload of a perform of a read-only operation; its script entry has read for a key.
(define fr.read -> [read-only [unit]])

\\ [Name Config Crashes Duplicates SupervisorRestarts Description]
(define fr.systems
  -> [["two-members-one-request"
       [remote-config [[c [script [[p "1" (fr.payload) 1]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 1 0
       "caller c, peer p; one request, retried once after timed-out; 1 crash, 1 duplicate"]
      ["two-members-one-request-two-crashes"
       [remote-config [[c [script [[p "1" (fr.payload) 1]]] [none]] [p [script []] [counter]]] [[c p]] none] 2 0 0
       "the same system; 2 crashes, no duplicate"]
      ["two-members-two-requests"
       [remote-config [[c [script [[p "1" (fr.payload) 1] [p "2" (fr.payload) 0]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 0 0
       "caller c, peer p; two requests, the first retried once; 1 crash, no duplicate"]
      ["three-members-undeclared-edge"
       [remote-config [[c [script [[p "1" (fr.payload) 0] [q "2" (fr.payload) 0]]] [none]] [p [script []] [counter]] [q [script []] [counter]]]
                      [[c p]] none] 2 1 0
       "caller c, peers p and q; c to p declared, c to q not; one request to each; 2 crashes, 1 duplicate"]
      ["two-callers-one-peer"
       [remote-config [[c [script [[p "1" (fr.payload) 0]]] [none]] [d [script [[p "1" (fr.payload) 0]]] [none]] [p [script []] [counter]]]
                      [[c p] [d p]] none] 1 1 0
       "callers c and d, peer p; both use request key 1; 1 crash, 1 duplicate"]
      ["tc1-caller"
       [remote-config [[c (fr.tc1-program) [none]] [p [script []] [counter]]] [[c p]] none] 1 1 0
       "caller c is a tc1 handler-machine program with one retry; peer p; 1 crash, 1 duplicate"]
      ["two-members-supervisor-restart"
       [remote-config [[c [script [[p "1" (fr.payload) 1]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 1 1
       "caller c, peer p; one request, retried once after timed-out; 1 crash, 1 duplicate, 1 supervisor restart"]
      ["two-members-key-reuse"
       [remote-config [[c [script [[p "1" (fr.payload) 0] [p "1" (fr.other-payload) 0]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 1 0
       "caller c, peer p; key 1 performed with one argument and then with another; 1 crash, 1 duplicate"]
      ["two-members-read-alongside"
       [remote-config [[c [script [[p "1" (fr.payload) 0] [p read (fr.read) 0]]] [none]] [p [script []] [counter]]] [[c p]] none] 1 1 0
       "caller c, peer p; a request that changes state, then a read-only one; 1 crash, 1 duplicate"]
      ["storeless-peer-read-only"
       [remote-config [[c [script [[m read (fr.read) 1]]] [none]] [m [script []] [meter]]] [[c m]] none] 1 1 0
       "caller c, peer m with no durable store; one read-only request, retried once after timed-out; 1 crash, 1 duplicate"]])

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
  Mutant [Name Config Crashes Duplicates Restarts Description] ->
    (let R (fr.explore (fr.with-mutant Config Mutant) Crashes Duplicates Restarts false)
         Paths (fr.paths (shen.dict 65536) 1)
         Passed (and (= (nth 6 R) 0) (> (nth 3 R) 0))
      [[object ["system" Name] ["description" Description]
               ["members" (str (length (remote.specs Config)))]
               ["crash_budget" (str Crashes)] ["duplicate_budget" (str Duplicates)] ["supervisor_restart_budget" (str Restarts)]
               ["states" (str (nth 1 R))] ["transitions" (str (nth 2 R))] ["terminal_states" (str (nth 3 R))]
               ["schedules" (fr.big-string (hd Paths))] ["longest_schedule" (str (hd (tl Paths)))]
               ["violations" (str (nth 6 R))]
               ["counterexamples" (map (/. C (fr.counterexample C)) (fr.take-first 2 (nth 5 R)))]
               ["steps" (fr.kinds-json (nth 7 R))]]
       Passed (nth 7 R)]))

\\ [Mutant System ExpectedProperty]
(define fr.mutants
  -> [[not-delivered-after-handover "two-members-one-request" "not-delivered-not-handed"]
      [forged-reply "two-members-one-request" "reply-implies-acted"]
      [non-idempotent-peer "two-members-one-request" "applied-at-most-once"]
      [undeclared-delivery "three-members-undeclared-edge" "declared-edges-only"]
      [late-reply-accepted "two-members-one-request" "single-outcome"]
      [linked-crash "two-members-one-request" "crash-isolation"]
      [purge-by-attempt "two-members-one-request" "not-delivered-sealed"]
      [no-timeout "two-members-one-request" "resolved-at-termination"]
      [reply-before-commit "two-members-one-request" "reply-implies-acted"]
      [forgetful-supervisor-restart "two-members-supervisor-restart" "not-delivered-not-handed"]
      [replay-on-different-argument "two-members-key-reuse" "key-bound-to-argument"]
      [read-only-writes "two-members-read-alongside" "read-only-changes-nothing"]
      [read-ignores-state "two-members-read-alongside" "read-reply-from-state"]])

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
        (let R (fr.explore (fr.with-mutant (nth 2 Sys) Mutant) (nth 3 Sys) (nth 4 Sys) (nth 5 Sys) true)
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
          B (nth 2 (fr.system "two-members-two-requests" (fr.systems)))
          K (nth 2 (fr.system "two-members-key-reuse" (fr.systems)))
          D (nth 2 (fr.system "two-members-read-alongside" (fr.systems)))
          \\ the same system with one retry of the read: too large to explore whole, used by hand schedules only
          DR [remote-config [[c [script [[p "1" (fr.payload) 0] [p read (fr.read) 1]]] [none]] [p [script []] [counter]]] [[c p]] none]
          M (nth 2 (fr.system "storeless-peer-read-only" (fr.systems)))
          Applied [[issue c p "1"] [deliver-request [c 1]] [act p [c 1] applied] [deliver-reply [c 1] (remote.ok [int "1"])]]
          One (remote.ok [int "1"])
          Record1 [1 [[[c "1"] [[int "5"] [int "1"]]]]]
       (append
         \\ the peer is down and nothing was handed over: not-delivered, and the copy in flight is destroyed
         (fr.hand "not-delivered-before-handover"
           (freeze (let R (remote.run A (remote.initial A 1 0) [[crash p] [issue c p "1"] [not-delivered [c 1]]])
                     (and (= (remote.net (hd R)) [])
                          (element? [outcome [c 1] [not-delivered]] (hd (tl R)))
                          (= (fr.log (fr.member-of p (hd R))) [])))))
         \\ the peer is up and nothing was handed over: not-delivered is possible all the same, the copy in
         \\ flight is destroyed, and the peer never acts; a handed-over request leaves only timed-out
         (fr.hand "not-delivered-while-peer-is-up"
           (freeze (let S0 (remote.initial A 0 0)
                        R1 (remote.run A S0 [[issue c p "1"]])
                        Ls (fr.labels A (hd R1))
                        R (remote.run A (hd R1) [[not-delivered [c 1]]])
                        R2 (remote.run A (hd R1) [[deliver-request [c 1]]])
                     (and (= (remote.status p (hd R1)) up)
                          (element? [not-delivered [c 1]] Ls)
                          (= (remote.net (hd R)) [])
                          (element? [outcome [c 1] [not-delivered]] (hd (tl R)))
                          (= (fr.durable (fr.member-of p (hd R))) [0 []])
                          (empty? (fr.labels A (hd R)))
                          (not (element? [not-delivered [c 1]] (fr.labels A (hd R2))))))))
         \\ after hand-over a dead peer gives timed-out only
         (fr.hand "no-not-delivered-after-handover"
           (freeze (let R (remote.run A (remote.initial A 1 0) [[issue c p "1"] [deliver-request [c 1]] [crash p]])
                        Ls (fr.labels A (hd R))
                     (and (element? [timeout [c 1]] Ls) (not (element? [not-delivered [c 1]] Ls))))))
         \\ a retry after timed-out is answered from the record and applied once
         (fr.hand "retry-is-replayed"
           (freeze (let R (remote.run A (remote.initial A 0 0)
                            [[issue c p "1"] [deliver-request [c 1]] [act p [c 1] applied] [timeout [c 1]] [issue c p "1"]
                             [deliver-request [c 2]] [act p [c 2] replayed] [deliver-reply [c 2] One]])
                     (and (= (fr.durable (fr.member-of p (hd R))) Record1)
                          (element? [outcome [c 2] [reply One]] (hd (tl R)))))))
         \\ the peer's record survives its restart; the caller's position does not survive its own
         (fr.hand "durable-record-survives-restart"
           (freeze (let R (remote.run A (remote.initial A 2 0)
                            [[issue c p "1"] [deliver-request [c 1]] [act p [c 1] applied] [crash p] [restart p] [crash c] [restart c]
                             [issue c p "1"] [deliver-request [c 2]] [act p [c 2] replayed]])
                     (= (fr.durable (fr.member-of p (hd R))) Record1))))
         \\ killed between its commit and its reply: the store has the record and nothing is in flight;
         \\ the request was handed over, so no not-delivered; the retry is answered from the record, applied once
         (fr.hand "committed-then-crashed-is-replayed"
           (freeze (let R (remote.run A (remote.initial A 1 0) [[issue c p "1"] [deliver-request [c 1]] [crash-after-commit p [c 1]]])
                        Ls (fr.labels A (hd R))
                        R2 (remote.run A (hd R) [[timeout [c 1]] [restart p] [issue c p "1"] [deliver-request [c 2]]])
                        Ls2 (fr.labels A (hd R2))
                        R3 (remote.run A (hd R2) [[act p [c 2] replayed] [deliver-reply [c 2] One]])
                     (and (= (remote.net (hd R)) [])
                          (= (remote.status p (hd R)) down)
                          (= (fr.durable (fr.member-of p (hd R))) Record1)
                          (element? [timeout [c 1]] Ls) (not (element? [not-delivered [c 1]] Ls))
                          (element? [act p [c 2] replayed] Ls2) (not (element? [act p [c 2] applied] Ls2))
                          (= (fr.durable (fr.member-of p (hd R3))) Record1)
                          (= (hd (tl (hd (hd (tl (remote.ghost (hd R3))))))) 1)
                          (element? [outcome [c 2] [reply One]] (hd (tl R3)))))))
         \\ the supervisor restarts with a request handed over: every message in flight is lost, no member
         \\ changes, and the request counts as handed over, so no not-delivered, with the peer up or down;
         \\ the request already in the peer's inbox is still acted on and its reply is the outcome
         (fr.hand "no-not-delivered-after-supervisor-restart"
           (freeze (let S0 (remote.initial-with A 1 1 1)
                        R1 (remote.run A S0 [[issue c p "1"] [duplicate request [c 1]] [deliver-request [c 1]]])
                        R (remote.run A (hd R1) [[supervisor-restart]])
                        Ls (fr.labels A (hd R))
                        Down (fr.labels A (hd (remote.run A (hd R) [[crash p]])))
                        R2 (remote.run A (hd R) [[act p [c 1] applied] [deliver-reply [c 1] One]])
                     (and (= (length (remote.net (hd R1))) 1)
                          (= (remote.net (hd R)) [])
                          (= (remote.members (hd R)) (remote.members (hd R1)))
                          (element? [timeout [c 1]] Ls) (not (element? [not-delivered [c 1]] Ls))
                          (element? [timeout [c 1]] Down) (not (element? [not-delivered [c 1]] Down))
                          (not (element? [supervisor-restart] Ls))
                          (element? [outcome [c 1] [reply One]] (hd (tl R2)))
                          (= (fr.durable (fr.member-of p (hd R2))) Record1)))))
         \\ the supervisor restarts with a request issued and not handed over: it counts as handed over all
         \\ the same, in this attempt and in the retry; a request id first issued after the restart does not
         (fr.hand "issued-before-supervisor-restart-counts-as-handed"
           (freeze (let S0 (remote.initial-with B 0 0 1)
                        R1 (remote.run B S0 [[issue c p "1"]])
                        Before (fr.labels B (hd R1))
                        R2 (remote.run B (hd R1) [[supervisor-restart]])
                        After (fr.labels B (hd R2))
                        R3 (remote.run B (hd R2) [[timeout [c 1]] [issue c p "1"]])
                        Retry (fr.labels B (hd R3))
                        R4 (remote.run B (hd R3) [[timeout [c 2]] [issue c p "2"]])
                        Fresh (fr.labels B (hd R4))
                        R5 (remote.run B (hd R4) [[not-delivered [c 3]]])
                     (and (element? [not-delivered [c 1]] Before)
                          (= (remote.net (hd R2)) [])
                          (= After [[timeout [c 1]]])
                          (element? [timeout [c 2]] Retry) (not (element? [not-delivered [c 2]] Retry))
                          (element? [not-delivered [c 3]] Fresh)
                          (element? [outcome [c 3] [not-delivered]] (hd (tl R5)))
                          (= (fr.durable (fr.member-of p (hd R5))) [0 []])))))
         \\ a key reused with another argument: conflict, inside the reply; the store is unchanged, and the
         \\ first argument's record still answers a copy of the first request
         (fr.hand "key-reused-with-another-argument-is-a-conflict"
           (freeze (let S0 (remote.initial K 0 1)
                        R1 (remote.run K S0 [[issue c p "1"] [duplicate request [c 1]] [deliver-request [c 1]] [act p [c 1] applied]
                                             [deliver-reply [c 1] One] [issue c p "1"] [deliver-request [c 2]]])
                        Ls (fr.labels K (hd R1))
                        R2 (remote.run K (hd R1) [[act p [c 2] conflict] [deliver-reply [c 2] (remote.conflict)]])
                        R3 (remote.run K (hd R2) [[deliver-request [c 1]] [act p [c 1] replayed]])
                     (and (element? [act p [c 2] conflict] Ls)
                          (not (element? [act p [c 2] replayed] Ls)) (not (element? [act p [c 2] applied] Ls))
                          (not (element? [crash-after-commit p [c 2]] Ls))
                          (= (fr.durable (fr.member-of p (hd R1))) Record1)
                          (= (fr.durable (fr.member-of p (hd R2))) Record1)
                          (element? [outcome [c 2] [reply (remote.conflict)]] (hd (tl R2)))
                          (= (fr.durable (fr.member-of p (hd R3))) Record1)))))
         \\ the same two performs when the first was never delivered: the second is the first application
         \\ of the key, and the record is made with the second argument
         (fr.hand "key-reused-after-not-delivered-is-applied"
           (freeze (let R (remote.run K (remote.initial K 0 0)
                            [[issue c p "1"] [not-delivered [c 1]] [issue c p "1"] [deliver-request [c 2]] [act p [c 2] applied]
                             [deliver-reply [c 2] One]])
                     (and (= (fr.durable (fr.member-of p (hd R))) [1 [[[c "1"] [[int "6"] [int "1"]]]]])
                          (element? [outcome [c 2] [reply One]] (hd (tl R)))))))
         \\ a read-only request: no key, the reply is the value itself, and the store is left exactly as it
         \\ was; a duplicate is evaluated again and records nothing either; no crash between commit and reply
         \\ is offered for it, there being no commit
         (fr.hand "read-only-records-nothing"
           (freeze (let R1 (remote.run D (remote.initial D 1 1) (append Applied [[issue c p "read-2"] [duplicate request [c 2]] [deliver-request [c 2]]]))
                        Ls (fr.labels D (hd R1))
                        R2 (remote.run D (hd R1) [[act p [c 2] read] [deliver-reply [c 2] [int "1"]]])
                        R3 (remote.run D (hd R2) [[deliver-request [c 2]] [act p [c 2] read]])
                     (and (element? [act p [c 2] read] Ls)
                          (not (element? [crash-after-commit p [c 2]] Ls))
                          (element? [crash p] Ls)
                          (= (fr.durable (fr.member-of p (hd R1))) Record1)
                          (= (fr.durable (fr.member-of p (hd R2))) Record1)
                          (element? [outcome [c 2] [reply [int "1"]]] (hd (tl R2)))
                          (= (fr.durable (fr.member-of p (hd R3))) Record1)
                          (element? [rep [c 2] c p "read-2" [int "1"]] (remote.net (hd R3)))
                          (= (hd (tl (remote.ghost (hd R3)))) [[[p c "1"] 1]])))))
         \\ a read handed over to a peer that is then killed: only timed-out; the retry is a new request,
         \\ and the restarted peer, another incarnation, answers it from the store it found
         (fr.hand "read-retried-across-a-peer-restart"
           (freeze (let R1 (remote.run DR (remote.initial DR 1 0) (append Applied [[issue c p "read-2"] [deliver-request [c 2]] [crash p]]))
                        Ls (fr.labels DR (hd R1))
                        R2 (remote.run DR (hd R1) [[timeout [c 2]] [restart p] [issue c p "read-3"] [deliver-request [c 3]] [act p [c 3] read]
                                                  [deliver-reply [c 3] [int "1"]]])
                     (and (element? [timeout [c 2]] Ls) (not (element? [not-delivered [c 2]] Ls))
                          (= (fr.durable (fr.member-of p (hd R2))) Record1)
                          (element? [outcome [c 2] [timed-out]] (hd (tl R2)))
                          (element? [outcome [c 3] [reply [int "1"]]] (hd (tl R2)))
                          (empty? (fr.labels DR (hd R2)))))))
         \\ each perform of a read-only operation is its own request: one that was handed over can only time
         \\ out, and the next one, never handed over, can still be reported not-delivered
         (fr.hand "read-not-delivered-is-per-perform"
           (freeze (let R1 (remote.run DR (remote.initial DR 0 0) (append Applied [[issue c p "read-2"] [deliver-request [c 2]]]))
                        First (fr.labels DR (hd R1))
                        R2 (remote.run DR (hd R1) [[timeout [c 2]] [issue c p "read-3"]])
                        Second (fr.labels DR (hd R2))
                        R3 (remote.run DR (hd R2) [[not-delivered [c 3]]])
                     (and (not (element? [not-delivered [c 2]] First))
                          (element? [not-delivered [c 3]] Second)
                          (element? [outcome [c 3] [not-delivered]] (hd (tl R3)))
                          (not (fr.any? (/. Message (remote.request-for? c p "read-3" Message)) (remote.net (hd R3))))
                          (= (fr.durable (fr.member-of p (hd R3))) Record1)))))
         \\ a peer with no durable store serves a read-only operation, before and after it is killed, and
         \\ has nothing durable at any time
         (fr.hand "storeless-peer-serves-reads"
           (freeze (let R (remote.run M (remote.initial M 1 0)
                            [[issue c m "read-1"] [deliver-request [c 1]] [crash m] [timeout [c 1]] [restart m]
                             [issue c m "read-2"] [deliver-request [c 2]] [act m [c 2] read] [deliver-reply [c 2] [int "0"]]])
                     (and (= (fr.durable (fr.member-of m (hd R))) [0 []])
                          (element? [outcome [c 2] [reply [int "0"]]] (hd (tl R)))
                          (empty? (remote.assembly-refusals M))
                          (empty? (remote.assembly-refusals D))
                          (empty? (remote.assembly-refusals DR))))))
         \\ a peer with no durable store and a request that is not read-only: refused when the system is
         \\ assembled, and so is a connection the manifest lacks; the model has no step for either system
         (fr.hand "storeless-peer-with-a-keyed-operation-is-refused-at-assembly"
           (freeze (let Bad [remote-config [[c [script [[m read (fr.read) 0] [m "1" (fr.payload) 0]]] [none]] [m [script []] [meter]]] [[c m]] none]
                     (and (= (remote.assembly-refusals Bad) [[m no-store c]])
                          (= (remote.assembly-refusals U) [[c q]])
                          (= (trap-error (remote.run Bad (remote.initial Bad 0 0)
                                           [[issue c m "read-1"] [timeout [c 1]] [issue c m "1"] [deliver-request [c 2]] [act m [c 2] applied]])
                                         (/. E refused))
                             refused)))))
         \\ an undeclared connection: nothing in flight, not-delivered at once
         (fr.hand "undeclared-is-refused"
           (freeze (let R (remote.run U (remote.initial U 0 0) [[issue c p "1"] [timeout [c 1]] [refuse c q "2"]])
                     (and (= (length (remote.net (hd R))) 1)
                          (element? [refused [c 2] c q "2"] (hd (tl R)))
                          (element? [outcome [c 2] [not-delivered]] (hd (tl R)))))))
         \\ the tc1 program: reply is matched and its value emitted, then the task ends
         (fr.hand "tc1-reply"
           (freeze (let R (remote.run T (remote.initial T 0 0)
                            [[issue c p "7"] [deliver-request [c 1]] [act p [c 1] applied] [deliver-reply [c 1] One] [finish c]])
                     (and (element? [member c [emit "16" "got" One]] (hd (tl R)))
                          (= (hd (reverse (hd (tl R)))) [member c [task-termination [ok [unit]]]])))))
         \\ the tc1 program retries with the same key and gets the recorded value
         (fr.hand "tc1-retry"
           (freeze (let R (remote.run T (remote.initial T 0 0)
                            [[issue c p "7"] [deliver-request [c 1]] [act p [c 1] applied] [timeout [c 1]] [issue c p "7"]
                             [deliver-request [c 2]] [act p [c 2] replayed] [deliver-reply [c 2] One] [finish c]])
                     (and (element? [member c [emit "36" "got" One]] (hd (tl R)))
                          (= (hd (fr.durable (fr.member-of p (hd R)))) 1)))))
         \\ the tc1 program: two timeouts end in "unknown"
         (fr.hand "tc1-unknown"
           (freeze (let R (remote.run T (remote.initial T 0 0)
                            [[issue c p "7"] [timeout [c 1]] [issue c p "7"] [timeout [c 2]] [finish c]])
                     (element? [member c [emit "50" "unknown" [unit]]] (hd (tl R)))))))))

\\ ---------- main ----------

(define fr.required-kinds
  -> [issue refuse finish deliver-request deliver-reply discard-reply drop duplicate act-applied act-replayed
      act-conflict act-read crash-after-commit timeout not-delivered crash restart supervisor-restart
      outcome-reply outcome-not-delivered outcome-timed-out])

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
                         ["evidence" "bounded exploration of a model; no implementation is run here (see harness/tc1-remote-run.shen)"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["mode" (value fr.*mode*)]
                         ["model_under_check" (if Control "mutant non-idempotent-peer in place of the model" "models/tc1/remote-system.shen")]
                         ["bounds" "whole reachable graph of each system; bounded by its scripts, retries and its crash, duplicate and supervisor-restart budgets; drop, timeout, not-delivered, member restart and reordering unbounded"]
                         ["properties" ["single-outcome" "resolved-at-termination" "reply-implies-acted" "not-delivered-not-handed" "not-delivered-sealed"
                                        "applied-at-most-once" "key-bound-to-argument" "declared-edges-only" "crash-isolation"
                                        "read-only-changes-nothing" "read-reply-from-state"]]
                         ["systems" (map (/. B (hd B)) Baselines)]
                         ["step_kinds_not_exercised" Missing]
                         ["hand_schedules_failed" Hand]
                         ["hand_schedules" (if Control "0" "19")]
                         ["mutants" (map (/. M (hd (tl M))) Mutants)]
                         ["mutants_not_killed" (map (/. M (fh.field "mutant" M)) NotKilled)]
                         ["negative_control" (value fr.*control*)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fr.main)
