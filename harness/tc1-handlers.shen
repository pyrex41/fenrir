\\ Fenrir harness, in Shen: TC1 user effects (contract spec/tc1/EFFECTS.md), both
\\ slices: tail-resumptive handlers (H1) and explicit one-shot resumptions (H2). For every hand fixture the Shen model
\\ and the JavaScript implementation must agree step for step and both must
\\ satisfy the handwritten expectations; and each defect injected into the
\\ implementation must be detected on at least one fixture. A defective run that
\\ crashes is counted separately and never as a detection.
\\ Development evidence only.
\\
\\   shen-jit script harness/tc1-handlers.shen LIBDIR ROOT OUTDIR [sandbox]

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*sandbox* (element? "sandbox" (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/expectations.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))

(define fh.failed
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (fh.failed Rest) [[object ["case" Name] ["reasons" Reasons]] | (fh.failed Rest)]))

(define fh.sum
  [] _ N -> N
  [R | Rs] F N -> (fh.sum Rs F (+ N (F R))))

\\ Only cases on which the model and the implementation agree give a reference for the defects.
(define fh.all-mutants
  [] [] Tally -> Tally
  [Row | Rows] [[_ Reasons _ _ _ Steps] | Results] Tally ->
    (fh.all-mutants Rows Results (if (= Reasons []) (fh.tally-mutants (tl (fh.field "mutants" Row)) Steps Tally) Tally)))

(define fh.main
  -> (let File (cn (value fh.*out*) "handlers.jsonl")
          R (fh.run-process "node" (fh.node-arguments "tools/tc1/run-handler-cases.mjs" [File] ["runtime/tc1" "tools/tc1" "fixtures/tc1"] File (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 120000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript handler run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (fh.check-case Row)) Rows)
          Failures (fh.failed Results)
          Tally (fh.all-mutants Rows Results [])
          Undetected (fh.undetected Tally)
          Crashing (fh.crashing Tally)
          Unreported (fh.unreported (fh.defect-names) Tally)
          Pass (and (empty? Failures) (> (length Rows) 0) (empty? Unreported) (empty? Undetected))
          Report [object ["schema" "fenrir.harness.tc1-handlers/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["slices" "TC1-H1 tail-resumptive handlers; TC1-H2 explicit one-shot resumptions"]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["cases" (str (length Rows))]
                         ["expectations_checked" (str (fh.sum Results (/. R (nth 3 R)) 0))]
                         ["model_steps" (str (fh.sum Results (/. R (nth 4 R)) 0))]
                         ["defects" (fh.tally-json Tally)]
                         ["defects_undetected" (append Unreported Undetected)]
                         ["defects_crashing" Crashing]
                         ["failures" Failures]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
