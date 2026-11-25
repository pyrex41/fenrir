\\ Fenrir frontend, driver: check, run and emit programs written in the surface
\\ syntax of spec/tc1/SURFACE.md. Run through frontend/fenrir.sh.
\\
\\   shen-jit script frontend/main.shen LIBDIR ROOT WORK COMMAND ARGUMENT...
\\ LIBDIR   Shen/JIT lib directory
\\ ROOT     repository root
\\ WORK     an existing scratch directory; the artifact is written to
\\          WORK/artifact.json and what the user should see to WORK/result
\\ COMMAND  check SOURCE MODULE
\\          run SOURCE MODULE FUEL [SCHEDULE]
\\          emit SOURCE MODULE OUT
\\          run-artifact ARTIFACT FUEL [SCHEDULE]
\\
\\ Loading prints a line per definition on standard output, so the result goes to
\\ a file and the exit status says how to read it:
\\   0 done   1 the program was rejected   2 a file could not be read or written,
\\   or the program cannot run alone (it needs its host, peer, or model)
\\   3 a defect in the frontend            4 the step budget ran out
\\
\\ The stages are kept apart on purpose. The elaborator produces an artifact; the
\\ JavaScript validator, an independent implementation of the artifact rules,
\\ judges those exact bytes; the model then runs what is decoded from the same
\\ bytes. Nothing here interprets a program.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fe.*work* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fe.*command* (tl (tl (tl (tl (value *argv*))))))
(set fe.*require-shen-typing* (and (cons? (value fe.*command*)) (= (hd (value fe.*command*)) "require-shen-typing")))
(if (value fe.*require-shen-typing*) (set fe.*command* (tl (value fe.*command*))) skip)
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "frontend/reader.shen"))
(load (cn (value fh.*root*) "frontend/elaborate.shen"))

(define fe.finish
  Status Text -> (do (write-to-file (cn (value fe.*work*) "result") Text)
                     (shen-jit.exit Status)))

(define fe.natural
  "" N -> N
  (@s D Ds) N -> (fe.natural Ds (+ (* N 10) (- (string->n D) 48))))

\\ ---------- elaboration ----------

\\ The artifact for Source, or no return: a diagnostic ends the run with status 1.
(define fe.artifact
  Source Module ->
    (let Octets (trap-error (read-file-as-bytelist Source)
                            (/. E (fe.finish 2 (make-string "~A: error: the file cannot be read~%" Source))))
         Cleared (set fe.*diagnostic* [])
      (trap-error (fe.elaborate Source Module Octets)
                  (/. E (fe.rejected Source (value fe.*diagnostic*) (error-to-string E))))))

(define fe.rejected
  \\ a problem inside an included file is reported at that file
  _ [L C Message File] _ -> (fe.finish 1 (make-string "~A:~A:~A: error: ~A~%" File L C Message))
  Source [L C Message] _ -> (fe.finish 1 (make-string "~A:~A:~A: error: ~A~%" Source L C Message))
  Source [] Error -> (fe.finish 3 (make-string "~A: internal error in the frontend: ~A~%" Source Error)))

\\ ---------- validation ----------

\\ The validator's report on the artifact text at Path: a decoded JSON object.
(define fe.validation
  Path -> (let Args [(cn (value fh.*root*) "frontend/validate.mjs") Path]
               R (fh.exec "node" (if (value fe.*require-shen-typing*) (append Args ["--with-input"]) Args) 120)
               Report (fh.last-report (hd (tl R)))
            (if (or (= Report []) (not (= (hd R) 0)))
                (fe.finish 3 (make-string "the artifact validator did not run: ~A~%" (hd (tl (tl R)))))
                Report)))

\\ Write the artifact, have it validated, and return [Text Report]. A rejection
\\ of what the elaborator accepted is a defect here or in the validator.
(define fe.checked
  Source Artifact ->
    (let Text (json.stringify Artifact [[byte-limit 16777216]])
         Path (cn (value fe.*work*) "artifact.json")
         Written (write-to-file Path Text)
         Report (fe.validation Path)
         Checked (fe.verdict Source Text Report (fh.member "status" Report))
         Typing (fe.require-typing Source Text Report)
      Checked))

\\ Run only after JavaScript validation. In strict mode both must accept the
\\ same text and input; a missing/unsupported checker is not a fallback.
(define fe.require-typing
  _ _ _ -> true where (not (value fe.*require-shen-typing*))
  Source Text Report ->
    (let Loaded (load (cn (value fh.*root*) "typing/validate.shen"))
         Input (fh.field "input" Report)
      (fe.typing-verdict Source (tv.validate Text Input 2000000))))

