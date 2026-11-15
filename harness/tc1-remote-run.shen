\\ Fenrir harness, in Shen: remote perform, the real system against the model
\\ (contract spec/tc1/EFFECTS.md §12, model models/tc1/remote-system.shen).
\\
\\ The system under check is real: the Erlang/OTP supervisor of supervisor/
\\ running two Solo5 guests as OS processes under the spt tender, a caller image
\\ (the TC1 program of fixtures/tc1/remote-caller.mjs on the C machine) and the
\\ counter peer image, built by tools/solo5/remote-build.mjs. For each schedule
\\ this file starts that system, lets the supervisor follow the schedule, and
\\ then judges what was recorded:
\\   (a) the supervisor's event log is replayed through the model, step by step:
\\       every recorded step must be enabled in the model, and the set of steps
\\       the supervisor considered enabled must be the model's set;
\\   (b) the contract's properties (harness/tc1-remote-properties.shen) must
\\       hold in every state and on every step of that replay;
\\   (c) what the guests printed on their consoles must be what the model says
\\       they observe: the caller's outcomes, its requests and its TC1 events,
\\       per incarnation; the peer's actions and the store it found at each boot;
\\       and the peer's store file at the end must be the model's durable store.
\\ The model's caller is the same program, read from the build's program.json
\\ and run by models/tc1/handler-machine.shen (models/tc1/remote-tc1-caller.shen).
\\ Every scheduled run is made twice and the two recordings must be equal.
\\ Then each defect switch of the supervisor or the peer must be killed: its
\\ recorded run must fail (a), (b) or (c). A run that ends in an error is
\\ counted as crashed, never as killed.
\\
\\ Evidence level: observed histories of one small system on the spt tender,
\\ accepted by the model. No hvt run, no proof. Development evidence; in no gate.
\\
\\   shen-jit script harness/tc1-remote-run.shen LIBDIR ROOT BUILD EBIN ERL WORK check CONTROL
\\   shen-jit script harness/tc1-remote-run.shen LIBDIR ROOT BUILD EBIN ERL WORK negative-control
\\ BUILD  directory written by tools/solo5/remote-build.mjs
\\ EBIN   directory of the compiled supervisor;  ERL  the erl executable
\\ WORK   an existing empty directory for the runs' files
\\ CONTROL is what the runner saw of the negative-control run, in which the
\\ non-idempotent peer stands in for the peer: the report must be a failure
\\ with a failure exit status.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fx.*args* (tl (tl (tl (value *argv*)))))
(set fx.*build* (cn (nth 1 (value fx.*args*)) "/"))
(set fx.*ebin* (nth 2 (value fx.*args*)))
(set fx.*erl* (nth 3 (value fx.*args*)))
(set fx.*work* (cn (nth 4 (value fx.*args*)) "/"))
(set fx.*mode* (nth 5 (value fx.*args*)))
(set fx.*control* (if (= (value fx.*mode*) "check") (nth 6 (value fx.*args*)) "none"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "models/tc1/remote-system.shen"))
(load (cn (value fh.*root*) "models/tc1/remote-tc1-caller.shen"))
(load (cn (value fh.*root*) "harness/tc1-remote-properties.shen"))

(set fx.*info* (json.parse (read-file-as-string (cn (value fx.*build*) "build.json")) []))
(set fx.*program* (json.parse (read-file-as-string (fh.field "program" (value fx.*info*))) [[byte-limit 16777216]]))
(set fx.*seeds* 40)
(set fx.*runs* 0)

\\ ---------- labels: the model's terms and the supervisor's JSON ----------

(define fx.number
  S -> (let N (tc0.i64.small S) (if (< N 0) (error "harness: not a small number ~S" S) N)))

(define fx.tag [C N] -> [C (fx.number N)])
(define fx.tag-json [C N] -> [C (str N)])

\\ Values on the wire are I64 in wire format version 1.
(define fx.val
  ["int" N] -> [int N]
  V -> (error "harness: unexpected value ~S" V))

(define fx.label
  ["issue" C P R] -> [issue C P R]
  ["refuse" C P R] -> [refuse C P R]
  ["finish" N] -> [finish N]
  ["deliver-request" T] -> [deliver-request (fx.tag T)]
  ["deliver-reply" T V] -> [deliver-reply (fx.tag T) (fx.val V)]
  ["discard-reply" T V] -> [discard-reply (fx.tag T) (fx.val V)]
  ["drop" "request" T] -> [drop request (fx.tag T)]
  ["drop" "reply" T V] -> [drop reply (fx.tag T) (fx.val V)]
  ["duplicate" "request" T] -> [duplicate request (fx.tag T)]
  ["duplicate" "reply" T V] -> [duplicate reply (fx.tag T) (fx.val V)]
  ["act" N T "applied"] -> [act N (fx.tag T) applied]
  ["act" N T "replayed"] -> [act N (fx.tag T) replayed]
  ["timeout" T] -> [timeout (fx.tag T)]
  ["peer-down" T] -> [peer-down (fx.tag T)]
  ["crash" N] -> [crash N]
  ["restart" N] -> [restart N]
  L -> (error "harness: unknown event ~S" L))

(define fx.label-json
  [issue C P R] -> ["issue" C P R]
  [refuse C P R] -> ["refuse" C P R]
  [finish N] -> ["finish" N]
  [deliver-request T] -> ["deliver-request" (fx.tag-json T)]
  [deliver-reply T V] -> ["deliver-reply" (fx.tag-json T) (fh.value V)]
  [discard-reply T V] -> ["discard-reply" (fx.tag-json T) (fh.value V)]
  [drop request T] -> ["drop" "request" (fx.tag-json T)]
  [drop reply T V] -> ["drop" "reply" (fx.tag-json T) (fh.value V)]
  [duplicate request T] -> ["duplicate" "request" (fx.tag-json T)]
  [duplicate reply T V] -> ["duplicate" "reply" (fx.tag-json T) (fh.value V)]
  [act N T How] -> ["act" N (fx.tag-json T) (str How)]
  [timeout T] -> ["timeout" (fx.tag-json T)]
  [peer-down T] -> ["peer-down" (fx.tag-json T)]
  [crash N] -> ["crash" N]
  [restart N] -> ["restart" N]
  L -> (error "harness: no JSON for the label ~S" L))

