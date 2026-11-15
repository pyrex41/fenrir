\\ Fenrir frontend, driver: check, run and emit programs written in the surface
\\ syntax of spec/tc1/SURFACE.md. Run through frontend/fenrir.sh.
\\
\\   shen-jit script frontend/main.shen LIBDIR ROOT WORK COMMAND ARGUMENT...
\\ LIBDIR   Shen/JIT lib directory
\\ ROOT     repository root
\\ WORK     an existing scratch directory; the artifact is written to
\\          WORK/artifact.json and what the user should see to WORK/result
\\ COMMAND  check SOURCE MODULE
\\          run SOURCE MODULE FUEL
\\          emit SOURCE MODULE OUT
\\          run-artifact ARTIFACT FUEL
\\
\\ Loading prints a line per definition on standard output, so the result goes to
\\ a file and the exit status says how to read it:
\\   0 done   1 the program was rejected   2 a file could not be read or written
\\   3 a defect in the frontend            4 the step budget ran out
\\
\\ The stages are kept apart on purpose. The elaborator produces an artifact; two
\\ validators judge those exact bytes: the JavaScript validator, an independent
\\ implementation of the artifact rules, and the Shen one of typing/ (structural
\\ checks, then a derivation found by search and accepted by the fixed checker of
\\ spec/tc1/TYPING.md); the model then runs what is decoded from the same bytes.
\\ A program runs only when both accept. Nothing here interprets a program.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fe.*work* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fe.*command* (tl (tl (tl (tl (value *argv*))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "frontend/reader.shen"))
(load (cn (value fh.*root*) "frontend/elaborate.shen"))
(load (cn (value fh.*root*) "harness/tc1-durable-common.shen"))

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
  Source [L C Message] _ -> (fe.finish 1 (make-string "~A:~A:~A: error: ~A~%" Source L C Message))
  Source [] Error -> (fe.finish 3 (make-string "~A: internal error in the frontend: ~A~%" Source Error)))

\\ ---------- validation ----------

\\ The validator's report on the artifact text at Path: a decoded JSON object.
(define fe.validation
  Path -> (let R (fh.exec "node" [(cn (value fh.*root*) "frontend/validate.mjs") Path] 120)
               Report (fh.last-report (hd (tl R)))
            (if (or (= Report []) (not (= (hd R) 0)))
                (fe.finish 3 (make-string "the artifact validator did not run: ~A~%" (hd (tl (tl R)))))
                Report)))

\\ Write the artifact, have both validators judge it, and return [Text Report
\\ RuleInstances]. A rejection of what the elaborator accepted is a defect here or
\\ in a validator, and so is any disagreement between the two validators: they are
\\ meant to agree, and the program is not run on the strength of one alone.
(define fe.checked
  Source Artifact ->
    (let Text (json.stringify Artifact [[byte-limit 16777216]])
         Path (cn (value fe.*work*) "artifact.json")
         Written (write-to-file Path Text)
      (let Report (fe.validation Path)
        (fe.judged Source Text Report (fe.typing Text (fe.input Report))))))