(define fe.typing-verdict
  _ [valid _] -> true
  Source [unsupported Schema] ->
    (fe.finish 2 (make-string "~A: Shen typing does not support schema ~A~%" Source Schema))
  Source [unknown Why] ->
    (fe.finish 2 (make-string "~A: Shen typing UNKNOWN: ~A~%" Source Why))
  Source [Status Check Message] ->
    (fe.finish 3 (make-string "~A: JavaScript validation accepted, but Shen typing says ~A (~A: ~A)~%" Source Status Check Message)))

(define fe.verdict
  Source Text Report "valid" ->
    (if (= (fh.member "canonical" Report) true)
        [Text Report]
        (fe.finish 3 (make-string "~A: internal error in the frontend: the artifact is valid but not in canonical encoding~%" Source)))
  Source _ Report "limit" ->
    (fe.finish 1 (make-string "~A: error: the program exceeds a size limit of the artifact validator (~A)~%"
                              Source (fh.member "message" Report)))
  Source _ Report _ ->
    (fe.finish 3 (make-string "~A: internal error: the artifact validator rejects what the frontend produced (~A). The elaborator should have reported this itself~%"
                              Source (fh.member "message" Report))))

(define fe.summary
  Report -> (make-string "~A, ~A, artifact sha256 ~A"
                         (fe.plural (fe.natural (fh.member "functions" Report) 0) "function")
                         (fe.plural (fe.natural (fh.member "nodes" Report) 0) "node")
                         (fh.member "sha256" Report)))

\\ ---------- running on the model ----------

\\ A value in surface syntax.
(define fe.show-value
  ["unit"] -> "unit"
  ["int" N] -> N
  ["bool" B] -> (if B "true" "false")
  ["bytes" Hex] -> (cn "#x" Hex)
  ["tuple" | Vs] -> (cn "(tuple" (cn (fe.spaced (map (/. V (fe.show-value V)) Vs)) ")"))
  ["data" _ Constructor] -> Constructor
  ["data" _ Constructor | Vs] -> (cn "(" (cn Constructor (cn (fe.spaced (map (/. V (fe.show-value V)) Vs)) ")"))))

(define fe.show-outcome
  ["Ok" V] -> (cn "Ok " (fe.show-value V))
  ["Trap" Code] -> (cn "Trap " Code))

(define fe.emit-lines
  [] -> ""
  [[object ["kind" "Emit"] | Rest] | Events] ->
    (cn (make-string "emit ~S: ~A~%" (fh.assoc "label" Rest) (fe.show-value (fh.assoc "value" Rest))) (fe.emit-lines Events))
  [_ | Events] -> (fe.emit-lines Events))

(define fe.emissions
  [] -> ""
  [Step | Steps] -> (cn (fe.emit-lines (fh.field "events" Step)) (fe.emissions Steps)))

\\ Where a trap arose: the node of the first step that left the machine unwinding,
\\ through the source map. Nothing is said when the map has no real position
\\ (the hand fixtures use line 0).
(define fe.trap-node
  [] -> []
  [Step | Steps] -> (if (= (fh.field "after" Step) "Unwind") (fh.member "node" (fh.field "site" Step)) (fe.trap-node Steps)))

(define fe.position
  _ [] -> ""
  Id [[object ["column" C] ["file" File] ["id" Id] ["line" L]] | _] ->
    (if (= L "0") "" (make-string "trap at: ~A:~A:~A~%" File L C))
  Id [_ | Rows] -> (fe.position Id Rows))

(define fe.trap-line
  ["Trap" _] Steps Artifact -> (fe.position (fe.trap-node Steps) (map (/. R (fh.canon R)) (fh.field "source_map" Artifact)))
  _ _ _ -> "")

\\ The remote effects the entry function leaves to the system (schema /3): the
\\ entry's effect set without Emit. Empty for every program that can run alone.
(define fe.entry-function
  Name [F | Fs] -> (if (= (fh.field "name" F) Name) F (fe.entry-function Name Fs)))

(define fe.left-to-the-system
  Artifact -> (remove "Emit" (fh.field "effects" (fe.entry-function (fh.field "entry" Artifact) (fh.field "functions" Artifact)))))

