\\ Fenrir harness, in Shen: drive the host-controlled TC1-C1 Solo5 guest over protocol
\\ fenrir.solo5.pure-call-control/3 (spec/solo5/pure-call-control-v3.md) and compare every
\\ guest step with the Shen task model (models/tc1/task-machine.shen) as it goes.
\\
\\   reference  the host chooses every step: each choice of a recorded schedule is a Run
\\              naming the task, and the guest's record must equal the model's step of
\\              that task. Hand fixtures under every schedule harness/tc1-tasks.shen runs
\\              them under; a declared sample of grammar G under one witness schedule per
\\              reference observation class, found here by the exploration of
\\              harness/tc1-task-explore.shen (fh.explore, loaded as a library).
\\   fifo       the guest chooses by its own FIFO production policy and names each choice;
\\              the host replays the choice on the model, compares, and requires the
\\              guest's schedule to be a production schedule by the model's own records
\\              and to equal the FIFO schedule the batch declares.
\\
\\ Injected guest defects (Init modes) must each be detected on at least one run; a run
\\ that fails (guest error, crash, timeout) is counted separately and never as a
\\ detection. Tapes of every hand-fixture run (the Run frames bind the schedule) are
\\ replayed strictly on cold boots; tape, hostile-host and hostile-guest negatives and the
\\ v3 byte vectors run as for v1. Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/solo5-tasks.shen LIBDIR ROOT BATCHDIR OUTDIR
\\ BATCHDIR as written by tools/solo5/control-task-build.mjs. The report is the last line.
\\
\\ The v1 host (harness/solo5-control.shen) is loaded for its frame, reader, session, tape
\\ and replay definitions; what v3 changes is redefined below.

(set fc.*as-library* true)
(load (cn (hd (tl (tl (value *argv*)))) "/harness/solo5-control.shen"))
(load (cn (value fh.*root*) "harness/tc1-task-common.shen"))
(set fh.*explore-as-library* true)
(set fh.*options* [])
(load (cn (value fh.*root*) "harness/tc1-task-explore.shen"))

(set fc.*protocol* "fenrir.solo5.pure-call-control/3")
(set fc.*profile* "fenrir.solo5.pure-call-machine/3")
(set fc.*tape-schema* "fenrir.solo5.pure-call-control-tape/3")
(set st.*scheduler* "reference")

\\ ---------- what v3 changes in the v1 definitions ----------

(define st.init-fields
  Artifact Batch Fuel Mode Program Protocol Scheduler Schema ->
    (cn "{" (cn (fc.kv "artifact_sha256" Artifact) (cn "," (cn (fc.kv "batch_sha256" Batch) (cn "," (cn (fc.kv "fuel" Fuel)
      (cn "," (cn (fc.kv "kind" "Init") (cn "," (cn (fc.kv "mode" Mode) (cn "," (cn (fc.kv "program" Program)
      (cn "," (cn (fc.kv "protocol" Protocol) (cn "," (cn (fc.kv "scheduler" Scheduler) (cn "," (cn (fc.kv "schema" Schema) "}")))))))))))))))))))

(define fc.init-payload
  I Mode -> (st.init-fields (fc.identity I "artifact_sha256") (fc.b "batch_sha256") (str (value fc.*fuel*)) Mode (str I)
                            (value fc.*protocol*) (value st.*scheduler*) (fc.identity I "schema")))

(define fc.check-ready
  J I Mode -> (if (and (= (fh.member "artifact_sha256" J) (fc.identity I "artifact_sha256"))
                       (= (fh.member "program" J) (str I)) (= (fh.member "mode" J) Mode)
                       (= (fh.member "scheduler" J) (value st.*scheduler*))
                       (= (fh.member "schema" J) (fc.identity I "schema"))
                       (= (fh.member "fuel" J) (str (value fc.*fuel*)))
                       (= (fh.member "epoch" J) "0") (= (fh.member "execution" J) "Running"))
                  J
                  (fc.fail "Protocol" "Identity")))

(define st.run-task
  N T -> (cn "{" (cn (fc.kv "kind" "Run") (cn "," (cn (fc.kv "steps" (str N)) (cn "," (cn (fc.kv "task" T) "}")))))))

(define st.has?
  Key [object | Ms] -> (element? Key (map (/. M (hd M)) Ms))
  _ _ -> false)

\\ A Steps response: 1..N records with consecutive epochs, a response epoch after the
\\ last, a known execution, wait_graph exactly when Deadlock, and (reference) every record
\\ a step of the task the host named.
(define fc.records
  J N Epoch -> (st.records J N Epoch any))