\\ A step as the supervisor names it before taking it: an act does not say yet
\\ whether it applies or replays, and handing a reply to the caller is one step
\\ whether the reply turns out to be the outcome or stale.
(define fx.before
  [act N T _] -> ["act" N (fx.tag-json T)]
  [discard-reply T V] -> ["deliver-reply" (fx.tag-json T) (fh.value V)]
  L -> (fx.label-json L))

(define fx.kind-of
  [act _ _ How] -> (concat act- How)
  [Kind | _] -> Kind)

\\ ---------- small helpers ----------

(define fx.subset?
  [] _ -> true
  [X | Xs] Ys -> (and (element? X Ys) (fx.subset? Xs Ys)))

(define fx.same-set?
  Xs Ys -> (and (fx.subset? Xs Ys) (fx.subset? Ys Xs)))

(define fx.prefix?
  [] _ -> true
  [X | Xs] [X | Ys] -> (fx.prefix? Xs Ys)
  _ _ -> false)

(define fx.keep
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (fx.keep F Xs)] (fx.keep F Xs)))

(define fx.every?
  _ [] -> true
  F [X | Xs] -> (if (F X) (fx.every? F Xs) false))

(define fx.count
  X [] -> 0
  X [X | Ys] -> (+ 1 (fx.count X Ys))
  X [_ | Ys] -> (fx.count X Ys))

(define fx.show
  X -> (make-string "~S" X))

(define fx.sum
  [] -> 0
  [N | Ns] -> (+ N (fx.sum Ns)))

\\ ---------- the model of the system that was built ----------

\\ The caller's program is the artifact the caller image was lowered from, and
\\ its bindings are the image's. The peer is the model's counter.
(define fx.config
  Edges Mutant -> [remote-config [["caller" [tc1 (fh.state (value fx.*program*)) (fh.field "bindings" (value fx.*info*))] [none]]
                                  ["peer" [script []] [counter]]]
                                 Edges Mutant])

\\ ---------- replaying a recorded event log through the model ----------

(define fx.find
  _ [] -> []
  L [[L Events S] | _] -> [[L Events S]]
  L [_ | Steps] -> (fx.find L Steps))

\\ The model's enabled steps as the supervisor would name them. In the free-running
\\ mode a crash is not a step the supervisor can take, only one it can find has
\\ happened, so it does not list crashes there.
(set fx.*free* false)

(define fx.model-enabled
  Steps -> (let All (map (/. Step (fx.before (hd Step))) Steps)
             (if (value fx.*free*) (fx.keep (/. L (not (= (hd L) "crash"))) All) All)))

\\ Enabled is what the supervisor recorded as enabled before each step, or the
\\ symbol unchecked. A crash the free-running supervisor found, rather than
\\ took, is recorded with "unobserved" in place of the set.
(define fx.enabled-agree?
  _ unchecked -> true
  _ ["unobserved" | _] -> true
  Steps [E | _] -> (fx.same-set? (fx.model-enabled Steps) E)
  _ _ -> false)

(define fx.rest
  unchecked -> unchecked
  [_ | Es] -> Es
  [] -> [])

\\ Result [Verdict Detail State Trace Boots Violations].
\\   accepted         every step was enabled in the model and no property failed
\\   rejected         Detail [Index Label ModelLabels]: the step is not a step of the model
\\   enabled-differs  Detail [Index ModelLabels SupervisorLabels]
\\   violated         Violations is the list of [Index Properties]
\\ Boots: [Name Durable] for each restart, the store the model says the member finds.
(define fx.replay
  Config S [] Enabled I Trace Boots Violations -> [(if (empty? Violations) accepted violated) [] S Trace (reverse Boots) (reverse Violations)]
  Config S [L | Ls] Enabled I Trace Boots Violations ->
    (let Steps (remote.successors Config S)
      (fx.replay-step Config S L Ls Enabled I Trace Boots Violations Steps (fx.find L Steps))))

(define fx.replay-step
  Config S L Ls Enabled I Trace Boots Violations Steps [] ->
    [rejected [I L (map (/. Step (hd Step)) Steps)] S Trace (reverse Boots) (reverse Violations)]
  \\ The step is the model's. Was the supervisor's view of what else could happen the model's too?
  Config S L Ls Enabled I Trace Boots Violations Steps _ ->
    [enabled-differs [I (fx.model-enabled Steps) (if (cons? Enabled) (hd Enabled) [])] S Trace (reverse Boots) (reverse Violations)]
    where (not (fx.enabled-agree? Steps Enabled))
  Config S L Ls Enabled I Trace Boots Violations Steps [[_ Events S2]] ->
    (let V (fr.union (fr.check-step Config S L S2) (fr.check-state Config S2))
      (fx.replay Config S2 Ls (fx.rest Enabled) (+ I 1) (append Trace Events)
                 (fx.note-boot L S2 Boots)
                 (if (empty? V) Violations [[I V] | Violations]))))

(define fx.note-boot
  [restart Name] S Boots -> [[Name (fr.durable (fr.member-of Name S))] | Boots]
  _ _ Boots -> Boots)

\\ ---------- what the model says each image observes ----------

\\ The trace cut into the incarnations of member M: a new one starts at its restart.
(define fx.segments
  M [] Current Acc -> (reverse [(reverse Current) | Acc])
  M [[restarted M] | Es] Current Acc -> (fx.segments M Es [] [(reverse Current) | Acc])
  M [E | Es] Current Acc -> (fx.segments M Es [E | Current] Acc))

(define fx.outcome-json
  [reply V] -> ["reply" (fh.value V)]
  [peer-down] -> ["peer_down"]
  [timed-out] -> ["timed_out"])

(define fx.model-outcomes
  M [] -> []
  M [[outcome [M _] O] | Es] -> [(fx.outcome-json O) | (fx.model-outcomes M Es)]
  M [_ | Es] -> (fx.model-outcomes M Es))

(define fx.model-events
  M [] -> []
  M [[member M E] | Es] -> [(fh.event E) | (fx.model-events M Es)]
  M [_ | Es] -> (fx.model-events M Es))

