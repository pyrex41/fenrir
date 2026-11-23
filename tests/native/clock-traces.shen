\\ Replay each explicit schedule on the Shen model and retain its full observations.
(set fh.*lib* (cn (nth 2 (value *argv*)) "/"))
(set fh.*root* (cn (nth 3 (value *argv*)) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-task-common.shen"))

(define clock.trace
  Program Row ->
    (let Choices (fh.field "choices" Row)
         Run (fh.task-run (hd Program) (nth 2 Program) Choices 1000)
         Kind (hd Run)
         Key (if (= Kind "Deadlock") "wait_graph" "outcome")
      [object ["policy" (fh.field "policy" Row)] ["execution" Kind]
              [Key (nth 2 Run)] ["steps" (nth 3 Run)]]))

(let Input (json.parse (read-file-as-string (nth 4 (value *argv*))) [[byte-limit 4194304]])
     Program (fh.task-program (fh.field "artifact" Input))
     Runs (map (/. Row (clock.trace Program Row)) (fh.field "schedules" Input))
  (write-to-file (nth 5 (value *argv*)) (json.stringify Runs [[byte-limit 16777216]])))
