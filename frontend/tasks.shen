\\ ---------- TC1-C1: a task program runs under a schedule ----------

\\ The schedule is an input of the model (CONCURRENCY.md section 9). By default it is
\\ the production FIFO schedule; a policy (lowest, highest, random:N, prandom:N, fifo) or
\\ a file holding a JSON list of task IDs may be given instead. A policy is turned into
\\ choices by frontend/schedule.mjs; the model replays them, refusing any choice that is
\\ not Runnable in its own state, and the run says which schedule it used and whether
\\ the model's own records make it a production schedule.
(define fe.policy?
  S -> (or (element? S ["fifo" "lowest" "highest"]) (fh.starts? "random:" S) (fh.starts? "prandom:" S)))

(define fe.choices
  _ "" _ _ -> (fe.finish 2 (make-string "a schedule policy or file path is required~%"))
  Path Schedule Fuel Profile ->
    (if (fe.policy? Schedule)
        (let R (fh.exec "node" [(cn (value fh.*root*) "frontend/schedule.mjs") Path Schedule (str Fuel) Profile] 120)
             J (fh.last-report (hd (tl R)))
          (if (and (= (hd R) 0) (cons? J) (fe.schedule-ids? (fh.field "choices" J))) (fh.field "choices" J)
              (fe.finish 2 (make-string "the schedule policy ~A could not be applied: ~A~%" Schedule (hd (tl (tl R)))))))
        (let Input (fh.process-result (io.read-file Schedule 1048576))
             J (fe.schedule-file Schedule Input)
          (if (fe.schedule-ids? J) J
              (fe.finish 2 (make-string "~A: error: a schedule file holds a JSON list of task IDs, such as [c#34;0c#34;,c#34;1c#34;]~%" Schedule))))))

(define fe.schedule-file
  Schedule [ok Bytes] ->
    (trap-error (json.decode Bytes [[byte-limit 1048576] [depth-limit 2]])
                (/. E (fe.finish 2 (make-string "~A: error: the schedule file is not a bounded JSON list~%" Schedule))))
  Schedule _ -> (fe.finish 2 (make-string "~A: error: cannot read the schedule file (file or size limit)~%" Schedule)))

(define fe.schedule-ids?
  [] -> true
  [X | Xs] -> (and (string? X) (fe.decimal-id? X) (fe.schedule-ids? Xs))
  _ -> false)

(define fe.native-profile
  "portable" -> (set tm.*spawn-limits* [])
  Profile ->
    (let Path (cn (value fh.*root*) "spec/native/standalone-v1.json")
         Manifest (json.parse (read-file-as-string Path) [[byte-limit 65536]])
         Limits (fh.field "limits" Manifest)
         Children (json.integer (fh.field "max_live_nonroot_children" Limits))
         Handlers (json.integer (fh.field "max_inherited_handlers" Limits))
      (if (and (= Profile (fh.field "id" Manifest)) (> Children 0) (>= Handlers 0))
          (set tm.*spawn-limits* [Children Handlers])
          (fe.finish 2 (make-string "invalid task limits for execution profile ~A~%" Profile)))))

(define fe.decimal-id?
  "" -> false
  "0" -> true
  (@s "0" _) -> false
  S -> (and (<= (length (explode S)) 20) (fe.all? (/. C (fe.digit? (string->n C))) (explode S))))

(define fe.task-emissions
  [] -> ""
  [Step | Steps] -> (cn (fe.task-emit-lines (fh.field "events" Step)) (fe.task-emissions Steps)))

(define fe.task-emit-lines
  [] -> ""
  [E | Es] -> (cn (if (= (fh.field "kind" E) "Emit")
                      (make-string "emit ~S: ~A (task ~A)~%" (fh.field "label" E) (fe.show-value (fh.field "value" E)) (fh.field "task" E))
                      "")
                  (fe.task-emit-lines Es)))

(define fe.show-task-outcome
  ["Cancelled"] -> "Cancelled"
  O -> (fe.show-outcome O))

(define fe.wait-text
  [object ["await" X] ["task" T]] -> (make-string "task ~A awaits task ~A" T X)
  [object ["receive" X] ["task" T]] -> (make-string "task ~A receives on channel ~A" T X)
  [object ["send" X] ["task" T]] -> (make-string "task ~A sends on channel ~A" T X)
  [object ["join" X] ["task" T]] -> (make-string "task ~A joins scope ~A" T X)
  [object ["running" _] ["task" T]] -> (make-string "task ~A is running" T))

(define fe.waits
  [W] -> (fe.wait-text (fh.canon W))
  [W | Ws] -> (cn (fe.wait-text (fh.canon W)) (cn ", " (fe.waits Ws))))

(define fe.execute-tasks
  Text Artifact Fuel Schedule Profile ->
    (let Path (cn (value fe.*work*) "run-artifact.json")
         Written (write-to-file Path Text)
         _ (fe.native-profile Profile)
         Choices (fe.choices Path Schedule Fuel Profile)
         Program (fh.task-program Artifact)
         Run (fh.task-run (hd Program) (hd (tl Program)) Choices Fuel)
         Steps (nth 3 Run)
         Production (fh.production? Steps)
         Kind (if (fe.policy? Schedule) (cn "policy " Schedule) (cn "file " Schedule))
         Said (make-string "schedule: ~A, ~A~%" Kind
                           (if Production "a production schedule by the model's records" "a reference schedule, not a production one"))
         Defect (if (and (not Production) (or (= Schedule "fifo") (fh.starts? "prandom:" Schedule)))
                    (fe.finish 3 (make-string "internal error: the production policy ~A gave a schedule the model's records do not make a production schedule~%" Schedule))
                    true)
         Body (fe.task-emissions Steps)
         Complete (element? (hd Run) ["Completed" "Deadlock"])
         Exact (if (and Complete (not (= (length Steps) (length Choices))))
                   (fe.schedule-error Schedule (fe.policy? Schedule) "the schedule has unused choices after termination")
                   true)
      (cond ((= (hd Run) "Completed")
              (fe.finish 0 (cn Body (make-string "outcome: ~A~%~Asteps: ~A~%" (fe.show-task-outcome (nth 2 Run)) Said (length Steps)))))
            ((= (hd Run) "Deadlock")
              (fe.finish 0 (cn Body (make-string "outcome: deadlock: ~A~%~Asteps: ~A~%" (fe.waits (nth 2 Run)) Said (length Steps)))))
            ((= (hd Run) "ScheduleDiverged")
              (fe.schedule-error Schedule (fe.policy? Schedule)
                 (make-string "the schedule chooses task ~A at step ~A, which is not Runnable there" (nth (+ 1 (length Steps)) Choices) (length Steps))))
            ((= (hd Run) "ScheduleIncomplete")
              (fe.schedule-error Schedule (fe.policy? Schedule)
                 (make-string "the schedule ended after ~A choices before the run did" (length Steps))))
            (true (fe.finish 4 (cn Body (make-string "outcome: none (stopped after the budget of ~A steps; set FENRIR_FUEL to raise it)~%" Fuel)))))))

(define fe.schedule-error
  Schedule true Message -> (fe.finish 3 (make-string "internal error: policy ~A: ~A~%" Schedule Message))
  Schedule false Message -> (fe.finish 1 (make-string "~A: error: ~A~%" Schedule Message)))
