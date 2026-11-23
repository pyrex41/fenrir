\\ Slots are [type index]. x19 addresses pointer slots (the GC root array);
\\ x20 addresses untraced words. Both registers are callee-saved.
(define mg.limit
  Name -> (mg.index (mg.nth 1 (arm.field Name (value arm.*limits*))) 0))

(define mg.reject
  Id Message -> (let Pos (arm.lookup (mg.optional Id (value mg.*origins*) Id) (value arm.*positions*))
                     Line (make-string "~A:~A:~A: ~A: ~A~%" (arm.field "file" Pos)
                              (arm.field "line" Pos) (arm.field "column" Pos) (value arm.*profile*) Message)
                  (do (write-to-file (value arm.*error*) Line) (error "~A" Message))))

(define mg.pointer?
  T -> (not (element? T ["I64" "Bool" "Unit"])))

(define mg.reserve-words
  Count -> (let N (+ Count (value mg.*words*))
             (do (set mg.*words* N)
                 (if (> N (value mg.*word-peak*)) (set mg.*word-peak* N) skip))))

(define mg.slot
  T -> (if (mg.pointer? T)
           (let I (value mg.*roots*)
             (do (set mg.*roots* (+ I 1))
                 (if (>= I (value mg.*peak*)) (set mg.*peak* (+ I 1)) skip) [T I]))
           (let I (value mg.*words*) Reserve (mg.reserve-words 1) [T I])))

(define mg.access
  Op Reg [Type I] -> (arm.line (make-string "~A ~A, [~A, #~A]" Op Reg
                         (if (mg.pointer? Type) "x19" "x20") (* 8 I))))

(define mg.save
  T -> (let S (mg.slot T) Written (mg.access "str" "x0" S) S))

(define mg.runtime
  Name -> (arm.line (cn (if (= (value arm.*entry*) "_fenrir_entry") "bl _fen_" "bl fen_") Name)))

(define mg.ctor
  Name [C | _] N -> [N (arm.field "fields" C)] where (= Name (arm.field "name" C))
  Name [_ | Cs] N -> (mg.ctor Name Cs (+ N 1))
  Name [] _ -> (error "unknown constructor ~A" Name))

(define mg.type-table
  [] _ -> []
  [D | Ds] Start ->
    (let Cs (arm.field "constructors" D)
      [[(arm.field "name" D) [Start Cs]] | (mg.type-table Ds (+ Start (length Cs)))]))

(define mg.traps
  -> (map (/. Name [object ["name" Name] ["fields" []]])
          ["Overflow" "DivZero" "Bounds" "InvalidDuration" "TaskLimit" "ChildFailed"]))

(define mg.variant
  Name T -> (mg.ctor Name (mg.task-ctors T) 0) where (not (= [] (mg.task-variants T)))
  Name "TrapCode" -> (mg.ctor Name (mg.traps) 1)
  Name ["Data" T] -> (let Table (arm.lookup T (value mg.*types*))
                       (mg.ctor Name (hd (tl Table)) (hd Table))))

(define mg.mask
  [] -> 0
  [[T _] | Ss] -> (+ (if (mg.pointer? T) 1 0) (* 2 (mg.mask Ss))))

(define mg.init-fields
  [] _ -> done
  [S | Ss] I -> (do (mg.access "ldr" "x2" S) (arm.line (make-string "str x2, [x0, #~A]" (* 8 I)))
                     (mg.init-fields Ss (+ I 1))))

(define mg.nullary
  Tag -> (arm.lines [".p2align 3" (make-string "Lnullary~A:" Tag) ".zero 72"
                     (make-string ".long ~A" Tag) ".byte 0,2,0,0"]))

(define mg.aggregate
  _ Tag T [] -> (do (if (element? Tag (value mg.*constants*)) skip
                        (set mg.*constants* [Tag | (value mg.*constants*)]))
                    (mg.address (make-string "Lnullary~A" Tag)) (mg.save T))
  Id Tag T Slots -> (do (if (> (length Slots) 8) (error "native object exceeds eight fields") skip)
                        (arm.lines [(make-string "mov x0, #~A" (mg.mask Slots)) (make-string "mov x1, #~A" Tag)])
                        (mg.runtime "allocate") (arm.line "cbnz x0, 3f") (arm.trap 3 Id)
                        (arm.line "3:") (mg.init-fields Slots 0) (mg.save T)))

