\\ Returns [type assembler-word] for immutable literals. Only forms with
\\ no effects, traps, or runtime inputs may enter the image constant pool.
(define mg.static-fields
  [] -> []
  [E | Es] -> (let S (mg.static E)
                (if (= S none) none
                  (let Rest (mg.static-fields Es) (if (= Rest none) none [S | Rest])))))

(define mg.static
  ["int" _ N] -> ["I64" N]
  ["bool" _ B] -> ["Bool" (if B "1" "0")]
  ["unit" _] -> ["Unit" "0"]
  ["bytes" Id Hex] -> (do (mg.byte-literal Id Hex) ["Bytes" (cn "Lbytes" Id)])
  ["construct" _ Name Variant | Es] ->
    (let T (if (= Name "TrapCode") Name ["Data" Name]) Fields (mg.static-fields Es)
      (if (= Fields none) none (mg.image-cell T (hd (mg.variant Variant T)) Fields)))
  ["tuple" _ | Es] ->
    (let Fields (mg.static-fields Es)
      (if (= Fields none) none (mg.image-cell ["Tuple" | (map (function hd) Fields)] 0 Fields)))
  _ -> none)

(define mg.byte-literal
  Id Hex -> (if (element? [Id Hex] (value mg.*bytes*)) skip
                (set mg.*bytes* [[Id Hex] | (value mg.*bytes*)])))

(define mg.image-cell
  T Tag Fields ->
    (let Key [Tag (mg.mask Fields) (map (/. S (mg.nth 1 S)) Fields)]
         Table (value mg.*images*) Existing (mg.optional Key Table none)
      (if (= Existing none)
          (let Label (make-string "Lstatic~A" (length Table))
            (do (set mg.*images* [[Key Label] | Table]) [T Label]))
          [T Existing])))

(define mg.image-data
  [[Tag Mask Words] Label] ->
    (do (if (= Mask 0) skip
          (arm.line (if (= (value arm.*entry*) "_fenrir_entry") ".section __DATA_CONST,__const" ".section .rodata")))
        (arm.lines [".p2align 3" (cn Label ":")])
        (map (/. W (arm.line (cn ".quad " W))) Words)
        (arm.lines [(make-string ".zero ~A" (* 8 (- 9 (length Words)))) (make-string ".long ~A" Tag)
                    (make-string ".byte ~A,2,0,0" Mask) ".text"])))

(define mg.make-aggregate
  E T Id Tag Es Env ->
    (let Literal (mg.static E)
      (if (= Literal none) (mg.aggregate Id Tag T (map (/. Field (mg.expr Field Env)) Es))
          (do (mg.address (mg.nth 1 Literal)) (mg.save (hd Literal))))))

(define mg.match-known
  Name [[Name Vars Body] | _] Slots Env Tail ->
    (let Inner (mg.bind-slots Vars Slots Env) (if Tail (mg.tail Body Inner) (mg.expr Body Inner)))
  Name [_ | Arms] Slots Env Tail -> (mg.match-known Name Arms Slots Env Tail))

(define mg.bind-slots
  [] [] Env -> Env
  [V | Vs] [S | Ss] Env -> (mg.bind-slots Vs Ss [[V S] | Env]))
