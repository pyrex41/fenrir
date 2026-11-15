\\ Fenrir harness, in Shen: strict replay for TC1 handlers. A tape of the JavaScript
\\ handler machine is recorded against the model's reference trace and replayed on a
\\ fresh machine (tools/tc1/replay-reference.mjs; the tape binds the program, the
\\ reference, the implementation source and defect switches, and the handler catalog).
\\ Development evidence only.
\\
\\   shen-jit script harness/tc1-strict-replay.shen LIBDIR ROOT OUTDIR [sandbox]
\\
\\ Pass requires all of:
\\   every TC1 hand fixture agrees with the model and its handwritten expectations
\\     (harness/expectations.shen), and its tape replays exactly and is admitted;
\\   every retained failure (fixtures/tc1/handler-retained-failures.json, the original
\\     and minimized cases of the reduction campaigns): without defects its tape is
\\     admitted, and with its defect switched on the tape diverges at exactly the
\\     retained epoch.
\\ The model's traces are computed here, fresh; nothing the files say about a trace is
\\ taken on trust except the divergence epoch, which is the expectation.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*sandbox* (element? "sandbox" (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/expectations.shen"))
(load (cn (value fh.*root*) "harness/tc1-replay.shen"))

(define fh.s-retained -> "fixtures/tc1/handler-retained-failures.json")
(define fh.s-fuel -> 1000)

(define fh.s-failed
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (fh.s-failed Rest) [[object ["case" Name] ["reasons" Reasons]] | (fh.s-failed Rest)]))

(define fh.s-not
  _ [] -> []
  Test [R | Rs] -> (if (Test R) (fh.s-not Test Rs) [(fh.member "name" R) | (fh.s-not Test Rs)]))

\\ The hand fixtures: agreement and expectations first; only agreeing cases are replayed.
(define fh.s-hand
  -> (let File (cn (value fh.*out*) "handlers.jsonl")
          R (process.run "node" (fh.node-arguments "tools/tc1/run-handler-cases.mjs" [File] ["runtime/tc1" "tools/tc1" "fixtures/tc1"] File (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 120000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript handler run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (fh.check-case Row)) Rows)
          Failures (fh.s-failed Results)
          Replayed (if (empty? Failures)
                       (fh.tc1-replay "hand" (map (/. R [(hd R) (nth 5 R) (nth 6 R) null]) Results) (value fh.*out*) (value fh.*sandbox*))
                       [])
       [(length Rows) Failures Replayed]))

(define fh.s-model
  Program -> (let Run (fh.run (fh.state Program) (fh.s-fuel) 0 [])
               (if (= (hd Run) "Completed") (hd (tl Run)) (error "harness: the model does not complete a retained failure"))))

\\ The retained failures: [Cases FixedResults DefectiveResults].
(define fh.s-retained-replay
  -> (let Retained (json.parse (read-file-as-string (cn (value fh.*root*) (fh.s-retained))) [[byte-limit 16777216]])
          Cases (map (/. C [(fh.field "name" C) (fh.field "program" C) (fh.s-model (fh.field "program" C)) (fh.field "defect" C)
                            (fh.field "divergence_epoch" C) (fh.field "role" C)])
                     (fh.field "cases" Retained))
          Fixed (fh.tc1-replay "retained-fixed" (map (/. C [(hd C) (nth 2 C) (nth 3 C) null]) Cases) (value fh.*out*) (value fh.*sandbox*))
          Defective (fh.tc1-replay "retained-defective" (map (/. C [(hd C) (nth 2 C) (nth 3 C) (nth 4 C)]) Cases) (value fh.*out*) (value fh.*sandbox*))
       [Cases Fixed Defective]))

\\ Names of retained cases whose defective replay did not diverge at the retained epoch.
(define fh.s-not-diverged
  [] _ -> []
  [C | Cs] Results -> (let R (fh.s-result (hd C) Results)
                        (if (and (not (= R [])) (fh.diverged-at? (nth 5 C) R))
                            (fh.s-not-diverged Cs Results)
                            [(hd C) | (fh.s-not-diverged Cs Results)])))

(define fh.s-result
  _ [] -> []
  Name [R | Rs] -> (if (= (fh.member "name" R) Name) R (fh.s-result Name Rs)))

\\ The defects with both an original and a minimized retained case.
(define fh.s-defects
  Cases -> (fh.s-paired (map (/. C (nth 4 C)) Cases) Cases))

(define fh.s-paired
  [] _ -> []
  [D | Ds] Cases -> (let Rest (fh.s-paired Ds Cases)
                      (if (and (not (element? D Rest)) (fh.s-has? D "original" Cases) (fh.s-has? D "minimized" Cases)) [D | Rest] Rest)))

(define fh.s-has?
  _ _ [] -> false
  D Role [C | Cs] -> (or (and (= (nth 4 C) D) (= (nth 6 C) Role)) (fh.s-has? D Role Cs)))

(define fh.main
  -> (let Hand (fh.s-hand)
          HandCount (hd Hand)
          HandFailures (hd (tl Hand))
          HandReplayed (nth 3 Hand)
          HandNotAdmitted (fh.s-not (/. R (fh.admitted? R)) HandReplayed)
          Retained (fh.s-retained-replay)
          Cases (hd Retained)
          FixedNotAdmitted (fh.s-not (/. R (fh.admitted? R)) (nth 2 Retained))
          NotDiverged (fh.s-not-diverged Cases (nth 3 Retained))
          Pass (and (> HandCount 0) (empty? HandFailures) (= (length HandReplayed) HandCount) (empty? HandNotAdmitted)
                    (> (length Cases) 0) (= (length (nth 2 Retained)) (length Cases)) (= (length (nth 3 Retained)) (length Cases))
                    (empty? FixedNotAdmitted) (empty? NotDiverged))
          Report [object ["schema" "fenrir.harness.tc1-strict-replay/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["hand_cases" (str HandCount)]
                         ["hand_failures" HandFailures]
                         ["hand_admitted" (str (- (length HandReplayed) (length HandNotAdmitted)))]
                         ["hand_not_admitted" HandNotAdmitted]
                         ["retained_cases" (str (length Cases))]
                         ["retained_defects" (fh.s-defects Cases)]
                         ["retained_fixed_admitted" (str (- (length (nth 2 Retained)) (length FixedNotAdmitted)))]
                         ["retained_fixed_not_admitted" FixedNotAdmitted]
                         ["retained_diverged_at_epoch" (str (- (length Cases) (length NotDiverged)))]
                         ["retained_not_diverged" NotDiverged]
                         ["catalog_hash" (if (empty? HandReplayed) "" (fh.member "catalog_hash" (hd HandReplayed)))]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
