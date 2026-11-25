\\ Fenrir harness, in Shen: one request served by a peer's program, on three
\\ machines (contract spec/tc1/EFFECTS.md section 12.12).
\\
\\ A case is a peer program, one of the operations it serves, the request's
\\ input and the store it is served on. For every case the Shen model
\\ (models/tc1/handler-machine.shen with the store effects of
\\ models/tc1/remote-tc1-peer.shen, in this process), the JavaScript machine
\\ (runtime/tc1/peer-request.mjs) and the C machine in a Solo5 guest
\\ (backends/solo5/remote/check.c, with the store code the peer image uses,
\\ serve.c) must agree on the whole run: every machine step, every store
\\ perform with its value, in order, how the run ended, and the writes it would
\\ commit. Hand cases also carry an expected outcome and expected writes,
\\ written from the programs' text before any machine ran; the model must give
\\ those. The deliberate defect of the JavaScript and of the C store code, a read
\\ that does not see its own request's writes, must each be detected on at
\\ least one case.
\\ What is not here: the commit, the reply record, replay and conflict. Those
\\ are the peer runtime's and are checked on the real system by
\\ harness/tc1-remote-run.shen.
\\ Evidence level: agreement of three implementations on listed cases. Its
\\ report is the remote-peer row of the TC1 gate (harness/tc1-gate.shen).
\\
\\   shen-jit script harness/tc1-peer-requests.shen LIBDIR ROOT DIR
\\ DIR  directory written by tools/tc1/peer-requests.mjs

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fq.*dir* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "models/tc1/remote-system.shen"))
(load (cn (value fh.*root*) "models/tc1/remote-tc1-peer.shen"))

\\ ---------- guest output: strict frames ----------

\\ "FGRUN/1 " then a decimal length, a newline, exactly that many payload bytes, a
\\ newline. Lines that do not start with FG are tender diagnostics and are skipped.
\\ (The frame reader of harness/solo5-pure-call.shen, which is a program and cannot be loaded.)
(define fq.prefix?
  V I End -> (and (<= (+ I 8) End)
                  (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71) (= (buffer.u8 V (+ I 2)) 82)
                  (= (buffer.u8 V (+ I 3)) 85) (= (buffer.u8 V (+ I 4)) 78) (= (buffer.u8 V (+ I 5)) 47)
                  (= (buffer.u8 V (+ I 6)) 49) (= (buffer.u8 V (+ I 7)) 32)))

(define fq.fg-line?
  V I End -> (and (<= (+ I 2) End) (= (buffer.u8 V I) 70) (= (buffer.u8 V (+ I 1)) 71)))

(define fq.length-field
  V I End N Digits -> (error "harness: truncated frame header") where (>= I End)
  V I End N Digits -> (if (> Digits 0) [N (+ I 1)] (error "harness: empty frame length")) where (= (buffer.u8 V I) 10)
  V I End N Digits ->
    (let B (buffer.u8 V I)
      (if (and (>= B 48) (<= B 57) (< Digits 9))
          (fq.length-field V (+ I 1) End (+ (* N 10) (- B 48)) (+ Digits 1))
          (error "harness: invalid frame length"))))

(define fq.scan
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (if (fq.prefix? V I End)
        (let Header (fq.length-field V (+ I 8) End 0 0)
             N (hd Header)
             Start (hd (tl Header))
          (if (and (< (+ Start N) End) (= (buffer.u8 V (+ Start N)) 10))
              (fq.scan V (+ Start (+ N 1)) End
                       [(json.decode (buffer.slice V Start N) [[byte-limit 1048576]]) | Acc])
              (error "harness: frame length does not match its payload")))
        (if (fq.fg-line? V I End)
            (error "harness: unknown FG frame")
            (fq.scan V (fh.next-line V I End) End Acc))))

\\ Hello, then per case: Case, its samples and store performs, End; then Terminal.
\\ A run is [Execution Trace Writes].
(define fq.entries
  [[object ["execution" X] ["kind" "End"] ["writes" Writes]] | Frames] Entries Acc -> (fq.cases Frames [[X (reverse Entries) Writes] | Acc])
  [Entry | Frames] Entries Acc -> (fq.entries Frames [(fh.canon Entry) | Entries] Acc)
  [] _ _ -> (error "harness: guest output ends inside a case"))

(define fq.cases
  [[object ["kind" "Terminal"]]] Acc -> (reverse Acc)
  [[object ["index" _] ["kind" "Case"]] | Frames] Acc -> (fq.entries Frames [] Acc)
  _ _ -> (error "harness: guest case framing"))

(define fq.guest-runs
  [[object ["batch_sha256" B] ["kind" "Hello"]] | Frames] B -> (fq.cases Frames [])
  _ _ -> (error "harness: guest identity mismatch"))

