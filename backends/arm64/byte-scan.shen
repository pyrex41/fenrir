\\ Recognize a total byte predicate and its three possible scan outcomes.
\\ An unrecognized term, out-of-range literal or exhausted evaluation budget
\\ leaves the original checked Fenrir loop in place.
(define scan.number
  S -> (mg.index S 0) where (and (<= (buffer.length (buffer.from-string S)) 3)
                                 (not (= "-" (pos S 0))))
  _ -> unknown)

(define scan.eval
  E Env Fuel -> unknown where (<= Fuel 0)
  ["var" _ V] Env _ -> (mg.optional V Env unknown)
  ["int" _ N] _ _ -> (scan.number N)
  ["bool" _ B] _ _ -> B
  ["if" _ C Y N] Env F -> (scan.choose (scan.eval C Env (- F 1)) Y N Env F)
  ["prim" _ Op A B] Env F -> (scan.cmp Op (scan.eval A Env (- F 1)) (scan.eval B Env (- F 1)))
  ["call" _ Name ["tuple" _ | Args]] Env F ->
     (let Shape (arm.lookup Name (value mg.*shapes*))
       (if (= Shape none) unknown
         (let Values (map (/. E (scan.eval E Env (- F 1))) Args)
           (if (element? unknown Values) unknown
               (scan.eval (mg.nth 1 Shape) (mg.bind-slots (map (function hd) (hd Shape)) Values []) (- F 1))))))
  _ _ _ -> unknown)

(define scan.choose
  true Y _ Env F -> (scan.eval Y Env (- F 1))
  false _ N Env F -> (scan.eval N Env (- F 1))
  _ _ _ _ _ -> unknown)

(define scan.cmp
  _ unknown _ -> unknown
  _ _ unknown -> unknown
  "eq" A B -> (= A B)
  "lt" A B -> (< A B)
  "le" A B -> (<= A B)
  "gt" A B -> (> A B)
  "ge" A B -> (>= A B)
  _ _ _ -> unknown)

(define scan.action
  ["if" _ C Y N] Env Name B I ->
     (let P (scan.eval C Env 10)
       (cases (= P true) (scan.action Y Env Name B I)
              (= P false) (scan.action N Env Name B I) true unknown))
  ["int" _ "-1"] _ _ _ _ -> 0
  ["var" _ I] _ _ _ I -> 1
  ["call" _ Name ["tuple" _ ["var" _ B] ["prim" _ "add" ["var" _ I] ["int" _ "1"]]]] _ Name B I -> 2
  _ _ _ _ _ -> unknown)

(define scan.table
  256 _ _ _ _ _ Acc -> (reverse Acc)
  Byte V E Name B I Acc ->
    (let Action (scan.action E [[V Byte]] Name B I)
      (if (= Action unknown) [] (scan.table (+ Byte 1) V E Name B I [Action | Acc]))))

(define scan.match
  F [[[B "Bytes"] [I "I64"]]
      ["if" _ ["prim" _ "eq" ["var" _ I] ["prim" _ "bytes_length" ["var" _ B]]]
              ["int" _ "-1"] ["let" _ V ["prim" _ "bytes_index" ["var" _ B] ["var" _ I]] E]]] ->
    (scan.table 0 V E (arm.field "name" F) B I [])
  _ _ -> [])

(define scan.range
  [] _ _ Best -> Best
  [2 | Rest] I Start [Lo Hi] ->
    (scan.range Rest (+ I 1) Start (if (> (- I Start) (- Hi Lo)) [Start I] [Lo Hi]))
  [_ | Rest] I _ Best -> (scan.range Rest (+ I 1) (+ I 1) Best))

(define scan.fast
  [] _ -> skip
  Table Id ->
    (let Label (cn "LscanTable" Id) Range (scan.range Table 0 0 [0 -1])
      (do (set mg.*scan-data* [[Label Table] | (value mg.*scan-data*)])
          (arm.lines ["ldr w3, [x8, #72]" "cmn w3, #1" "b.ne 9f" "ldr x4, [x8]"
                      "cmp x9, x4" "b.hi 9f" "add x2, x8, #80"])
          (mg.address Label)
          (if (< (mg.nth 1 Range) 0) (arm.line "6:")
            (arm.lines [(make-string "movi v1.16b, #~A" (hd Range))
                        (make-string "movi v2.16b, #~A" (mg.nth 1 Range)) "6:"
                        "sub x6, x4, x9" "cmp x6, #16" "b.lo 7f" "ldr q0, [x2, x9]"
                        "cmhs v3.16b, v0.16b, v1.16b" "cmhs v4.16b, v2.16b, v0.16b"
                        "and v3.16b, v3.16b, v4.16b" "uminv b3, v3.16b" "umov w5, v3.b[0]"
                        "cbz w5, 7f" "add x9, x9, #16" "b 6b" "7:"]))
          (arm.lines ["cmp x9, x4" "b.eq 8f" "ldrb w5, [x2, x9]" "ldrb w5, [x0, x5]"
                      "cbz w5, 8f" "cmp w5, #1" "b.eq 7f" "add x9, x9, #1" "b 6b" "8:"
                      "mov x9, #-1" "7:" "mov x0, x9" "mov x1, #0" "ret" "9:"]))))

(define scan.data
  [Label Table] -> (do (arm.line (cn Label ":")) (map (/. N (arm.line (make-string ".byte ~A" N))) Table)))
