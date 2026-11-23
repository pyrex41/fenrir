\\ Input is a validated scalar artifact. Every stack slot is 16 bytes.
\\ x9 is the incoming SP, x0 is the value, x1 carries the trap status.
(define arm.field
  K [object | Fields] -> (arm.lookup K Fields))

(define arm.lookup
  K [[K V] | _] -> V
  K [_ | Rest] -> (arm.lookup K Rest)
  K [] -> (error "missing scalar field or binding ~A" K))

(define arm.ascii
  "" _ -> done
  (@s C Cs) Stream -> (do (write-byte (string->n C) Stream) (arm.ascii Cs Stream)))

(define arm.line
  Text -> (if (= (value arm.*buffer*) none)
            (arm.ascii (cn Text (n->string 10)) (value arm.*out*))
            (set arm.*buffer* [Text | (value arm.*buffer*)])))

(define arm.lines
  [] -> done
  [L | Ls] -> (do (arm.line L) (arm.lines Ls)))

(define arm.push
  -> (arm.line "str x0, [sp, #-16]!"))

(define arm.carry
  N -> -1 where (< N 0)
  N -> 0 where (< N 65536)
  N -> (+ 1 (arm.carry (- N 65536))))

\\ Parse decimal literals a digit at a time in Z/(2^64). All host
\\ intermediates fit 32 bits, including for the minimum signed integer.
(define arm.scale
  [] _ _ -> []
  [W | Ws] Factor Carry ->
    (let N (+ (* W Factor) Carry)
         Q (arm.carry N)
         R (- N (* 65536 Q))
      [R | (arm.scale Ws Factor Q)]))

(define arm.digits
  "" Words -> Words
  (@s D Ds) Words -> (arm.digits Ds (arm.scale Words 10 (- (string->n D) 48))))

(define arm.words
  (@s "-" N) -> (arm.scale (arm.digits N [0 0 0 0]) -1 0)
  N -> (arm.digits N [0 0 0 0]))

(define arm.literal
  [] _ -> done
  [W | Ws] Shift ->
    (do (arm.line (make-string "~A x0, #~A, lsl #~A" (if (= Shift 0) "movz" "movk") W Shift))
        (arm.literal Ws (+ Shift 16))))

(define arm.trap
  Code Site -> (let Id (if (= (value arm.*buffer*) none) Site (mg.optional Site (value mg.*origins*) Site))
    (do (set arm.*sites* [Id | (value arm.*sites*)]) (if (= (value arm.*buffer*) none)
      (arm.lines ["mov sp, x9" (make-string "mov x1, #~A" Code) (if (= (value arm.*image-kind*) standalone) (cn "b Lreport" Id) "ret")])
      (arm.lines [(make-string "mov x1, #~A" Code) (cn "bl Lreport" Id) (cn "b " (value mg.*unwind*))])))))

(define arm.checked
  Ins Id -> (do (arm.line Ins) (arm.line "b.vc 1f") (arm.trap 1 Id) (arm.line "1:")))

(define arm.binary
  "add" Id -> (arm.checked "adds x0, x1, x0" Id)
  "sub" Id -> (arm.checked "subs x0, x1, x0" Id)
  "mul" Id -> (do (arm.lines ["smulh x3, x1, x0" "mul x0, x1, x0" "cmp x3, x0, asr #63" "b.eq 1f"])
                  (arm.trap 1 Id) (arm.line "1:"))
  "div" Id -> (do (arm.line "cbnz x0, 1f") (arm.trap 2 Id)
                  (arm.lines ["1:" "cmn x0, #1" "b.ne 2f" "negs xzr, x1" "b.vc 2f"])
                  (arm.trap 1 Id) (arm.lines ["2:" "sdiv x0, x1, x0"]))
  Op _ -> (arm.lines ["cmp x1, x0" (cn "cset x0, " Op)]) where (element? Op ["eq" "lt" "le" "gt" "ge"])
  Op _ -> (error "unsupported scalar operation ~A" Op))

(define arm.expr
  ["int" _ N] _ _ -> (arm.literal (arm.words N) 0)
  ["bool" _ B] _ _ -> (arm.line (if (= B true) "movz x0, #1" "movz x0, #0"))
  ["var" _ V] Env D -> (arm.line (make-string "ldr x0, [sp, #~A]" (* 16 (- (- D 1) (arm.lookup V Env)))))
  ["prim" Id "neg" A] Env D -> (do (arm.expr A Env D) (arm.checked "negs x0, x0" Id))
  ["prim" _ "not" A] Env D -> (do (arm.expr A Env D) (arm.lines ["cmp x0, #0" "cset x0, eq"]))
  ["prim" Id Op A B] Env D ->
    (do (arm.expr A Env D) (arm.push) (arm.expr B Env (+ D 1))
        (arm.line "ldr x1, [sp], #16") (arm.binary Op Id))
  ["if" Id C T F] Env D ->
    (do (arm.expr C Env D) (arm.line (cn "cbz x0, Lelse" Id))
        (arm.expr T Env D) (arm.line (cn "b Lendif" Id)) (arm.line (make-string "Lelse~A:" Id))
        (arm.expr F Env D) (arm.line (make-string "Lendif~A:" Id)))
  ["let" _ V E Body] Env D ->
    (do (arm.expr E Env D) (arm.push) (arm.expr Body [[V D] | Env] (+ D 1)) (arm.line "add sp, sp, #16"))
  ["call" _ Name A] Env D ->
    (do (arm.expr A Env D) (arm.line (cn "bl Lfn" (arm.lookup Name (value arm.*functions*))))
        (arm.line (make-string "add x9, sp, #~A" (* D 16)))
        (arm.line (make-string "ldr x30, [sp, #~A]" (* (- D 2) 16)))
        (arm.lines ["cbz x1, 1f" "mov sp, x9" "ret" "1:"]))
  E _ _ -> (error "unsupported scalar expression ~A" (hd E)))