(define mg.bind-fields
  [] [] _ _ Env -> Env
  [V | Vs] [T | Ts] S I Env ->
    (do (mg.access "ldr" "x2" S) (arm.line (make-string "ldr x0, [x2, #~A]" (* 8 I)))
        (mg.bind-fields Vs Ts S (+ I 1) [[V (mg.save T)] | Env])))

(define mg.dispatch
  [] _ _ -> (arm.line "brk #0")
  [[Name _ _] | Arms] Type Id ->
    (let Tag (hd (mg.variant Name Type))
      (do (arm.lines [(make-string "mov x2, #~A" Tag) "cmp x0, x2" (make-string "b.eq Lmatch~Ax~A" Id Tag)])
          (mg.dispatch Arms Type Id))))

(define mg.arms
  [] _ _ _ Result -> Result
  [[Name Vs Body] | Arms] S Id Env Result ->
    (let C (mg.variant Name (hd S))
         Label (arm.line (make-string "Lmatch~Ax~A:" Id (hd C)))
         Scope (mg.bind-fields Vs (hd (tl C)) S 0 Env)
         Value (mg.expr Body Scope)
         Out (if (= Result none) (mg.slot (hd Value)) Result)
      (do (mg.access "ldr" "x0" Value) (mg.access "str" "x0" Out) (arm.line (cn "b Lmatched" Id))
          (mg.arms Arms S Id Env Out))))

(define mg.binary
  "eq" _ T -> (mg.runtime "equal") where (mg.pointer? T)
  Op Id _ -> (arm.binary Op Id))

(define mg.address
  Label -> (if (= (value arm.*entry*) "_fenrir_entry")
    (arm.lines [(make-string "adrp x0, ~A@PAGE" Label) (make-string "add x0, x0, ~A@PAGEOFF" Label)])
    (arm.lines [(cn "adrp x0, " Label) (cn "add x0, x0, :lo12:" Label)])))

(define mg.byte-data
  "" -> done
  (@s A (@s B Hex)) -> (do (arm.line (make-string ".byte 0x~A~A" A B)) (mg.byte-data Hex)))

(define mg.byte-object
  [Id Hex] -> (do (arm.lines [".p2align 3" (make-string "Lbytes~A:" Id)
                              (make-string ".quad ~A" (/ (buffer.length (buffer.from-string Hex)) 2))
                              ".zero 64" ".long 0xffffffff" ".byte 0,2,0,0"])
                  (mg.byte-data Hex)))

(define mg.used?
  Id ["var" _ Id] -> true
  Id [X | Xs] -> (or (mg.used? Id X) (mg.used? Id Xs))
  _ _ -> false)

(define mg.captures
  [] _ -> []
  [[Id Slot] | Env] Body ->
    (if (mg.used? Id Body) [[Id Slot] | (mg.captures Env Body)] (mg.captures Env Body)))

(define mg.lambda
  Id Param Arg Result Effects Body Env ->
    (let Captures (mg.captures Env Body) Slots (map (/. C (hd (tl C))) Captures)
         Fields (map (/. C [(hd C) (hd (hd (tl C)))]) Captures)
         F [object ["parameter_id" Param] ["argument_type" Arg] ["body" Body] ["id" Id] ["name" Id]]
         Label (cn "Llambda" Id)
      (do (if (> (length Slots) (mg.limit "max_inline_captures"))
              (mg.reject Id (make-string "Closure captures ~A bindings, exceeding the limit of ~A"
                             (length Slots) (mg.limit "max_inline_captures"))) skip)
          (set mg.*lambdas* [[F Fields Label] | (value mg.*lambdas*)])
          (arm.lines [(make-string "mov x0, #~A" (* 2 (mg.mask Slots))) "mov x1, #0"])
          (mg.runtime "allocate") (arm.line "cbnz x0, 3f") (arm.trap 3 Id)
          (arm.lines ["3:" "mov x4, x0"]) (mg.address Label) (arm.lines ["str x0, [x4]" "mov x0, x4"])
          (mg.init-fields Slots 1) (mg.save ["Arrow" Arg Result Effects]))))

(define mg.host-op
  Effect Op [[Effect Op Symbol Type] | _] -> [Symbol Type]
  Effect Op [_ | Rest] -> (mg.host-op Effect Op Rest)
  _ _ [] -> none)

