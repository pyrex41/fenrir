\\ TC0 I64 arithmetic for the pure-call machine. Pure kernel: no host time, entropy or I/O.
\\ Exact on any Shen port, whatever its integer width: an I64 value is a canonical
\\ decimal STRING (optional "-", no leading zero, "0" for zero) and all arithmetic is
\\ done on little-endian lists of decimal digits. No host number above 99 is formed.
\\ Shen/JIT integers are 62-bit fixnums (a wider literal reads as a real, a wider
\\ result raises), so arithmetic on host integers cannot represent I64 there.
\\ arithmetic.shen is the earlier host-integer version; only the arithmetic-demo
\\ expression machine still uses it, and the two are never loaded together.

(define tc0.i64.digit
  C -> (- (string->n C) 48))

(define tc0.i64.drop-zeros
  [0 | Ds] -> (tc0.i64.drop-zeros Ds)
  Ds -> Ds)

\\ Remove most-significant zeros from a little-endian magnitude.
(define tc0.i64.strip
  M -> (reverse (tc0.i64.drop-zeros (reverse M))))

(define tc0.i64.mag
  Cs -> (tc0.i64.strip (reverse (map (/. C (tc0.i64.digit C)) Cs))))

\\ A value is [Sign Magnitude], Sign 1 or -1; zero is [1 []].
(define tc0.i64.norm
  [_ []] -> [1 []]
  V -> V)

(define tc0.i64.parse-chars
  ["-" | Cs] -> (tc0.i64.norm [-1 (tc0.i64.mag Cs)])
  Cs -> [1 (tc0.i64.mag Cs)])

(define tc0.i64.parse
  S -> (tc0.i64.parse-chars (explode S)))

(define tc0.i64.digits
  [] -> ""
  [D | Ds] -> (cn (str D) (tc0.i64.digits Ds)))

(define tc0.i64.show
  [_ []] -> "0"
  [1 M] -> (tc0.i64.digits (reverse M))
  [-1 M] -> (cn "-" (tc0.i64.digits (reverse M))))

(define tc0.i64.cmp-msd
  [] [] -> 0
  [X | _] [Y | _] -> -1 where (< X Y)
  [X | _] [Y | _] -> 1 where (> X Y)
  [_ | Xs] [_ | Ys] -> (tc0.i64.cmp-msd Xs Ys))

(define tc0.i64.cmp-length
  LA LB _ _ -> -1 where (< LA LB)
  LA LB _ _ -> 1 where (> LA LB)
  _ _ A B -> (tc0.i64.cmp-msd (reverse A) (reverse B)))

\\ Compare two stripped magnitudes: -1, 0 or 1.
(define tc0.i64.cmp
  A B -> (tc0.i64.cmp-length (length A) (length B) A B))

(define tc0.i64.add-carry
  [] [] 0 -> []
  [] [] C -> [C]
  [] B C -> (tc0.i64.add-carry [0] B C)
  A [] C -> (tc0.i64.add-carry A [0] C)
  [X | Xs] [Y | Ys] C ->
    (let S (+ X (+ Y C))
      (if (> S 9)
          [(- S 10) | (tc0.i64.add-carry Xs Ys 1)]
          [S | (tc0.i64.add-carry Xs Ys 0)])))

(define tc0.i64.add-mag
  A B -> (tc0.i64.strip (tc0.i64.add-carry A B 0)))

(define tc0.i64.sub-borrow
  [] [] _ -> []
  A [] Br -> (tc0.i64.sub-borrow A [0] Br)
  [X | Xs] [Y | Ys] Br ->
    (let D (- X (+ Y Br))
      (if (< D 0)
          [(+ D 10) | (tc0.i64.sub-borrow Xs Ys 1)]
          [D | (tc0.i64.sub-borrow Xs Ys 0)])))

\\ Requires A >= B.
(define tc0.i64.sub-mag
  A B -> (tc0.i64.strip (tc0.i64.sub-borrow A B 0)))

(define tc0.i64.tens
  P Q -> Q where (< P 10)
  P Q -> (tc0.i64.tens (- P 10) (+ Q 1)))

(define tc0.i64.scale
  [] _ 0 -> []
  [] _ C -> [C]
  [Y | Ys] X C ->
    (let P (+ (* X Y) C)
      (let Q (tc0.i64.tens P 0)
        [(- P (* 10 Q)) | (tc0.i64.scale Ys X Q)])))

(define tc0.i64.mul-mag
  [] _ -> []
  [X | Xs] B -> (tc0.i64.add-mag (tc0.i64.scale B X 0) [0 | (tc0.i64.mul-mag Xs B)]))

