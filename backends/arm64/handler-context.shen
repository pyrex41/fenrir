\\ Split a strict expression around its first use of K. Input nodes use the
\\ validated artifact's list representation. Output is none or
\\ [split Before Use Answer After]. Before binds operands left-to-right.
\\ After consumes Answer once and refers to earlier operands by binding id.

(define arm.resume-argument
  ["resume" _ K Arg] K -> Arg
  ["let" Id Binder Init Body] K ->
    (let Arg (arm.resume-argument Body K)
      (if (= Arg none) none ["let" Id Binder Init Arg]))
  ["if" Id Test Yes No] K ->
    (let A (arm.resume-argument Yes K) B (arm.resume-argument No K)
      (if (or (= A none) (= B none)) none ["if" Id Test A B]))
  _ _ -> none)

(define arm.split-use
  [Tag Id K | Args] -> (let Answer (cn Id "answer")
                         [split [] [Tag Id K | Args] Answer ["var" Answer Answer]]))

(define arm.split
  ["resume" Id K Arg] K _ _ -> (arm.split-use ["resume" Id K Arg])
  ["discontinue" Id K] K true _ -> (arm.split-use ["discontinue" Id K])
  ["if" Id Test Yes No] K Tasks true ->
    (let Arg (arm.resume-argument ["if" Id Test Yes No] K)
      (if (= Arg none)
          (arm.operands ["if" Id] [Test] [Yes No] Id 2 K Tasks)
          (arm.split-use ["resume" Id K Arg])))
  [Tag Id | Args] K Tasks _ ->
    (cases (= Tag "tuple") (arm.operands [Tag Id] Args [] Id 2 K Tasks)
           (= Tag "apply") (arm.operands [Tag Id] Args [] Id 2 K Tasks)
           (element? Tag ["prim" "call" "emit"])
             (arm.operands [Tag Id (hd Args)] (tl Args) [] Id 3 K Tasks)
           (= Tag "construct")
             (arm.operands [Tag Id (hd Args) (hd (tl Args))] (tl (tl Args)) [] Id 4 K Tasks)
           (element? Tag ["project" "if" "match"])
             (arm.operands [Tag Id] [(hd Args)] (tl Args) Id 2 K Tasks)
           (= Tag "let")
             (arm.operands [Tag Id (hd Args)] [(hd (tl Args))] (tl (tl Args)) Id 3 K Tasks)
           (= Tag "perform")
             (arm.operands [Tag Id (hd Args) (hd (tl Args))] [(hd (tl (tl Args)))] [] Id 4 K Tasks)
           true none))

(define arm.operands
  _ [] _ _ _ _ _ -> none
  Prefix [E | Rest] Suffix Id Index K Tasks ->
    (let Part (arm.split E K Tasks true)
      (if (= Part none)
          (let Binder (cn Id (cn "operand" (str Index)))
               Later (arm.operands (append Prefix [["var" Binder Binder]]) Rest Suffix Id (+ Index 1) K Tasks)
            (arm.prepend-binding Binder E Later))
          (arm.wrap Prefix (append Rest Suffix) Part))))

(define arm.prepend-binding
  _ _ none -> none
  Binder E [split Before Use Answer After] -> [split [[Binder E] | Before] Use Answer After])

(define arm.wrap
  Prefix Suffix [split Before Use Answer After] ->
    [split Before Use Answer (append Prefix [After | Suffix])])

\\ Verify the output of the pass before code generation consumes it.
(define arm.occurrences
  _ [] -> 0
  Id ["var" _ Id] -> 1
  Id [X | Xs] -> (+ (arm.occurrences Id X) (arm.occurrences Id Xs))
  _ _ -> 0)

(define arm.check-bindings
  [] _ -> true
  [[Id _] | Rest] After ->
    (and (= 1 (arm.occurrences Id After)) (arm.check-bindings Rest After)))

(define arm.verify
  none _ -> none
  [split Before [Tag Site K | Args] Answer After] K ->
    (if (and (element? Tag ["resume" "discontinue"])
             (and (= Answer (cn Site "answer"))
                  (and (= 1 (arm.occurrences Answer After))
                       (arm.check-bindings Before After))))
        [split Before [Tag Site K | Args] Answer After]
        (error "invalid handler context at ~A" Site))
  _ _ -> (error "handler context selected the wrong resumption"))
