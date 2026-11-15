\\ Fenrir harness: the negative control of the generated-family row of the TC1
\\ gate, on its own. It runs that row's check (fh.tc1-random-with, tc1-random-rows.shen)
\\ on one seed with each injected defect of the JavaScript handler machine switched on,
\\ and once with none. Pass: FAIL with every defect, PASS with none.
\\
\\   shen-jit script harness/tc1-random-control.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/gate-core.shen"))
(load (cn (value fh.*root*) "harness/tc1-random-rows.shen"))

(define fh.main
  -> (let Row (fh.tc1-random-control [])
          Report [object ["schema" "fenrir.harness.tc1-random-control/1"]
                         ["status" (if (= (hd Row) "PASS") "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["scope" (make-string "one seed, ~A programs, per injected defect and once with none" (fh.tc1-control-per-seed))]
                         ["row" (hd Row)]
                         ["reasons" (nth 2 Row)]
                         ["family_row_status" [object | (nth 3 Row)]]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if (= (hd Row) "PASS") 0 1)))))

(fh.main)