(define st.records
  J N Epoch Named ->
    (let Steps (fh.member "steps" J)
         K (if (cons? Steps) (length Steps) 0)
         X (fh.member "execution" J)
      (if (and (> K 0) (<= K N)
               (fc.consecutive? Steps Epoch)
               (= (fh.member "epoch" J) (str (+ Epoch K)))
               (element? X ["Running" "Completed" "Deadlock" "BudgetExhausted"])
               (= (= X "Deadlock") (st.has? "wait_graph" J))
               (or (= Named any) (fc.every? (/. R (= (fh.member "task" R) Named)) Steps)))
          Steps
          (fc.fail "Protocol" "BadSteps"))))

(define fc.tape-header
  I Mode -> (json.stringify
              [object ["artifact_sha256" (fc.identity I "artifact_sha256")] ["batch_sha256" (fc.b "batch_sha256")]
                      ["control_sha256" (fc.b "control_sha256")] ["fuel" (str (value fc.*fuel*))] ["kind" "TapeHeader"]
                      ["machine_profile" (value fc.*profile*)] ["mode" Mode] ["program" (str I)]
                      ["protocol" (value fc.*protocol*)] ["scheduler" (value st.*scheduler*)] ["schema" (fc.identity I "schema")]
                      ["solo5" (fh.field "path" (fc.b "solo5_identity"))] ["tape" (value fc.*tape-schema*)]
                      ["tender_sha256" (fc.b "tender_sha256")]] []))

\\ As v1, and the recorded Init must be the one the header implies, scheduler included.
(define fc.compatible
  H Middle ->
    (let I (if (fc.decimal? (fh.member "program" H)) (fc.number (fh.member "program" H)) -1)
      (cond ((not (= (fh.member "tape" H) (value fc.*tape-schema*))) (fc.fail "Incompatible" "TapeSchema"))
            ((not (= (fh.member "protocol" H) (value fc.*protocol*))) (fc.fail "Incompatible" "Protocol"))
            ((not (= (fh.member "machine_profile" H) (value fc.*profile*))) (fc.fail "Incompatible" "Profile"))
            ((not (and (= (fh.member "batch_sha256" H) (fc.b "batch_sha256")) (= (fh.member "control_sha256" H) (fc.b "control_sha256"))
                       (= (fh.member "tender_sha256" H) (fc.b "tender_sha256"))))
              (fc.fail "Incompatible" "Image"))
            ((not (and (>= I 0) (< I (value fc.*count*)) (= (fh.member "artifact_sha256" H) (fc.identity I "artifact_sha256"))
                       (= (fh.member "schema" H) (fc.identity I "schema"))))
              (fc.fail "Incompatible" "Artifact"))
            ((not (element? (fh.member "scheduler" H) ["reference" "fifo"])) (fc.fail "Incompatible" "Init"))
            ((not (= (nth 4 (nth 2 Middle)) (st.with-scheduler (fh.member "scheduler" H) (freeze (fc.init-payload I (fh.member "mode" H))))))
              (fc.fail "Incompatible" "Init"))
            (true I))))

(define st.with-scheduler
  Scheduler F -> (let Old (value st.*scheduler*)
                      _ (set st.*scheduler* Scheduler)
                      R (trap-error (thaw F) (/. E (do (set st.*scheduler* Old) (simple-error (error-to-string E)))))
                      _ (set st.*scheduler* Old)
                   R))

\\ ---------- the model, in the guest's shapes ----------

(define st.program I -> (fh.task-program (fc.artifact I)))

\\ The model's execution in the guest's words.
(define st.execution
  M Epoch -> (let F (fh.task-footer M)
               (if (= F []) (if (>= Epoch (value fc.*fuel*)) "BudgetExhausted" "Running") (hd F))))

(define st.footer-detail
  M -> (let F (fh.task-footer M) (if (= F []) [] (fh.canon (hd (tl F))))))

\\ The model's step of task Id: [CanonicalRecord Next], or [schedule-error] when Id is not
\\ Runnable in the model.
(define st.model-step
  Prog M Epoch Id -> (if (element? Id (tm.runnable M))
                         (let R (tm.step Prog M Id) [(fh.canon (fh.task-record Epoch Id R)) (hd (tl R))])
                         [schedule-error]))

\\ Compare guest records with the model stepping Named (or, for any, the task each record
\\ names): [agree M Epoch ModelRecords] or [diverge Epoch].
(define st.compare
  Prog [] M Epoch Named Acc -> [agree M Epoch (reverse Acc)]
  Prog [R | Rs] M Epoch Named Acc ->
    (let Id (if (= Named any) (fh.member "task" R) Named)
         S (st.model-step Prog M Epoch Id)
      (if (= (hd S) schedule-error) [diverge Epoch]
          (if (= (fh.canon R) (hd S))
              (st.compare Prog Rs (hd (tl S)) (+ Epoch 1) Named [(hd S) | Acc])
              [diverge Epoch]))))