\\ Only the result of a strict subexpression escapes its temporary slots.
\\ Move that result below the released range before compiling a sibling.
(define mg.expr
  E Env -> (let Roots (value mg.*roots*) Words (value mg.*words*) S (mg.expression E Env)
                R (set mg.*roots* Roots) W (set mg.*words* Words)
                Base (if (mg.pointer? (hd S)) Roots Words)
             (if (>= (mg.nth 1 S) Base)
                 (let Out (mg.slot (hd S))
                   (do (if (= S Out) skip (do (mg.access "ldr" "x0" S) (mg.access "str" "x0" Out))) Out))
                 S)))

(define mg.expression
  ["handle" Id Effect Cs Body] Env -> (mg.handle Id Effect Cs Body Env)
  ["perform" _ Effect Op E] Env -> (mg.perform Effect Op E Env)
  E Env -> (mg.use E Env) where (and (not (value mg.*tasks*)) (and (= (hd E) "discontinue") (mg.use? E)))
  [Tag Id | _] _ -> (mg.reject Id (make-string "Unsupported clause continuation following ~A in this context" Tag))
                    where (element? Tag ["resume" "discontinue"])
  ["lambda" Id Param Arg Result Effects _ Body] Env -> (mg.lambda Id Param Arg Result Effects Body Env)
  ["apply" _ E A] Env ->
    (let F (mg.expr E Env) Arg (mg.expr A Env)
      (do (mg.access "ldr" "x0" Arg) (mg.access "ldr" "x1" F)
          (arm.lines ["ldr x2, [x1]" "blr x2" (cn "cbnz x1, " (value mg.*unwind*))])
          (mg.save (mg.nth 2 (hd F)))))

  ["emit" _ Name E] Env ->
    (let S (mg.expr E Env)
      (do (mg.write (make-string "emit ~A: " (json.stringify Name [])))
          (mg.access "ldr" "x0" S) (arm.line (cn "bl " (mg.printer (hd S))))
          (if (value mg.*tasks*) (do (mg.write " (task ") (mg.runtime "print_task_id") (mg.write ")")) skip)
          (mg.write (n->string 10)) (arm.line "mov x0, #0") (mg.save "Unit")))
  ["bytes" Id Hex] _ ->
    (do (mg.byte-literal Id Hex) (mg.address (cn "Lbytes" Id)) (mg.save "Bytes"))
  ["prim" _ "bytes_length" E] Env ->
    (do (mg.access "ldr" "x0" (mg.expr E Env)) (arm.line "ldr x0, [x0]") (mg.save "I64"))
  ["prim" Id "bytes_index" A B] Env ->
    (let S (mg.expr A Env) I (mg.expr B Env)
      (do (mg.access "ldr" "x0" S) (mg.access "ldr" "x1" I) (mg.runtime "bytes_index")
          (arm.line "tbz x0, #63, 3f") (arm.trap 4 Id) (arm.line "3:") (mg.save "I64")))
  ["prim" Id "bytes_concat" A B] Env ->
    (let L (mg.expr A Env) R (mg.expr B Env)
      (do (mg.access "ldr" "x0" L) (mg.access "ldr" "x1" R) (mg.runtime "bytes_concat")
          (arm.line "cbnz x0, 3f") (arm.trap 3 Id) (arm.line "3:") (mg.save "Bytes")))

  ["int" _ N] _ -> (do (arm.literal (arm.words N) 0) (mg.save "I64"))
  ["bool" _ B] _ -> (do (arm.line (if (= B true) "mov x0, #1" "mov x0, #0")) (mg.save "Bool"))
  ["unit" _] _ -> (do (arm.line "mov x0, #0") (mg.save "Unit"))
  ["var" _ V] Env -> (arm.lookup V Env)
  ["let" _ V E Body] Env -> (mg.expr Body [[V (mg.expr E Env)] | Env])
  ["tuple" Id | Es] Env ->
    (let E ["tuple" Id | Es] Literal (mg.static E)
      (if (= Literal none)
          (let Slots (map (/. Item (mg.expr Item Env)) Es)
            (mg.aggregate Id 0 ["Tuple" | (map (function hd) Slots)] Slots))
          (do (mg.address (mg.nth 1 Literal)) (mg.save (hd Literal)))))
  ["construct" Id T Name | Es] Env ->
    (let Type (if (= T "TrapCode") T ["Data" T]) Tag (hd (mg.variant Name Type))
      (mg.make-aggregate ["construct" Id T Name | Es] Type Id Tag Es Env))
  ["project" _ ["tuple" _ | Es] Index] Env ->
    (mg.nth (mg.index Index 0) (map (/. Field (mg.expr Field Env)) Es))
  ["project" _ E Index] Env ->
    (let S (mg.expr E Env) I (mg.index Index 0)
      (do (mg.access "ldr" "x0" S) (arm.line (make-string "ldr x0, [x0, #~A]" (* 8 I)))
          (mg.save (mg.nth I (tl (hd S))))))
  ["prim" Id "neg" E] Env -> (do (mg.access "ldr" "x0" (mg.expr E Env))
                                 (arm.checked "negs x0, x0" Id) (mg.save "I64"))
  ["prim" _ "not" E] Env -> (do (mg.access "ldr" "x0" (mg.expr E Env))
                                (arm.lines ["cmp x0, #0" "cset x0, eq"]) (mg.save "Bool"))
  ["prim" Id Op A B] Env ->
    (let L (mg.expr A Env) R (mg.expr B Env)
      (do (mg.access "ldr" "x1" L) (mg.access "ldr" "x0" R) (mg.binary Op Id (hd L))
          (mg.save (if (element? Op ["eq" "lt" "le" "gt" "ge"]) "Bool" "I64"))))
  ["call" _ Name Arg] Env -> (mg.direct-call Name (tl (tl Arg)) Env false) where (mg.direct Name Arg)
  ["call" _ Name E] Env ->
    (let Arg (mg.expr E Env) F (arm.lookup Name (value mg.*functions*))
      (do (mg.access "ldr" "x0" Arg) (arm.line (cn "bl Lfn" (arm.field "id" F)))
          (arm.line (cn "cbnz x1, " (value mg.*unwind*))) (mg.save (arm.field "result_type" F))))
  ["if" Id E Yes No] Env ->
    (let C (mg.expr E Env) Loaded (mg.access "ldr" "x0" C) Branch (arm.line (cn "cbz x0, Lelse" Id))
         Y (mg.expr Yes Env) Out (mg.slot (hd Y))
      (do (mg.access "ldr" "x0" Y) (mg.access "str" "x0" Out)
          (arm.lines [(cn "b Lendif" Id) (make-string "Lelse~A:" Id)])
          (mg.access "ldr" "x0" (mg.expr No Env)) (mg.access "str" "x0" Out)
          (arm.line (make-string "Lendif~A:" Id)) Out))
  ["match" _ ["construct" _ _ Name | Es] | Arms] Env ->
    (mg.match-known Name Arms (map (/. Field (mg.expr Field Env)) Es) Env false)
  ["match" Id E | Arms] Env ->
    (let S (mg.expr E Env)
      (do (mg.access "ldr" "x0" S) (arm.line "ldr w0, [x0, #72]") (mg.dispatch Arms (hd S) Id)
          (let Out (mg.arms Arms S Id Env none) End (arm.line (make-string "Lmatched~A:" Id)) Out)))
  E Env -> (mg.task-expr E Env) where (value mg.*tasks*)
  E _ -> (error "unsupported managed expression ~A" (hd E)))