(define fx.model-requests
  M [] -> []
  M [[issued _ M P R] | Es] -> [[P R] | (fx.model-requests M Es)]
  M [[refused _ M P R] | Es] -> [[P R] | (fx.model-requests M Es)]
  M [_ | Es] -> (fx.model-requests M Es))

(define fx.model-finished?
  M Segment -> (fr.any? (/. E (fx.termination? M E)) Segment))

(define fx.termination?
  M [member M [task-termination _]] -> true
  _ _ -> false)

\\ [Caller Rid How Value] for each action of peer M, with the request id of the attempt.
(define fx.model-acts
  M Attempts [] -> []
  M Attempts [[acted Tag M How V] | Es] ->
    (let A (remote.attempt Tag Attempts)
      [[(hd (tl A)) (hd (tl (tl (tl A)))) (str How) (fh.value V)] | (fx.model-acts M Attempts Es)])
  M Attempts [_ | Es] -> (fx.model-acts M Attempts Es))

\\ ---------- what the images printed ----------

\\ "FGRUN/1 " then a decimal length, a newline, exactly that many payload bytes, a
\\ newline. Lines that do not start with FG are tender diagnostics and are skipped.
\\ (The frame reader of harness/solo5-pure-call.shen, which is a program and cannot be loaded.)
(define fx.frame-prefix?
  V I End -> (and (<= (+ I 8) End)
                  (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71) (= (buffer.u8 V (+ I 2)) 82)
                  (= (buffer.u8 V (+ I 3)) 85) (= (buffer.u8 V (+ I 4)) 78) (= (buffer.u8 V (+ I 5)) 47)
                  (= (buffer.u8 V (+ I 6)) 49) (= (buffer.u8 V (+ I 7)) 32)))

(define fx.fg-line?
  V I End -> (and (<= (+ I 2) End) (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71)))

(define fx.length-field
  V I End N Digits -> (error "harness: truncated frame header") where (>= I End)
  V I End N Digits -> (if (> Digits 0) [N (+ I 1)] (error "harness: empty frame length")) where (= (buffer.u8 V I) 10)
  V I End N Digits ->
    (let B (buffer.u8 V I)
      (if (and (>= B 48) (<= B 57) (< Digits 9))
          (fx.length-field V (+ I 1) End (+ (* N 10) (- B 48)) (+ Digits 1))
          (error "harness: invalid frame length"))))

(define fx.scan
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (if (fx.frame-prefix? V I End)
        (let Header (fx.length-field V (+ I 8) End 0 0)
             N (hd Header)
             Start (hd (tl Header))
          (if (and (< (+ Start N) End) (= (buffer.u8 V (+ Start N)) 10))
              (fx.scan V (+ Start (+ N 1)) End
                       [(json.decode (buffer.slice V Start N) [[byte-limit 1048576]]) | Acc])
              (error "harness: frame length does not match its payload")))
        (if (fx.fg-line? V I End)
            (error "harness: unknown FG frame")
            (fx.scan V (fh.next-line V I End) End Acc))))

(define fx.frames
  File -> (let V (buffer.from-string (read-file-as-string File)) (fx.scan V 0 (buffer.length V) [])))

\\ The consoles of member M, one list of frames per incarnation, in order.
(define fx.consoles
  M R -> (map (/. C (fx.frames (fh.field "file" C)))
              (fx.keep (/. C (= (fh.field "member" C) M)) (fh.field "consoles" R))))

(define fx.of-kind
  Kind Frames -> (fx.keep (/. F (= (fh.member "kind" F) Kind)) Frames))

(define fx.guest-events
  [] -> []
  [F | Fs] -> (append (fh.field "events" (fh.field "sample" F)) (fx.guest-events Fs)))

\\ ---------- (c): the consoles against the model's observations ----------

\\ Each check returns [] or a list with one description of the difference.
(define fx.differ
  true _ -> []
  false What -> [What])

(define fx.caller-incarnation
  M I Segment Frames ->
    (let Hello (fx.of-kind "Hello" Frames)
         Outcomes (map (/. F (fh.field "outcome" F)) (fx.of-kind "Outcome" Frames))
         Requests (map (/. F [(fh.field "peer" F) (fh.field "key" F)]) (fx.of-kind "Remote" Frames))
         Events (fx.guest-events (fx.of-kind "Step" Frames))
         ModelEvents (fx.model-events M Segment)
         Where (make-string "~A incarnation ~A: " M I)
      (append
        (fx.differ (and (= (length Hello) 1) (= (fh.field "incarnation" (hd Hello)) (str I)) (= (fh.field "role" (hd Hello)) "caller"))
                   (cn Where "hello frame"))
        (fx.differ (empty? (fx.of-kind "Fault" Frames)) (cn Where (cn "the image reported a fault: " (fx.show (fx.of-kind "Fault" Frames)))))
        \\ every outcome the supervisor reported, and no other, reached the program
        (fx.differ (= Outcomes (fx.model-outcomes M Segment))
                   (cn Where (make-string "outcomes printed ~S, model ~S" Outcomes (fx.model-outcomes M Segment))))
        \\ the image may have run past the model's last step for it: it runs until its next scheduling point
        (fx.differ (fx.prefix? (fx.model-requests M Segment) Requests) (cn Where "requests"))
        (fx.differ (fx.prefix? ModelEvents Events) (cn Where "tc1 events"))
        (fx.differ (or (not (fx.model-finished? M Segment)) (= ModelEvents Events)) (cn Where "tc1 events of a finished program")))))

(define fx.peer-incarnation
  M I Segment Frames Attempts Durable ->
    (let Hello (fx.of-kind "Hello" Frames)
         Acts (map (/. F [(fh.field "caller" F) (fh.field "key" F) (fh.field "how" F) (fh.field "value" F)]) (fx.of-kind "Act" Frames))
         Where (make-string "~A incarnation ~A: " M I)
      (append
        (fx.differ (and (= (length Hello) 1) (= (fh.field "incarnation" (hd Hello)) (str I)) (= (fh.field "role" (hd Hello)) "peer"))
                   (cn Where "hello frame"))
        (fx.differ (empty? (fx.of-kind "Fault" Frames)) (cn Where "the image reported a fault"))
        \\ the store the image found when it started is the model's durable store at that point
        (fx.differ (and (= (length Hello) 1)
                        (= (fh.field "applications" (hd Hello)) (str (hd Durable)))
                        (= (fh.field "records" (hd Hello)) (str (length (hd (tl Durable))))))
                   (cn Where "store found at start"))
        (fx.differ (= Acts (fx.model-acts M Attempts Segment))
                   (cn Where (make-string "actions printed ~S, model ~S" Acts (fx.model-acts M Attempts Segment)))))))