\\ The leading run of equal choices, at most Max: [Task N Rest].
(define st.group
  [C | Cs] Max -> (st.group-from C 1 Cs Max))

(define st.group-from
  C N [C | Cs] Max -> (st.group-from C (+ N 1) Cs Max) where (< N Max)
  C N Cs _ -> [C N Cs])

\\ ---------- one controlled run ----------

\\ Result [Outcome DivergenceEpoch GuestEpoch Records Frames Execution Choices ModelRecords]:
\\ Outcome agreed or diverged; Execution the model's at the stop (or "ScheduleIncomplete"
\\ when the choices ran out first); Choices the tasks that stepped.
(define st.controlled
  I Mode Scheduler Choices Group ->
    (let _ (set st.*scheduler* Scheduler)
         S (fc.open I Mode (make-string "~Aconsole-~A-~A.txt" (value fc.*out*) Mode I))
         P (st.program I)
      (fc.with S (/. S (if (= Scheduler "fifo")
                           (st.drive-fifo S (hd P) (hd (tl P)) 0 [] [])
                           (st.drive S (hd P) (hd (tl P)) 0 Choices Group [] []))))))

(define st.drive
  S Prog M Epoch Choices Group Acc Models ->
    (let X (st.execution M Epoch)
      (cond ((not (= X "Running")) (st.finish S agreed none Acc X Models))
            ((empty? Choices) (st.finish S diverged (str Epoch) Acc "ScheduleIncomplete" Models))
            (true
              (let G (st.group Choices (if Group 64 1))
                   T (hd G)
                   _ (fc.send S "R" (st.run-task (hd (tl G)) T))
                   J (fc.expect S "S")
                   Records (st.records J (hd (tl G)) Epoch T)
                   C (st.compare Prog Records M Epoch T [])
                   Seen (append Acc Records)
                   K (length Records)
                (cond ((= (hd C) diverge) (st.finish S diverged (str (nth 2 C)) Seen X Models))
                      ((not (= (fh.member "execution" J) (st.execution (nth 2 C) (nth 3 C)))) (st.finish S diverged (str (nth 3 C)) Seen X Models))
                      ((and (= (fh.member "execution" J) "Deadlock") (not (= (fh.canon (fh.member "wait_graph" J)) (st.footer-detail (nth 2 C)))))
                        (st.finish S diverged (str (nth 3 C)) Seen X Models))
                      \\ A legal short batch may also reflect the guest's payload bound.
                      \\ Continue from the next unconsumed choice, never from the request size.
                      (true (st.drive S Prog (nth 2 C) (nth 3 C) (fc.drop-n K Choices) Group Seen (append Models (nth 4 C))))))))))

(define fc.drop-n
  0 L -> L
  _ [] -> []
  N [_ | L] -> (fc.drop-n (- N 1) L))

(define st.drive-fifo
  S Prog M Epoch Acc Models ->
    (let X (st.execution M Epoch)
      (if (not (= X "Running"))
          (st.finish S agreed none Acc X Models)
          (let _ (fc.send S "R" (fc.run-payload 1))
               J (fc.expect S "S")
               Records (st.records J 1 Epoch any)
               C (st.compare Prog Records M Epoch any [])
               Seen (append Acc Records)
            (cond ((= (hd C) diverge) (st.finish S diverged (str (nth 2 C)) Seen X Models))
                  ((not (= (fh.member "execution" J) (st.execution (nth 2 C) (nth 3 C)))) (st.finish S diverged (str (nth 3 C)) Seen X Models))
                  ((and (= (fh.member "execution" J) "Deadlock") (not (= (fh.canon (fh.member "wait_graph" J)) (st.footer-detail (nth 2 C)))))
                    (st.finish S diverged (str (nth 3 C)) Seen X Models))
                  (true (st.drive-fifo S Prog (nth 2 C) (nth 3 C) Seen (append Models (nth 4 C)))))))))

(define st.finish
  S Outcome At Acc X Models -> (let Bye (fc.terminate S)
                                 _ (if (and (= (fh.member "kind" Bye) "Bye")
                                            (= (fh.member "epoch" Bye) (str (length Acc)))
                                            (or (not (= Outcome agreed)) (= (fh.member "execution" Bye) X)))
                                       true (fc.fail "Protocol" "BadBye"))
                                 [Outcome At (fh.member "epoch" Bye) Acc (reverse (<-address S 3)) X
                                  (map (/. R (fh.member "task" R)) Acc) Models]))

(define st.safely
  F -> (trap-error (thaw F) (/. E [failed (fc.classify E) "?" [] [] "?" [] []])))

\\ ---------- runs ----------

(define st.family I -> (fc.identity I "family"))
(define st.schedules I -> (fc.identity I "schedules"))
(define st.fifo I -> (fc.identity I "fifo"))