(define mg.nth
  0 [X | _] -> X
  N [_ | Xs] -> (mg.nth (- N 1) Xs))

(define mg.index
  "" N -> N
  (@s C Cs) N -> (mg.index Cs (+ (* N 10) (- (string->n C) 48))))

(define mg.clear
  N -> (if (= N 0) skip
        (arm.lines ["mov x3, x19" (make-string "mov x2, #~A" N) "1:" "str xzr, [x3], #8"
                    "subs x2, x2, #1" "b.ne 1b"])))

(define mg.frame
  Roots Words -> (let Size (* 8 (+ Roots Words))
    (do (arm.lines ["stp x29, x30, [sp, #-16]!" "mov x29, sp" "stp x19, x20, [sp, #-16]!"
                    "sub sp, sp, #32" "mov x5, sp" (make-string "mov x3, #~A" (+ Size 15))
                    "and x3, x3, #-16" "sub sp, sp, x3" "mov x19, sp"
                    (make-string "mov x2, #~A" (* Roots 8)) "add x20, x19, x2"])
        (if (value mg.*link*) (mg.clear Roots) skip)
        (if (= (value mg.*fields*) none) (mg.access "str" "x0" (value mg.*argument*))
            (mg.incoming (value mg.*fields*) 0))
        (mg.copy-captures (value mg.*capture-slots*) 1)
        (if (value mg.*link*)
            (do (arm.lines ["mov x0, x5" "mov x1, x19" (make-string "mov x2, #~A" Roots)]) (mg.runtime "enter")) skip))))