(define fx.caller-all
  M I [] [] -> []
  M I [S | Ss] [F | Fs] -> (append (fx.caller-incarnation M I S F) (fx.caller-all M (+ I 1) Ss Fs))
  M I _ _ -> [(make-string "~A: the number of consoles is not the number of incarnations" M)])

(define fx.peer-all
  M I [] [] _ _ -> []
  M I [S | Ss] [F | Fs] Attempts [D | Ds] -> (append (fx.peer-incarnation M I S F Attempts D) (fx.peer-all M (+ I 1) Ss Fs Attempts Ds))
  M I _ _ _ _ -> [(make-string "~A: the number of consoles is not the number of incarnations" M)])

(define fx.boots-of
  M [] -> []
  M [[M D] | Bs] -> [D | (fx.boots-of M Bs)]
  M [_ | Bs] -> (fx.boots-of M Bs))

\\ The peer's store file, as the supervisor read it after the run, against the model's durable store.
(define fx.store-differences
  M [Count Log] [] -> ["no store was reported"]
  M [Count Log] [Store | _] ->
    (fx.differ (and (= (fh.field "applications" Store) (str Count))
                    (fx.same-set? (fh.field "records" Store) (map (/. Rec [(hd (hd Rec)) (hd (tl (hd Rec))) (fh.value (hd (tl Rec)))]) Log))
                    (= (length (fh.field "records" Store)) (length Log)))
               (make-string "~A: the store file holds ~S, the model ~S ~S" M Store Count Log)))

(define fx.observations
  R Final Trace Boots ->
    (let Attempts (hd (remote.ghost Final))
      (append (fx.caller-all "caller" 1 (fx.segments "caller" Trace [] []) (fx.consoles "caller" R))
              (fx.peer-all "peer" 1 (fx.segments "peer" Trace [] []) (fx.consoles "peer" R) Attempts
                           [[0 []] | (fx.boots-of "peer" Boots)])
              (fx.store-differences "peer" (fr.durable (fr.member-of "peer" Final))
                                    (fx.keep (/. S (= (fh.field "member" S) "peer")) (fh.field "stores" R))))))

\\ ---------- the judgement of one run ----------

(define fx.budget
  Key Schedule -> (let V (fh.member Key Schedule) (if (= V []) 0 (fx.number V))))

\\ The model's crash budget for a run. A schedule states it. A free run has
\\ none: there it is the number of crashes that were found to have happened.
(define fx.crash-budget
  Schedule Labels -> (if (= (fh.field "mode" Schedule) "free")
                         (fx.count crash (map (/. L (hd L)) Labels))
                         (fx.budget "crashes" Schedule)))

\\ Result [Verdict Detail Info], Info [Labels Outcomes Terminal] when the log could be replayed.
\\   "accepted"            (a), (b) and (c) hold
\\   "rejected"            a recorded step is not a step of the model
\\   "enabled-differs"     the supervisor's enabled steps are not the model's
\\   "violated"            a property fails on the replay
\\   "observations-differ" the consoles or the store are not what the model says
\\   "error"               the run did not produce a judgeable record; never a kill
(define fx.judge
  Edges Mutant R -> (trap-error (fx.judge-run Edges Mutant R) (/. E ["error" (error-to-string E) []])))

(define fx.judge-run
  Edges Mutant R -> ["error" (make-string "the run ended in an error: ~A" (fh.member "error" R)) []] where (= (fh.field "status" R) "error")
  Edges Mutant R ->
    (let Config (fx.config Edges Mutant)
         Schedule (fh.field "schedule" R)
         Labels (map (/. E (fx.label E)) (fh.field "events" R))
         Free (set fx.*free* (= (fh.field "mode" Schedule) "free"))
         S0 (remote.initial Config (fx.crash-budget Schedule Labels) (fx.budget "duplicates" Schedule))
         V0 (fr.check-state Config S0)
         P (fx.replay Config S0 Labels (if (= Mutant none) (fh.field "enabled" R) unchecked) 0 [] [] (if (empty? V0) [] [[initial V0]]))
         Final (nth 3 P)
         Trace (nth 4 P)
         Rest (remote.successors Config Final)
         Terminal (empty? Rest)
         Info [Labels (fx.model-outcomes "caller" Trace) Terminal]
      (fx.verdict Mutant R P Rest Info)))

(define fx.verdict
  Mutant R [rejected [I L Enabled] | _] _ Info ->
    ["rejected" (make-string "step ~A, ~S, is not enabled in the model; the model's steps there: ~S" I L Enabled) Info]
  Mutant R [enabled-differs [I Model Supervisor] | _] _ Info ->
    ["enabled-differs" (make-string "before step ~A the model enables ~S and the supervisor ~S" I Model Supervisor) Info]
  Mutant R [violated _ _ _ _ Violations] _ Info ->
    ["violated" (make-string "~S" Violations) Info]
  Mutant R [accepted _ Final Trace Boots _] Rest Info ->
    (let AtEnd (fx.differ (or (not (= Mutant none)) (not (fh.field "settled" R))
                              (fx.same-set? (fx.model-enabled Rest) (fh.field "enabled_at_end" R)))
                          "the steps enabled at the end are not the model's")
         Unresolved (if (empty? Rest) (fr.check-terminal Final) [])
         \\ Refused at start: no image ran, so there is nothing to compare.
         Seen (if (and (= Mutant none) (not (= (fh.field "status" R) "refused-at-start"))) (fx.observations R Final Trace Boots) [])
      (if (not (empty? Unresolved))
          ["violated" (make-string "at the end: ~S" Unresolved) Info]
          (if (not (empty? AtEnd))
              ["enabled-differs" (hd AtEnd) Info]
              (if (empty? Seen) ["accepted" "" Info] ["observations-differ" (hd Seen) Info])))))