\\ [I ScheduleName Production Choices] for every recorded schedule of every program.
(define st.recorded
  [] -> []
  [I | Is] -> (append (map (/. Sc [I (fh.field "name" Sc) (fh.field "production" Sc) (fh.field "choices" Sc)]) (st.schedules I))
                      (st.recorded Is)))

\\ Witness schedules of the sample: one per reference observation class, by the exploration.
(define st.witnesses
  [] -> []
  [I | Is] -> (let P (st.program I)
                   X (fh.explore reference (hd P) (hd (tl P)))
                (append (st.witness-rows I (reverse (nth 5 X)) 0 (nth 4 X)) (st.witnesses Is))))

(define st.witness-rows
  I [] _ _ -> []
  I [[_ Choices] | Os] K Truncated -> [[I (cn "obs-" (str K)) false Choices Truncated] | (st.witness-rows I Os (+ K 1) Truncated)])

\\ A reference run of a recorded schedule passes when it agrees, reaches the model's footer,
\\ and (for a production policy's schedule) is a production schedule by the model's records.
(define st.reference-pass?
  [I Name Production Choices | _] Run -> (and (= (hd Run) agreed) (element? (nth 6 Run) ["Completed" "Deadlock"])
                                              (or (not Production) (fh.production? (nth 8 Run)))))

(define st.fifo-pass?
  I Run -> (and (= (hd Run) agreed) (element? (nth 6 Run) ["Completed" "Deadlock"])
                (= (nth 7 Run) (st.fifo I)) (fh.production? (nth 8 Run))))

\\ A defective run: killed when it ran in order and the comparison failed (divergence, or for
\\ fifo-reversed choices other than the FIFO schedule); survived when it passed; crashed when
\\ the session failed (a guest error or any harness failure), never a kill.
(define st.verdict
  failed _ -> crashed
  _ true -> survived
  _ false -> killed)

(define st.count
  V Vs -> (fc.count-if (/. X (= X V)) Vs 0))

(define st.tally
  Verdicts -> [object ["killed" (str (st.count killed Verdicts))] ["survived" (str (st.count survived Verdicts))]
                      ["crashed" (str (st.count crashed Verdicts))]])

(define st.mode-reference
  Mode Rows -> (map (/. R (let Run (st.safely (freeze (st.controlled (hd R) Mode "reference" (nth 4 R) false)))
                            (cond ((= (hd Run) failed) crashed)
                                  ((= (nth 6 Run) "ScheduleIncomplete") crashed)
                                  ((= (hd Run) diverged) killed)
                                  (true survived))))
                    Rows))

\\ Runs that agree with the model and are production schedules, yet are not the FIFO
\\ schedule: only the comparison with the declared FIFO schedule catches those.
(set st.*production-not-fifo* 0)
(define st.mode-fifo
  Mode Is -> (map (/. I (let Run (st.safely (freeze (st.controlled I Mode "fifo" [] false)))
                             _ (if (and (= (hd Run) agreed) (fh.production? (nth 8 Run)) (not (= (nth 7 Run) (st.fifo I))))
                                   (set st.*production-not-fifo* (+ 1 (value st.*production-not-fifo*))) skip)
                          (st.verdict (hd Run) (st.fifo-pass? I Run))))
                  Is))

(define st.failures
  [] [] -> []
  [R | Rs] [Run | Runs] -> (if (st.reference-pass? R Run) (st.failures Rs Runs)
                               [[object ["program" (fc.identity (hd R) "name")] ["schedule" (nth 2 R)] ["result" (str (hd Run))]
                                        ["at" (str (nth 2 Run))] ["execution" (str (nth 6 Run))] ["detail" (fc.detail Run)]]
                                | (st.failures Rs Runs)]))

(define st.fifo-failures
  [] [] -> []
  [I | Is] [Run | Runs] -> (if (st.fifo-pass? I Run) (st.fifo-failures Is Runs)
                               [[object ["program" (fc.identity I "name")] ["schedule" "fifo (guest)"] ["result" (str (hd Run))]
                                        ["at" (str (nth 2 Run))] ["execution" (str (nth 6 Run))] ["detail" (fc.detail Run)]
                                        ["guest_choices_equal_declared_fifo" (if (= (nth 7 Run) (st.fifo I)) "yes" "no")]]
                                | (st.fifo-failures Is Runs)]))

(define fc.detail
  [failed C | _] -> (make-string "~A" C)
  [_ At | _] -> (make-string "diverged at ~A" At))

\\ ---------- negatives specific to v3 ----------

\\ Tape edits: the Run at frame 3 names another task (Runnable at epoch 0 only root), and
\\ the header names the other scheduler.
(define st.tape-negatives
  Base -> (let T (fc.split-tape Base)
               H (hd T)
               Fs (hd (tl T))
               HJ (fc.decode H)
               Run (fc.at 3 Fs)
               Edited (fc.replace-at 3 (fc.set-payload "task" "1" Run) Fs)
            [["edited-schedule-choice" "Diverged:frame 4" (fc.text-of H Edited)]
             ["header-names-other-scheduler" "Incompatible:Init" (fc.text-of (json.stringify (fc.set-member "scheduler" "fifo" HJ) []) Fs)]]))

\\ [Name Expected Prelude Bytes Close] for the v3 frames, against the reference guest.
(define st.host-cases
  I -> (let Init (/. Seq P (fc.frame "H" "I" Seq P))
            A (fc.identity I "artifact_sha256")
            Batch (fc.b "batch_sha256")
            Fuel (str (value fc.*fuel*))
            Schema (fc.identity I "schema")
            Run (/. P (fc.frame "H" "R" 2 P))
         [["run-without-task-under-reference" "BadState@2 exit 3" 1 (Run (fc.run-payload 1)) false]
          ["run-names-unallocated-task" "NotRunnable@2 exit 3" 1 (Run (st.run-task 1 "7")) false]
          ["run-task-not-canonical" "BadPayload@2 exit 3" 1 (Run (st.run-task 1 "01")) false]
          ["run-task-keys-reordered" "BadPayload@2 exit 3" 1 (Run "{c#34;kindc#34;:c#34;Runc#34;,c#34;taskc#34;:c#34;0c#34;,c#34;stepsc#34;:c#34;1c#34;}") false]
          ["run-task-budget-over-limit" "BadBudget@2 exit 3" 1 (Run (st.run-task 65 "0")) false]
          ["reply-frame-type" "UnknownType@2 exit 3" 1 (fc.frame "H" "A" 2 "{c#34;kindc#34;:c#34;Replyc#34;,c#34;requestc#34;:c#34;0c#34;,c#34;valuec#34;:[c#34;unitc#34;]}") false]
          ["init-v1-template" "BadPayload@1 exit 3" 0 (Init 1 (fc.init-fields A Batch Fuel "normal" (str I) (value fc.*protocol*) Schema)) false]
          ["init-unknown-scheduler" "Identity@1 exit 3" 0 (Init 1 (st.init-fields A Batch Fuel "normal" (str I) (value fc.*protocol*) "lifo" Schema)) false]
          ["init-unknown-mode" "Identity@1 exit 3" 0 (Init 1 (st.init-fields A Batch Fuel "reverse-operands" (str I) (value fc.*protocol*) "reference" Schema)) false]
          ["init-v2-protocol" "Identity@1 exit 3" 0 (Init 1 (st.init-fields A Batch Fuel "normal" (str I) "fenrir.solo5.pure-call-control/2" "reference" Schema)) false]
          ["bad-magic" "BadMagic@1 exit 3" 0 "FGX1 HI 00000001 00000002c#10;{}c#10;" false]
          ["out-of-order-sequence" "BadSequence@2 exit 3" 1 (fc.frame "H" "R" 4 (st.run-task 1 "0")) false]
          ["hangup" "Hangup@2 exit 3" 1 "" true]]))

\\ A Run with a task under the FIFO scheduler: BadState.
(define st.fifo-named-run
  I -> (let _ (set st.*scheduler* "fifo")
            R (fc.bad-host I 1 (fc.frame "H" "R" 2 (st.run-task 1 "0")) false)
            _ (set st.*scheduler* "reference")
         R))

\\ After the run has ended (Completed or Deadlock), a further Run is NotRunning.
(define st.run-after-end
  I Choices -> (trap-error
                 (let _ (set st.*scheduler* "reference")
                      S (fc.open I "normal" (cn (value fc.*out*) "console-hostile-host.txt"))
                   (fc.with S (/. S (let Seq (st.run-out S Choices 0)
                                         _ (fc.write S (fc.frame "H" "R" Seq (st.run-task 1 "0")))
                                         F (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                                         _ (fc.drain (<-address S 1))
                                         St (fc.exit-status S)
                                      [(str Seq) (make-string "~A@~A exit ~A" (fh.member "code" (fc.decode (nth 4 F))) (nth 3 F) St)]))))
                 (/. E ["?" (cn "failed: " (error-to-string E))])))

(define st.run-out
  S [] Epoch -> (<-address S 2)
  S [C | Cs] Epoch -> (let _ (fc.send S "R" (st.run-task 1 C))
                           J (fc.expect S "S")
                           R (st.records J 1 Epoch C)
                        (if (= (fh.member "execution" J) "Running") (st.run-out S Cs (+ Epoch 1)) (<-address S 2))))

\\ Hostile guest: scripted Steps frames this host's parser must refuse.
(define st.guest-cases
  I -> (let S (fc.open I "normal" (cn (value fc.*out*) "console-hostile-guest.txt"))
            G (fc.with S (/. S (let _ (fc.send S "R" (st.run-task 1 "0"))
                                    _ (fc.expect S "S")
                                    _ (fc.terminate S)
                                    Log (reverse (<-address S 3))
                                 [(fc.at 0 Log) (fc.at 2 Log) (fc.at 4 Log) (fc.at 6 Log)])))
            Hello (fc.at 0 G) Ready (fc.at 1 G) Steps (fc.at 2 G) Bye (fc.at 3 G)
            SF (fc.parsed Steps)
            SJ (fc.decode (fc.at 3 SF))
            Record (hd (fh.member "steps" SJ))
            Out (/. Rs (fc.concat Rs))
            With (/. J (fc.raw [(hd SF) "S" 2 (json.stringify J [])]))
         [["deadlock-without-wait-graph" "Protocol:BadSteps" (Out [Hello Ready (With (fc.set-member "execution" "Deadlock" SJ)) Bye])]
          ["wait-graph-while-running" "Protocol:BadSteps" (Out [Hello Ready (With (append SJ [["wait_graph" []]])) Bye])]
          ["record-of-another-task" "Protocol:BadSteps" (Out [Hello Ready (With (fc.set-member "steps" [(fc.set-member "task" "1" Record)] SJ)) Bye])]
          ["unknown-execution" "Protocol:BadSteps" (Out [Hello Ready (With (fc.set-member "execution" "Blocked" SJ)) Bye])]
          ["unmodified-control" "accepted" (Out [Hello Ready Steps Bye])]]))

(define st.dialogue
  S I -> (let _ (fc.check-hello (fc.expect S "H"))
              _ (fc.send S "I" (fc.init-payload I "normal"))
              _ (fc.check-ready (fc.expect S "Y") I "normal")
              _ (fc.send S "R" (st.run-task 1 "0"))
              _ (st.records (fc.expect S "S") 1 0 "0")
              _ (fc.send S "X" "{c#34;kindc#34;:c#34;Terminatec#34;}")
              _ (fc.expect S "B")
              _ (fc.drain (<-address S 1))
           "accepted"))

(define st.scripted-result
  I Bytes -> (trap-error (st.dialogue (fc.session [] (fc.scripted Bytes) "") I)
                         (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

\\ ---------- the specification's v3 byte vectors ----------

(define st.host-vector
  "init-reference-seq-1" -> (fc.frame "H" "I" 1 (st.init-fields (fc.chars 64 "a") (fc.chars 64 "b") "1000" "normal" "0" (value fc.*protocol*) "reference" "tc1-task-demo/1"))
  "init-fifo-seq-1" -> (fc.frame "H" "I" 1 (st.init-fields (fc.chars 64 "a") (fc.chars 64 "b") "1000" "lost-wakeup" "3" (value fc.*protocol*) "fifo" "tc1-task-demo/1"))
  "run-task-seq-2" -> (fc.frame "H" "R" 2 (st.run-task 1 "0"))
  "run-task-12-seq-9" -> (fc.frame "H" "R" 9 (st.run-task 12 "3"))
  "run-fifo-seq-4" -> (fc.frame "H" "R" 4 (fc.run-payload 1))
  _ -> "")

(define st.vector-row
  [Name "host" _ Hex] -> (fc.negative-row [Name "encoded-identically" (if (= (st.host-vector Name) (fc.unhex Hex)) "encoded-identically" "different")])
  [Name "steps" _ Hex] -> (fc.negative-row [Name "accepted"
                                            (trap-error (let F (fc.next-frame (fc.scripted (fc.unhex Hex)) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                                                             J (fc.decode (nth 4 F))
                                                             _ (st.records J 64 (fc.number (fh.member "epoch" (hd (fh.member "steps" J)))) any)
                                                          (if (= (fc.raw [(nth 1 F) (nth 2 F) (nth 3 F) (nth 4 F)]) (fc.unhex Hex)) "accepted" "re-encoded differently"))
                                                        (/. E (hd (tl (fc.classify E)))))])
  [Name "steps-reject" Code Hex] -> (fc.negative-row [Name Code
                                            (trap-error (let F (fc.next-frame (fc.scripted (fc.unhex Hex)) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                                                             J (fc.decode (nth 4 F))
                                                             _ (st.records J 64 (fc.number (fh.member "epoch" (hd (fh.member "steps" J)))) any)
                                                          "accepted")
                                                        (/. E (hd (tl (fc.classify E)))))])
  L -> (fc.vector-row L))

(define st.vectors
  -> (map (/. L (st.vector-row (fc.words L "" [])))
          (fc.filter (/. L (and (not (= L "")) (not (fh.starts? "#" L))))
                     (fh.lines (read-file-as-string (cn (value fh.*root*) "spec/solo5/pure-call-control-v3.vectors"))))))

\\ ---------- the check ----------

(define st.in-family
  F -> (fc.filter (/. I (= (st.family I) F)) (value fc.*indices*)))

(define st.sum
  [] -> 0
  [X | Xs] -> (+ X (st.sum Xs)))

(define st.steps-of
  Runs -> (st.sum (map (/. R (length (nth 4 R))) Runs)))

(define st.first-long
  [] _ -> (error "harness: no taped run has three Run exchanges")
  [T | Ts] [R | Rs] -> (if (>= (length (hd (tl (fc.read-tape T)))) 17) [T R] (st.first-long Ts Rs)))

(define st.fifo-tape
  I Run -> (st.with-scheduler "fifo" (freeze (fc.seal (fc.tape-header I "normal") (nth 5 Run)))))

(define st.main
  -> (let Start (clock.monotonic)
          _ (if (= (fc.b "schema") "fenrir.solo5.control-task-batch/1") (fc.check-batch-identity false)
                (error "harness: wrong task batch schema"))
          Hand (st.in-family "tc1-task-hand")
          Sample (st.in-family "tc1-task-small-sample")
          Extra (fc.filter (/. I (not (element? (st.family I) ["tc1-task-hand" "tc1-task-small-sample"]))) (value fc.*indices*))
          Recorded (st.recorded (append Hand Extra))
          RefRuns (map (/. R (st.safely (freeze (st.controlled (hd R) "normal" "reference" (nth 4 R) false)))) Recorded)
          RefPass (fc.count-if (/. P (st.reference-pass? (hd P) (hd (tl P)))) (fc.pairs-of Recorded RefRuns) 0)
          ExploreStart (clock.monotonic)
          Witnesses (st.witnesses Sample)
          ExploreMs (- (clock.monotonic) ExploreStart)
          WitnessRuns (map (/. W (st.safely (freeze (st.controlled (hd W) "normal" "reference" (nth 4 W) true)))) Witnesses)
          WitnessPass (fc.count-if (/. P (st.reference-pass? (hd P) (hd (tl P)))) (fc.pairs-of Witnesses WitnessRuns) 0)
          Truncated (fc.count-if (/. W (nth 5 W)) Witnesses 0)
          WitnessPrograms (map (/. W (hd W)) Witnesses)
          All (value fc.*indices*)
          FifoRuns (map (/. I (st.safely (freeze (st.controlled I "normal" "fifo" [] false)))) All)
          FifoPass (fc.count-if (/. P (st.fifo-pass? (hd P) (hd (tl P)))) (fc.pairs-of All FifoRuns) 0)
          ControlMs (- (clock.monotonic) Start)
          \\ Injected guest defects, on the hand fixtures.
          HandRecorded (st.recorded Hand)
          Defects [["cancel-off-point" (st.mode-reference "cancel-off-point" HandRecorded)]
                   ["lost-wakeup" (st.mode-reference "lost-wakeup" HandRecorded)]
                   ["capacity-off-by-one" (st.mode-reference "capacity-off-by-one" HandRecorded)]
                   ["fifo-reversed" (st.mode-fifo "fifo-reversed" Hand)]]
          Undetected (map (/. D (hd D)) (fc.filter (/. D (= (st.count killed (hd (tl D))) 0)) Defects))
          \\ Strict replay: a tape of every hand-fixture run, reference and FIFO.
          HandRef (fc.filter (/. P (element? (hd (hd P)) Hand)) (fc.pairs-of Recorded RefRuns))
          RefTapes (map (/. P (st.with-scheduler "reference" (freeze (fc.seal (fc.tape-header (hd (hd P)) "normal") (nth 5 (hd (tl P))))))) HandRef)
          FifoTapes (map (/. I (st.fifo-tape I (nth (+ I 1) FifoRuns))) Hand)
          Tapes (append RefTapes FifoTapes)
          _ (fc.write-tapes (fc.range 0 (length Tapes)) Tapes)
          ReplayStart (clock.monotonic)
          Replays (map (/. T (fc.repeat 2 (freeze (fc.replay-result T)) [])) Tapes)
          ReplayExact (fc.count-if (/. Rs (fc.every? (/. R (= R "Exact")) Rs)) Replays 0)
          Rerecorded (map (/. I (st.fifo-tape I (st.controlled I "normal" "fifo" [] false))) Hand)
          Identical (fc.count-if (/. P (= (hd P) (hd (tl P)))) (fc.pairs-of FifoTapes Rerecorded) 0)
          ReplayMs (- (clock.monotonic) ReplayStart)
          Long (hd (st.first-long RefTapes HandRef))
          LongIndex (hd (hd (hd (tl (st.first-long RefTapes HandRef)))))
          _ (set st.*scheduler* "reference")
          TapeRows (map (/. N (fc.negative-row [(fc.at 0 N) (fc.at 1 N) (fc.replay-result (fc.at 2 N))]))
                        (append (fc.tape-negatives Long) (st.tape-negatives Long)))
          Deadlocking (hd (fc.filter (/. P (= (nth 6 (hd (tl P))) "Deadlock")) HandRef))
          AfterEnd (st.run-after-end (hd (hd Deadlocking)) (nth 4 (hd Deadlocking)))
          HostRows (append (map (/. C (fc.negative-row (fc.host-case LongIndex C))) (st.host-cases LongIndex))
                           [(fc.negative-row ["fifo-run-naming-a-task" "BadState@2 exit 3" (st.fifo-named-run LongIndex)])
                            (fc.negative-row ["run-after-deadlock" (cn "NotRunning@" (cn (hd AfterEnd) " exit 3")) (hd (tl AfterEnd))])])
          GuestRows (map (/. C (fc.negative-row [(fc.at 0 C) (fc.at 1 C) (st.scripted-result LongIndex (fc.at 2 C))])) (st.guest-cases LongIndex))
          VectorRows (st.vectors)
          Pass (and (not (empty? Hand)) (not (empty? Recorded)) (not (empty? Sample))
                    (= RefPass (length Recorded)) (= WitnessPass (length Witnesses)) (= Truncated 0)
                    (fc.every? (/. I (element? I WitnessPrograms)) Sample)
                    (= FifoPass (length All)) (empty? Undetected)
                    (= ReplayExact (length Tapes)) (= Identical (length FifoTapes))
                    (fc.rows-pass? TapeRows) (fc.rows-pass? HostRows) (fc.rows-pass? GuestRows) (fc.rows-pass? VectorRows) (> (length VectorRows) 0))
          Report [object ["schema" "fenrir.harness.solo5-tasks/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["protocol" (value fc.*protocol*)] ["machine_profile" (value fc.*profile*)]
                         ["transport" "stock solo5-spt; net devices ctlin=@0 (host->guest pipe) and ctlout=@2 (guest->host pipe); console separate"]
                         ["tender_sha256" (fc.b "tender_sha256")] ["control_sha256" (fc.b "control_sha256")] ["batch_sha256" (fc.b "batch_sha256")]
                         ["solo5" (fh.field "path" (fc.b "solo5_identity"))]
                         ["programs" (str (value fc.*count*))] ["families" (fc.b "families")] ["sample" (fc.b "sample")] ["fuel" (str (value fc.*fuel*))]
                         ["reference_recorded" [object ["runs" (str (length Recorded))] ["agreeing" (str RefPass)]
                                                       ["production_policy_runs" (str (fc.count-if (/. R (nth 3 R)) Recorded 0))]
                                                       ["steps_agreed" (str (st.steps-of RefRuns))]]]
                         ["reference_witnesses" [object ["programs" (str (length Sample))] ["witness_schedules" (str (length Witnesses))]
                                                        ["agreeing" (str WitnessPass)] ["exploration_bound_hit" (str Truncated)]
                                                        ["steps_agreed" (str (st.steps-of WitnessRuns))] ["exploration_milliseconds" (str ExploreMs)]]]
                         ["fifo_guest_scheduler" [object ["runs" (str (length All))] ["agreeing_production_and_fifo" (str FifoPass)]
                                                         ["steps_agreed" (str (st.steps-of FifoRuns))]]]
                         ["failures" (append (st.failures Recorded RefRuns) (st.failures Witnesses WitnessRuns) (st.fifo-failures All FifoRuns))]
                         ["controlled_milliseconds" (str ControlMs)]
                         ["defects" [object | (map (/. D [(hd D) (st.tally (hd (tl D)))]) Defects)]]
                         ["fifo_reversed_runs_production_but_not_fifo" (str (value st.*production-not-fifo*))]
                         ["defects_undetected" Undetected]
                         ["replay" [object ["tapes" (str (length Tapes))] ["reference_tapes" (str (length RefTapes))] ["fifo_tapes" (str (length FifoTapes))]
                                           ["cold_boots_per_tape" "2"] ["tapes_exact_on_every_boot" (str ReplayExact)]
                                           ["fifo_rerecordings_byte_identical" (str Identical)] ["milliseconds" (str ReplayMs)]]]
                         ["tape_negatives" TapeRows]
                         ["hostile_host" HostRows]
                         ["hostile_guest" GuestRows]
                         ["vectors" VectorRows]
                         ["free_run" "refused: the lowering rejects task programs for the free-running image (no scheduler input)"]
                         ["total_boots" (str (value fc.*boots*))]
                         ["milliseconds" (str (- (clock.monotonic) Start))]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 16777216]]))
           (shen-jit.exit (if Pass 0 1)))))

(if (trap-error (value st.*as-library*) (/. E false)) skip (st.main))