\\ Doubling ladder [[D*2^k 2^k] ...], largest first, while D*2^k <= A.
(define tc0.i64.div-ladder
  A [[D Q] | Rest] ->
    (let D2 (tc0.i64.add-mag D D)
      (if (> (tc0.i64.cmp D2 A) 0)
          [[D Q] | Rest]
          (tc0.i64.div-ladder A [[D2 (tc0.i64.add-mag Q Q)] [D Q] | Rest]))))

(define tc0.i64.div-walk
  _ [] Total -> Total
  A [[D Q] | Rest] Total ->
    (if (>= (tc0.i64.cmp A D) 0)
        (tc0.i64.div-walk (tc0.i64.sub-mag A D) Rest (tc0.i64.add-mag Total Q))
        (tc0.i64.div-walk A Rest Total)))

\\ Floor of A / B on magnitudes; B is not zero.
(define tc0.i64.div-mag
  A B -> (tc0.i64.div-walk A (tc0.i64.div-ladder A [[B [1]]]) []))

(define tc0.i64.add
  [S A] [S B] -> [S (tc0.i64.add-mag A B)]
  [SA A] [SB B] ->
    (let C (tc0.i64.cmp A B)
      (if (= C 0)
          [1 []]
          (if (> C 0) [SA (tc0.i64.sub-mag A B)] [SB (tc0.i64.sub-mag B A)]))))

(define tc0.i64.negate
  [S M] -> (tc0.i64.norm [(- 0 S) M]))

(define tc0.i64.product-sign
  S S -> 1
  _ _ -> -1)

(define tc0.i64.mul
  [SA A] [SB B] -> (tc0.i64.norm [(tc0.i64.product-sign SA SB) (tc0.i64.strip (tc0.i64.mul-mag A B))]))

\\ Truncation toward zero: the quotient of the magnitudes carries the sign.
(define tc0.i64.div
  [SA A] [SB B] -> (tc0.i64.norm [(tc0.i64.product-sign SA SB) (tc0.i64.div-mag A B)]))

(define tc0.i64.signed-cmp
  [1 A] [1 B] -> (tc0.i64.cmp A B)
  [-1 A] [-1 B] -> (tc0.i64.cmp B A)
  [1 _] [-1 _] -> 1
  [-1 _] [1 _] -> -1)

\\ -1, 0 or 1 for two canonical I64 strings.
(define tc0.i64.compare
  A B -> (tc0.i64.signed-cmp (tc0.i64.parse A) (tc0.i64.parse B)))

\\ 2^63 - 1 and 2^63 as little-endian digit lists.
(define tc0.i64.max-mag -> [7 0 8 5 7 7 4 5 8 6 3 0 2 7 3 3 2 2 9])
(define tc0.i64.min-mag -> [8 0 8 5 7 7 4 5 8 6 3 0 2 7 3 3 2 2 9])

(define tc0.i64.fits?
  [1 M] -> (<= (tc0.i64.cmp M (tc0.i64.max-mag)) 0)
  [-1 M] -> (<= (tc0.i64.cmp M (tc0.i64.min-mag)) 0))

(define tc0.i64.checked
  V -> (if (tc0.i64.fits? V) [ok (tc0.i64.show V)] [trap overflow]))

(define tc0.i64.horner
  [] N -> N
  [C | Cs] N -> (tc0.i64.horner Cs (+ (* N 10) (tc0.i64.digit C))))

(define tc0.i64.small-chars
  ["-" | _] -> -1
  Cs -> -1 where (> (length Cs) 9)
  Cs -> (tc0.i64.horner Cs 0))

\\ A canonical I64 string as a host number when it is in 0..999999999, else -1.
\\ For indexing host lists only.
(define tc0.i64.small
  S -> (tc0.i64.small-chars (explode S)))

\\ The machine's arithmetic entry point, over canonical decimal strings.
(define tc0.arithmetic
  add [A B] -> (tc0.i64.checked (tc0.i64.add (tc0.i64.parse A) (tc0.i64.parse B)))
  sub [A B] -> (tc0.i64.checked (tc0.i64.add (tc0.i64.parse A) (tc0.i64.negate (tc0.i64.parse B))))
  mul [A B] -> (tc0.i64.checked (tc0.i64.mul (tc0.i64.parse A) (tc0.i64.parse B)))
  div [_ "0"] -> [trap div-zero]
  div [A B] -> (tc0.i64.checked (tc0.i64.div (tc0.i64.parse A) (tc0.i64.parse B)))
  neg [A] -> (tc0.i64.checked (tc0.i64.negate (tc0.i64.parse A)))
  _ _ -> [invalid operation-or-arity])
