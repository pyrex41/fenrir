\\ A distinct routine for each reachable type. Publish its label before
\\ visiting fields so a recursive datatype can refer to its own printer.
(define mg.printer
  Type -> (let Table (value mg.*printers*)
            (if (element? Type (map (function hd) Table)) (arm.lookup Type Table)
              (let Label (make-string "Lprint~A" (length Table))
                (do (set mg.*printers* [[Type Label] | Table])
                    (set mg.*pending* [[Type Label] | (value mg.*pending*)]) Label)))))

(define mg.write
  Text -> (let Label (make-string "Ltext~A" (length (value mg.*texts*)))
               View (buffer.from-string Text)
            (do (set mg.*texts* [[Label View] | (value mg.*texts*)])
                (mg.address Label) (arm.line (make-string "mov x1, #~A" (buffer.length View)))
                (mg.runtime "write"))))

(define mg.print-fields
  [] _ -> done
  [T | Ts] I -> (do (mg.write " ") (arm.line (make-string "ldr x0, [x19, #~A]" (* 8 I)))
                    (arm.line (cn "bl " (mg.printer T))) (mg.print-fields Ts (+ I 1))))

(define mg.named
  Name [] -> (mg.write Name)
  Name Fields -> (do (mg.write (cn "(" Name)) (mg.print-fields Fields 0) (mg.write ")")))

(define mg.print-variants
  [] _ -> (arm.line "brk #0")
  [C | Cs] Tag ->
    (do (arm.lines ["ldr w2, [x19, #72]" (make-string "mov w3, #~A" Tag) "cmp w2, w3" "b.ne 4f"])
        (mg.named (arm.field "name" C) (arm.field "fields" C))
        (arm.lines ["b 5f" "4:"]) (mg.print-variants Cs (+ Tag 1))))

(define mg.print-body
  "I64" -> (mg.runtime "write_i64")
  "Bytes" -> (mg.runtime "print_bytes")
  "Unit" -> (mg.write "unit")
  "Bool" -> (do (arm.line "cbz x0, 4f") (mg.write "true") (arm.lines ["b 5f" "4:"]) (mg.write "false"))
  ["Tuple" | Ts] -> (mg.named "tuple" Ts)
  "TrapCode" -> (mg.print-variants (mg.traps) 1)
  ["Data" Name] -> (let Table (arm.lookup Name (value mg.*types*)) (mg.print-variants (hd (tl Table)) (hd Table)))
  T -> (mg.print-variants (mg.task-ctors T) 0) where (not (= [] (mg.task-variants T)))
  T -> (error "unsupported native printer ~A" T))

(define mg.emit-printers
  [] -> done
  [[Type Label] | Rest] ->
    (do (set mg.*pending* Rest) (arm.lines [(cn Label ":") "stp x19, x30, [sp, #-16]!" "mov x19, x0"])
        (mg.print-body Type) (arm.lines ["5:" "ldp x19, x30, [sp], #16" "ret"])
        (mg.emit-printers (value mg.*pending*))))

(define mg.text-data
  [Label View] -> (do (arm.line (cn Label ":")) (arm.bytes View 0 (buffer.length View))))

(define mg.result-printer
  T -> (let Symbol (if (= (value arm.*entry*) "_fenrir_entry") "_fen_print_result" "fen_print_result")
         (do (arm.lines [".p2align 2" (cn ".globl " Symbol) (cn Symbol ":")
                         (cn "b " (mg.printer (if (= T "Bool") "I64" T)))])
             (mg.emit-printers (value mg.*pending*))
             (map (function mg.text-data) (value mg.*texts*)))))
