\\ Fenrir harness, in Shen: the hand cases. For every hand fixture, the Shen
\\ model and the JavaScript implementation must agree step for step, and both
\\ must satisfy the expectations a person wrote down for that case: outcome,
\\ step staging, count of return frames, continuation depth bound, closure
\\ descriptor count and emission order. Development evidence only.
\\
\\   shen-jit script harness/hand-cases.shen LIBDIR ROOT OUTDIR [sandbox] [pure-call|pure-data]
\\
\\ Launches node on tools/tc0/run-pure-call-hand.mjs for the implementation's
\\ traces. The model runs in this process and does not see them before comparing.
\\ Covers the checks of the Python tool tools/check-tc0-pure-call.py.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
\\ Optional further arguments, in any order:
\\   sandbox                 run the implementation inside tools/tc0/sandbox.mjs
\\   pure-call | pure-data   check that generated family instead of the hand fixtures
(set fh.*options* (tl (tl (tl (tl (value *argv*))))))
(set fh.*sandbox* (element? "sandbox" (value fh.*options*)))
(set fh.*family* (if (element? "pure-call" (value fh.*options*)) ["pure-call"] (if (element? "pure-data" (value fh.*options*)) ["pure-data"] [])))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/expectations.shen"))

(define fh.sum
  [] _ N -> N
  [R | Rs] F N -> (fh.sum Rs F (+ N (F R))))

(define fh.failed
  [] -> []
  [[Name Reasons | _] | Rest] -> (if (= Reasons []) (fh.failed Rest) [[object ["case" Name] ["reasons" Reasons]] | (fh.failed Rest)]))

\\ Strict replay: a tape of the implementation recorded against the model's trace
\\ must replay exactly on a fresh machine and be admitted, for every case.
(define fh.not-admitted
  [] -> []
  [R | Rs] -> (if (and (= (fh.field "replay" R) "Exact") (= (fh.field "conformance" R) "Admitted") (= (fh.field "execution" R) "Completed"))
                  (fh.not-admitted Rs)
                  [[object ["case" (fh.field "name" R)] ["reasons" ["strict replay was not admitted"]]] | (fh.not-admitted Rs)]))

(define fh.main
  -> (let File (cn (value fh.*out*) "hand.jsonl")
          R (process.run "node" (fh.node-arguments "tools/tc0/run-pure-call-hand.mjs" [File | (value fh.*family*)] ["fixtures/tc0"] File (value fh.*sandbox*))
                         (buffer.from-string "") [[timeout 60000]])
          Ran (if (and (= (hd R) ok) (process.success? (hd (tl R)))) true (error "harness: the JavaScript hand-case run did not complete"))
          View (buffer.from-string (read-file-as-string File))
          Rows (fh.json-lines View 0 (buffer.length View) [])
          Results (map (/. Row (fh.check-case Row)) Rows)
          Agreement (fh.failed Results)
          \\ Replay only what agreed: a disagreeing case has no reference to replay against.
          Replayed (if (empty? Agreement)
                       (fh.replay (map (/. R [(hd R) (nth 5 R) (nth 6 R) null]) Results) (value fh.*out*) (value fh.*sandbox*))
                       [])
          Failures (append Agreement (fh.not-admitted Replayed))
          Pass (and (empty? Failures) (> (length Rows) 0) (= (length Replayed) (length Rows)))
          Report [object ["schema" "fenrir.harness.hand-cases/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["source" (if (empty? (value fh.*family*)) "hand fixtures" (hd (value fh.*family*)))]
                         ["cases" (str (length Rows))]
                         ["expectations_checked" (str (fh.sum Results (/. R (nth 3 R)) 0))]
                         ["model_steps" (str (fh.sum Results (/. R (nth 4 R)) 0))]
                         ["strict_replay_admitted" (str (- (length Replayed) (length (fh.not-admitted Replayed))))]
                         ["failures" Failures]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
