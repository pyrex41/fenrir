(tc +)
(define anything
  {A --> B}
  X -> (anything X))
(datatype arith
  ________________
  [plus z N N] : fact;

  [plus M N K] : fact;
  ____________________________
  [plus [s M] N [s K]] : fact;)
(define ok1 {A --> fact} _ -> [plus [s [s z]] [s z] [s [s [s z]]]])