\\ The entry input both validators judge the artifact with: the one validate.mjs chose
\\ (0, or for a durable program the least value of main's argument type).
(define fe.input
  Report -> (let I (fh.member "input" Report) (if (= I []) ["int" "0"] I)))

\\ The Shen side's verdict on Text. Its files are loaded only when an artifact
\\ exists to judge, which a rejected program never gets to: compiling the search's
\\ sequent rules is most of what the Shen side costs a run (about 0.3 s).
(set fe.*typing-loaded* false)

(define fe.typing
  Text Input -> (do (if (value fe.*typing-loaded*) skip
                  (do (load (cn (value fh.*root*) "typing/validate.shen")) (set fe.*typing-loaded* true)))
              (tv.validate Text Input (value fe.*typing-budget*))))

\\ The Shen side's search budget, in inferences per proof. Running out is UNKNOWN,
\\ which is never acceptance.
(set fe.*typing-budget* 2000000)

\\ Text, the JavaScript validator's report, and the Shen side's verdict (tv.validate):
\\ both accept, both stop at a cap, or both reject; anything else is a disagreement.
(define fe.judged
  Source Text Report Typing -> (fe.judged-by Source Text Report (fh.member "status" Report) Typing))

(define fe.judged-by
  Source Text Report "valid" [valid D] -> (do (fe.verdict Source Text Report "valid") [Text Report (fe.rule-instances D)])
  Source Text Report "limit" [limit _ _] -> (fe.verdict Source Text Report "limit")
  Source Text Report "invalid" [invalid _ _] -> (fe.verdict Source Text Report "invalid")
  Source _ Report _ Typing -> (fe.finish 3 (fe.disagreement Source Report Typing)))

(define fe.disagreement
  Source Report Typing ->
    (make-string "~A: internal error: the two artifact validators disagree: the JavaScript validator says ~A, the Shen typing checker says ~A~%"
                 Source (fe.javascript-reason Report) (fe.typing-reason Typing)))

(define fe.javascript-reason
  Report -> (if (= (fh.member "status" Report) "valid") "valid" (make-string "~A (~A)" (fh.member "status" Report) (fh.member "message" Report))))

(define fe.typing-reason
  [valid _] -> "valid"
  [unknown Why] -> (cn "UNKNOWN, " Why)
  [Status Check Message] -> (make-string "~A (~A: ~A)" Status Check Message)
  [Status Why] -> (make-string "~A (~A)" Status Why))

(define fe.rule-instances
  [_ _ Ps] -> (+ 1 (fe.total (map (/. P (fe.rule-instances P)) Ps))))

(define fe.total
  [] -> 0
  [N | Ns] -> (+ N (fe.total Ns)))

(define fe.verdict
  Source Text Report "valid" ->
    (if (= (fh.member "canonical" Report) true)
        [Text Report]
        (fe.finish 3 (make-string "~A: internal error in the frontend: the artifact is valid but not in canonical encoding~%" Source)))
  Source _ Report "limit" ->
    (fe.finish 1 (make-string "~A: error: the program exceeds a size limit of the artifact validator (~A). Its limits are 200 expression nodes, nesting depth 64, and 256 octets in a bytes literal~%"
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

\\ TC1-D1 (spec/tc1/DURABLE.md): a program with durable effects runs on the durable
\\ model with no host. Its first host request ends the run: run shows it and says that
\\ the program waits for a host (the harness supplies one: harness/run-tc1-durable.sh,
\\ harness/run-service-fenrir.sh). A main that takes a request cannot be run here.
(define fe.execute-durable
  Artifact Fuel ->
    (let Main (hd (fh.keep-main (fh.field "functions" Artifact)))
         Takes (fh.field "argument_type" Main)
         Refused (if (= Takes "I64") true
                     (fe.finish 1 (make-string "the entry function main takes ~A, a request its host supplies: run has only input 0; run it under a host~%" (json.stringify Takes []))))
         Run (dh.run Artifact ["int" "0"] [replies] Fuel)
         Steps (nth 2 Run)
         Text (cn (fe.emissions Steps) (fe.requests (dt.events-of Steps)))
      (cond ((= (hd Run) "Completed")
              (let Outcome (fh.model-outcome Steps)
                (fe.finish 0 (cn Text (make-string "outcome: ~A~%~Asteps: ~A~%" (fe.show-outcome Outcome) (fe.trap-line Outcome Steps Artifact) (length Steps))))))
            ((= (hd Run) "AwaitingHost")
              (fe.finish 0 (cn Text (make-string "outcome: none (waiting for the host's reply; run has no host)~%steps: ~A~%" (length Steps)))))
            (true (fe.finish 4 (cn Text (make-string "outcome: none (stopped after the budget of ~A steps; set FENRIR_FUEL to raise it)~%" Fuel)))))))

(define fh.keep-main
  [] -> []
  [F | Fs] -> (if (= (fh.field "name" F) "main") [F] (fh.keep-main Fs)))

(define dt.events-of
  [] -> []
  [S | Ss] -> (append (fh.field "events" S) (dt.events-of Ss)))

(define fe.requests
  [] -> ""
  [E | Es] -> (cn (if (= (fh.field "kind" E) "HostRequest")
                      (make-string "host request ~A: ~A.~A ~A~%" (fh.field "seq" E) (fh.field "effect" E) (fh.field "operation" E) (fe.show-value (fh.field "value" E)))
                      "")
                  (fe.requests Es)))

\\ Run the artifact decoded from Text and report emissions in order, the outcome
\\ and the number of model steps. Entry input is the harness's fixed 0.
(define fe.execute
  Text Fuel -> (fe.execute-durable (json.parse Text [[byte-limit 16777216]]) Fuel)
    where (fh.starts? "tc1-durable-demo/1" (fh.field "schema_version" (json.parse Text [[byte-limit 16777216]])))
  Text Fuel ->
    (let Artifact (json.parse Text [[byte-limit 16777216]])
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
      (fe.finish 0 (make-string "ok: ~A: ~A, typing derivation of ~A rule instances~%" Source (fe.summary (hd (tl Checked))) (nth 3 Checked))))
  ["run" Source Module Fuel] ->
    (let Checked (fe.checked Source (fe.artifact Source Module))
      (fe.execute (hd Checked) (fe.natural Fuel 0)))
  ["emit" Source Module Out] ->
    (let Checked (fe.checked Source (fe.artifact Source Module))
         Written (trap-error (write-to-file Out (hd Checked))
                             (/. E (fe.finish 2 (make-string "~A: error: the file cannot be written~%" Out))))
      (fe.finish 0 (make-string "wrote ~A: ~A~%" Out (fe.summary (hd (tl Checked))))))
  \\ An existing artifact, such as a hand fixture: validated, then run, and reported
  \\ as run reports. This is how the tests compare a surface program with a fixture.
  ["run-artifact" Path Fuel] ->
    (let Text (trap-error (read-file-as-string Path)
                          (/. E (fe.finish 2 (make-string "~A: error: the file cannot be read~%" Path))))
         Report (fe.validation Path)
         Typing (fe.typing Text (fe.input Report))
         Status (fh.member "status" Report)
      (if (and (= Status "valid") (= (hd Typing) valid))
          (fe.execute Text (fe.natural Fuel 0))
          (if (or (= Status "valid") (= (hd Typing) valid) (= (hd Typing) unknown))
              (fe.finish 3 (fe.disagreement Path Report Typing))
              (fe.finish 1 (make-string "~A: error: not a valid artifact (~A)~%" Path (fh.member "message" Report))))))
  _ -> (fe.finish 3 (make-string "internal error: frontend/main.shen was started with arguments it does not understand~%")))

(fe.command (value fe.*command*))