\\ ---------- running the real system ----------

(define fx.manifest
  Edges -> [object ["members" [[object ["name" "caller"] ["kind" "caller"] ["image" (fh.field "caller" (value fx.*info*))]]
                              [object ["name" "peer"] ["kind" "peer"] ["image" (fh.field "peer" (value fx.*info*))]]]]
                   ["connections" Edges]])

\\ One run of the supervisor: the decoded result.json, or an error record.
(define fx.execute
  Name Edges Schedule Defects StartCheck ->
    (let Dir (cn (value fx.*work*) Name)
         Spec [object ["dir" Dir] ["tender" (fh.field "tender" (value fx.*info*))] ["manifest" (fx.manifest Edges)]
                      ["schedule" Schedule] ["defects" Defects] ["start_check" StartCheck] ["life_ms" "60000"]]
         Count (set fx.*runs* (+ 1 (value fx.*runs*)))
         Ran (fh.exec (value fx.*erl*) ["-noshell" "-pa" (value fx.*ebin*) "-run" "fenrir_main" "main" "-extra"
                                        (json.stringify Spec [[byte-limit 1048576]])] 120)
      (trap-error (json.parse (read-file-as-string (cn Dir "/result.json")) [[byte-limit 67108864]])
                  (/. E [object ["status" "error"] ["error" (make-string "no result: exit ~A ~A" (hd Ran) (hd (tl (tl Ran))))]
                                ["events" []] ["consoles" []] ["stores" []]]))))

(define fx.list-schedule
  Steps -> [object ["mode" "list"] ["crashes" (str (fx.count crash (map (/. L (hd L)) Steps)))]
                   ["duplicates" (str (fx.count duplicate (map (/. L (hd L)) Steps)))]
                   ["steps" (map (/. L (fx.label-json L)) Steps)]])

\\ What two runs of one schedule must have in common: everything but file names.
(define fx.recording
  R -> [(fh.field "status" R) (fh.field "events" R) (fh.member "enabled" R) (fh.member "enabled_at_end" R) (fh.member "stores" R)
        (trap-error (map (/. C [(fh.field "member" C) (fh.field "incarnation" C) (fh.field "exit" C) (fx.frames (fh.field "file" C))])
                         (fh.field "consoles" R))
                    (/. E unreadable))])

\\ Run twice. Result [R Same?].
(define fx.twice
  Name Edges Schedule Defects StartCheck ->
    (let A (fx.execute (cn Name "-a") Edges Schedule Defects StartCheck)
         B (fx.execute (cn Name "-b") Edges Schedule Defects StartCheck)
      [A (= (fx.recording A) (fx.recording B))]))

\\ ---------- hand schedules: expectations written from the contract ----------

(define fx.declared -> [["caller" "peer"]])

