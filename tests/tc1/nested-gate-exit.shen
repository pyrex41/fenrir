\\ Run from the checkout root:
\\ "$FENRIR_SHEN_JIT/bin/shen-jit" script tests/tc1/nested-gate-exit.shen "$FENRIR_SHEN_JIT/lib" "$PWD" /private/output/dir "$FENRIR_SHEN_JIT/bin/shen-jit"
\\ The output directory must already exist and be private to this test. No guests,
\\ sandbox or qualification run: exercise real TC1 rows with fixture children.

(define test.expect
  Expected Actual -> (if (= Expected Actual) true (error "Expected ~A, got ~A" Expected Actual)))

(define test.callee
  [fn Name] -> Name
  [Call Arg] -> (test.callee Call)
  _ -> unknown)

\\ Load the real row definitions without invoking the gate's entry point.
(let Reversed (reverse (read-file (cn (nth 3 (value *argv*)) "/harness/tc1-gate.shen")))
     Checked (test.expect fh.gate-main (test.callee (hd Reversed)))
  (map (/. Form (eval Form)) (reverse (tl Reversed))))

(define test.child
  Report Exit ->
    (let Text (json.stringify Report [])
         Child (cn (value fh.*out*) "child")
         Written (write-to-file Child (make-string "#!/bin/sh~%printf '%s~%' '~A'~%exit ~A~%" Text Exit))
         Made (fh.exec "chmod" ["+x" Child] 5)
         Ready (test.expect 0 (hd Made))
      (set fh.*jit* Child)))

(define test.prerequisite
  Verdict Exit Expected ->
    (do (test.child [object ["schema" "tc0-a-gate-run/3"] ["head" "test-head"]
                            ["verdict" Verdict] ["rows" []] ["waivers" []]
                            ["required_rows_passing" "1/1"] ["authority" "owner-accepted, registered"]
                            ["qualification" Verdict] ["claims" []]] Exit)
        (test.expect Expected (hd (fh.tc0-a-gate [["head" "test-head"]])))))

(define test.exhaustive
  Status Exit Expected ->
    (do (test.child [object ["schema" "fenrir.harness.tc1-exhaustive/1"] ["status" Status]
                            ["scope_complete" true] ["programs" (fh.tc1-programs)] ["agreeing" (fh.tc1-programs)]
                            ["model_steps" "1"] ["outcomes" [object]] ["defects" [object]]] Exit)
        (test.expect Expected (hd (fh.tc1-exhaustive [])))))

(test.prerequisite "PASS" 0 "PASS")
(test.prerequisite "PASS" 1 "UNKNOWN")
(test.prerequisite "FAIL" 1 "FAIL")
(test.prerequisite "BLOCKED" 2 "BLOCKED")
(test.exhaustive "development-pass" 0 "PASS")
(test.exhaustive "development-pass" 1 "UNKNOWN")
(test.exhaustive "development-fail" 1 "FAIL")
(output "Nested gate exit controls passed~%")
(shen-jit.exit 0)