\\ The durable harness is optional for check/emit and for running older slices.
\\ Run the D1 model with no replies: the first HostRequest ends the run.
(define fe.execute-durable
  Artifact Fuel ->
    (let Takes (fh.field "type" (fh.field "input_schema" Artifact))
         Fixed (if (= Takes "I64") true
                   (fe.finish 2 (make-string "this program cannot be run alone: the entry takes a request its host supplies, and run has only I64 input 0. check and emit work on it~%")))
         Ready (trap-error (load (cn (value fh.*root*) "harness/tc1-durable-common.shen"))
                           (/. E (fe.finish 2 (make-string "cannot run TC1-D1 without the durable model harness (~A). check and emit work on it~%" (error-to-string E)))))
         Run (dh.run Artifact ["int" "0"] [replies] Fuel)
         Steps (nth 2 Run)
         Text (fe.durable-observations Steps)
      (cond ((= (hd Run) "Completed")
              (let Outcome (fh.model-outcome Steps)
                (fe.finish 0 (cn Text (make-string "outcome: ~A~%~Asteps: ~A~%" (fe.show-outcome Outcome) (fe.trap-line Outcome Steps Artifact) (length Steps))))))
            ((= (hd Run) "AwaitingHost")
              (fe.finish 0 (cn Text (make-string "outcome: none (waiting for the host's reply; run has no host)~%steps: ~A~%" (length Steps)))))
            ((= (hd Run) "BudgetExhausted")
              (fe.finish 4 (cn Text (make-string "outcome: none (stopped after the budget of ~A steps; set FENRIR_FUEL to raise it)~%" Fuel))))
            (true (fe.finish 3 (make-string "unexpected durable model execution: ~A~%" (hd Run)))))))

(define fe.host-event
  Event -> (if (= (fh.field "kind" Event) "HostRequest")
               (make-string "host request ~A: ~A.~A ~A~%" (fh.field "seq" Event) (fh.field "effect" Event)
                           (fh.field "operation" Event) (fe.show-value (fh.field "value" Event)))
               (fe.emit-lines [Event])))

(define fe.durable-observations
  [] -> ""
  [Step | Steps] ->
    (cn (fe.durable-event-lines (fh.field "events" Step))
        (fe.durable-observations Steps)))

(define fe.durable-event-lines
  [] -> ""
  [E | Es] -> (cn (fe.host-event E) (fe.durable-event-lines Es)))

\\ Run the artifact decoded from Text and report emissions in order, the outcome
\\ and the number of model steps. Entry input is the harness's fixed 0.
\\ A program that leaves a remote effect to the system is not run here: the
\\ outcome of a remote perform comes from a supervisor and a peer, and this
\\ driver has neither.
(define fe.execute
  Text Fuel Schedule Profile ->
    (let Artifact (json.parse Text [[byte-limit 16777216]])
         Schema (fh.field "schema_version" Artifact)
      (cond ((element? Schema ["tc1-task-demo/1" "tc1-time-demo/1"])
              (do (load (cn (value fh.*root*) "harness/tc1-task-common.shen"))
                  (load (cn (value fh.*root*) "frontend/tasks.shen"))
                  (fe.execute-tasks Text Artifact Fuel (if (= Schedule default) "fifo" Schedule) Profile)))
            ((not (= Schedule default))
              (fe.finish 2 (make-string "a schedule applies only to TC1-C1 task programs~%")))
            ((= Schema "tc1-durable-demo/1") (fe.execute-durable Artifact Fuel))
            (true (fe.execute-handler Artifact Fuel)))))

(define fe.execute-handler
  Artifact Fuel ->
    (let Entered (if (= (fh.field "schema_version" Artifact) "tc1-handler-demo/4")
                     (fe.finish 2 (make-string "this program cannot be run alone: it serves a remote effect, and its implementations run inside a peer image, once for each request (sh harness/run-tc1-remote-run.sh builds and runs one). check and emit work on it~%"))
                     true)
         Far (fe.left-to-the-system Artifact)
         Alone (if (empty? Far) true
                   (fe.finish 2 (make-string "this program cannot be run alone: main performs the remote effect ~A, which only a system of images discharges (sh harness/run-tc1-remote-run.sh builds and runs one). check and emit work on it~%" (hd Far))))
         Run (fh.run (fh.state Artifact) Fuel 0 [])
         Steps (hd (tl Run))
      (if (= (hd Run) "Completed")
          (let Outcome (fh.model-outcome Steps)
            (fe.finish 0 (cn (fe.emissions Steps)
                             (make-string "outcome: ~A~%~Asteps: ~A~%" (fe.show-outcome Outcome) (fe.trap-line Outcome Steps Artifact) (length Steps)))))
          (fe.finish 4 (cn (fe.emissions Steps)
                           (make-string "outcome: none (stopped after the budget of ~A steps; set FENRIR_FUEL to raise it)~%" Fuel))))))