\\ [Name Edges StartCheck Steps ExpectedStatus ExpectedOutcomes ExpectedApplications Why]
\\ ExpectedOutcomes: what the caller's program must be given, in order, over all
\\ its incarnations. The recorded log must be exactly Steps (or, when the status
\\ is step-not-enabled, Steps without the last one).
(define fx.hand
  -> (let C "caller"
          P "peer"
          T (/. N [C N])
          One [int "1"]
          Two [int "2"]
          \\ the second request, from issue to reply, as attempt N
          Second (/. N [[issue C P "8"] [deliver-request (T N)] [act P (T N) applied] [deliver-reply (T N) Two] [finish C]])
       [["plain-reply" (fx.declared) true
         (append [[issue C P "7"] [deliver-request (T 1)] [act P (T 1) applied] [deliver-reply (T 1) One]] (Second 2))
         "completed" [["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "a request is handed over, applied, and its reply is the outcome"]
        ["request-dropped-timeout-retry" (fx.declared) true
         (append [[issue C P "7"] [drop request (T 1)] [timeout (T 1)]
                  [issue C P "7"] [deliver-request (T 2)] [act P (T 2) applied] [deliver-reply (T 2) One]] (Second 3))
         "completed" [["timed_out"] ["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "the request is lost; timed-out; the retry with the same key is applied"]
        ["reply-dropped-timeout-retry-replayed" (fx.declared) true
         (append [[issue C P "7"] [deliver-request (T 1)] [act P (T 1) applied] [drop reply (T 1) One] [timeout (T 1)]
                  [issue C P "7"] [deliver-request (T 2)] [act P (T 2) replayed] [deliver-reply (T 2) One]] (Second 3))
         "completed" [["timed_out"] ["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "the reply is lost; timed-out; the retry is answered from the record and applied once"]
        ["peer-killed-before-handover" (fx.declared) true
         [[crash P] [issue C P "7"] [peer-down (T 1)] [issue C P "8"] [peer-down (T 2)] [finish C] [restart P]]
         "completed" [["peer_down"] ["peer_down"]] 0
         "the peer is down and nothing was handed over: peer-down, and the peer never acts"]
        ["peer-killed-after-handover-before-acting" (fx.declared) true
         (append [[issue C P "7"] [deliver-request (T 1)] [crash P] [timeout (T 1)] [restart P]
                  [issue C P "7"] [deliver-request (T 2)] [act P (T 2) applied] [deliver-reply (T 2) One]] (Second 3))
         "completed" [["timed_out"] ["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "killed with the request in its inbox: only timed-out; after the restart the retry is applied"]
        ["peer-killed-after-acting-store-intact" (fx.declared) true
         (append [[issue C P "7"] [deliver-request (T 1)] [act P (T 1) applied] [crash P] [drop reply (T 1) One] [timeout (T 1)] [restart P]
                  [issue C P "7"] [deliver-request (T 2)] [act P (T 2) replayed] [deliver-reply (T 2) One]] (Second 3))
         "completed" [["timed_out"] ["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "killed after it applied: timed-out; the restarted peer has its record and replays it"]
        ["no-peer-down-after-handover" (fx.declared) true
         [[issue C P "7"] [deliver-request (T 1)] [crash P] [peer-down (T 1)]]
         "step-not-enabled" [] 0
         "after a hand-over the supervisor does not offer peer-down, even with the peer down"]
        ["duplicate-applied-once" (fx.declared) true
         (append [[issue C P "7"] [duplicate request (T 1)] [deliver-request (T 1)] [deliver-request (T 1)]
                  [act P (T 1) applied] [act P (T 1) replayed] [deliver-reply (T 1) One] [discard-reply (T 1) One]] (Second 2))
         "completed" [["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "two copies of one request are handed over: applied once, replayed once; the second reply is stale"]
        ["late-reply-discarded" (fx.declared) true
         (append [[issue C P "7"] [deliver-request (T 1)] [act P (T 1) applied] [timeout (T 1)]
                  [issue C P "7"] [discard-reply (T 1) One]
                  [deliver-request (T 2)] [act P (T 2) replayed] [deliver-reply (T 2) One]] (Second 3))
         "completed" [["timed_out"] ["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "the reply arrives after timed-out, while the caller waits in its retry: discarded, not shown"]
        ["caller-restarts-from-the-beginning" (fx.declared) true
         (append [[issue C P "7"] [deliver-request (T 1)] [act P (T 1) applied] [crash C] [restart C]
                  [issue C P "7"] [discard-reply (T 1) One]
                  [deliver-request (T 2)] [act P (T 2) replayed] [deliver-reply (T 2) One]] (Second 3))
         "completed" [["reply" ["int" "1"]] ["reply" ["int" "2"]]] 2
         "a caller that crashed while waiting gets no outcome; restarted, it performs again and is answered from the record"]
        ["undeclared-refused-at-start" [] true
         []
         "refused-at-start" [] none
         "the caller's program declares a connection the manifest lacks: nothing is started"]
        ["undeclared-refused-at-run-time" [] false
         [[refuse C P "7"] [refuse C P "8"] [finish C]]
         "completed" [["peer_down"] ["peer_down"]] 0
         "the backstop, with the start-time check switched off: nothing in flight, peer-down at once"]]))

(define fx.drop-last
  [_] -> []
  [X | Xs] -> [X | (fx.drop-last Xs)]
  [] -> [])

(define fx.applications
  R -> (let Stores (fh.member "stores" R)
         (if (cons? Stores) (fx.number (fh.field "applications" (hd Stores))) none)))

\\ Failures of one hand schedule, as text; [] when it passes. Result [Json Failures Labels].
(define fx.run-hand
  Defects [Name Edges StartCheck Steps Status Outcomes Applications Why] ->
    (let T (fx.twice Name Edges (fx.list-schedule Steps) Defects StartCheck)
         R (hd T)
         J (fx.judge Edges none R)
         Info (hd (tl (tl J)))
         Refused (= Status "refused-at-start")
         Expected (if (= Status "step-not-enabled") (fx.drop-last Steps) Steps)
         Failures (append
                    (fx.differ (hd (tl T)) "two runs of the schedule were recorded differently")
                    (fx.differ (= (fh.field "status" R) Status) (make-string "status ~A, expected ~A" (fh.field "status" R) Status))
                    (fx.differ (= (hd J) "accepted") (cn (hd J) (cn ": " (hd (tl J)))))
                    (if (cons? Info)
                        (append (fx.differ (= (hd Info) Expected) "the recorded steps are not the schedule's")
                                (fx.differ (= (hd (tl Info)) Outcomes) (make-string "outcomes ~S, expected ~S" (hd (tl Info)) Outcomes)))
                        [])
                    (fx.differ (= (fx.applications R) Applications) (make-string "applications ~S, expected ~S" (fx.applications R) Applications))
                    \\ refused at start: the missing connection is named and no image was started
                    (fx.differ (or (not Refused)
                                   (and (= (fh.field "refusals" R) (fx.declared)) (empty? (fh.field "consoles" R)) (empty? (fh.field "events" R))))
                               "a refusal at start must name the connection and start nothing")
                    \\ not enabled: the refused step is the last one, and the model does not enable it either
                    (fx.differ (or (not (= Status "step-not-enabled")) (not (= (fh.field "status" R) Status))
                                   (= (fh.field "step" (fh.field "not_enabled" R)) (fx.label-json (hd (reverse Steps)))))
                               "the step that was not enabled is not the expected one"))
      [[object ["schedule" Name] ["contract" Why] ["status" (fh.field "status" R)] ["verdict" (hd J)]
               ["steps" (str (length (fh.field "events" R)))]
               ["outcomes" (if (cons? Info) (hd (tl Info)) [])]
               ["terminal" (if (cons? Info) (hd (tl (tl Info))) false)]
               ["failures" Failures]]
       Failures
       (if (cons? Info) (hd Info) [])]))

\\ ---------- seeded schedules ----------

(define fx.seeded-schedule
  Seed -> [object ["mode" "seeded"] ["seed" (str Seed)] ["crashes" "1"] ["duplicates" "1"] ["max_steps" "120"]])

\\ Result [Seed Failures Labels Terminal Outcomes].
(define fx.run-seed
  Seed ->
    (let T (fx.twice (cn "seed-" (str Seed)) (fx.declared) (fx.seeded-schedule Seed) [] true)
         R (hd T)
         J (fx.judge (fx.declared) none R)
         Info (hd (tl (tl J)))
         Failures (append
                    (fx.differ (hd (tl T)) "two runs of the seed were recorded differently")
                    (fx.differ (= (fh.field "status" R) "completed") (cn "status " (fh.field "status" R)))
                    (fx.differ (= (hd J) "accepted") (cn (hd J) (cn ": " (hd (tl J))))))
      [Seed Failures (if (cons? Info) (hd Info) []) (if (cons? Info) (hd (tl (tl Info))) false) (if (cons? Info) (hd (tl Info)) [])]))

(define fx.seeds
  N N -> []
  I N -> [(fx.run-seed (+ I 1)) | (fx.seeds (+ I 1) N)])

\\ ---------- defects ----------

\\ [Defect Edges StartCheck Steps ModelMutant Property What]
\\ Each defect is a switch of the real supervisor or of the real peer image. The
\\ model mutant named with it is the same defect in the model; the property is
\\ the one that mutant violates in harness/tc1-remote.shen.
(define fx.defects
  -> (let C "caller"
          P "peer"
          T (/. N [C N])
       [["peer-down-after-handover" (fx.declared) true
         [[issue C P "7"] [deliver-request (T 1)] [crash P] [peer-down (T 1)]]
         peer-down-after-handover "peer-down-not-handed"
         "the supervisor reports peer-down for a request it has handed over"]
        ["non-idempotent-peer" (fx.declared) true
         [[issue C P "7"] [duplicate request (T 1)] [deliver-request (T 1)] [deliver-request (T 1)] [act P (T 1)] [act P (T 1)]]
         non-idempotent-peer "applied-at-most-once"
         "the peer image applies a request id it has a record for"]
        ["late-reply-accepted" (fx.declared) true
         [[issue C P "7"] [deliver-request (T 1)] [act P (T 1)] [timeout (T 1)] [deliver-reply (T 1)]]
         late-reply-accepted "single-outcome"
         "the supervisor hands the caller a reply for an attempt that timed out"]
        ["relay-undeclared" [] false
         [[issue C P "7"] [deliver-request (T 1)] [act P (T 1)] [deliver-reply (T 1)]]
         undeclared-delivery "declared-edges-only"
         "the supervisor carries a connection the manifest lacks (start-time check switched off)"]]))

\\ A schedule as commands: the supervisor reports what happened, so a command
\\ may leave out the end of a label.
(define fx.command
  [act N T] -> ["act" N (fx.tag-json T)]
  [deliver-reply T] -> ["deliver-reply" (fx.tag-json T)]
  L -> (fx.label-json L))

(define fx.command-schedule
  Steps -> [object ["mode" "list"] ["crashes" (str (fx.count crash (map (/. L (hd L)) Steps)))]
                   ["duplicates" (str (fx.count duplicate (map (/. L (hd L)) Steps)))]
                   ["steps" (map (/. L (fx.command L)) Steps)]])

(define fx.properties-of
  [] -> []
  [[_ Vs] | Rest] -> (fr.union Vs (fx.properties-of Rest)))

\\ What the model mutant makes of the same recording: the properties it violates.
(define fx.under-mutant
  Edges Mutant R ->
    (trap-error
      (let Config (fx.config Edges Mutant)
           Schedule (fh.field "schedule" R)
           P (fx.replay Config (remote.initial Config (fx.budget "crashes" Schedule) (fx.budget "duplicates" Schedule))
                        (map (/. E (fx.label E)) (fh.field "events" R)) unchecked 0 [] [] [])
        (if (= (hd P) violated) (fx.properties-of (nth 6 P)) [(str (hd P))]))
      (/. E ["error"])))

\\ Killed: the run itself completed, twice the same, and the judgement of its
\\ recording is a failure of (a), (b) or (c). An error anywhere is "crashed".
\\ The same schedule on the system without the defect must not be a failure.
(define fx.run-defect
  [Defect Edges StartCheck Steps Mutant Property What] ->
    (let Schedule (fx.command-schedule Steps)
         T (fx.twice (cn "defect-" Defect) Edges Schedule [Defect] StartCheck)
         R (hd T)
         J (fx.judge Edges none R)
         Under (fx.under-mutant Edges Mutant R)
         Faithful (fx.execute (cn "faithful-" Defect) Edges Schedule [] StartCheck)
         FJ (fx.judge Edges none Faithful)
         Verdict (if (or (= (hd J) "error") (not (= (fh.field "status" R) "completed")) (not (hd (tl T))))
                     "crashed"
                     (if (and (element? (hd J) ["rejected" "violated" "observations-differ" "enabled-differs"]) (= (hd FJ) "accepted"))
                         "killed"
                         "survived"))
      [Verdict [object ["defect" Defect] ["what" What] ["verdict" Verdict]
                       ["judgement" (hd J)] ["detail" (hd (tl J))]
                       ["schedule" (map (/. L (fx.show L)) Steps)]
                       ["recorded" (map (/. E (fx.show (fx.label E))) (fh.field "events" R))]
                       ["model_mutant" (str Mutant)] ["model_mutant_violates" Under] ["aimed_at" Property]
                       ["aimed_property_violated" (element? Property Under)]
                       ["same_schedule_without_the_defect" (cn (fh.field "status" Faithful) (cn ", " (hd FJ)))]
                       ["recorded_twice_the_same" (hd (tl T))]]]))

\\ ---------- the free-running mode ----------

\\ Runs in which the supervisor is not told what to do: its policy and the wall
\\ clock decide. Not repeated: nothing makes two such runs equal.
\\ [Name Schedule ExpectedOutcomes RequiredKinds]. In the second the peer's OS
\\ process is killed from outside the supervisor's step machine once two steps
\\ have been taken (the request is then in the peer's inbox): the supervisor has
\\ to find the peer dead, restart it, and time the caller out on the clock.
(define fx.free-runs
  -> [["free" [object ["mode" "free"] ["timeout_ms" "2000"] ["deadline_ms" "20000"]]
       [["reply" ["int" "1"]] ["reply" ["int" "2"]]] []]
      ["free-peer-killed" [object ["mode" "free"] ["timeout_ms" "300"] ["deadline_ms" "20000"] ["kill" [["peer" "2"]]]]
       [["timed_out"] ["reply" ["int" "1"]] ["reply" ["int" "2"]]] [crash restart timeout]]])

\\ Result [Passed Json Labels].
(define fx.free
  [Name Schedule Outcomes Required] ->
    (let R (fx.execute Name (fx.declared) Schedule [] true)
         J (fx.judge (fx.declared) none R)
         Info (hd (tl (tl J)))
         Kinds (if (cons? Info) (map (/. L (hd L)) (hd Info)) [])
         Passed (and (= (fh.field "status" R) "completed") (= (hd J) "accepted") (cons? Info) (hd (tl (tl Info)))
                     (= (hd (tl Info)) Outcomes) (fx.subset? Required Kinds))
      [Passed
       [object ["run" Name] ["passed" Passed] ["status" (fh.field "status" R)] ["verdict" (hd J)] ["detail" (hd (tl J))]
               ["steps" (str (length (fh.field "events" R)))] ["outcomes" (if (cons? Info) (hd (tl Info)) [])]]
       (if (cons? Info) (hd Info) [])]))

\\ ---------- main ----------

(define fx.required-kinds
  -> [issue refuse finish deliver-request deliver-reply discard-reply drop duplicate act-applied act-replayed
      timeout peer-down crash restart])

(define fx.tally
  [] Acc -> Acc
  [L | Ls] Acc -> (fx.tally Ls (fh.count-key (fx.kind-of L) Acc)))

(define fx.tally-all
  [] Acc -> Acc
  [Labels | Rest] Acc -> (fx.tally-all Rest (fx.tally Labels Acc)))

(define fx.outcome-kinds
  [] Acc -> Acc
  [Outcomes | Rest] Acc -> (fx.outcome-kinds Rest (fx.count-outcomes Outcomes Acc)))

(define fx.count-outcomes
  [] Acc -> Acc
  [[Kind | _] | Os] Acc -> (fx.count-outcomes Os (fh.count-key Kind Acc)))

(define fx.kinds-json
  Kinds -> [object | (map (/. K [(str (hd K)) (str (hd (tl K)))]) Kinds)])

(define fx.names-json
  Kinds -> [object | (map (/. K [(hd K) (str (hd (tl K)))]) Kinds)])

(define fx.has-kind?
  K [] -> false
  K [[K _] | _] -> true
  K [_ | Rest] -> (fx.has-kind? K Rest))

(define fx.main
  -> (let Control (= (value fx.*mode*) "negative-control")
          \\ The control: the non-idempotent peer image in place of the peer, judged as if it were the system.
          Hand (if Control
                   (map (/. H (fx.run-hand ["non-idempotent-peer"] H)) (fx.keep (/. H (= (hd H) "duplicate-applied-once")) (fx.hand)))
                   (map (/. H (fx.run-hand [] H)) (fx.hand)))
          HandFailed (fx.keep (/. H (not (empty? (hd (tl H))))) Hand)
          Seeds (if Control [] (fx.seeds 0 (value fx.*seeds*)))
          SeedsFailed (fx.keep (/. S (not (empty? (hd (tl S))))) Seeds)
          Free (if Control [] (map (/. F (fx.free F)) (fx.free-runs)))
          FreeFailed (fx.keep (/. F (not (hd F))) Free)
          Defects (if Control [] (map (/. D (fx.run-defect D)) (fx.defects)))
          NotKilled (fx.keep (/. D (not (= (hd D) "killed"))) Defects)
          Kinds (fx.tally-all (append (map (/. H (nth 3 H)) Hand) (map (/. S (nth 3 S)) Seeds) (map (/. F (nth 3 F)) Free)) [])
          Missing (map (/. K (str K)) (fx.keep (/. K (not (fx.has-kind? K Kinds))) (fx.required-kinds)))
          Accepted (+ (- (length Hand) (length HandFailed)) (+ (- (length Seeds) (length SeedsFailed)) (- (length Free) (length FreeFailed))))
          ControlOk (= (value fx.*control*) "failed-as-required")
          Pass (and (not Control) (empty? HandFailed) (empty? SeedsFailed) (empty? FreeFailed) (empty? NotKilled) (empty? Missing) ControlOk)
          Report [object ["schema" "fenrir.harness.tc1-remote-run/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["evidence" "observed histories of the real system accepted by the model; one small system; spt tender only; no hvt run; no proof"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["mode" (value fx.*mode*)]
                         ["system" "Erlang/OTP supervisor (supervisor/) with two Solo5 guests under the tender: caller = TC1 program on the C machine, peer = counter with a durable store; transport: block-device mailboxes, wire format 1"]
                         ["system_under_check" (if Control "the non-idempotent peer image in place of the peer" "as built")]
                         ["model" "models/tc1/remote-system.shen with models/tc1/remote-tc1-caller.shen; the caller is the program the image was built from"]
                         ["abi" (fh.field "abi" (value fx.*info*))]
                         ["solo5_commit" (fh.field "solo5_commit" (value fx.*info*))]
                         ["tender_sha256" (fh.field "tender_sha256" (value fx.*info*))]
                         ["caller_sha256" (fh.field "caller_sha256" (value fx.*info*))]
                         ["peer_sha256" (fh.field "peer_sha256" (value fx.*info*))]
                         ["program_sha256" (fh.field "program_sha256" (value fx.*info*))]
                         ["properties" ["single-outcome" "resolved-at-termination" "reply-implies-acted" "peer-down-not-handed" "peer-down-sealed"
                                        "applied-at-most-once" "declared-edges-only" "crash-isolation"]]
                         ["schedules_accepted" (str Accepted)]
                         ["hand_schedules" (str (length Hand))]
                         ["hand_schedules_failed" (map (/. H (fh.field "schedule" (hd H))) HandFailed)]
                         ["hand" (map (/. H (hd H)) Hand)]
                         ["seeded_schedules" (str (length Seeds))]
                         ["seeded_budgets" "1 crash, 1 duplicate, at most 120 steps"]
                         ["seeded_failed" (map (/. S [object ["seed" (str (hd S))] ["failures" (hd (tl S))]]) (fh.take 5 SeedsFailed))]
                         ["seeded_steps" (str (fx.sum (map (/. S (length (nth 3 S))) Seeds)))]
                         ["seeded_ran_until_no_step_was_enabled" (str (length (fx.keep (/. S (nth 4 S)) Seeds)))]
                         ["free_runs" (map (/. F (hd (tl F))) Free)]
                         ["steps_by_kind" (fx.kinds-json Kinds)]
                         ["outcomes_by_kind" (fx.names-json (fx.outcome-kinds (append (map (/. H (fh.field "outcomes" (hd H))) Hand) (map (/. S (nth 5 S)) Seeds)) []))]
                         ["step_kinds_not_exercised" Missing]
                         ["defects" (map (/. D (hd (tl D))) Defects)]
                         ["defects_not_killed" (map (/. D (fh.field "defect" (hd (tl D)))) NotKilled)]
                         ["determinism" "every scheduled run was made twice; status, event log, enabled sets, console frames and store must be equal"]
                         ["supervisor_runs" (str (value fx.*runs*))]
                         ["negative_control" (value fx.*control*)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if Pass 0 1)))))

(fx.main)
