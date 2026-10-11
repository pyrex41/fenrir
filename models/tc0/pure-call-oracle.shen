\\ UNQUALIFIED batch driver for the pure-call model; shakeable by Yggdrasil.
\\ Reads "Budget State" pairs from stdin as DATA until the symbol end. Per case it
\\ prints, for each step, the sample, then the value whenever the next state is in
\\ the value phase, then the final phase tag and [case-end]. This is the same
\\ observation sequence the earlier per-expression host probe printed.
\\ The model never evaluates input; reads are declared data so the shaken slice
\\ stays eval-free (manifest: needs-eval=false, cannot-reach=eval).
(load "arithmetic.shen")
(load "pure-call-machine.shen")

(set yggdrasil.*read-data* true)

\\ The reader returns bracket lists as cons forms ([a b] reads as
\\ [cons a [cons b []]]). Decode exactly that shape back to data and refuse
\\ anything else, such as a parenthesised application, instead of guessing.
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

\\ Input: zero or more "Budget State" pairs, then the symbol end. Each case's
\\ observations are followed by [case-end], so one process serves a batch.
(define tc0.pc.cases
  S -> (let Budget (read S)
         (if (= Budget end)
             done
             (let State (tc0.pc.data (read S))
               (do (tc0.pc.drive State (tc0.pc.budget Budget))
                   (output "[case-end]~%")
                   (tc0.pc.cases S))))))

(tc0.pc.cases (stinput))
