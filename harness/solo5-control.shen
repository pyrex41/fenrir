\\ Fenrir harness, in Shen: drive the host-controlled pure-call Solo5 guest step by
\\ step over protocol fenrir.solo5.pure-call-control/1
\\ (spec/solo5/pure-call-control-v1.md), compare every step with the Shen model as it
\\ goes, stop the guest at the first divergence, record tapes and replay them strictly
\\ against cold boots, and run hostile-peer tests in both directions. Development
\\ evidence only; no qualification verdict.
\\
\\ Host: Shen/JIT 0.7 with its JSON, buffer and subprocess libraries. The tender is the
\\ STOCK solo5-spt; the channel is two Solo5 net devices it attaches to the pipes this
\\ process holds (--net:ctlin=@0 --net:ctlout=@2). No helper process sits between this
\\ program and the tender, and every protocol decision is made here.
\\   shen-jit script harness/solo5-control.shen LIBDIR ROOT BATCHDIR OUTDIR
\\ BATCHDIR as written by tools/solo5/control-pure-call-build.mjs; OUTDIR receives tapes
\\ and the console logs. The report is the last line of standard output.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fc.*batch* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fc.*out* (cn (hd (tl (tl (tl (tl (value *argv*)))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

(set fc.*protocol* "fenrir.solo5.pure-call-control/1")
(set fc.*profile* "fenrir.solo5.pure-call-machine/1")
(set fc.*tape-schema* "fenrir.solo5.pure-call-control-tape/1")
(set fc.*guest-max* 61440)
(set fc.*host-max* 512)
(set fc.*run-max* 64)
\\ Milliseconds the host waits for any one guest frame before it calls the run a
\\ HarnessTimeout; and the quiet interval of the no-advance check.
(set fc.*frame-timeout* 10000)
(set fc.*quiet* 300)

\\ ---------- failures ----------

\\ A classified failure travels as an error "fc|Class|Detail". Classes: Protocol (the
\\ peer broke the protocol; Detail is the code), GuestError (the guest reported Error),
\\ HarnessTimeout, Transport, TenderFailure, Incompatible, TapeIntegrity, Structure,
\\ Diverged. Anything else is HarnessError.
(define fc.fail
  Class Detail -> (simple-error (make-string "fc|~A|~A" Class Detail)))

(define fc.upto
  "" _ -> ""
  (@s C Cs) C -> ""
  (@s C Cs) D -> (cn C (fc.upto Cs D)))

(define fc.after
  "" _ -> ""
  (@s C Cs) C -> Cs
  (@s _ Cs) D -> (fc.after Cs D))

\\ [Class Detail] of a caught error.
(define fc.classify
  E -> (let M (error-to-string E)
         (if (fh.starts? "fc|" M)
             (let Rest (fh.drop "fc|" M) [(fc.upto Rest "|") (fc.after Rest "|")])
             ["HarnessError" M])))

\\ ---------- frames ----------

(define fc.length
  S -> (buffer.length (buffer.from-string S)))

(define fc.pad
  S -> S where (>= (length (explode S)) 8)
  S -> (fc.pad (cn "0" S)))

\\ "FGC1 " Dir Type " " seq(8) " " length(8) LF payload LF.
(define fc.frame
  Dir Type Seq Payload ->
    (cn "FGC1 " (cn Dir (cn Type (cn " " (cn (fc.pad (str Seq)) (cn " " (cn (fc.pad (str (fc.length Payload)))
        (cn "c#10;" (cn Payload "c#10;"))))))))))

(define fc.digit?
  B -> (and (>= B 48) (<= B 57)))

(define fc.fixed
  V I 0 Acc -> Acc
  V I K Acc -> (fc.fixed V (+ I 1) (- K 1) (+ (* Acc 10) (- (buffer.u8 V I) 48))))

(define fc.all-digits?
  V I 0 -> true
  V I K -> (and (fc.digit? (buffer.u8 V I)) (fc.all-digits? V (+ I 1) (- K 1))))

(define fc.printable?
  V I End -> true where (>= I End)
  V I End -> (let B (buffer.u8 V I) (and (>= B 32) (<= B 126) (fc.printable? V (+ I 1) End))))

\\ Parse one frame at the start of view V (N bytes available). Dirs and Types are lists
\\ of the allowed direction and type characters; Seq the expected sequence number, or
\\ any; Max the payload limit. The checks run in the order the guest's own reader uses.
\\ Returns [need K] when K bytes are needed, else [frame Dir Type Seq Payload Size].
(define fc.parse
  V N Dirs Types Seq Max ->
    (if (< N 26)
        [need 26]
        (let C (/. I (n->string (buffer.u8 V I)))
          (cond ((not (= (buffer.string (buffer.slice V 0 5)) "FGC1 ")) (fc.fail "Protocol" "BadMagic"))
                ((not (element? (C 5) Dirs)) (fc.fail "Protocol" "BadDirection"))
                ((not (element? (C 6) Types)) (fc.fail "Protocol" "UnknownType"))
                ((not (and (= (C 7) " ") (= (C 16) " ") (= (buffer.u8 V 25) 10)
                           (fc.all-digits? V 8 8) (fc.all-digits? V 17 8)))
                  (fc.fail "Protocol" "BadHeader"))
                ((and (not (= Seq any)) (not (= (fc.fixed V 8 8 0) Seq))) (fc.fail "Protocol" "BadSequence"))
                ((> (fc.fixed V 17 8 0) Max) (fc.fail "Protocol" "Oversize"))
                (true
                  (let L (fc.fixed V 17 8 0)
                    (cond ((< N (+ 27 L)) [need (+ 27 L)])
                          ((not (= (buffer.u8 V (+ 26 L)) 10)) (fc.fail "Protocol" "BadTrailer"))
                          ((not (fc.printable? V 26 (+ 26 L))) (fc.fail "Protocol" "BadPayload"))
                          (true [frame (C 5) (C 6) (fc.fixed V 8 8 0) (buffer.string (buffer.slice V 26 L)) (+ 27 L)]))))))))

\\ ---------- a reader over a pipe, or over fixed bytes ----------

\\ [Endpoint Buffer Start End Eof]: Endpoint [] means the bytes are all there already.
\\ A pipe reader holds 256 KiB, more than four guest frames; a peer that floods it fails.
(define fc.reader
  E Capacity -> (let R (absvector 5)
                  (do (address-> R 0 E) (address-> R 1 (buffer.new Capacity)) (address-> R 2 0) (address-> R 3 0)
                      (address-> R 4 (= E [])) R)))

(define fc.scripted
  Bytes -> (let V (buffer.from-string Bytes)
                N (buffer.length V)
                R (fc.reader [] (+ N 1))
             (do (buffer.copy! (<-address R 1) 0 V 0 N) (address-> R 3 N) R)))

(define fc.available
  R -> (- (<-address R 3) (<-address R 2)))

(define fc.view
  R -> (buffer.slice (<-address R 1) (<-address R 2) (fc.available R)))

\\ Read once more: true when bytes arrived, false at end of input; a timeout raises
\\ HarnessTimeout, or returns timeout when Quiet.
(define fc.read-more
  R Ms Quiet ->
    (if (<-address R 4)
        false
        (let B (<-address R 1)
             _ (if (> (<-address R 2) 0)
                   (do (buffer.copy! B 0 B (<-address R 2) (fc.available R))
                       (address-> R 3 (fc.available R)) (address-> R 2 0))
                   true)
             _ (if (>= (<-address R 3) (buffer.length B)) (fc.fail "Protocol" "Flood") true)
             E (process.pipe-until (<-address R 0) (clock.deadline Ms) (freeze false))
             Result (io.read-some E (buffer.slice B (<-address R 3) (- (buffer.length B) (<-address R 3))) [])
          (cond ((= (hd Result) read) (do (address-> R 3 (+ (<-address R 3) (hd (tl Result)))) true))
                ((= (hd Result) eof) (do (address-> R 4 true) false))
                ((= (io.error-domain (hd (tl Result))) timeout)
                  (if Quiet timeout (fc.fail "HarnessTimeout" "no complete guest frame within the deadline")))
                (true (fc.fail "Transport" (io.error-message (hd (tl Result)))))))))

\\ The next frame, consumed: [Dir Type Seq Payload Raw].
(define fc.next-frame
  R Dirs Types Seq Max ->
    (let P (fc.parse (fc.view R) (fc.available R) Dirs Types Seq Max)
      (if (= (hd P) need)
          (if (fc.read-more R (value fc.*frame-timeout*) false)
              (fc.next-frame R Dirs Types Seq Max)
              (fc.fail "Protocol" "Truncated"))
          (let Size (nth 6 P)
               Raw (buffer.string (buffer.slice (fc.view R) 0 Size))
               _ (address-> R 2 (+ (<-address R 2) Size))
            [(nth 2 P) (nth 3 P) (nth 4 P) (nth 5 P) Raw]))))

\\ After Bye: the guest must say nothing more before its output ends.
(define fc.drain
  R -> (if (> (fc.available R) 0)
           (fc.fail "Protocol" "TrailingOutput")
           (if (fc.read-more R (value fc.*frame-timeout*) false) (fc.drain R) true)))

\\ ---------- sessions ----------

\\ [Child Reader HostSeq Log Console]. Child [] is a scripted guest: sends go nowhere.
(define fc.session
  Child Reader Console -> (let S (absvector 5)
                    (do (address-> S 0 Child) (address-> S 1 Reader) (address-> S 2 1) (address-> S 3 [])
                        (address-> S 4 Console) S)))

(set fc.*boots* 0)

(define fc.spawn
  Program Args Console ->
    (let R (process.spawn Program Args [[stdin pipe] [stdout [file Console]] [stderr pipe]])
         _ (set fc.*boots* (+ 1 (value fc.*boots*)))
      (if (= (hd R) ok)
          (fc.session (hd (tl R)) (fc.reader (process.stderr (hd (tl R))) 262144) Console)
          (fc.fail "TenderFailure" "spawn failed"))))

(define fc.boot
  Image Console -> (fc.spawn (value fc.*tender*) ["--mem=32" "--net:ctlin=@0" "--net:ctlout=@2" Image] Console))

(define fc.log
  S Raw -> (address-> S 3 [Raw | (<-address S 3)]))

(define fc.write
  S Bytes ->
    (if (= (<-address S 0) [])
        true
        (let R (io.write-all (process.stdin (<-address S 0)) (buffer.from-string Bytes) [])
          (if (= (hd R) ok) true (fc.fail "Transport" "request write failed")))))

\\ Send one request of Type with Payload; the sequence number is the session's.
(define fc.send
  S Type Payload ->
    (let Raw (fc.frame "H" Type (<-address S 2) Payload)
         _ (fc.write S Raw)
         _ (fc.log S Raw)
      (address-> S 2 (+ 1 (<-address S 2)))))

(define fc.kind
  "H" -> "Hello" "Y" -> "Ready" "S" -> "Steps" "D" -> "Digest" "B" -> "Bye" "E" -> "Error")

(define fc.decode
  Payload -> (trap-error (json.decode (buffer.from-string Payload) [[byte-limit 1048576]])
                         (/. E (fc.fail "Protocol" "BadPayload"))))

\\ The response to the last request (or Hello, sequence 0), of the given Type, decoded.
\\ An Error frame is a GuestError: never a pass.
(define fc.expect
  S Type ->
    (let Seq (- (<-address S 2) 1)
         F (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] Seq (value fc.*guest-max*))
         _ (fc.log S (nth 5 F))
         J (fc.decode (nth 4 F))
         _ (if (and (cons? J) (= (hd J) object) (= (fh.member "kind" J) (fc.kind (nth 2 F))))
               true (fc.fail "Protocol" "BadPayload"))
      (cond ((= (nth 2 F) "E") (fc.fail "GuestError" (fh.member "code" J)))
            ((not (= (nth 2 F) Type)) (fc.fail "Protocol" "UnexpectedType"))
            (true J))))

(define fc.status
  [ok [exited N]] -> N
  [ok [signalled N]] -> (- 0 N)
  _ -> pending)

\\ Wait for the tender to exit; its exit status, or a HarnessTimeout.
(define fc.exit-status
  S -> (if (= (<-address S 0) [])
           0
           (let C (<-address S 0)
                St (fc.status (process.wait C 5000))
             (if (= St pending)
                 (do (process.kill C) (process.wait C 5000) (process.close C)
                     (fc.fail "HarnessTimeout" "tender did not exit"))
                 (do (process.close C) St)))))

\\ Kill a session that failed, then re-raise the failure.
(define fc.abandon
  S E -> (do (if (= (<-address S 0) [])
                 true
                 (trap-error (let C (<-address S 0)
                                  _ (process.kill C)
                                  _ (process.wait C 5000)
                               (process.close C))
                             (/. X true)))
             (simple-error (error-to-string E))))

(define fc.with
  S F -> (trap-error (F S) (/. E (fc.abandon S E))))

\\ Terminate, expect Bye, the end of output and exit status 0.
(define fc.terminate
  S -> (let _ (fc.send S "X" "{c#34;kindc#34;:c#34;Terminatec#34;}")
            Bye (fc.expect S "B")
            _ (fc.drain (<-address S 1))
            St (fc.exit-status S)
         (if (= St 0) Bye (fc.fail "TenderFailure" (make-string "exit ~A after Bye" St)))))

\\ ---------- the batch ----------

(set fc.*batch-json* (json.parse (read-file-as-string (cn (value fc.*batch*) "batch.json")) [[byte-limit 16777216]]))
(define fc.b Key -> (fh.field Key (value fc.*batch-json*)))
(set fc.*tender* (fc.b "tender"))
(set fc.*control* (fc.b "control"))
(set fc.*guest* (fc.b "guest"))

\\ Canonical decimal string to number.
(define fc.number-of
  "" Acc -> Acc
  (@s C Cs) Acc -> (if (fc.digit? (string->n C)) (fc.number-of Cs (+ (* Acc 10) (- (string->n C) 48)))
                       (error "harness: not a decimal ~A" C)))
(define fc.number S -> (fc.number-of S 0))

(set fc.*count* (fc.number (fc.b "count")))
(set fc.*fuel* (fc.number (fc.b "fuel")))
(set fc.*identities* (fc.b "programs"))
(define fc.identity I Key -> (fh.field Key (nth (+ I 1) (value fc.*identities*))))

\\ The model runs exactly the bytes whose SHA-256 the Init request names: each
\\ artifacts/<i>.json is hashed here (sha256sum, one call) and decoded here.
(define fc.artifact-path I -> (make-string "~Aartifacts/~A.json" (value fc.*batch*) I))
(define fc.range
  I N -> [] where (>= I N)
  I N -> [I | (fc.range (+ I 1) N)])
(set fc.*indices* (fc.range 0 (value fc.*count*)))

(define fc.hashes
  Paths -> (let R (fh.exec "sha256sum" Paths 120)
             (if (= (hd R) 0)
                 (map (/. L (fh.take-string 64 L)) (fc.nonempty (fh.lines (hd (tl R)))))
                 (error "harness: sha256sum failed"))))
(define fc.nonempty
  [] -> []
  ["" | Ls] -> (fc.nonempty Ls)
  [L | Ls] -> [L | (fc.nonempty Ls)])

(set fc.*artifact-hashes* (fc.hashes (map (/. I (fc.artifact-path I)) (value fc.*indices*))))
(define fc.check-hashes
  [] [] _ -> true
  [H | Hs] [I | Is] N -> (if (= H (fc.identity I "artifact_sha256")) (fc.check-hashes Hs Is N)
                             (error "harness: artifact ~A bytes do not match the declared SHA-256" I)))
(fc.check-hashes (value fc.*artifact-hashes*) (value fc.*indices*) 0)
(set fc.*artifacts* (map (/. I (json.parse (read-file-as-string (fc.artifact-path I)) [[byte-limit 16777216]])) (value fc.*indices*)))
(define fc.artifact I -> (nth (+ I 1) (value fc.*artifacts*)))
(define fc.family I -> (fc.identity I "family"))

\\ ---------- requests ----------

(define fc.q S -> (cn "c#34;" (cn S "c#34;")))
(define fc.kv K V -> (cn (fc.q K) (cn ":" (fc.q V))))

(define fc.init-payload
  I Mode -> (fc.init-fields (fc.identity I "artifact_sha256") (fc.b "batch_sha256") (str (value fc.*fuel*)) Mode (str I)
                            (value fc.*protocol*) (fc.identity I "schema")))

(define fc.init-fields
  Artifact Batch Fuel Mode Program Protocol Schema ->
    (cn "{" (cn (fc.kv "artifact_sha256" Artifact) (cn "," (cn (fc.kv "batch_sha256" Batch) (cn "," (cn (fc.kv "fuel" Fuel)
      (cn "," (cn (fc.kv "kind" "Init") (cn "," (cn (fc.kv "mode" Mode) (cn "," (cn (fc.kv "program" Program)
      (cn "," (cn (fc.kv "protocol" Protocol) (cn "," (cn (fc.kv "schema" Schema) "}")))))))))))))))))

(define fc.run-payload
  N -> (cn "{" (cn (fc.kv "kind" "Run") (cn "," (cn (fc.kv "steps" (str N)) "}")))))

(set fc.*digest-payload* "{c#34;kindc#34;:c#34;Digestc#34;}")

\\ Hello must name this protocol, machine profile, batch and program count.
(define fc.check-hello
  J -> (if (and (= (fh.member "protocol" J) (value fc.*protocol*))
                (= (fh.member "machine_profile" J) (value fc.*profile*))
                (= (fh.member "batch_sha256" J) (fc.b "batch_sha256"))
                (= (fh.member "programs" J) (str (value fc.*count*))))
           J
           (fc.fail "Protocol" "Identity")))

(define fc.check-ready
  J I Mode -> (if (and (= (fh.member "artifact_sha256" J) (fc.identity I "artifact_sha256"))
                       (= (fh.member "program" J) (str I)) (= (fh.member "mode" J) Mode)
                       (= (fh.member "schema" J) (fc.identity I "schema"))
                       (= (fh.member "epoch" J) "0") (= (fh.member "execution" J) "Running"))
                  J
                  (fc.fail "Protocol" "Identity")))

\\ Boot, Hello, Init, Ready: an initialized session.
(define fc.open
  I Mode Console -> (fc.with (fc.boot (value fc.*control*) Console)
                      (/. S (let _ (fc.check-hello (fc.expect S "H"))
                                 _ (fc.send S "I" (fc.init-payload I Mode))
                                 _ (fc.check-ready (fc.expect S "Y") I Mode)
                              S))))

\\ A Steps response to Run N at epoch Epoch: 1..N records with consecutive epochs from
\\ Epoch, a response epoch after the last, and a known execution state.
(define fc.records
  J N Epoch -> (let Steps (fh.member "steps" J)
                    K (if (cons? Steps) (length Steps) 0)
                 (if (and (> K 0) (<= K N)
                          (fc.consecutive? Steps Epoch)
                          (= (fh.member "epoch" J) (str (+ Epoch K)))
                          (element? (fh.member "execution" J) ["Running" "Completed" "BudgetExhausted"]))
                     Steps
                     (fc.fail "Protocol" "BadSteps"))))

(define fc.consecutive?
  [] _ -> true
  [S | Ss] E -> (and (= (fh.member "epoch" S) (str E)) (fc.consecutive? Ss (+ E 1))))

\\ ---------- the model, one step at a time ----------

\\ [Record Next] for the step from State at Epoch, in the guest's JSON shape.
(define fc.model-record
  State Epoch -> (let T (fh.model-step State)
                      Next (hd (tl T))
                   [[object ["after" (fh.after (fh.phase Next))] ["depth" (str (fh.depth Next))] ["epoch" (str Epoch)]
                            ["events" (map (/. E (fh.event E)) (hd (tl (tl T))))] ["site" (fh.site (fh.model-site State))]]
                    Next]))

(define fc.model-execution
  State Epoch -> "Completed" where (= (fh.phase State) terminal)
  State Epoch -> "BudgetExhausted" where (>= Epoch (value fc.*fuel*))
  _ _ -> "Running")

\\ Compare Records with the model from State at Epoch. [agree State Epoch] or
\\ [diverge Epoch] at the first record that differs.
(define fc.compare
  [] State Epoch -> [agree State Epoch]
  [R | Rs] State Epoch -> (let M (fc.model-record State Epoch)
                            (if (= R (hd M))
                                (fc.compare Rs (hd (tl M)) (+ Epoch 1))
                                [diverge Epoch])))

\\ ---------- one controlled run ----------

\\ Drive program I in Mode with the host's step schedule (a list of Run sizes, cycled),
\\ comparing every step with the model and stopping at the first divergence.
\\ Result: [Outcome DivergenceEpoch GuestEpoch GuestRecords Tape] with Outcome agreed
\\ or diverged; DivergenceEpoch is none when agreed; GuestEpoch is the epoch Bye reports.
(define fc.controlled
  I Mode Schedule -> (let S (fc.open I Mode (make-string "~Aconsole-~A-~A.txt" (value fc.*out*) Mode I))
                       (fc.with S (/. S (fc.drive S (fh.state (fc.artifact I)) 0 Schedule Schedule [])))))

(define fc.drive
  S State Epoch [] All Acc -> (fc.drive S State Epoch All All Acc)
  S State Epoch [N | Ns] All Acc ->
    (if (not (= (fc.model-execution State Epoch) "Running"))
        (fc.finish S agreed none Acc)
        (let _ (fc.send S "R" (fc.run-payload N))
             J (fc.expect S "S")
             Records (fc.records J N Epoch)
             C (fc.compare Records State Epoch)
             Seen (append Acc Records)
          (cond ((= (hd C) diverge) (fc.finish S diverged (str (nth 2 C)) Seen))
                ((not (= (fh.member "execution" J) (fc.model-execution (nth 2 C) (nth 3 C))))
                  (fc.finish S diverged (str (nth 3 C)) Seen))
                (true (fc.drive S (nth 2 C) (nth 3 C) Ns All Seen))))))

(define fc.finish
  S Outcome At Acc -> (let Bye (fc.terminate S)
                        [Outcome At (fh.member "epoch" Bye) Acc (reverse (<-address S 3))]))

\\ ---------- the free-running guest, for cross-checks only ----------

\\ The existing free-run frames (FGRUN/1) of guest.spt over the same batch: an
\\ independent record of what the guest machine does when nobody controls it.
(define fc.fr-prefix?
  V I End -> (and (<= (+ I 8) End) (= (buffer.string (buffer.slice V I 8)) "FGRUN/1 ")))

(define fc.fr-length
  V I End N -> (error "harness: truncated free-run frame") where (>= I End)
  V I End N -> [N (+ I 1)] where (= (buffer.u8 V I) 10)
  V I End N -> (fc.fr-length V (+ I 1) End (+ (* N 10) (- (buffer.u8 V I) 48))))

(define fc.fr-scan
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (if (fc.fr-prefix? V I End)
        (let H (fc.fr-length V (+ I 8) End 0)
          (fc.fr-scan V (+ (hd (tl H)) (+ (hd H) 1)) End
                      [(json.decode (buffer.slice V (hd (tl H)) (hd H)) [[byte-limit 1048576]]) | Acc]))
        (fc.fr-scan V (fh.next-line V I End) End Acc)))

(define fc.fr-steps
  [[object ["execution" X] ["kind" "End"]] | Frames] Steps Acc -> (fc.fr-programs Frames [[X (reverse Steps)] | Acc])
  [Step | Frames] Steps Acc -> (fc.fr-steps Frames [Step | Steps] Acc))

(define fc.fr-programs
  [[object ["kind" "Terminal"]]] Acc -> (reverse Acc)
  [[object ["index" _] ["kind" "Program"]] | Frames] Acc -> (fc.fr-steps Frames [] Acc))

(define fc.fr-range
  Mode First End ->
    (let R (process.run (value fc.*tender*) ["--mem=32" (value fc.*guest*) (make-string "~A ~A ~A" Mode First End)]
                        (buffer.from-string "") [[timeout 120000] [stdout-limit 134217728]])
         V (if (and (= (hd R) ok) (process.success? (hd (tl R)))) (process.output-bytes (hd (tl R)))
               (error "harness: free-run guest failed"))
         Frames (fc.fr-scan V 0 (buffer.length V) [])
      (if (= (fh.member "batch_sha256" (hd Frames)) (fc.b "batch_sha256"))
          (fc.fr-programs (tl Frames) [])
          (error "harness: free-run identity"))))

(define fc.free-run
  Mode First Count -> [] where (>= First Count)
  Mode First Count -> (let End (if (> (+ First 250) Count) Count (+ First 250))
                        (append (fc.fr-range Mode First End) (fc.free-run Mode End Count))))

(define fc.first-divergence
  [] [] _ -> none
  [S | Ms] [S | Gs] I -> (fc.first-divergence Ms Gs (+ I 1))
  _ _ I -> (str I))

(define fc.prefix?
  [] _ -> true
  [X | Xs] [X | Ys] -> (fc.prefix? Xs Ys)
  _ _ -> false)

\\ ---------- tapes ----------

\\ A tape is frames: a header (dir T, type H, seq 0), every exchanged frame in order
\\ (Hello, then each request and its response), and a footer (dir T, type F) whose seq
\\ is the number of exchanged frames plus one and whose payload binds their count and
\\ the SHA-256 of every byte before the footer.
(define fc.tape-header
  I Mode -> (json.stringify
              [object ["artifact_sha256" (fc.identity I "artifact_sha256")] ["batch_sha256" (fc.b "batch_sha256")]
                      ["control_sha256" (fc.b "control_sha256")] ["fuel" (str (value fc.*fuel*))] ["kind" "TapeHeader"]
                      ["machine_profile" (value fc.*profile*)] ["mode" Mode] ["program" (str I)]
                      ["protocol" (value fc.*protocol*)] ["schema" (fc.identity I "schema")]
                      ["solo5" (fh.field "path" (fc.b "solo5_identity"))] ["tape" (value fc.*tape-schema*)]
                      ["tender_sha256" (fc.b "tender_sha256")]] []))

(define fc.concat
  [] -> ""
  [S | Ss] -> (cn S (fc.concat Ss)))

(set fc.*scratch* 0)
(define fc.sha256-of
  Text -> (let _ (set fc.*scratch* (+ 1 (value fc.*scratch*)))
               Path (make-string "~Asha-~A.bin" (value fc.*out*) (value fc.*scratch*))
               _ (write-to-file Path Text)
            (fh.sha256 Path)))

(define fc.seal
  Header Raws -> (let Body (cn (fc.frame "T" "H" 0 Header) (fc.concat Raws))
                   (cn Body (fc.frame "T" "F" (+ 1 (length Raws))
                                      (json.stringify [object ["frames" (str (length Raws))] ["kind" "TapeFooter"]
                                                              ["sha256" (fc.sha256-of Body)]] [])))))

(define fc.all-frames
  R Acc -> (reverse Acc) where (= (fc.available R) 0)
  R Acc -> (fc.all-frames R [(fc.next-frame R ["T" "H" "G"] ["H" "F" "I" "R" "D" "X" "Y" "S" "B" "E"] any 1048576) | Acc]))

\\ [HeaderJson Middle] of a tape's text, Middle the exchanged frames [Dir Type Seq Payload Raw].
(define fc.read-tape
  Text -> (let Fs (trap-error (fc.all-frames (fc.scripted Text) [])
                              (/. E (fc.fail "TapeIntegrity" (cn "Malformed-" (hd (tl (fc.classify E)))))))
               _ (if (and (>= (length Fs) 2) (= (hd (hd Fs)) "T") (= (nth 2 (hd Fs)) "H") (= (nth 3 (hd Fs)) 0))
                     true (fc.fail "TapeIntegrity" "Header"))
               Footer (fh.last Fs)
               _ (if (and (= (hd Footer) "T") (= (nth 2 Footer) "F")) true (fc.fail "TapeIntegrity" "Footer"))
               Middle (fc.but-last (tl Fs))
               FJ (fc.decode (nth 4 Footer))
               Body (fc.concat (map (/. F (nth 5 F)) (fc.but-last Fs)))
               _ (if (and (= (nth 3 Footer) (+ 1 (length Middle))) (= (fh.member "frames" FJ) (str (length Middle))))
                     true (fc.fail "TapeIntegrity" "Count"))
               _ (if (= (fh.member "sha256" FJ) (fc.sha256-of Body)) true (fc.fail "TapeIntegrity" "Digest"))
            [(fc.decode (nth 4 (hd Fs))) Middle]))

(define fc.but-last
  [_] -> []
  [X | Xs] -> [X | (fc.but-last Xs)])

(define fc.response-type
  "I" -> "Y" "R" -> "S" "D" -> "D" "X" -> "B")

\\ Exchange structure: Hello at seq 0; then pairs (request seq k, response seq k), Init
\\ first and only once, each response of its request's type or Error, Terminate last; and
\\ after a Steps response that is not Running, only Digest or Terminate (a tape that
\\ claims the run ended and then runs it on contradicts itself).
(define fc.structure
  [[G H 0 _ _] | Pairs] -> (fc.pairs Pairs 1 true) where (and (= G "G") (= H "H"))
  _ -> (fc.fail "Structure" "Hello"))

(define fc.pairs
  [] _ _ -> (fc.fail "Structure" "NoTerminate")
  [[HD Q QS QP _] [GD A AS AP _] | Rest] K Running ->
    (cond ((not (and (= HD "H") (= GD "G"))) (fc.fail "Structure" "Direction"))
          ((not (and (= QS K) (= AS K))) (fc.fail "Structure" "Sequence"))
          ((not (= (= Q "I") (= K 1))) (fc.fail "Structure" "Init"))
          ((not (or (= A "E") (= A (fc.response-type Q)))) (fc.fail "Structure" "ResponseType"))
          ((and (= Q "R") (not Running)) (fc.fail "Structure" "AfterTerminal"))
          ((or (= Q "X") (= A "E")) (if (empty? Rest) true (fc.fail "Structure" "AfterEnd")))
          (true (fc.pairs Rest (+ K 1)
                          (if (= A "S") (= (fh.member "execution" (fc.decode AP)) "Running") Running))))
  _ _ _ -> (fc.fail "Structure" "Unpaired"))

(define fc.compatible
  H Middle ->
    (let I (if (fc.decimal? (fh.member "program" H)) (fc.number (fh.member "program" H)) -1)
      (cond ((not (= (fh.member "tape" H) (value fc.*tape-schema*))) (fc.fail "Incompatible" "TapeSchema"))
            ((not (= (fh.member "protocol" H) (value fc.*protocol*))) (fc.fail "Incompatible" "Protocol"))
            ((not (= (fh.member "machine_profile" H) (value fc.*profile*))) (fc.fail "Incompatible" "Profile"))
            ((not (and (= (fh.member "batch_sha256" H) (fc.b "batch_sha256")) (= (fh.member "control_sha256" H) (fc.b "control_sha256"))
                       (= (fh.member "tender_sha256" H) (fc.b "tender_sha256"))))
              (fc.fail "Incompatible" "Image"))
            ((not (and (>= I 0) (< I (value fc.*count*)) (= (fh.member "artifact_sha256" H) (fc.identity I "artifact_sha256"))
                       (= (fh.member "schema" H) (fc.identity I "schema"))))
              (fc.fail "Incompatible" "Artifact"))
            ((not (= (nth 4 (nth 2 Middle)) (fc.init-payload I (fh.member "mode" H)))) (fc.fail "Incompatible" "Init"))
            (true I))))

(define fc.decimal?
  "" -> false
  S -> (fc.every? (/. C (fc.digit? (string->n C))) (explode S)))

(define fc.every?
  _ [] -> true
  F [X | Xs] -> (and (F X) (fc.every? F Xs)))

\\ Strict replay: the recorded requests, byte for byte, to a cold boot; every guest frame
\\ must equal the recorded one byte for byte, and the guest must end as recorded.
(define fc.replay-text
  Text -> (let T (fc.read-tape Text)
               H (hd T)
               Middle (hd (tl T))
               _ (fc.structure Middle)
               _ (fc.compatible H Middle)
            (trap-error (fc.replay-live Middle)
              (/. E (let C (fc.classify E)
                      (if (= (hd C) "Diverged") (simple-error (error-to-string E))
                          (fc.fail "Diverged" (cn (hd C) (cn "-" (hd (tl C)))))))))))

(define fc.replay-live
  [Hello | Pairs] ->
    (fc.with (fc.boot (value fc.*control*) (cn (value fc.*out*) "console-replay.txt"))
      (/. S (let G (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] 0 (value fc.*guest-max*))
                 _ (if (= (nth 5 G) (nth 5 Hello)) true (fc.fail "Diverged" "frame 0"))
              (fc.replay-pairs S Pairs 1)))))

(define fc.replay-pairs
  S [] K -> "Exact"
  S [Q A | Rest] K ->
    (let _ (fc.write S (nth 5 Q))
         G (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] (nth 3 Q) (value fc.*guest-max*))
         _ (if (= (nth 5 G) (nth 5 A)) true (fc.fail "Diverged" (make-string "frame ~A" (+ K 1))))
      (if (empty? Rest)
          (let _ (fc.drain (<-address S 1))
               St (fc.exit-status S)
            (if (= St (if (= (nth 2 A) "B") 0 3)) "Exact" (fc.fail "Diverged" (make-string "exit ~A" St))))
          (fc.replay-pairs S Rest (+ K 2)))))

\\ "Exact", or the rejection as "Class:Detail".
(define fc.replay-result
  Text -> (trap-error (fc.replay-text Text) (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

\\ ---------- tape edits for the negative tests ----------

\\ Frames as [Dir Type Seq Payload], re-encoded after an edit.
(define fc.split-tape
  Text -> (let T (fc.read-tape Text) [(json.stringify (hd T) []) (map (/. F [(nth 1 F) (nth 2 F) (nth 3 F) (nth 4 F)]) (hd (tl T)))]))

(define fc.raw F -> (fc.frame (nth 1 F) (nth 2 F) (nth 3 F) (nth 4 F)))
(define fc.reseal Header Fs -> (fc.seal Header (map (/. F (fc.raw F)) Fs)))

\\ Renumber the exchange: Hello 0, then pairs 1, 2, ...
(define fc.renumber
  [Hello | Pairs] -> [Hello | (fc.renumber-pairs Pairs 1)])
(define fc.renumber-pairs
  [] _ -> []
  [[D1 T1 _ P1] [D2 T2 _ P2] | Rest] K -> [[D1 T1 K P1] [D2 T2 K P2] | (fc.renumber-pairs Rest (+ K 1))])

(define fc.remove-at
  0 [_ | Xs] -> Xs
  N [X | Xs] -> [X | (fc.remove-at (- N 1) Xs)])
(define fc.insert-at
  0 Y Xs -> [Y | Xs]
  N Y [X | Xs] -> [X | (fc.insert-at (- N 1) Y Xs)])
(define fc.replace-at
  0 Y [_ | Xs] -> [Y | Xs]
  N Y [X | Xs] -> [X | (fc.replace-at (- N 1) Y Xs)])

(define fc.set-member
  K V [object | Ms] -> [object | (map (/. M (if (= (hd M) K) [K V] M)) Ms)])

(define fc.set-payload
  K V [D T S P] -> [D T S (json.stringify (fc.set-member K V (fc.decode P)) [])])

\\ Flip the first character of a string field's value (a hex digit: 0 <-> 1, else 0).
(define fc.flip
  (@s "0" Cs) -> (cn "1" Cs)
  (@s _ Cs) -> (cn "0" Cs))

(define fc.text-of Header Fs -> (fc.reseal Header Fs))

\\ Every negative tape test: [Name ExpectedRejection Text]. Base is a recorded tape of a
\\ run with at least three Run exchanges; its frames are Hello, Init, Ready, Run, Steps...
(define fc.tape-negatives
  Base -> (let T (fc.split-tape Base)
               H (hd T)
               Fs (hd (tl T))
               HJ (fc.decode H)
               Edit (/. K V (json.stringify (fc.set-member K V HJ) []))
               \\ positions: 0 Hello, 1 Init, 2 Ready, 3 Run, 4 Steps, 5 Run, 6 Steps, 7 Run, 8 Steps
               Without (fc.remove-at 5 (fc.remove-at 5 Fs))
               Extra (fc.insert-at 5 (fc.at 5 Fs) (fc.insert-at 5 (fc.at 6 Fs) Fs))
               Swapped (fc.replace-at 3 (fc.at 5 Fs) (fc.replace-at 4 (fc.at 6 Fs) (fc.replace-at 5 (fc.at 3 Fs) (fc.replace-at 6 (fc.at 4 Fs) Fs))))
               Steps (fc.at 4 Fs)
               Edited (fc.replace-at 4 (fc.set-payload "digest" (fc.flip (fh.member "digest" (fc.decode (fc.at 3 Steps)))) Steps) Fs)
               Early (fc.replace-at 4 (fc.set-payload "execution" "Completed" Steps) Fs)
               Bye (fh.last Fs)
               EarlyBye (fc.set-payload "epoch" "1" (fc.set-payload "execution" "Completed" ["G" "B" 3 (fc.at 3 Bye)]))
               EarlyEnd (append (fc.take-n 5 Early) [["H" "X" 3 "{c#34;kindc#34;:c#34;Terminatec#34;}"] EarlyBye])
               Sealed (fc.text-of H Edited)
               Other (fc.identity (if (= (fh.member "program" HJ) "0") 1 0) "artifact_sha256")
            [["wrong-artifact-hash" "Incompatible:Artifact" (fc.text-of (Edit "artifact_sha256" Other) Fs)]
             ["wrong-protocol-version" "Incompatible:Protocol" (fc.text-of (Edit "protocol" "fenrir.solo5.pure-call-control/2") Fs)]
             ["wrong-machine-profile" "Incompatible:Profile" (fc.text-of (Edit "machine_profile" "fenrir.solo5.pure-call-machine/2") Fs)]
             ["wrong-guest-image" "Incompatible:Image" (fc.text-of (Edit "control_sha256" (fc.flip (fh.member "control_sha256" HJ))) Fs)]
             ["missing-record" "Structure:Sequence" (fc.text-of H Without)]
             ["missing-record-renumbered" "Diverged:frame 6" (fc.text-of H (fc.renumber Without))]
             ["extra-record" "Structure:Sequence" (fc.text-of H Extra)]
             ["extra-record-renumbered" "Diverged:frame 8" (fc.text-of H (fc.renumber Extra))]
             ["reordered-records" "Structure:Sequence" (fc.text-of H Swapped)]
             ["reordered-records-renumbered" "Diverged:frame 4" (fc.text-of H (fc.renumber Swapped))]
             ["edited-response" "Diverged:frame 4" Sealed]
             ["edited-response-unsealed" "TapeIntegrity:Digest" (fc.unsealed Base Edited H)]
             ["early-terminal-then-run" "Structure:AfterTerminal" (fc.text-of H Early)]
             ["early-terminal-consistent" "Diverged:frame 4" (fc.text-of H EarlyEnd)]
             ["truncated-tape" "TapeIntegrity:Malformed-Truncated" (fc.take-string-n (- (fc.length Base) 40) Base)]
             ["footer-missing" "TapeIntegrity:Footer" (fc.without-footer Base)]]))

(define fc.at N L -> (nth (+ N 1) L))

(define fc.take-n
  0 _ -> []
  N [X | Xs] -> [X | (fc.take-n (- N 1) Xs)])

(define fc.take-string-n
  N S -> (buffer.string (buffer.slice (buffer.from-string S) 0 N)))

\\ The edited frames under the ORIGINAL footer: the digest no longer matches.
(define fc.unsealed
  Base Fs Header -> (let Original (fc.read-tape-raw Base)
                      (cn (fc.frame "T" "H" 0 Header) (cn (fc.concat (map (/. F (fc.raw F)) Fs)) (fh.last Original)))))

(define fc.read-tape-raw
  Text -> (map (/. F (nth 5 F)) (fc.all-frames (fc.scripted Text) [])))

(define fc.without-footer
  Text -> (fc.concat (fc.but-last (fc.read-tape-raw Text))))

\\ ---------- hostile host: scripted bad requests against the real guest ----------

\\ After Prelude (0: Hello only; 1: Init and Ready; 2: also one Run; done: run to
\\ completion), send Bytes as they are, close the request pipe when Close, and require one
\\ Error frame with Code at sequence Seq, then the end of output and exit status 3.
\\ The observed outcome, as "Code@Seq exit N" or "Class:Detail".
(define fc.prelude
  S I 0 -> true
  S I 1 -> (let _ (fc.send S "I" (fc.init-payload I "normal")) (fc.check-ready (fc.expect S "Y") I "normal"))
  S I 2 -> (let _ (fc.prelude S I 1) _ (fc.send S "R" (fc.run-payload 1)) (fc.records (fc.expect S "S") 1 0))
  S I done -> (let _ (fc.prelude S I 1) (fc.run-out S 0)))

(define fc.run-out
  S Epoch -> (let _ (fc.send S "R" (fc.run-payload 64))
                  J (fc.expect S "S")
                  R (fc.records J 64 Epoch)
               (if (= (fh.member "execution" J) "Running") (fc.run-out S (+ Epoch (length R))) J)))

(define fc.bad-host
  I Prelude Bytes Close ->
    (trap-error
      (fc.with (fc.boot (value fc.*control*) (cn (value fc.*out*) "console-hostile-host.txt"))
        (/. S (let _ (fc.check-hello (fc.expect S "H"))
                   _ (fc.prelude S I Prelude)
                   Seq (<-address S 2)
                   _ (fc.write S Bytes)
                   _ (if Close (io.close (process.stdin (<-address S 0))) true)
                   F (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                   J (fc.decode (nth 4 F))
                   _ (fc.drain (<-address S 1))
                   St (fc.exit-status S)
                (make-string "~A@~A exit ~A" (if (= (nth 2 F) "E") (fh.member "code" J) (cn "frame " (nth 2 F)))
                             (nth 3 F) St))))
      (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

\\ [Name Expected Prelude Bytes Close]
(define fc.host-cases
  I Other -> (let Run (/. Seq N (fc.frame "H" "R" Seq (fc.run-payload N)))
                  Init (/. Seq P (fc.frame "H" "I" Seq P))
                  Good (fc.init-payload I "normal")
                  Batch (fc.b "batch_sha256")
                  Fuel (str (value fc.*fuel*))
                  Schema (fc.identity I "schema")
                  RunText (fc.run-payload 1)
               [["bad-magic" "BadMagic@1 exit 3" 0 "FGX1 HI 00000001 00000002c#10;{}c#10;" false]
                ["bad-direction" "BadDirection@2 exit 3" 1 (fc.frame "G" "R" 2 RunText) false]
                ["unknown-type" "UnknownType@2 exit 3" 1 (fc.frame "H" "Q" 2 RunText) false]
                ["bad-header" "BadHeader@2 exit 3" 1 "FGC1 HR 0000000x 00000002c#10;{}c#10;" false]
                ["out-of-order-sequence" "BadSequence@2 exit 3" 1 (Run 4 1) false]
                ["duplicate-sequence" "BadSequence@3 exit 3" 2 (Run 2 1) false]
                ["oversize" "Oversize@2 exit 3" 1 "FGC1 HR 00000002 00000513c#10;" false]
                ["truncated-header" "Truncated@2 exit 3" 1 "FGC1 HR 0000" true]
                ["truncated-payload" "Truncated@2 exit 3" 1 (fc.take-string-n 36 (Run 2 1)) true]
                ["bad-trailer" "BadTrailer@2 exit 3" 1 (cn (fc.take-string-n (- (fc.length (Run 2 1)) 1) (Run 2 1)) "X") false]
                ["control-byte-in-payload" "BadPayload@2 exit 3" 1 (fc.frame "H" "R" 2 "{c#34;kindc#34;:c#34;Runc#34;,c#9;c#34;stepsc#34;:c#34;1c#34;}") false]
                ["non-canonical-number" "BadPayload@2 exit 3" 1 (fc.frame "H" "R" 2 "{c#34;kindc#34;:c#34;Runc#34;,c#34;stepsc#34;:c#34;01c#34;}") false]
                ["reordered-keys" "BadPayload@2 exit 3" 1 (fc.frame "H" "R" 2 "{c#34;stepsc#34;:c#34;1c#34;,c#34;kindc#34;:c#34;Runc#34;}") false]
                ["kind-type-mismatch" "BadPayload@2 exit 3" 1 (fc.frame "H" "R" 2 (value fc.*digest-payload*)) false]
                ["budget-zero" "BadBudget@2 exit 3" 1 (Run 2 0) false]
                ["budget-over-limit" "BadBudget@2 exit 3" 1 (Run 2 65) false]
                ["run-before-init" "BadState@1 exit 3" 0 (Run 1 1) false]
                ["second-init" "BadState@2 exit 3" 1 (Init 2 Good) false]
                ["wrong-artifact" "Identity@1 exit 3" 0 (Init 1 (fc.init-fields Other Batch Fuel "normal" (str I) (value fc.*protocol*) Schema)) false]
                ["wrong-protocol" "Identity@1 exit 3" 0 (Init 1 (fc.init-fields (fc.identity I "artifact_sha256") Batch Fuel "normal" (str I) "fenrir.solo5.pure-call-control/2" Schema)) false]
                ["wrong-batch" "Identity@1 exit 3" 0 (Init 1 (fc.init-fields (fc.identity I "artifact_sha256") (fc.flip Batch) Fuel "normal" (str I) (value fc.*protocol*) Schema)) false]
                ["unknown-mode" "Identity@1 exit 3" 0 (Init 1 (fc.init-fields (fc.identity I "artifact_sha256") Batch Fuel "fast" (str I) (value fc.*protocol*) Schema)) false]
                ["run-after-completion" "NotRunning" done "" false]
                ["garbage-after-terminate" "TrailingInput@2 exit 3" 1 (cn (fc.frame "H" "X" 2 "{c#34;kindc#34;:c#34;Terminatec#34;}") "junk") false]
                ["hangup" "Hangup@2 exit 3" 1 "" true]]))

\\ run-after-completion needs the sequence number the completed run reached.
(define fc.host-case
  I [Name "NotRunning" done _ _] ->
    (let Seen (fc.bad-host-done I)
      [Name (cn "NotRunning@" (cn (hd Seen) " exit 3")) (hd (tl Seen))])
  I [Name Expected Prelude Bytes Close] -> [Name Expected (fc.bad-host I Prelude Bytes Close)])

(define fc.bad-host-done
  I -> (trap-error
         (fc.with (fc.boot (value fc.*control*) (cn (value fc.*out*) "console-hostile-host.txt"))
           (/. S (let _ (fc.check-hello (fc.expect S "H"))
                      _ (fc.prelude S I done)
                      Seq (<-address S 2)
                      _ (fc.write S (fc.frame "H" "R" Seq (fc.run-payload 1)))
                      F (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                      _ (fc.drain (<-address S 1))
                      St (fc.exit-status S)
                   [(str Seq) (make-string "~A@~A exit ~A" (fh.member "code" (fc.decode (nth 4 F))) (nth 3 F) St)])))
         (/. E ["?" (cn "failed: " (error-to-string E))])))

\\ ---------- hostile guest: scripted bad output against this host's parser ----------

\\ The dialogue the host holds with any guest: Hello, Init/Ready, one Run of 1, Terminate/Bye,
\\ end of output. The same functions as the live runs, over a scripted byte source.
(define fc.dialogue
  S I -> (let _ (fc.check-hello (fc.expect S "H"))
              _ (fc.send S "I" (fc.init-payload I "normal"))
              _ (fc.check-ready (fc.expect S "Y") I "normal")
              _ (fc.send S "R" (fc.run-payload 1))
              _ (fc.records (fc.expect S "S") 1 0)
              _ (fc.send S "X" "{c#34;kindc#34;:c#34;Terminatec#34;}")
              _ (fc.expect S "B")
              _ (fc.drain (<-address S 1))
           "accepted"))

(define fc.scripted-result
  I Bytes -> (trap-error (fc.dialogue (fc.session [] (fc.scripted Bytes) "") I)
                         (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

\\ The guest frames [Hello Ready Steps Bye] of a real dialogue with program I.
(define fc.good-output
  I -> (let S (fc.open I "normal" (cn (value fc.*out*) "console-hostile-guest.txt"))
         (fc.with S (/. S (let _ (fc.send S "R" (fc.run-payload 1))
                               _ (fc.expect S "S")
                               _ (fc.terminate S)
                               Log (reverse (<-address S 3))
                            [(fc.at 0 Log) (fc.at 2 Log) (fc.at 4 Log) (fc.at 6 Log)])))))

(define fc.parsed
  Raw -> (let F (fc.next-frame (fc.scripted Raw) ["G"] ["H" "Y" "S" "D" "B" "E"] any 1048576)
           [(nth 1 F) (nth 2 F) (nth 3 F) (nth 4 F)]))

(define fc.char-at
  N C S -> (let V (buffer.from-string S)
                L (buffer.length V)
             (cn (buffer.string (buffer.slice V 0 N)) (cn C (buffer.string (buffer.slice V (+ N 1) (- L (+ N 1))))))))

\\ [Name Expected Bytes]
(define fc.guest-cases
  I -> (let G (fc.good-output I)
            Hello (fc.at 0 G) Ready (fc.at 1 G) Steps (fc.at 2 G) Bye (fc.at 3 G)
            Out (/. Rs (fc.concat Rs))
            RF (fc.parsed Ready) SF (fc.parsed Steps)
            SJ (fc.decode (fc.at 3 SF))
            Record (hd (fh.member "steps" SJ))
            Two (fc.raw [(hd SF) "S" 2 (json.stringify (fc.set-member "epoch" "2" (fc.set-member "steps" [Record Record] SJ)) [])])
            Gap (fc.raw [(hd SF) "S" 2 (json.stringify (fc.set-member "steps" [(fc.set-member "epoch" "5" Record)] SJ) [])])
         [["bad-magic" "Protocol:BadMagic" (Out [Hello (fc.char-at 0 "X" Ready) Steps Bye])]
          ["wrong-direction" "Protocol:BadDirection" (Out [Hello (fc.char-at 5 "H" Ready) Steps Bye])]
          ["unknown-type" "Protocol:UnknownType" (Out [Hello (fc.char-at 6 "Q" Ready) Steps Bye])]
          ["bad-header" "Protocol:BadHeader" (Out [Hello (fc.char-at 17 "x" Ready) Steps Bye])]
          ["truncated-header" "Protocol:Truncated" (Out [Hello (fc.take-string-n 10 Ready)])]
          ["truncated-payload" "Protocol:Truncated" (Out [Hello (fc.take-string-n 60 Ready)])]
          ["duplicate-sequence" "Protocol:BadSequence" (Out [Hello Ready (fc.raw [(hd SF) "S" 1 (fc.at 3 SF)]) Bye])]
          ["out-of-order-sequence" "Protocol:BadSequence" (Out [Hello Ready (fc.raw [(hd SF) "S" 3 (fc.at 3 SF)]) Bye])]
          ["oversize" "Protocol:Oversize" (Out [Hello (cn "FGC1 GY 00000001 00061441c#10;" (fc.at 3 RF)) Steps Bye])]
          ["bad-trailer" "Protocol:BadTrailer" (Out [Hello (fc.char-at (- (fc.length Ready) 1) "X" Ready) Steps Bye])]
          ["control-byte-in-payload" "Protocol:BadPayload" (Out [Hello (fc.char-at 27 "c#9;" Ready) Steps Bye])]
          ["not-json" "Protocol:BadPayload" (Out [Hello (fc.raw ["G" "Y" 1 "{not json"]) Steps Bye])]
          ["kind-type-mismatch" "Protocol:BadPayload" (Out [Hello (fc.raw (fc.set-payload "kind" "Digest" RF)) Steps Bye])]
          ["wrong-response-type" "Protocol:UnexpectedType" (Out [Hello Ready (fc.raw ["G" "D" 2 (json.stringify (fc.set-member "kind" "Digest" [object ["digest" (fh.member "digest" SJ)] ["epoch" "1"] ["execution" "Running"] ["kind" "Digest"]]) [])]) Bye])]
          ["more-steps-than-requested" "Protocol:BadSteps" (Out [Hello Ready Two Bye])]
          ["epoch-discontinuity" "Protocol:BadSteps" (Out [Hello Ready Gap Bye])]
          ["hello-wrong-protocol" "Protocol:Identity" (Out [(fc.raw (fc.set-payload "protocol" "fenrir.solo5.pure-call-control/2" (fc.parsed Hello))) Ready Steps Bye])]
          ["ready-wrong-artifact" "Protocol:Identity" (Out [Hello (fc.raw (fc.set-payload "artifact_sha256" (fc.flip (fc.identity I "artifact_sha256")) RF)) Steps Bye])]
          ["guest-error-frame" "GuestError:Identity" (Out [Hello (fc.raw ["G" "E" 1 "{c#34;codec#34;:c#34;Identityc#34;,c#34;kindc#34;:c#34;Errorc#34;}"]) Steps Bye])]
          ["garbage-after-bye" "Protocol:TrailingOutput" (Out [Hello Ready Steps Bye "junk"])]
          ["unmodified-control" "accepted" (Out [Hello Ready Steps Bye])]]))

\\ Live: a peer that never answers, one that dies mid-frame, and the real guest when the
\\ host sends nothing. Each must be a HarnessTimeout or a protocol failure, never a pass.
(define fc.live-result
  Program Args -> (trap-error
                    (fc.with (fc.spawn Program Args (cn (value fc.*out*) "console-live.txt"))
                      (/. S (let _ (fc.expect S "H") "accepted")))
                    (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

(define fc.silent-guest-result
  -> (trap-error
       (fc.with (fc.boot (value fc.*control*) (cn (value fc.*out*) "console-live.txt"))
         (/. S (let _ (fc.expect S "H")
                    \\ No request: the guest must stay silent, and silence is not a pass.
                    _ (fc.expect S "Y")
                 "accepted")))
       (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

\\ ---------- stop mid-program; no advance without a request ----------

\\ true when nothing arrives on the response channel for Ms milliseconds.
(define fc.quiet?
  S Ms -> (let R (<-address S 1)
            (and (= (fc.available R) 0) (= (fc.read-more R Ms true) timeout))))

(define fc.send-split
  S Type Payload At -> (let Raw (fc.frame "H" Type (<-address S 2) Payload)
                            _ (fc.write S (fc.take-string-n At Raw))
                            Quiet (fc.quiet? S (value fc.*quiet*))
                            V (buffer.from-string Raw)
                            _ (fc.write S (buffer.string (buffer.slice V At (- (buffer.length V) At))))
                            _ (fc.log S Raw)
                            _ (address-> S 2 (+ 1 (<-address S 2)))
                         Quiet))

\\ Two copies of a request in one write; the two decoded responses.
(define fc.send-coalesced
  S Payload -> (let K (<-address S 2)
                    A (fc.frame "H" "D" K Payload)
                    B (fc.frame "H" "D" (+ K 1) Payload)
                    _ (fc.write S (cn A B))
                    _ (fc.log S A)
                    _ (address-> S 2 (+ K 1))
                    RA (fc.expect S "D")
                    _ (fc.log S B)
                    _ (address-> S 2 (+ K 2))
                    RB (fc.expect S "D")
                 [RA RB]))

(define fc.no-advance
  I -> (let S (fc.boot (value fc.*control*) (cn (value fc.*out*) "console-no-advance.txt"))
         (fc.with S
           (/. S (let _ (fc.check-hello (fc.expect S "H"))
                      Q0 (fc.quiet? S (value fc.*quiet*))
                      _ (fc.send S "I" (fc.init-payload I "normal"))
                      _ (fc.check-ready (fc.expect S "Y") I "normal")
                      M0 (fh.state (fc.artifact I))
                      _ (fc.send S "R" (fc.run-payload 2))
                      C1 (fc.compare (fc.records (fc.expect S "S") 2 0) M0 0)
                      _ (fc.send S "D" (value fc.*digest-payload*))
                      D1 (fc.expect S "D")
                      Q1 (fc.quiet? S (value fc.*quiet*))
                      _ (fc.send S "D" (value fc.*digest-payload*))
                      D2 (fc.expect S "D")
                      \\ A request split across two writes: nothing until it is complete.
                      Q2 (fc.send-split S "D" (value fc.*digest-payload*) 10)
                      D3 (fc.expect S "D")
                      \\ Two requests in one write: two responses, in order.
                      D45 (fc.send-coalesced S (value fc.*digest-payload*))
                      _ (fc.send S "R" (fc.run-payload 1))
                      C2 (fc.compare (fc.records (fc.expect S "S") 1 2) (nth 2 C1) 2)
                      Bye (fc.terminate S)
                   [object ["program" (str I)]
                           ["quiet_ms" (str (value fc.*quiet*))]
                           ["silent_after_hello" (if Q0 "yes" "no")]
                           ["silent_after_run_2" (if Q1 "yes" "no")]
                           ["digest_before_wait" (fh.member "digest" D1)] ["digest_after_wait" (fh.member "digest" D2)]
                           ["epoch_before_wait" (fh.member "epoch" D1)] ["epoch_after_wait" (fh.member "epoch" D2)]
                           ["silent_on_partial_request" (if Q2 "yes" "no")]
                           ["split_request_answered" (if (= D3 D2) "yes" "no")]
                           ["coalesced_requests_answered" (if (= D45 [D2 D2]) "yes" "no")]
                           ["steps_agree" (if (and (= (hd C1) agree) (= (hd C2) agree)) "yes" "no")]
                           ["bye_epoch" (fh.member "epoch" Bye)] ["bye_execution" (fh.member "execution" Bye)]
                           ["model_execution_at_stop" (fc.model-execution (nth 2 C2) 3)]])))))

(define fc.no-advance-pass?
  J -> (and (= (fh.member "silent_after_hello" J) "yes") (= (fh.member "silent_after_run_2" J) "yes")
            (= (fh.member "digest_before_wait" J) (fh.member "digest_after_wait" J))
            (= (fh.member "epoch_before_wait" J) "2") (= (fh.member "epoch_after_wait" J) "2")
            (= (fh.member "steps_agree" J) "yes") (= (fh.member "bye_epoch" J) "3")
            (= (fh.member "silent_on_partial_request" J) "yes") (= (fh.member "split_request_answered" J) "yes")
            (= (fh.member "coalesced_requests_answered" J) "yes")
            (= (fh.member "bye_execution" J) "Running") (= (fh.member "model_execution_at_stop" J) "Running")))

\\ ---------- the specification's byte vectors ----------

\\ spec/solo5/pure-call-control-v1.vectors: host vectors this encoder must produce
\\ exactly, guest vectors this parser must accept and re-encode unchanged, and reject
\\ vectors it must refuse with the stated code.
(define fc.words
  "" W Acc -> (reverse (if (= W "") Acc [W | Acc]))
  (@s " " Cs) W Acc -> (fc.words Cs "" (if (= W "") Acc [W | Acc]))
  (@s C Cs) W Acc -> (fc.words Cs (cn W C) Acc))

(define fc.hex-digit
  C -> (let N (string->n C) (if (fc.digit? N) (- N 48) (- N 87))))

(define fc.unhex
  Hex -> (let Cs (explode Hex)
              V (buffer.new (/ (length Cs) 2))
           (buffer.string (fc.unhex-into V 0 Cs))))

(define fc.unhex-into
  V _ [] -> V
  V I [A B | Cs] -> (do (buffer.u8! V I (+ (* 16 (fc.hex-digit A)) (fc.hex-digit B))) (fc.unhex-into V (+ I 1) Cs)))

(define fc.chars
  0 _ -> ""
  N C -> (cn C (fc.chars (- N 1) C)))

(define fc.host-vector
  "init-seq-1" -> (fc.frame "H" "I" 1 (fc.init-fields (fc.chars 64 "a") (fc.chars 64 "b") "200" "normal" "0"
                                                      (value fc.*protocol*) "tc0-a-pure-call-demo/2"))
  "run-1-seq-2" -> (fc.frame "H" "R" 2 (fc.run-payload 1))
  "run-64-seq-9" -> (fc.frame "H" "R" 9 (fc.run-payload 64))
  "digest-seq-3" -> (fc.frame "H" "D" 3 (value fc.*digest-payload*))
  "terminate-seq-86" -> (fc.frame "H" "X" 86 "{c#34;kindc#34;:c#34;Terminatec#34;}")
  _ -> "")

(define fc.vector-row
  [Name "host" _ Hex] -> (fc.negative-row [Name "encoded-identically" (if (= (fc.host-vector Name) (fc.unhex Hex)) "encoded-identically" "different")])
  [Name "guest" _ Hex] -> (fc.negative-row [Name "accepted"
                                            (trap-error (let F (fc.next-frame (fc.scripted (fc.unhex Hex)) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                                                          (if (= (fc.raw [(nth 1 F) (nth 2 F) (nth 3 F) (nth 4 F)]) (fc.unhex Hex)) "accepted" "re-encoded differently"))
                                                        (/. E (hd (tl (fc.classify E)))))])
  [Name "reject" Code Hex] -> (fc.negative-row [Name Code
                                                (trap-error (do (fc.next-frame (fc.scripted (fc.unhex Hex)) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*)) "accepted")
                                                            (/. E (hd (tl (fc.classify E)))))])
  L -> (fc.negative-row [(make-string "~S" L) "a vector line" "malformed"]))

(define fc.vectors
  -> (map (/. L (fc.vector-row (fc.words L "" [])))
          (fc.filter (/. L (and (not (= L "")) (not (fh.starts? "#" L))))
                     (fh.lines (read-file-as-string (cn (value fh.*root*) "spec/solo5/pure-call-control-v1.vectors"))))))

\\ ---------- the check ----------

\\ Host-selected step schedules: the hand cases and TC1 fixtures one step per request;
\\ the exhaustive sample a cycle of Run sizes; the defect runs one step per request, so
\\ that the guest stops exactly at the first diverging step.
(define fc.schedule
  I "normal" -> [1 2 5 16 64] where (= (fc.family I) "exhaustive-5-sample")
  _ _ -> [1])

(define fc.run-all
  Mode -> (map (/. I (trap-error (fc.controlled I Mode (fc.schedule I Mode))
                                 (/. E [failed (fc.classify E) "?" [] []])))
               (value fc.*indices*)))

(define fc.first-diverged
  [I | Is] Rows -> (if (= (hd (nth (+ I 1) Rows)) diverged) I (fc.first-diverged Is Rows))
  [] _ -> (error "harness: no taped program diverged"))

(define fc.count-if
  F [] N -> N
  F [X | Xs] N -> (fc.count-if F Xs (if (F X) (+ N 1) N)))

(define fc.zip3
  [] [] [] -> []
  [A | As] [B | Bs] [C | Cs] -> [[A B C] | (fc.zip3 As Bs Cs)])

\\ Per program: [Index Controlled FreeRun Model] where Controlled is fc.controlled's result,
\\ FreeRun [Execution Steps] of guest.spt and Model [Execution Steps] of the model.
(define fc.mode-summary
  Mode Controlled Free Model ->
    (let Rows (fc.zip3 Controlled Free Model)
         Diverged (fc.count-if (/. R (= (hd (hd R)) diverged)) Rows 0)
         \\ The epoch where the controlled run stopped equals the first divergence of the
         \\ complete free-run trace from the complete model trace.
         Exact (fc.count-if (/. R (= (nth 2 (hd R)) (fc.first-divergence (nth 2 (nth 3 R)) (nth 2 (nth 2 R)) 0))) Rows 0)
         \\ Stopped exactly one step after the diverging one (one step per request).
         Stopped (fc.count-if (/. R (or (= (nth 2 (hd R)) none) (= (fc.number (nth 3 (hd R))) (+ 1 (fc.number (nth 2 (hd R))))))) Rows 0)
         \\ What the controlled guest reported is what the free-running guest did.
         Same (fc.count-if (/. R (fc.prefix? (nth 4 (hd R)) (nth 2 (nth 2 R)))) Rows 0)
         Steps (fc.count-if (/. X true) (fc.flatten (map (/. R (nth 4 (hd R))) Rows)) 0)
         Requests (fc.count-if (/. X true) (fc.flatten (map (/. R (nth 5 (hd R))) Rows)) 0)
         Failed (fc.count-if (/. R (= (hd (hd R)) failed)) Rows 0)
      [object ["mode" Mode] ["programs" (str (length Rows))] ["programs_failed" (str Failed)] ["steps_reported" (str Steps)] ["frames_exchanged" (str Requests)]
              ["programs_diverged" (str Diverged)]
              ["diverged_by_family" [object ["hand" (str (fc.diverged-in "hand" Controlled))]
                                            ["tc1-handlers" (str (fc.diverged-in "tc1-handlers" Controlled))]
                                            ["exhaustive-5-sample" (str (fc.diverged-in "exhaustive-5-sample" Controlled))]]]
              ["stop_epoch_equals_free_run_first_divergence" (str Exact)]
              ["stopped_one_step_after_divergence" (str Stopped)]
              ["records_equal_free_run_prefix" (str Same)]]))

(define fc.diverged-in
  Family Controlled -> (fc.count-if (/. P (and (= (fc.family (hd P)) Family) (= (hd (hd (tl P))) diverged)))
                                    (fc.pairs-of (value fc.*indices*) Controlled) 0))

\\ One row per taped program: what ran, how many steps and frames, and its replays.
(define fc.taped-rows
  [] _ _ -> []
  [I | Is] Normal [Rs | Rss] ->
    (let R (nth (+ I 1) Normal)
      [[object ["program" (str I)] ["family" (fc.family I)] ["name" (fc.identity I "name")] ["schema" (fc.identity I "schema")]
               ["steps_agreed" (str (length (nth 4 R)))] ["frames" (str (length (nth 5 R)))]
               ["outcome" (str (hd R))] ["replays" (str (length Rs))]
               ["replays_exact" (str (fc.count-if (/. X (= X "Exact")) Rs 0))]]
       | (fc.taped-rows Is Normal Rss)]))

(define fc.flatten
  [] -> []
  [X | Xs] -> (append X (fc.flatten Xs)))

(define fc.mode-pass?
  "normal" J -> (and (= (fh.member "programs_diverged" J) "0") (= (fh.member "programs_failed" J) "0") (fc.all-programs? J))
  _ J -> (and (not (= (fh.member "programs_diverged" J) "0")) (= (fh.member "programs_failed" J) "0") (fc.all-programs? J)))

(define fc.all-programs?
  J -> (let N (fh.member "programs" J)
         (and (= (fh.member "stop_epoch_equals_free_run_first_divergence" J) N)
              (= (fh.member "stopped_one_step_after_divergence" J) N)
              (= (fh.member "records_equal_free_run_prefix" J) N))))

(define fc.tape-of
  I Mode R -> (fc.seal (fc.tape-header I Mode) (nth 5 R)))

(define fc.repeat
  0 _ Acc -> Acc
  N F Acc -> (fc.repeat (- N 1) F [(thaw F) | Acc]))

(define fc.negative-row
  [Name Expected Observed] -> [object ["test" Name] ["expected" Expected] ["observed" Observed]
                                      ["result" (if (= Expected Observed) "as-expected" "UNEXPECTED")]])

(define fc.rows-pass?
  Rows -> (fc.every? (/. R (= (fh.member "result" R) "as-expected")) Rows))

(set fc.*replay-boots* 3)
(set fc.*long-replay-boots* 10)

(define fc.main
  -> (let Start (clock.monotonic)
          Count (value fc.*count*)
          Model (map (/. I (fh.run (fh.state (fc.artifact I)) (value fc.*fuel*) 0 [])) (value fc.*indices*))
          Normal (fc.run-all "normal")
          Reversed (fc.run-all "reverse-operands")
          Wrapped (fc.run-all "wrap-overflow")
          ControlMs (- (clock.monotonic) Start)
          ControlBoots (value fc.*boots*)
          Modes [(fc.mode-summary "normal" Normal (fc.free-run "normal" 0 Count) Model)
                 (fc.mode-summary "reverse-operands" Reversed (fc.free-run "reverse-operands" 0 Count) Model)
                 (fc.mode-summary "wrap-overflow" Wrapped (fc.free-run "wrap-overflow" 0 Count) Model)]
          ModesPass (and (fc.mode-pass? "normal" (fc.at 0 Modes)) (fc.mode-pass? "reverse-operands" (fc.at 1 Modes))
                         (fc.mode-pass? "wrap-overflow" (fc.at 2 Modes)))
          \\ Strict replay: tapes of every hand and TC1 run (one step per request).
          Taped (fc.filter (/. I (not (= (fc.family I) "exhaustive-5-sample"))) (value fc.*indices*))
          Tapes (map (/. I (fc.tape-of I "normal" (nth (+ I 1) Normal))) Taped)
          _ (fc.write-tapes Taped Tapes)
          ReplayStart (clock.monotonic)
          Replays (map (/. T (fc.repeat (value fc.*replay-boots*) (freeze (fc.replay-result T)) [])) Tapes)
          ReplayExact (fc.count-if (/. Rs (fc.every? (/. R (= R "Exact")) Rs)) Replays 0)
          Rerecorded (map (/. I (fc.tape-of I "normal" (fc.controlled I "normal" [1]))) Taped)
          Identical (fc.count-if (/. P (= (hd P) (hd (tl P)))) (fc.pairs-of Tapes Rerecorded) 0)
          Long (fc.long-base Taped Tapes)
          LongReplays (fc.repeat (value fc.*long-replay-boots*) (freeze (fc.replay-result Long)) [])
          StoppedIndex (fc.first-diverged Taped Reversed)
          Stopped (fc.tape-of StoppedIndex "reverse-operands" (nth (+ StoppedIndex 1) Reversed))
          StoppedReplays (fc.repeat (value fc.*replay-boots*) (freeze (fc.replay-result Stopped)) [])
          ReplayMs (- (clock.monotonic) ReplayStart)
          TapeRows (map (/. N (fc.negative-row [(fc.at 0 N) (fc.at 1 N) (fc.replay-result (fc.at 2 N))])) (fc.tape-negatives Long))
          HostRows (map (/. C (fc.negative-row (fc.host-case (fc.long-index Taped Tapes) C)))
                        (fc.host-cases (fc.long-index Taped Tapes) (fc.identity (if (= (fc.long-index Taped Tapes) 0) 1 0) "artifact_sha256")))
          GuestRows (map (/. C (fc.negative-row [(fc.at 0 C) (fc.at 1 C) (fc.scripted-result (fc.long-index Taped Tapes) (fc.at 2 C))]))
                         (fc.guest-cases (fc.long-index Taped Tapes)))
          _ (set fc.*frame-timeout* 1000)
          LiveRows (map (/. R (fc.negative-row R))
                        [["never-answers (sleep in place of the tender)" "HarnessTimeout:no complete guest frame within the deadline"
                          (fc.live-result "sleep" ["30"])]
                         ["dies-mid-frame (sh in place of the tender)" "Protocol:Truncated"
                          (fc.live-result "sh" ["-c" "printf 'FGC1 GH 0000' >&2"])]
                         ["real-guest-no-request-after-hello" "HarnessTimeout:no complete guest frame within the deadline"
                          (fc.silent-guest-result)]])
          _ (set fc.*frame-timeout* 10000)
          NoAdvance (fc.no-advance (fc.long-index Taped Tapes))
          VectorRows (fc.vectors)
          ReplayPass (and (= ReplayExact (length Tapes)) (= Identical (length Tapes))
                          (fc.every? (/. R (= R "Exact")) LongReplays) (fc.every? (/. R (= R "Exact")) StoppedReplays))
          Pass (and ModesPass ReplayPass (fc.rows-pass? TapeRows) (fc.rows-pass? HostRows) (fc.rows-pass? GuestRows)
                    (fc.rows-pass? LiveRows) (fc.rows-pass? VectorRows) (> (length VectorRows) 0) (fc.no-advance-pass? NoAdvance))
          Report [object ["schema" "fenrir.harness.solo5-control/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["protocol" (value fc.*protocol*)] ["machine_profile" (value fc.*profile*)]
                         ["transport" "stock solo5-spt; net devices ctlin=@0 (host->guest pipe) and ctlout=@2 (guest->host pipe); console separate"]
                         ["tender_sha256" (fc.b "tender_sha256")] ["control_sha256" (fc.b "control_sha256")]
                         ["guest_sha256" (fc.b "guest_sha256")] ["batch_sha256" (fc.b "batch_sha256")]
                         ["solo5" (fh.field "path" (fc.b "solo5_identity"))]
                         ["programs" (str Count)] ["families" (fc.b "families")] ["exhaustive_sample" (fc.b "sample")]
                         ["fuel" (str (value fc.*fuel*))]
                         ["controlled_runs" [object ["boots" (str ControlBoots)] ["milliseconds" (str ControlMs)]]]
                         ["modes" Modes]
                         ["replay" [object ["tapes" (str (length Tapes))] ["cold_boots_per_tape" (str (value fc.*replay-boots*))]
                                           ["tapes_exact_on_every_boot" (str ReplayExact)]
                                           ["independent_rerecordings_byte_identical" (str Identical)]
                                           ["long_tape_program" (str (fc.long-index Taped Tapes))]
                                           ["long_tape_cold_boots" (str (length LongReplays))]
                                           ["long_tape_exact" (str (fc.count-if (/. R (= R "Exact")) LongReplays 0))]
                                           ["stopped_mid_program_tape" (make-string "program ~A, reverse-operands" StoppedIndex)]
                                           ["stopped_mid_program_tape_exact" (str (fc.count-if (/. R (= R "Exact")) StoppedReplays 0))]
                                           ["milliseconds" (str ReplayMs)]]]
                         ["taped_programs" (fc.taped-rows Taped Normal Replays)]
                         ["tape_negatives" TapeRows]
                         ["hostile_host" HostRows]
                         ["hostile_guest" GuestRows]
                         ["live_nonresponding" LiveRows]
                         ["no_advance_and_stop" NoAdvance]
                         ["vectors" VectorRows]
                         ["total_boots" (str (value fc.*boots*))]
                         ["milliseconds" (str (- (clock.monotonic) Start))]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if Pass 0 1)))))

(define fc.filter
  _ [] -> []
  F [X | Xs] -> (if (F X) [X | (fc.filter F Xs)] (fc.filter F Xs)))

(define fc.pairs-of
  [] [] -> []
  [A | As] [B | Bs] -> [[A B] | (fc.pairs-of As Bs)])

(define fc.write-tapes
  [] [] -> true
  [I | Is] [T | Ts] -> (do (write-to-file (make-string "~Atape-~A.fgc" (value fc.*out*) I) T) (fc.write-tapes Is Ts)))

\\ The negative tests use the first taped program whose run has at least six steps.
(define fc.long-index
  [I | Is] [T | Ts] -> (if (>= (length (hd (tl (fc.read-tape T)))) 17) I (fc.long-index Is Ts))
  _ _ -> (error "harness: no taped program has six steps"))

(define fc.long-base
  [I | Is] [T | Ts] -> (if (>= (length (hd (tl (fc.read-tape T)))) 17) T (fc.long-base Is Ts))
  _ _ -> (error "harness: no taped program has six steps"))

\\ harness/solo5-durable.shen (protocol v2) loads this file for its definitions and sets
\\ fc.*as-library* first; run on its own, this is the v1 check.
(if (trap-error (value fc.*as-library*) (/. E false)) skip (fc.main))