(define fq.guest-range
  Tender Guest Batch Mode First End ->
    (let R (fh.run-process Tender ["--mem=32" Guest (make-string "~A ~A ~A" Mode First End)] (buffer.from-string "")
                        [[timeout 120000] [stdout-limit 134217728]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (let V (process.output-bytes (hd (tl R)))
            (fq.guest-runs (fq.scan V 0 (buffer.length V) []) Batch))
          (error "harness: guest run failed for ~A ~A..~A" Mode First End))))

(define fq.guest-all
  Tender Guest Batch Mode First Count -> [] where (>= First Count)
  Tender Guest Batch Mode First Count ->
    (let End (if (> (+ First 100) Count) Count (+ First 100))
      (append (fq.guest-range Tender Guest Batch Mode First End)
              (fq.guest-all Tender Guest Batch Mode End Count))))

\\ ---------- the model's run of one case ----------

(define fq.value
  ["unit"] -> [unit]
  ["int" N] -> [int N]
  ["tuple" | Vs] -> [tuple | (map (/. V (fq.value V)) Vs)]
  V -> (error "harness: unexpected input ~S" V))

(define fq.store
  [] Store -> Store
  [[K V] | Cells] Store -> (fq.store Cells (remote.store-put K V Store)))

(define fq.store-event
  [get K V] -> [object ["key" K] ["store" "get"] ["value" V]]
  [put K V] -> [object ["key" K] ["store" "put"] ["value" V]])

\\ The machine's step records, as fh.run makes them, with the store performs
\\ between them; the machine takes no step for a store perform.
(define fq.trace
  [tc1-state [terminal _] | _] _ Buffer _ _ Acc -> ["Completed" (reverse Acc) Buffer]
  _ _ Buffer 0 _ Acc -> ["BudgetExhausted" (reverse Acc) Buffer]
  State Store Buffer Fuel Epoch Acc ->
    (let P (remote.store-perform State Store Buffer false)
      (if (= P [])
          (let T (tc1.step State)
               Next (hd (tl T))
               Step [object ["after" (fh.after (fh.phase Next))] ["depth" (str (fh.depth Next))] ["epoch" (str Epoch)]
                            ["events" (map (/. E (fh.event E)) (hd (tl (tl T))))] ["site" (fh.site (tc1.site State))]]
            (fq.trace Next Store Buffer (- Fuel 1) (+ Epoch 1) [(fh.canon Step) | Acc]))
          (fq.trace (hd P) Store (hd (tl P)) Fuel Epoch [(fq.store-event (hd (tl (tl P)))) | Acc]))))

(define fq.program
  "0" [P | _] -> P
  "1" [_ P | _] -> P
  "2" [_ _ P | _] -> P
  N _ -> (error "harness: no program ~A" N))

\\ [Run Outcome]: the run, and how the model's memoised run of the same request ends.
(define fq.model
  Programs Fuel Case ->
    (let Program (fq.program (fh.field "program" Case) Programs)
         Op (fh.field "operation" Case)
         Input (fq.value (fh.field "input" Case))
         Store (fq.store (fh.field "store" Case) [])
      [(fq.trace (remote.peer-state Program Op Input) Store [] Fuel 0 [])
       (remote.served false Program Op Input Store)]))

(define fq.js
  Key Case -> (let R (fh.field Key Case)
                [(fh.field "execution" R) (map (/. E (fh.canon E)) (fh.field "trace" R)) (fh.field "writes" R)]))

\\ ---------- comparison ----------

\\ The expectation of a hand case against the model: the outcome, and for an Ok outcome the writes.
(define fq.expectation
  Case [Run [Outcome Writes]] ->
    (let E (fh.field "expected" Case)
      (if (cons? E)
          (if (and (= (fh.canon (fh.field "outcome" E)) (fh.outcome Outcome))
                   (or (= (hd Outcome) trap) (= (fh.field "writes" E) Writes))
                   (= Writes (nth 3 Run)))
              held failed)
          none)))

(define fq.count
  _ [] -> 0
  F [X | Xs] -> (+ (if (F X) 1 0) (fq.count F Xs)))

(define fq.differing
  [] [] [] Acc -> (reverse Acc)
  [C | Cs] [[M _] | Ms] [R | Rs] Acc -> (fq.differing Cs Ms Rs (if (= M R) Acc [(fh.field "name" C) | Acc]))
  _ _ _ _ -> (error "harness: run counts differ"))

(define fq.first-difference
  [] [] _ -> "none"
  [E | Ms] [E | Rs] I -> (fq.first-difference Ms Rs (+ I 1))
  _ _ I -> (str I))

(define fq.describe
  Name [C | Cs] [[M _] | Ms] [R | Rs] ->
    (if (= (fh.field "name" C) Name)
        [object ["case" Name] ["model_execution" (hd M)] ["other_execution" (hd R)]
                ["first_differing_entry" (fq.first-difference (hd (tl M)) (hd (tl R)) 0)]
                ["model_writes" (nth 3 M)] ["other_writes" (nth 3 R)]]
        (fq.describe Name Cs Ms Rs)))

(define fq.entries-of
  F [] -> 0
  F [[[_ Trace _] _] | Ms] -> (+ (fq.count F Trace) (fq.entries-of F Ms)))

(define fq.store-entry?
  [object ["key" _] | _] -> true
  _ -> false)

(define fq.outcomes
  [] Acc -> Acc
  [[_ [[ok _] _]] | Ms] Acc -> (fq.outcomes Ms (fh.count-key "Ok" Acc))
  [[_ [[trap Code] _]] | Ms] Acc -> (fq.outcomes Ms (fh.count-key (cn "Trap:" (fh.trap-name Code)) Acc)))

(define fq.main
  -> (let Batch (json.parse (read-file-as-string (cn (value fq.*dir*) "batch.json")) [])
          Artifacts (json.parse (read-file-as-string (fh.field "programs" Batch)) [[byte-limit 16777216]])
          Programs (map (/. A (fh.peer (fh.field "module" A) true A)) Artifacts)
          View (buffer.from-string (read-file-as-string (fh.field "cases" Batch)))
          Cases (fh.json-lines View 0 (buffer.length View) [])
          Count (length Cases)
          Fuel (tc0.i64.small (fh.field "fuel" Batch))
          Model (map (/. C (fq.model Programs Fuel C)) Cases)
          Js (map (/. C (fq.js "js" C)) Cases)
          Guest (fq.guest-all (fh.field "tender" Batch) (fh.field "guest" Batch) (fh.field "batch_sha256" Batch) "normal" 0 Count)
          JsDiffer (fq.differing Cases Model Js [])
          GuestDiffer (fq.differing Cases Model Guest [])
          Checked (fq.expectations Cases Model [])
          Failed (map (/. X (hd X)) (fh.take 10 (hd (tl Checked))))
          JsStale (length (fq.differing Cases Model (map (/. C (fq.js "js_stale_reads" C)) Cases) []))
          GuestStale (length (fq.differing Cases Model (fq.guest-all (fh.field "tender" Batch) (fh.field "guest" Batch) (fh.field "batch_sha256" Batch) "stale-reads" 0 Count) []))
          Pass (and (> Count 0) (= Count (tc0.i64.small (fh.field "count" Batch))) (empty? JsDiffer) (empty? GuestDiffer)
                    (empty? (hd (tl Checked))) (= (hd Checked) (tc0.i64.small (fh.field "hand" Batch)))
                    (> JsStale 0) (> GuestStale 0))
          Report [object ["schema" "fenrir.harness.tc1-peer-requests/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["evidence" "three implementations of one request served by a peer's program agree on listed cases: the Shen model, the JavaScript machine and the C machine in a Solo5 guest; the commit and the reply record are not exercised here"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["model" "models/tc1/handler-machine.shen with the store effects of models/tc1/remote-tc1-peer.shen, run in this process"]
                         ["programs" (fh.field "sources" Batch)]
                         ["abi" (fh.field "abi" Batch)]
                         ["solo5_commit" (fh.field "solo5_commit" Batch)]
                         ["tender_sha256" (fh.field "tender_sha256" Batch)]
                         ["guest_sha256" (fh.field "guest_sha256" Batch)]
                         ["batch_sha256" (fh.field "batch_sha256" Batch)]
                         ["cases" (str Count)]
                         ["hand_cases" (fh.field "hand" Batch)]
                         ["generated_cases" (fh.field "generated" Batch)]
                         ["generated_seed" (fh.field "seed" Batch)]
                         ["fuel" (str Fuel)]
                         ["model_steps" (str (fq.entries-of (/. E (not (fq.store-entry? E))) Model))]
                         ["store_performs" (str (fq.entries-of (/. E (fq.store-entry? E)) Model))]
                         ["outcomes" [object | (map (/. K [(hd K) (str (hd (tl K)))]) (fq.outcomes Model []))]]
                         ["cases_with_writes" (str (fq.count (/. M (cons? (nth 3 (hd M)))) Model))]
                         ["javascript_differing" (str (length JsDiffer))]
                         ["guest_differing" (str (length GuestDiffer))]
                         ["expectations_checked" (str (hd Checked))]
                         ["expectations_failed" Failed]
                         ["defects_detected" [object ["javascript-stale-reads" (str JsStale)] ["guest-stale-reads" (str GuestStale)]]]
                         ["failures" (append (map (/. N (fq.describe N Cases Model Js)) (fh.take 5 JsDiffer))
                                             (map (/. N (fq.describe N Cases Model Guest)) (fh.take 5 GuestDiffer)))]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

\\ [Checked Failed]: how many cases carry an expectation, and those the model does not meet.
(define fq.expectations
  [] [] Acc -> [(length Acc) (fq.failed Acc)]
  [C | Cs] [M | Ms] Acc -> (let E (fq.expectation C M)
                            (fq.expectations Cs Ms (if (= E none) Acc [[(fh.field "name" C) E] | Acc]))))

(define fq.failed
  [] -> []
  [[Name failed] | Rest] -> [[Name failed] | (fq.failed Rest)]
  [_ | Rest] -> (fq.failed Rest))

(fq.main)