(define mg.pop-frame
  -> (arm.lines ["sub sp, x29, #16" "ldp x19, x20, [sp], #16" "ldp x29, x30, [sp], #16"]))

(define mg.restore
  -> (do (if (= (value arm.*buffer*) none) (mg.unlink) (arm.line "UNLINK_ROOTS")) (mg.pop-frame)))

(define mg.unlink
  -> (if (value mg.*link*) (mg.runtime "leave_result") skip))

(define mg.has-call?
  [] -> false
  [(@s "b" (@s "l" _)) | _] -> true
  [_ | Rest] -> (mg.has-call? Rest))

(define mg.emit-body
  [] -> done
  ["UNLINK_ROOTS" | Rest] -> (do (mg.unlink) (mg.emit-body Rest))
  [L | Rest] -> (do (arm.line L) (mg.emit-body Rest)))

(define mg.tail-arms
  [] _ _ _ -> done
  [[Name Vs Body] | Arms] S Id Env ->
    (let C (mg.variant Name (hd S))
         Label (arm.line (make-string "Lmatch~Ax~A:" Id (hd C)))
         Scope (mg.bind-fields Vs (hd (tl C)) S 0 Env)
      (do (mg.tail Body Scope) (mg.tail-arms Arms S Id Env))))

(define mg.tail
  E Env -> (if (= none (value mg.*key*)) (mg.tail-body E Env) (mg.clause-tail E Env)))

(define mg.tail-body
  ["call" _ Name Arg] Env -> (mg.direct-call Name (tl (tl Arg)) Env true) where (mg.direct Name Arg)
  ["apply" _ E A] Env ->
    (let F (mg.expr E Env) Arg (mg.expr A Env)
      (do (mg.access "ldr" "x0" Arg) (mg.access "ldr" "x1" F)
          (mg.restore) (arm.lines ["ldr x2, [x1]" "br x2"])))
  ["match" _ ["construct" _ _ Name | Es] | Arms] Env ->
    (mg.match-known Name Arms (map (/. Field (mg.expr Field Env)) Es) Env true)
  ["match" Id E | Arms] Env ->
    (let S (mg.expr E Env)
      (do (mg.access "ldr" "x0" S) (arm.line "ldr w0, [x0, #72]")
          (mg.dispatch Arms (hd S) Id) (mg.tail-arms Arms S Id Env)))
  ["call" _ Name E] Env ->
    (do (mg.access "ldr" "x0" (mg.expr E Env)) (mg.restore)
        (arm.line (cn "b Lfn" (arm.field "id" (arm.lookup Name (value mg.*functions*))))))
  ["if" Id C Yes No] Env ->
    (do (mg.access "ldr" "x0" (mg.expr C Env)) (arm.line (cn "cbz x0, Lelse" Id))
        (mg.tail Yes Env) (arm.line (make-string "Lelse~A:" Id)) (mg.tail No Env))
  ["let" _ V E Body] Env -> (mg.tail Body [[V (mg.expr E Env)] | Env])
  E Env -> (do (mg.access "ldr" "x0" (mg.expr E Env)) (arm.line "mov x1, #0")
               (arm.line (cn "b " (value mg.*return*)))))

(define mg.copy-captures
  [] _ -> done
  [[_ S] | Cs] I -> (do (arm.line (make-string "ldr x3, [x1, #~A]" (* 8 I)))
                         (mg.access "str" "x3" S) (mg.copy-captures Cs (+ I 1))))

(define mg.function
  F Entry -> (mg.emit-function F Entry [] (cn "Lfn" (arm.field "id" F))))

(define mg.export
  Name [[Name Symbol] | _] ->
    (let S (if (= (value arm.*entry*) "_fenrir_entry") (cn "_" Symbol) Symbol)
      (arm.lines [(cn ".globl " S) (cn S ":")]))
  Name [_ | Xs] -> (mg.export Name Xs)
  _ [] -> skip)

