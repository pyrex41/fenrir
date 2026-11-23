\\ A descriptor occupies four consecutive untraced words. Its table and the
\\ pending clause chain live in traced slots for the duration of the handle.
(define mg.numbered
  [] _ -> []
  [D | Ds] N -> [[(arm.field "name" D) [N D]] | (mg.numbered Ds (+ N 1))])

(define mg.clause
  [Name | Fields] [[Name | Vs] | _] -> Vs
  Op [_ | Cs] -> (mg.clause Op Cs))

(define mg.closures
  [] _ _ _ _ -> []
  [Op | Ops] Clauses Id Env N ->
    (let Fields (mg.clause [(arm.field "name" Op)] Clauses)
         Label (make-string "~Aop~A" Id N)
         Saved (set mg.*origins* [[Label Id] | (value mg.*origins*)])
         Explicit (if (= 3 (length Fields))
                     (set mg.*clause-keys* [[Label (mg.nth 1 Fields)] | (value mg.*clause-keys*)]) skip)
         S (mg.lambda Label (hd Fields) (arm.field "argument_type" Op)
                      (arm.field "result_type" Op) [] (hd (reverse Fields)) Env)
      [S | (mg.closures Ops Clauses Id Env (+ N 1))]))

(define mg.set-answers
  [] _ -> done
  [[_ _ K _] | Cs] Type -> (do (set mg.*answers* [[K Type] | (value mg.*answers*)])
                                (mg.set-answers Cs Type))
  [_ | Cs] Type -> (mg.set-answers Cs Type))

(define mg.handle
  Id Effect Cs Body Env ->
    (let Decl (arm.lookup Effect (value mg.*effects*))
         Ops (arm.field "operations" (mg.nth 1 Decl))
         Check (if (> (length Ops) (mg.limit "max_handler_operations"))
                 (mg.reject Id (make-string "Handler has ~A operations, exceeding the limit of ~A" (length Ops) (mg.limit "max_handler_operations"))) skip)
         Closures (mg.closures Ops Cs Id Env 0)
         Table (mg.aggregate Id 0 ["Tuple" | (map (function hd) Closures)] Closures)
         Pending (mg.slot ["Tuple"])
         Offset (* 8 (value mg.*words*)) Reserve (mg.reserve-words 4)
         Frame (make-string "add x0, x20, #~A" Offset)
         Outer (value mg.*unwind*) Landing (cn "Lhandler" Id)
         Installed (do (mg.access "ldr" "x1" Table)
                       (arm.lines [Frame (make-string "mov x2, #~A" (hd Decl))
                                   (make-string "add x3, x19, #~A" (* 8 (mg.nth 1 Pending)))])
                       (mg.runtime "install_handler"))
         Unwind (set mg.*unwind* Landing)
         Value (mg.expr Body Env)
         Answer (mg.set-answers Cs (hd Value))
         Restore (set mg.*unwind* Outer)
         Out (mg.slot (hd Value))
      (do (mg.access "ldr" "x0" Value)
          (arm.lines [(cn "b " (cn Landing "finish")) (cn Landing ":")
                      (make-string "add x2, x20, #~A" Offset) "cmp x1, x2"
                      (cn "b.eq " (cn Landing "finish")) "stp x0, x1, [sp, #-16]!" "ldr x0, [x2]"])
          (mg.runtime "restore_handler") (arm.lines ["ldp x0, x1, [sp], #16" (cn "b " Outer)
                                                    (cn Landing "finish:")])
          (mg.access "str" "x0" Out) (arm.line (make-string "add x1, x20, #~A" Offset))
          (mg.runtime "finish_handler") (arm.line (cn "cbnz x1, " Outer)) (mg.access "str" "x0" Out) Out)))

(define mg.perform
  Effect Op E Env ->
    (let S (mg.expr E Env) Host (mg.host-op Effect Op (value mg.*host*))
         Decl (arm.lookup Effect (value mg.*effects*))
         Method (arm.lookup Op (mg.numbered (arm.field "operations" (mg.nth 1 Decl)) 0))
      (do (mg.access "ldr" "x0" S)
          (if (= Host none)
              (do (arm.lines [(make-string "mov x1, #~A" (hd Decl)) (make-string "mov x2, #~A" (hd Method))])
                  (mg.runtime "perform"))
              (arm.line (cn (if (= (value arm.*entry*) "_fenrir_entry") "bl _" "bl ") (hd Host))))
          (arm.line (cn "cbnz x1, " (value mg.*unwind*))) (mg.save (arm.field "result_type" (mg.nth 1 Method))))))

(define mg.payload
  ["resume" _ _ Arg] Env -> (mg.expr Arg Env)
  ["discontinue" Id _] Env -> (mg.expr ["unit" Id] Env))

(define mg.use?
  [Tag _ K | _] -> (and (= K (value mg.*key*)) (element? Tag ["resume" "discontinue"]))
  _ -> false)

(define mg.use
  E Env -> (let S (mg.payload E Env)
             (do (arm.line (if (= (hd E) "resume") "mov x0, #1" "mov x0, #2"))
                 (mg.runtime "use_resumption") (arm.line "cbnz x0, 3f")
                 (arm.trap 6 (mg.nth 1 E)) (arm.line "3:") S)))

(define mg.before
  [] Env -> Env
  [[V E] | Rest] Env -> (mg.before Rest [[V (mg.expr E Env)] | Env]))

(define mg.deferred
  Id V Use Body Env ->
    (let S (mg.payload Use Env) Resume (= (hd Use) "resume")
         T (arm.lookup (value mg.*key*) (value mg.*answers*)) Label (cn Id "after")
         Saved (set mg.*origins* [[Label (mg.nth 1 Use)] | (value mg.*origins*)])
         F (mg.lambda Label V (if Resume T "Unit") T [] Body Env)
      (do (mg.access "ldr" "x0" F) (mg.runtime (if Resume "defer_clause" "defer_abandon"))
          (arm.line "cbz x0, 3f") (arm.trap 3 (mg.nth 1 Use)) (arm.line "3:") (mg.return-value S))))

(define mg.return-value
  S -> (do (mg.access "ldr" "x0" S) (arm.line "mov x1, #0") (arm.line (cn "b " (value mg.*return*)))))

(define mg.clause-tail
  E Env -> (mg.return-value (mg.use E Env)) where (mg.use? E)
  ["let" Id V Use Body] Env -> (mg.deferred Id V Use Body Env) where (mg.use? Use)
  E Env -> (mg.context-tail (arm.verify (arm.split E (value mg.*key*) (value mg.*tasks*) false) (value mg.*key*)) E Env))

(define mg.context-tail
  none E Env -> (mg.tail-body E Env)
  [split Before Use V After] E Env ->
     (mg.deferred (mg.nth 1 E) V Use After (mg.before Before Env)))

(define mg.optional
  _ [] Default -> Default
  K [[K V] | _] _ -> V
  K [_ | Rest] Default -> (mg.optional K Rest Default))