(define arm.calls?
  ["call" | _] -> true
  [X | Xs] -> (or (arm.calls? X) (arm.calls? Xs))
  _ -> false)

(define arm.tail
  E Env D -> (do (arm.expr E Env D) (arm.lines ["mov sp, x9" "movz x1, #0" "ret"]))
             where (not (arm.calls? E))
  ["call" _ Name A] Env D ->
    (do (arm.expr A Env D) (arm.line "mov sp, x9")
        (arm.line (cn "b Lfn" (arm.lookup Name (value arm.*functions*)))))
  ["let" _ V E Body] Env D ->
    (do (arm.expr E Env D) (arm.push) (arm.tail Body [[V D] | Env] (+ D 1)))
  ["if" Id C T F] Env D ->
    (do (arm.expr C Env D) (arm.line (cn "cbz x0, Lelse" Id)) (arm.tail T Env D)
        (arm.line (make-string "Lelse~A:" Id)) (arm.tail F Env D))
  E Env D -> (do (arm.expr E Env D) (arm.lines ["mov sp, x9" "movz x1, #0" "ret"])))

(define arm.fn-id
  F -> [(arm.field "name" F) (arm.field "id" F)])

(define arm.expr-function
  F -> (do (arm.line (cn (value arm.*entry*) ":"))
           (arm.line "mov x9, sp") (arm.push)
           (arm.expr (arm.field "body" F) [[(arm.field "parameter_id" F) 0]] 1)
           (arm.lines ["add sp, sp, #16" "movz x1, #0" "ret"])))

(define arm.function
  F _ -> (arm.expr-function F) where (= (value arm.*image-kind*) proof-expr)
  F Entry -> (let Id (arm.field "id" F)
    (do (if (= Entry (arm.field "name" F)) (arm.line (cn (value arm.*entry*) ":")) skip)
        (arm.line (make-string "Lfn~A:" Id))
        (arm.line "mov x9, sp") (arm.push) (arm.line "str x30, [sp, #-16]!")
        (arm.tail (arm.field "body" F) [[(arm.field "parameter_id" F) 0]] 2))))

(define arm.bytes
  View I End -> done where (= I End)
  View I End -> (do (arm.line (make-string ".byte ~A" (buffer.u8 View I)))
                    (arm.bytes View (+ I 1) End)))

(define arm.report
  Pos -> (let Id (arm.field "id" Pos)
              Label (cn "Lposition" Id)
              Darwin (= (value arm.*entry*) "_fenrir_entry")
              Text (make-string "trap at: ~A:~A:~A~%" (arm.field "file" Pos) (arm.field "line" Pos) (arm.field "column" Pos))
              View (buffer.from-string Text)
           (if (element? Id (value arm.*sites*))
             (do (arm.lines [".p2align 2" (make-string "Lreport~A:" Id) "stp x1, x30, [sp, #-16]!"])
                 (if Darwin
                   (arm.lines [(make-string "adrp x0, ~A@PAGE" Label) (make-string "add x0, x0, ~A@PAGEOFF" Label)
                               "bl _fen_set_location"])
                   (arm.lines [(cn "adrp x0, " Label) (cn "add x0, x0, :lo12:" Label) "bl fen_set_location"]))
                 (arm.lines ["ldp x1, x30, [sp], #16" "ret" (cn Label ":")])
                 (arm.bytes View 0 (buffer.length View)) (arm.line ".byte 0"))
             skip)))

(define arm.scalar-type
  F -> (and (element? (arm.field "argument_type" F) ["I64" "Bool"])
            (and (element? (arm.field "result_type" F) ["I64" "Bool"]) (= [] (arm.field "effects" F)))))

(define arm.scalar-functions?
  [] -> true
  [F | Fs] -> (and (arm.scalar-type F) (arm.scalar-functions? Fs)))

(define arm.scalar
  Artifact -> (let Fs (arm.field "functions" Artifact)
                   Table (set arm.*functions* (map (function arm.fn-id) Fs))
                   Sites (set arm.*sites* [])
                   Checked (if (arm.scalar-functions? Fs) true (error "Shen scalar backend requires pure I64/Bool functions"))
                   Entry (arm.field "entry" Artifact)
                (do (arm.lines [".text" ".p2align 2" (cn ".globl " (value arm.*entry*))])
                    (map (/. F (arm.function F Entry)) Fs)
                    (if (= (value arm.*image-kind*) standalone)
                        (do (map (function arm.report) (arm.field "source_map" Artifact)) (arm.scalar-printer)) skip))))

(define arm.scalar-printer
  -> (if (= (value arm.*entry*) "_fenrir_entry")
                      (arm.lines [".p2align 2" ".globl _fen_print_result" "_fen_print_result:" "b _fen_write_i64"])
                      (arm.lines [".p2align 2" ".globl fen_print_result" "fen_print_result:" "b fen_write_i64"])))

(define arm.scalar-tree?
  [Tag _ | Args] -> (and (element? Tag ["var" "int" "bool" "let" "prim" "if" "call"])
                         (arm.scalar-children? Args))
  _ -> false)

(define arm.scalar-children?
  [] -> true
  [X | Xs] -> (and (if (cons? X) (arm.scalar-tree? X) true) (arm.scalar-children? Xs)))

(define arm.scalar-bodies?
  [] -> true
  [F | Fs] -> (and (arm.scalar-tree? (arm.field "body" F)) (arm.scalar-bodies? Fs)))

(define arm.scalar-program?
  A -> (let Fs (arm.field "functions" A)
         (and (arm.scalar-functions? Fs) (arm.scalar-bodies? Fs))))
