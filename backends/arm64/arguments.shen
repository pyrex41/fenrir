\\ An exported entry accepts the boxed parameter. Known direct calls can use
\\ x8..x15 when the callee destructures every field and the box never escapes.
(define mg.parameters
  [] Body Param _ -> (if (mg.used? Param Body) none [[] Body])
  [T | Ts] ["let" _ Binder ["project" _ ["var" _ Param] Field] Body] Param I ->
    (let Rest (mg.parameters Ts Body Param (+ I 1))
      (if (= Rest none) none [[[Binder T] | (hd Rest)] (mg.nth 1 Rest)]))
    where (= Field (str I))
  _ _ _ _ -> none)

(define mg.unpacked
  ["Tuple" | Ts] F -> (mg.parameters Ts (arm.field "body" F) (arm.field "parameter_id" F) 0)
                     where (<= (length Ts) 8)
  _ _ -> none)

(define mg.direct
  Name ["tuple" _ | Es] ->
    (let Shape (arm.lookup Name (value mg.*shapes*))
      (if (= Shape none) false (= (length Es) (length (hd Shape)))))
  _ _ -> false)

(define mg.load-args
  [] _ -> done
  [S | Ss] I -> (do (mg.access "ldr" (make-string "x~A" (+ I 8)) S) (mg.load-args Ss (+ I 1))))

(define mg.incoming
  [] _ -> done
  [[_ S] | Ss] I -> (do (mg.access "str" (make-string "x~A" (+ I 8)) S) (mg.incoming Ss (+ I 1))))

(define mg.unbox
  [] _ -> done
  [_ | Ts] I -> (do (arm.line (make-string "ldr x~A, [x0, #~A]" (+ 8 I) (* 8 I))) (mg.unbox Ts (+ I 1))))

(define mg.direct-call
  Name Es Env Tail ->
    (let F (arm.lookup Name (value mg.*functions*)) Label (cn "Ldirect" (arm.field "id" F))
         Slots (map (/. E (mg.expr E Env)) Es)
      (if (and Tail (= Name (value mg.*self*)))
          (do (set mg.*loops* true) (mg.load-args Slots 0)
              (arm.line (cn "b Lrepeat" (arm.field "id" F))))
          (do (if Tail (arm.line "UNLINK_ROOTS") skip)
              (mg.load-args Slots 0)
              (if Tail
                  (do (mg.pop-frame) (arm.line (cn "b " Label)))
                  (do (arm.line (cn "bl " Label)) (arm.line (cn "cbnz x1, " (value mg.*unwind*)))
                      (mg.save (arm.field "result_type" F))))))))
