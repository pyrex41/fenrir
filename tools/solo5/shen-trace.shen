\\ Harness driver, not model: print one sample per reference step of the
\\ expression model until its terminal state or the fuel bound.
(define fg.trace
  [state [terminal Outcome] Env []] _ -> (do (print [fg-end completed]) (nl))
  State 0 -> (do (print [fg-end budget-exhausted]) (nl))
  State Fuel -> (do (print (tc0.demo.sample State))
                    (do (nl) (fg.trace (hd (tl (tc0.demo.step State))) (- Fuel 1)))))
