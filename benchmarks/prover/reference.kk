module reference

type formula {
  Atom(bit: int)
  Neg(body: formula)
  Binary(op: string, left: formula, right: formula)
}

type outcome {
  Proof(witness: string)
  Model(bits: int)
  Exhausted
}

fun prepend-rule(rule: string, result: outcome): outcome
  match result
    Proof(w) -> Proof(rule ++ w)
    other -> other

fun search(queue: list<(bool,formula)>, pos: int, neg: int, fuel: int): div (outcome,int)
  if fuel == 0 then (Exhausted,0) else
    match queue
      Nil -> (Model(pos),fuel - 1)
      Cons((sign,term),rest) ->
        match term
          Atom(bit) -> {
            val opposite = if sign then neg else pos
            val own = if sign then pos else neg
            if (opposite / bit) % 2 == 1 then (Proof("x"),fuel - 1) else {
              val add = if (own / bit) % 2 == 0 then bit else 0
              val (result,left) = search(rest, if sign then pos + add else pos, if sign then neg else neg + add, fuel - 1)
              (prepend-rule("s",result),left)
            }
          }
          Neg(body) -> {
            val (result,left) = search(rest ++ [(sign.not,body)],pos,neg,fuel - 1)
            (prepend-rule("s",result),left)
          }
          Binary(op,a,b) -> {
            val first = (if op == ">" then sign.not else sign,a)
            val second = (sign,b)
            if (op == "&") == sign then {
              val (result,left) = search(rest ++ [first,second],pos,neg,fuel - 1)
              (prepend-rule("s",result),left)
            } else {
              val (result,left) = search(rest ++ [first],pos,neg,fuel - 1)
              match result
                Proof(w) -> {
                  val (next,remaining) = search(rest ++ [second],pos,neg,left)
                  (prepend-rule("b" ++ w,next),remaining)
                }
                other -> (other,left)
            }
          }

fun row(name:string, budget:int, term:formula)
  val (result,left) = search([(False,term)],0,0,budget)
  val (status,witness) = match result
    Proof(w) -> ("proof",w)
    Model(n) -> ("model",n.show)
    Exhausted -> ("exhausted","-")
  println(name ++ " " ++ status ++ " " ++ (budget - left).show ++ " " ++ witness)

fun check-step(queue: list<(bool,formula)>, pos: int, neg: int, tape: list<char>): div maybe<list<char>>
  match tape
    Nil -> Nothing
    Cons(rule,tail) ->
      match queue
        Nil -> Nothing
        Cons((sign,term),rest) ->
          match term
            Atom(bit) -> {
              val opposite = if sign then neg else pos
              val own = if sign then pos else neg
              if (opposite / bit) % 2 == 1 then {
                if rule == 'x' then Just(tail) else Nothing
              } elif rule == 's' then {
                val add = if (own / bit) % 2 == 0 then bit else 0
                check-step(rest, if sign then pos + add else pos, if sign then neg else neg + add, tail)
              } else Nothing
            }
            Neg(body) -> if rule == 's' then check-step(rest ++ [(sign.not,body)],pos,neg,tail) else Nothing
            Binary(op,a,b) -> {
              val first = (if op == ">" then sign.not else sign,a)
              val second = (sign,b)
              if (op == "&") == sign then {
                if rule == 's' then check-step(rest ++ [first,second],pos,neg,tail) else Nothing
              } elif rule == 'b' then {
                match check-step(rest ++ [first],pos,neg,tail)
                  Nothing -> Nothing
                  Just(next) -> check-step(rest ++ [second],pos,neg,next)
              } else Nothing
            }

fun verify-proof(term:formula, witness:string): div bool
  match check-step([(False,term)],0,0,witness.list)
    Just(Nil) -> True
    _ -> False