\\ ---------- commands ----------

(define fe.command
  ["check" Source Module] ->
    (let Checked (fe.checked Source (fe.artifact Source Module))
      (fe.finish 0 (make-string "ok: ~A: ~A~%" Source (fe.summary (hd (tl Checked))))))
  ["run" Source Module Fuel] -> (fe.command ["run" Source Module Fuel default "portable"])
  ["run" Source Module Fuel Schedule] -> (fe.command ["run" Source Module Fuel Schedule "portable"])
  ["run" Source Module Fuel Schedule Profile] ->
    (if (element? Profile ["portable" "fenrir-native-standalone/1"])
        (let Checked (fe.checked Source (fe.artifact Source Module))
          (fe.execute (hd Checked) (fe.natural Fuel 0) Schedule Profile))
        (fe.finish 2 (make-string "unknown execution profile ~A~%" Profile)))
  ["emit" Source Module Out] ->
    (let Checked (fe.checked Source (fe.artifact Source Module))
         Manifest (write-to-file (cn (value fe.*work*) "inputs.json")
                       (json.stringify (value fe.*input-files*) [[byte-limit 16777216]]))
         Written (trap-error (write-to-file Out (hd Checked))
                             (/. E (fe.finish 2 (make-string "~A: error: the file cannot be written~%" Out))))
      (fe.finish 0 (make-string "wrote ~A: ~A~%" Out (fe.summary (hd (tl Checked))))))
  \\ An existing artifact, such as a hand fixture: validated, then run, and reported
  \\ as run reports. This is how the tests compare a surface program with a fixture.
  ["run-artifact" Path Fuel] -> (fe.command ["run-artifact" Path Fuel default "portable"])
  ["run-artifact" Path Fuel Schedule] -> (fe.command ["run-artifact" Path Fuel Schedule "portable"])
  ["run-artifact" Path Fuel "" Profile] -> (fe.command ["run-artifact" Path Fuel default Profile])
  ["run-artifact" Path Fuel Schedule Profile] ->
    (if (element? Profile ["portable" "fenrir-native-standalone/1"])
        (fe.run-checked-artifact Path (fe.snapshot Path) (fe.natural Fuel 0) Schedule Profile)
        (fe.finish 2 (make-string "unknown execution profile ~A~%" Profile)))
    where (value fe.*require-shen-typing*)
  ["run-artifact" Path Fuel Schedule Profile] ->
    (if (element? Profile ["portable" "fenrir-native-standalone/1"])
        (fe.run-checked-artifact Path Path (fe.natural Fuel 0) Schedule Profile)
        (fe.finish 2 (make-string "unknown execution profile ~A~%" Profile)))
  _ -> (fe.finish 3 (make-string "internal error: frontend/main.shen was started with arguments it does not understand~%")))

\\ In strict mode both validators and the model consume one byte snapshot.
(define fe.snapshot
  Path -> (let Result (fh.process-result (io.read-file Path 1048577))
               Snapshot (cn (value fe.*work*) "artifact.json")
            (fe.save-snapshot Path Result Snapshot)))

(define fe.save-snapshot
  Source [ok Bytes] Dest ->
    (if (result.ok? (io.write-file Dest Bytes)) Dest
        (fe.finish 2 (make-string "~A: error: cannot write an artifact snapshot~%" Source)))
  Source _ _ -> (fe.finish 2 (make-string "~A: error: cannot read an artifact snapshot (file or size limit)~%" Source)))

(define fe.run-checked-artifact
  Source Path Fuel Schedule Profile ->
    (let Text (trap-error (read-file-as-string Path)
                          (/. E (fe.finish 2 (make-string "~A: error: the file cannot be read~%" Source))))
         Report (fe.validation Path)
      (if (= (fh.member "status" Report) "valid")
          (do (fe.require-typing Source Text Report) (fe.execute Text Fuel Schedule Profile))
          (fe.finish 1 (make-string "~A: error: not a valid artifact (~A)~%" Source (fh.member "message" Report))))))

(fe.command (value fe.*command*))