(define mg.emit-function
  F Entry Captures Label ->
    (let Id (arm.field "id" F)
         Epilogue (set mg.*return* (cn "Lreturn" Id))
         Self (set mg.*self* (arm.field "name" F)) Loops (set mg.*loops* false)
         Key (set mg.*key* (mg.optional Id (value mg.*clause-keys*) none))
         Unwind (set mg.*unwind* Epilogue)
         WordPeak (set mg.*word-peak* 0) Peak (set mg.*peak* 0) Roots (set mg.*roots* 0) Words (set mg.*words* 0)
         Shape (mg.optional (arm.field "name" F) (value mg.*shapes*) none)
         Arg (set mg.*argument* (if (= Shape none) (mg.slot (arm.field "argument_type" F)) none))
         Fields (set mg.*fields* (if (= Shape none) none (map (/. C [(hd C) (mg.slot (mg.nth 1 C))]) (hd Shape))))
         Scope (set mg.*capture-slots* (map (/. C [(hd C) (mg.slot (hd (tl C)))]) Captures))
         Buffer (set arm.*buffer* [])
         Tail (if (= Shape none) (mg.tail (arm.field "body" F) [[(arm.field "parameter_id" F) Arg] | Scope])
                  (mg.tail (mg.nth 1 Shape) Fields))
         Size (+ 48 (* 8 (+ (value mg.*peak*) (value mg.*word-peak*))))
         FrameCheck (if (> Size (mg.limit "max_managed_frame_bytes"))
                       (mg.reject Id (make-string "Managed stack frame needs ~A bytes, exceeding the limit of ~A"
                                     Size (mg.limit "max_managed_frame_bytes"))) skip)
         Body (reverse (value arm.*buffer*)) Reset (set arm.*buffer* none)
         Linked (set mg.*link* (and (> (value mg.*peak*) 0) (mg.has-call? Body)))
      (do (mg.export (arm.field "name" F) (value mg.*exports*))
          (if (= Entry (arm.field "name" F)) (if (value mg.*tasks*) (mg.task-entry F) (arm.line (cn (value arm.*entry*) ":"))) skip)
          (arm.line (cn Label ":"))
          (if (= Shape none) skip (do (mg.unbox Fields 0) (arm.line (make-string "Ldirect~A:" Id))))
          (scan.fast (scan.match F Shape) Id)
          (mg.frame (value mg.*peak*) (value mg.*word-peak*))
          (if (value mg.*loops*) (arm.line (make-string "Lbody~A:" Id)) skip)
          (mg.emit-body Body) (arm.line (cn Epilogue ":")) (mg.restore) (arm.line "ret")
          (if (value mg.*loops*)
              (do (arm.line (make-string "Lrepeat~A:" Id))
                  (if Linked (mg.clear (value mg.*peak*)) skip) (mg.incoming Fields 0)
                  (arm.line (cn "b Lbody" Id))) skip))))

(define mg.emit-lambdas
  [] -> done
  [[F Cs Label] | Rest] -> (do (set mg.*lambdas* Rest) (mg.emit-function F none Cs Label)
                               (mg.emit-lambdas (value mg.*lambdas*))))

(define mg.compile
  A -> (let Fs (arm.field "functions" A) Entry (arm.field "entry" A)
            Fns (set mg.*functions* (map (/. F [(arm.field "name" F) F]) Fs))
            Ds (set mg.*types* (mg.type-table (arm.field "datatypes" A) 7))
            T (arm.field "result_type" (arm.lookup Entry Fns))
            Shapes (set mg.*shapes* (map (/. F [(arm.field "name" F) (mg.unpacked (arm.field "argument_type" F) F)]) Fs))
            Effects (set mg.*effects* (mg.numbered (arm.field "effects" A) 0))
            Keys (set mg.*clause-keys* []) Answers (set mg.*answers* []) Origins (set mg.*origins* [])
            Lambdas (set mg.*lambdas* []) Printers (set mg.*printers* []) Pending (set mg.*pending* []) Texts (set mg.*texts* [])
            ScanData (set mg.*scan-data* []) Images (set mg.*images* []) Constants (set mg.*constants* []) Literals (set mg.*bytes* [])
            Sites (set arm.*sites* [])
         (do
             (arm.lines [".text" ".p2align 2"]) (if (value mg.*tasks*) skip (arm.line (cn ".globl " (value arm.*entry*))))
             (map (/. F (mg.function F Entry)) Fs)
             (mg.emit-lambdas (value mg.*lambdas*))
             (map (function arm.report) (arm.field "source_map" A))
             (mg.result-printer T)
             (map (function mg.byte-object) (value mg.*bytes*))
             (map (function mg.nullary) (value mg.*constants*))
             (map (function mg.image-data) (value mg.*images*))
             (map (function scan.data) (value mg.*scan-data*)))))
