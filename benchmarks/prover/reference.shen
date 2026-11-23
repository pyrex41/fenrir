(define pv.bit
  0 -> 1
  N -> (* 2 (pv.bit (- N 1))))

(define pv.mask
  [] -> 0
  [N | Ns] -> (+ (pv.bit N) (pv.mask Ns)))

(define pv.prefix
  C [proof W Fuel] -> [proof (cn C W) Fuel]
  _ Result -> Result)

(define pv.fork
  [proof W Fuel] Queue Pos Neg ->
    (pv.prefix (cn "b" W) (pv.search Queue Pos Neg Fuel))
  Failure _ _ _ -> Failure)

(define pv.search
  _ _ _ 0 -> [exhausted "-" 0]
  [] Pos _ Fuel -> [model (str (pv.mask Pos)) (- Fuel 1)]
  [[Sign Atom] | Rest] Pos Neg Fuel ->
    (if (element? Atom (if Sign Neg Pos))
        [proof "x" (- Fuel 1)]
        (let P (if (and Sign (not (element? Atom Pos))) [Atom | Pos] Pos)
             N (if (and (not Sign) (not (element? Atom Neg))) [Atom | Neg] Neg)
          (pv.prefix "s" (pv.search Rest P N (- Fuel 1)))))
    where (number? Atom)
  [[Sign [neg A]] | Rest] Pos Neg Fuel ->
    (pv.prefix "s" (pv.search (append Rest [[(not Sign) A]]) Pos Neg (- Fuel 1)))
  [[Sign [Op A B]] | Rest] Pos Neg Fuel ->
    (let First [(if (= Op imp) (not Sign) Sign) A]
         Second [Sign B]
      (if (= (= Op conj) Sign)
          (pv.prefix "s" (pv.search (append Rest [First Second]) Pos Neg (- Fuel 1)))
          (pv.fork (pv.search (append Rest [First]) Pos Neg (- Fuel 1))
                   (append Rest [Second]) Pos Neg))))

(define pv.format
  Name Budget [Status Witness Remaining] ->
    (make-string "~A ~A ~A ~A~%" Name Status (- Budget Remaining) Witness))

(define pv.row
  Name Budget Goal -> (pv.format Name Budget (pv.search [[false Goal]] [] [] Budget)))

(define pv.check-step
  _ _ _ invalid -> invalid
  [] _ _ _ -> invalid
  _ _ _ [] -> invalid
  [[Sign Atom] | Rest] Pos Neg [Rule | Tape] ->
    (if (element? Atom (if Sign Neg Pos))
        (if (= Rule "x") Tape invalid)
        (if (= Rule "s")
            (pv.check-step Rest
              (if (and Sign (not (element? Atom Pos))) [Atom | Pos] Pos)
              (if (and (not Sign) (not (element? Atom Neg))) [Atom | Neg] Neg)
              Tape)
            invalid))
    where (number? Atom)
  [[Sign [neg A]] | Rest] Pos Neg ["s" | Tape] ->
    (pv.check-step (append Rest [[(not Sign) A]]) Pos Neg Tape)
  [[Sign [Op A B]] | Rest] Pos Neg [Rule | Tape] ->
    (let First [(if (= Op imp) (not Sign) Sign) A]
         Second [Sign B]
      (if (= (= Op conj) Sign)
          (if (= Rule "s") (pv.check-step (append Rest [First Second]) Pos Neg Tape) invalid)
          (if (= Rule "b")
              (pv.check-step (append Rest [Second]) Pos Neg
                (pv.check-step (append Rest [First]) Pos Neg Tape))
              invalid)))
  _ _ _ _ -> invalid)

(define pv.verify
  Goal Witness -> (= [] (pv.check-step [[false Goal]] [] [] (explode Witness))))
