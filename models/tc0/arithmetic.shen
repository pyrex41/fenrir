\\ TC0 I64 arithmetic component. Pure kernel: no host time, entropy or I/O.
\\ Integer division must not use fractional Shen / (which rounds on this port).
(define tc0.checked
  N -> (if (or (< N -9223372036854775808) (> N 9223372036854775807))
           [trap overflow] [ok N]))

(define tc0.div-grow
  A D Q -> (if (> (* D 2) A) [D Q]
              (tc0.div-grow A (* D 2) (* Q 2))))

(define tc0.div-walk
  A D Q R ->
    (let Take (>= A D)
      (let Rest (if Take (- A D) A)
        (let Total (if Take (+ R Q) R)
          (if (= Q 1) Total
              (tc0.div-walk Rest (/ D 2) (/ Q 2) Total))))))

(define tc0.div-positive
  A B -> (if (< A B) 0
             (let Pair (tc0.div-grow A B 1)
               (tc0.div-walk A (hd Pair) (hd (tl Pair)) 0))))

(define tc0.div-integer
  A B ->
    (let AbsA (if (< A 0) (- 0 A) A)
      (let AbsB (if (< B 0) (- 0 B) B)
        (let Q (tc0.div-positive AbsA AbsB)
          (if (= (< A 0) (< B 0)) Q (- 0 Q))))))

(define tc0.arithmetic
  add [A B] -> (tc0.checked (+ A B))
  sub [A B] -> (tc0.checked (- A B))
  mul [A B] -> (tc0.checked (* A B))
  div [A 0] -> [trap div-zero]
  div [A B] -> (tc0.checked (tc0.div-integer A B))
  neg [A] -> (tc0.checked (- 0 A))
  Op Args -> [invalid operation-or-arity])
