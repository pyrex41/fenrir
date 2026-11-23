(define mg.task-variants
  "SendResult" -> [["Sent" []] ["Closed" []]]
  ["ReceiveResult" T] -> [["Item" [T]] ["End" []]]
  ["Outcome" T] -> [["Ok" [T]] ["Cancelled" []] ["Failed" ["TrapCode"]]]
  _ -> [])

(define mg.task-ctors
  T -> (map (/. C [object ["name" (hd C)] ["fields" (mg.nth 1 C)]]) (mg.task-variants T)))

(define mg.global
  Name -> (let S (if (= (value arm.*entry*) "_fenrir_entry") (cn "_" Name) Name)
            (arm.lines [(cn ".globl " S) (cn S ":")])))

(define mg.task-entry
  F -> (let Site (mg.nth 1 (arm.field "body" F))
         (do (set arm.*sites* [Site | (value arm.*sites*)])
             (mg.global "fenrir_task_root_location") (mg.address (cn "Lposition" Site)) (arm.line "ret")
             (mg.global "fenrir_task_result_is_object")
             (arm.line (if (mg.pointer? (arm.field "result_type" F)) "mov x0, #1" "mov x0, #0"))
             (arm.line "ret") (mg.global "fenrir_task_entry"))))

(define mg.scope
  Id E Env ->
    (let Offset (* 8 (value mg.*words*)) Reserve (mg.reserve-words 8)
         Frame (make-string "add x0, x20, #~A" Offset)
         Outer (value mg.*unwind*) Abort (cn "Labort" Id)
         Enter (do (arm.line Frame) (mg.runtime "enter_scope"))
         Catch (set mg.*unwind* Abort) S (mg.expr E Env) Restore (set mg.*unwind* Outer)
      (do (arm.lines [Frame "mov x1, #0"]) (mg.runtime "leave_scope")
          (arm.line "cbz x0, 3f") (arm.trap 5 Id)
          (arm.lines ["3:" (make-string "b Ljoined~A" Id) (cn Abort ":") "stp x0, x1, [sp, #-16]!"
                      Frame "mov x1, #1"]) (mg.runtime "leave_scope")
          (arm.lines ["ldp x0, x1, [sp], #16" (cn "b " Outer) (make-string "Ljoined~A:" Id)]) S)))

(define mg.status-trap
  Id Code -> (do (arm.lines [(make-string "cmp x1, #~A" Code) "b.ne 3f"])
                 (arm.trap Code Id) (arm.line "3:")))

(define mg.unit
  -> (do (arm.line "mov x0, #0") (mg.save "Unit")))

(define mg.task-null
  Tag T -> (do (if (element? Tag (value mg.*constants*)) skip
                   (set mg.*constants* [Tag | (value mg.*constants*)]))
               (mg.address (make-string "Lnullary~A" Tag))))

(define mg.failed-cases
  [] _ _ -> done
  [[Status TrapTag] | More] Id T ->
    (do (arm.lines [(make-string "cmp x1, #~A" Status) "b.ne 4f"])
        (mg.task-null TrapTag "TrapCode")
        (mg.access "ldr" "x0" (mg.aggregate Id 2 T [(mg.save "TrapCode")]))
        (arm.lines [(cn "b LawaitDone" Id) "4:"]) (mg.failed-cases More Id T)))

(define mg.await
  Id E Env ->
    (let S (mg.expr E Env) P (mg.nth 1 (hd S)) T ["Outcome" P]
      (do (mg.access "ldr" "x0" S) (mg.runtime "await_handle")
          (arm.line (cn "cbz x1, LawaitOk" Id))
          (mg.failed-cases [[1 1] [2 2] [4 3] [5 6] [7 5] [9 4]] Id T)
          (arm.lines ["cmp x1, #8" (cn "b.ne " (value mg.*unwind*))]) (mg.task-null 1 T)
          (arm.lines [(cn "b LawaitDone" Id) (make-string "LawaitOk~A:" Id)])
          (mg.access "ldr" "x0" (mg.aggregate Id 0 T [(mg.save P)]))
          (arm.line (make-string "LawaitDone~A:" Id)) (mg.save T))))

(define mg.task-expr
  ["scope" Id E] Env -> (mg.scope Id E Env)
  ["await" Id E] Env -> (mg.await Id E Env)
  ["spawn" Id E] Env ->
    (let F (mg.expr E Env) T (mg.nth 2 (hd F))
      (do (mg.access "ldr" "x0" F) (arm.line (if (mg.pointer? T) "mov x1, #1" "mov x1, #0"))
          (mg.runtime "spawn_closure") (mg.status-trap Id 3) (mg.status-trap Id 5)
          (arm.line "cbz x1, 3f") (arm.trap 7 Id) (arm.line "3:") (mg.save ["Task" T])))
  ["channel" Id T N] _ ->
    (do (arm.lines [(make-string "mov x0, #~A" N) (if (mg.pointer? T) "mov x1, #1" "mov x1, #0")])
        (mg.runtime "new_channel") (arm.line "cbnz x0, 3f") (arm.trap 3 Id)
        (arm.line "3:") (mg.save ["Channel" T]))
  ["send" _ Ch E] Env ->
    (let C (mg.expr Ch Env) S (mg.expr E Env)
      (do (mg.access "ldr" "x0" C) (mg.access "ldr" "x1" S) (mg.runtime "send_handle")
          (arm.line "cbz x0, 4f") (mg.task-null 0 "SendResult")
          (arm.lines ["b 5f" "4:"]) (mg.task-null 1 "SendResult")
          (arm.line "5:") (mg.save "SendResult")))
  ["receive" Id Ch] Env ->
    (let C (mg.expr Ch Env) P (mg.nth 1 (hd C)) T ["ReceiveResult" P]
      (do (mg.access "ldr" "x0" C) (mg.runtime "receive_handle") (arm.line "cbz x1, 4f")
          (mg.access "ldr" "x0" (mg.aggregate Id 0 T [(mg.save P)]))
          (arm.lines ["b 5f" "4:"]) (mg.task-null 1 T) (arm.line "5:") (mg.save T)))
  ["close" _ E] Env -> (do (mg.access "ldr" "x0" (mg.expr E Env)) (mg.runtime "close_handle") (mg.unit))
  ["cancel" _ E] Env -> (do (mg.access "ldr" "x0" (mg.expr E Env)) (mg.runtime "cancel_handle") (mg.unit))
  ["yield" _] _ -> (do (mg.runtime "root_yield") (mg.unit))
  ["now" _] _ -> (do (mg.runtime "root_now") (mg.save "I64"))
  ["sleep" Id E] Env -> (do (mg.access "ldr" "x0" (mg.expr E Env)) (mg.runtime "root_sleep")
                            (mg.status-trap Id 9) (arm.line "cbz x1, 3f") (arm.trap 1 Id)
                            (arm.line "3:") (mg.unit))
  E _ -> (error "unsupported native task expression ~A" (hd E)))
