\\ PROPOSED, UNQUALIFIED batch driver for the width-independent pure-call model.
\\ Same stdin protocol and output as ../pure-call-oracle.shen. Run with the
\\ working directory at models/tc0. I64 literals and IDs in the input states
\\ must be Shen strings (see tools/solo5/shen-pure-call-traces.py --portable).
(load "arithmetic.shen")
(load "pure-call-machine.shen")
(load "portable/i64.shen")
(load "portable/pure-call-overrides.shen")

(define tc0.pc.data
  [cons H T] -> [(tc0.pc.data H) | (tc0.pc.data T)]
  [] -> []
  X -> X where (or (symbol? X) (number? X) (string? X) (boolean? X))
  X -> (error "tc0.pc oracle: input is not bracket data"))

(define tc0.pc.phase
  State -> (hd (hd (tl State))))

(define tc0.pc.drive
  State 0 -> (output "~A~%" (tc0.pc.phase State))
  State N -> (output "~A~%" (tc0.pc.phase State)) where (= (tc0.pc.phase State) terminal)
  State N -> (let Sample (tc0.pc.sample State)
                  Next (hd (tl (tc0.pc.step State)))
               (do (output "~A~%" Sample)
                   (if (= (tc0.pc.phase Next) value)
                       (output "~A~%" (hd (tl (hd (tl Next)))))
                       skip)
                   (tc0.pc.drive Next (- N 1)))))

(define tc0.pc.budget
  N -> N where (and (integer? N) (>= N 0))
  _ -> (error "tc0.pc oracle: budget must be a nonnegative integer"))

(define tc0.pc.cases
  S -> (let Budget (read S)
         (if (= Budget end)
             done
             (let State (tc0.pc.data (read S))
               (do (tc0.pc.drive State (tc0.pc.budget Budget))
                   (output "[case-end]~%")
                   (tc0.pc.cases S))))))

(tc0.pc.cases (stinput))
