\\ Fenrir harness, in Shen: run a batch of TC0-A pure-call programs inside a
\\ Solo5 guest and compare every reference step with the Shen model, which runs
\\ in this same process. Development evidence only; no qualification verdict.
\\
\\ Host: Shen/JIT 0.7 with its JSON, buffer and subprocess libraries.
\\   shen-jit script harness/solo5-pure-call.shen LIBDIR ROOT BATCHDIR
\\ LIBDIR   Shen/JIT lib directory (with shen-process.so built)
\\ ROOT     repository root
\\ BATCHDIR directory holding batch.json, programs.json and the guest image,
\\          as written by tools/solo5/freerun-pure-call.mjs --build-only
\\
\\ What is NOT in Shen yet: generating the programs, validating them, and
\\ lowering them into the guest image. Those are still the JavaScript tools.
\\ Nothing here trusts the guest: its output is parsed strictly and compared
\\ with what the model computes; the model never sees guest output.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*batch* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ ---------- guest output: strict frames ----------

\\ "FGRUN/1 " then a decimal length, a newline, exactly that many payload bytes, a newline.
\\ Lines that do not start with FG are tender diagnostics and are skipped.
(define fh.prefix?
  V I End -> (and (<= (+ I 8) End)
                  (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71) (= (buffer.u8 V (+ I 2)) 82)
                  (= (buffer.u8 V (+ I 3)) 85) (= (buffer.u8 V (+ I 4)) 78) (= (buffer.u8 V (+ I 5)) 47)
                  (= (buffer.u8 V (+ I 6)) 49) (= (buffer.u8 V (+ I 7)) 32)))

(define fh.fg-line?
  V I End -> (and (<= (+ I 2) End) (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71)))

\\ Returns [Length IndexAfterNewline].
(define fh.length-field
  V I End N Digits -> (error "harness: truncated frame header") where (>= I End)
  V I End N Digits -> (if (> Digits 0) [N (+ I 1)] (error "harness: empty frame length")) where (= (buffer.u8 V I) 10)
  V I End N Digits ->
    (let B (buffer.u8 V I)
      (if (and (>= B 48) (<= B 57) (< Digits 9))
          (fh.length-field V (+ I 1) End (+ (* N 10) (- B 48)) (+ Digits 1))
          (error "harness: invalid frame length"))))

(define fh.scan
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (if (fh.prefix? V I End)
        (let Header (fh.length-field V (+ I 8) End 0 0)
             N (hd Header)
             Start (hd (tl Header))
          (if (and (< (+ Start N) End) (= (buffer.u8 V (+ Start N)) 10))
              (fh.scan V (+ Start (+ N 1)) End
                       [(json.decode (buffer.slice V Start N) [[byte-limit 1048576]]) | Acc])
              (error "harness: frame length does not match its payload")))
        (if (fh.fg-line? V I End)
            (error "harness: unknown FG frame")
            (fh.scan V (fh.next-line V I End) End Acc))))

(define fh.frames
  V -> (fh.scan V 0 (buffer.length V) []))

\\ Hello, then per program: Program, its steps, End; then Terminal.
(define fh.steps
  [[object ["execution" X] ["kind" "End"]] | Frames] Steps Acc -> (fh.programs Frames [[X (reverse Steps)] | Acc])
  [Step | Frames] Steps Acc -> (fh.steps Frames [Step | Steps] Acc)
  [] _ _ -> (error "harness: guest output ends inside a program"))

(define fh.programs
  [[object ["kind" "Terminal"]]] Acc -> (reverse Acc)
  [[object ["index" _] ["kind" "Program"]] | Frames] Acc -> (fh.steps Frames [] Acc)
  _ _ -> (error "harness: guest program framing"))

(define fh.guest-traces
  [[object ["batch_sha256" B] ["kind" "Hello"]] | Frames] B -> (fh.programs Frames [])
  _ _ -> (error "harness: guest identity mismatch"))

(define fh.guest-range
  Tender Guest Batch Mode First End ->
    (let R (process.run Tender ["--mem=32" Guest (make-string "~A ~A ~A" Mode First End)] (buffer.from-string "")
                        [[timeout 120000] [stdout-limit 134217728]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (fh.guest-traces (fh.frames (process.output-bytes (hd (tl R)))) Batch)
          (error "harness: guest run failed for ~A ~A..~A" Mode First End))))

(define fh.guest-all
  Tender Guest Batch Mode First Count -> [] where (>= First Count)
  Tender Guest Batch Mode First Count ->
    (let End (if (> (+ First 250) Count) Count (+ First 250))
      (append (fh.guest-range Tender Guest Batch Mode First End)
              (fh.guest-all Tender Guest Batch Mode End Count))))

\\ ---------- comparison ----------

(define fh.step-count
  [] N -> N
  [[_ Steps] | Rest] N -> (fh.step-count Rest (+ N (length Steps))))

\\ Indices of programs whose guest trace differs from the model trace.
(define fh.differing
  [] [] _ Acc -> (reverse Acc)
  [M | Ms] [G | Gs] I Acc -> (fh.differing Ms Gs (+ I 1) (if (= M G) Acc [I | Acc]))
  _ _ _ _ -> (error "harness: trace counts differ"))

(define fh.first-divergence
  [] [] _ -> "none"
  [S | Ms] [S | Gs] I -> (fh.first-divergence Ms Gs (+ I 1))
  _ _ I -> (str I))

(define fh.describe
  [] _ _ -> []
  [I | Is] Model Guest ->
    [[object ["program" (str I)]
             ["model_execution" (hd (nth (+ I 1) Model))] ["guest_execution" (hd (nth (+ I 1) Guest))]
             ["first_divergent_epoch" (fh.first-divergence (hd (tl (nth (+ I 1) Model))) (hd (tl (nth (+ I 1) Guest))) 0)]]
     | (fh.describe Is Model Guest)])

(define fh.main
  -> (let Batch (json.parse (read-file-as-string (cn (value fh.*batch*) "batch.json")) [])
          Sha (fh.field "batch_sha256" Batch)
          Tender (fh.field "tender" Batch)
          Guest (fh.field "guest" Batch)
          Programs (json.parse (read-file-as-string (fh.field "programs" Batch)) [[byte-limit 268435456]])
          Count (length Programs)
          Model (map (/. P (fh.run (fh.state P) 200 0 [])) Programs)
          Normal (fh.guest-all Tender Guest Sha "normal" 0 Count)
          Failures (fh.differing Model Normal 0 [])
          Reversed (length (fh.differing Model (fh.guest-all Tender Guest Sha "reverse-operands" 0 Count) 0 []))
          Wrapped (length (fh.differing Model (fh.guest-all Tender Guest Sha "wrap-overflow" 0 Count) 0 []))
          Pass (and (empty? Failures) (> Reversed 0) (> Wrapped 0))
          Report [object ["schema" "fenrir.harness.solo5-pure-call/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["model" "models/tc0/pure-call-machine.shen with models/tc0/i64.shen, run in this process"]
                         ["batch_sha256" Sha]
                         ["programs" (str Count)]
                         ["model_steps" (str (fh.step-count Model 0))]
                         ["guest_steps" (str (fh.step-count Normal 0))]
                         ["programs_differing" (str (length Failures))]
                         ["defects_detected" [object ["reverse-operands" (str Reversed)] ["wrap-overflow" (str Wrapped)]]]
                         ["failures" (fh.describe (fh.take 10 Failures) Model Normal)]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
