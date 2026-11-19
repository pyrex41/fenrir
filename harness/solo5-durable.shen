\\ Fenrir harness, in Shen: drive the host-controlled TC1-D1 Solo5 guest over protocol
\\ fenrir.solo5.pure-call-control/2 (spec/solo5/pure-call-control-v2.md). The host selects
\\ every step and answers every host request itself, with the replies the batch declares
\\ for the program; every guest record is compared with the Shen durable model as it
\\ goes, and the run stops at the first divergence. A reply the model calls a contract
\\ violation must be refused by the guest (BadReply) before the program sees it. Tapes
\\ record every frame, host replies included, and replay strictly against cold boots.
\\ Development evidence only; no qualification verdict.
\\
\\   shen-jit script harness/solo5-durable.shen LIBDIR ROOT BATCHDIR OUTDIR [quick]
\\ BATCHDIR as written by tools/solo5/control-durable-build.mjs. quick: controlled runs
\\ and one replay per tape only (for large service samples). The report is the last
\\ line of standard output.
\\
\\ The v1 host (harness/solo5-control.shen) is loaded for its frame, reader, session,
\\ tape and replay definitions; what v2 changes is redefined below.

(set fc.*as-library* true)
(load (cn (hd (tl (tl (value *argv*)))) "/harness/solo5-control.shen"))
(load (cn (value fh.*root*) "harness/tc1-durable-common.shen"))
(set dc.*quick* (element? "quick" (value *argv*)))

(set fc.*protocol* "fenrir.solo5.pure-call-control/2")
(set fc.*profile* "fenrir.solo5.pure-call-machine/2")
(set fc.*tape-schema* "fenrir.solo5.pure-call-control-tape/2")
(fc.check-batch-identity true)

\\ ---------- what v2 changes in the v1 definitions ----------

\\ Host requests now include Reply (A); guest responses are the v1 set.
(define fc.all-frames
  R Acc -> (reverse Acc) where (= (fc.available R) 0)
  R Acc -> (fc.all-frames R [(fc.next-frame R ["T" "H" "G"] ["H" "F" "I" "R" "A" "D" "X" "Y" "S" "B" "E"] any 1048576) | Acc]))

(define fc.response-type
  "I" -> "Y" "R" -> "S" "A" -> "S" "D" -> "D" "X" -> "B")

\\ A Steps response may end in HostWait.
(define fc.records
  J N Epoch -> (let Steps (fh.member "steps" J)
                    K (if (cons? Steps) (length Steps) 0)
                 (if (and (> K 0) (<= K N)
                          (fc.consecutive? Steps Epoch)
                          (= (fh.member "epoch" J) (str (+ Epoch K)))
                          (element? (fh.member "execution" J) ["Running" "Completed" "BudgetExhausted" "HostWait"]))
                     Steps
                     (fc.fail "Protocol" "BadSteps"))))

\\ Exchange structure (v2 section 8): as v1, and a Run only while Running, a Reply only
\\ while HostWait. State is the execution the last Steps response reported.
(define fc.pairs
  [] _ _ -> (fc.fail "Structure" "NoTerminate")
  [[HD Q QS QP _] [GD A AS AP _] | Rest] K State ->
    (cond ((not (and (= HD "H") (= GD "G"))) (fc.fail "Structure" "Direction"))
          ((not (and (= QS K) (= AS K))) (fc.fail "Structure" "Sequence"))
          ((not (= (= Q "I") (= K 1))) (fc.fail "Structure" "Init"))
          ((not (or (= A "E") (= A (fc.response-type Q)))) (fc.fail "Structure" "ResponseType"))
          ((and (= Q "R") (not (dc.running? State))) (fc.fail "Structure" "AfterTerminal"))
          ((and (= Q "A") (not (= State "HostWait"))) (fc.fail "Structure" "ReplyNotAwaited"))
          ((or (= Q "X") (= A "E")) (if (empty? Rest) true (fc.fail "Structure" "AfterEnd")))
          (true (fc.pairs Rest (+ K 1) (if (= A "S") (fh.member "execution" (fc.decode AP)) State))))
  _ _ _ -> (fc.fail "Structure" "Unpaired"))

(define dc.running?
  true -> true
  "Running" -> true
  _ -> false)

\\ ---------- the model, one step at a time ----------

(define dc.reply I -> (fc.identity I "replies"))
(define dc.input I -> (fc.identity I "input"))

\\ The model's execution in the guest's words.
(define dc.execution
  State Epoch -> "Completed" where (= (dm.phase State) terminal)
  State Epoch -> "HostWait" where (= (dm.phase State) host-wait)
  State Epoch -> "BudgetExhausted" where (>= Epoch (value fc.*fuel*))
  _ _ -> "Running")

\\ [Record Next] of the model's next step.
(define dc.model-record
  State Epoch -> (let T (dm.step State) [(dh.record Epoch [(dm.site State) (hd (tl T)) (hd (tl (tl T)))]) (hd (tl T))]))

(define dc.compare
  [] State Epoch -> [agree State Epoch]
  [R | Rs] State Epoch -> (let M (dc.model-record State Epoch)
                            (if (= R (hd M)) (dc.compare Rs (hd (tl M)) (+ Epoch 1)) [diverge Epoch])))

(define dc.reply-payload
  Seq V -> (cn "{" (cn (fc.kv "kind" "Reply") (cn "," (cn (fc.kv "request" (str Seq)) (cn ",c#34;valuec#34;:" (cn (json.stringify V []) "}")))))))

\\ ---------- one controlled run ----------

\\ [Outcome DivergenceEpoch GuestEpoch Records Frames Execution]: Outcome agreed or
\\ diverged; Execution the model's (Completed, BudgetExhausted, AwaitingHost or
\\ HostViolation, the last agreed only when the guest refused the reply with BadReply).
(define dc.controlled
  I Mode -> (let S (fc.open I Mode (make-string "~Aconsole-~A-~A.txt" (value fc.*out*) Mode I))
              (fc.with S (/. S (dc.drive S I (dh.state (fc.artifact I) (dc.input I)) 0 (dc.reply I) [])))))

(define dc.drive
  S I State Epoch Replies Acc ->
    (let X (dc.execution State Epoch)
      (cond ((= X "HostWait") (dc.answer S I State Epoch Replies Acc))
            ((not (= X "Running")) (dc.finish S agreed none Acc X))
            (true
              (let _ (fc.send S "R" (fc.run-payload 1))
                   J (fc.expect S "S")
                   Records (fc.records J 1 Epoch)
                   C (dc.compare Records State Epoch)
                   Seen (append Acc Records)
                (cond ((= (hd C) diverge) (dc.finish S diverged (str (nth 2 C)) Seen X))
                      ((not (= (fh.member "execution" J) (dc.execution (nth 2 C) (nth 3 C)))) (dc.finish S diverged (str (nth 3 C)) Seen X))
                      (true (dc.drive S I (nth 2 C) (nth 3 C) Replies Seen))))))))

(define dc.answer
  S _ _ _ [] Acc -> (dc.finish S agreed none Acc "AwaitingHost")
  S I State Epoch [V | Vs] Acc ->
    (let R (dm.reply State (dh.value V))
         _ (fc.send S "A" (dc.reply-payload (dm.seq-of-wait State) V))
      (if (= (hd R) violation)
          (dc.refused S Acc Epoch)
          (let J (fc.expect S "S")
               Records (fc.records J 1 Epoch)
               Expected (dh.record Epoch [(dm.site State) (hd (tl R)) (hd (tl (tl R)))])
               Seen (append Acc Records)
            (cond ((not (= Records [Expected])) (dc.finish S diverged (str Epoch) Seen "HostWait"))
                  ((not (= (fh.member "execution" J) (dc.execution (hd (tl R)) (+ Epoch 1)))) (dc.finish S diverged (str (+ Epoch 1)) Seen "HostWait"))
                  (true (dc.drive S I (hd (tl R)) (+ Epoch 1) Vs Seen)))))))

(define dm.seq-of-wait
  [dm-state [tc1-state [host-wait _ _ _ _ Seq] | _] _ _] -> Seq)

\\ The model calls the reply a violation: the guest must answer Error BadReply and exit 3.
(define dc.refused
  S Acc Epoch -> (trap-error (let _ (fc.expect S "S") (dc.finish S diverged (str Epoch) Acc "HostViolation"))
                             (/. E (let C (fc.classify E)
                                     (if (= C ["GuestError" "BadReply"])
                                         (let _ (fc.drain (<-address S 1))
                                              St (fc.exit-status S)
                                           [(if (= St 3) agreed diverged) none (str Epoch) Acc (reverse (<-address S 3)) "HostViolation"])
                                         (simple-error (error-to-string E)))))))

(define dc.finish
  S Outcome At Acc X -> (let Bye (fc.terminate S)
                          [Outcome At (fh.member "epoch" Bye) Acc (reverse (<-address S 3)) X]))

\\ ---------- hostile host: bad replies against the real guest ----------

\\ Boot program I (which must reach a host request), run to its first HostWait, then
\\ send Bytes; the guest must answer one Error frame and exit 3: "Code@Seq exit N".
(define dc.to-wait
  S Epoch -> (let _ (fc.send S "R" (fc.run-payload 64))
                  J (fc.expect S "S")
                  R (fc.records J 64 Epoch)
               (if (= (fh.member "execution" J) "HostWait") J
                   (if (= (fh.member "execution" J) "Running") (dc.to-wait S (+ Epoch (length R))) (fc.fail "Harness" "no host request")))))

(define dc.bad-reply
  I ToWait MakeBytes ->
    (trap-error
      (fc.with (fc.boot (value fc.*control*) (cn (value fc.*out*) "console-hostile-host.txt"))
        (/. S (let _ (fc.check-hello (fc.expect S "H"))
                   _ (fc.send S "I" (fc.init-payload I "normal"))
                   _ (fc.check-ready (fc.expect S "Y") I "normal")
                   _ (if ToWait (dc.to-wait S 0) true)
                   Seq (<-address S 2)
                   _ (fc.write S (MakeBytes Seq))
                   F (fc.next-frame (<-address S 1) ["G"] ["H" "Y" "S" "D" "B" "E"] any (value fc.*guest-max*))
                   J (fc.decode (nth 4 F))
                   _ (fc.drain (<-address S 1))
                   St (fc.exit-status S)
                (make-string "~A@~A exit ~A" (if (= (nth 2 F) "E") (fh.member "code" J) (cn "frame " (nth 2 F))) (nth 3 F) St))))
      (/. E (let C (fc.classify E) (cn (hd C) (cn ":" (hd (tl C))))))))

(define dc.host-cases
  I -> (let A (/. P (/. Seq (fc.frame "H" "A" Seq P)))
            Good (dc.reply-payload 0 (hd (dc.reply I)))
         [["reply-before-any-request" "BadState@2 exit 3" false (A Good)]
          ["reply-wrong-request-number" "BadReply@3 exit 3" true (A (dc.reply-payload 1 (hd (dc.reply I))))]
          ["reply-ill-typed" "BadReply@3 exit 3" true (A (dc.reply-payload 0 ["bytes" "zz"]))]
          ["reply-wrong-type" "BadReply@3 exit 3" true (A (dc.reply-payload 0 ["tuple" ["unit"] ["unit"]]))]
          ["reply-trailing-bytes" "BadReply@3 exit 3" true (A (cn (fc.take-string-n (- (fc.length Good) 1) Good) " }"))]
          ["reply-keys-reordered" "BadPayload@3 exit 3" true (A (cn "{c#34;requestc#34;:c#34;0c#34;,c#34;kindc#34;:c#34;Replyc#34;,c#34;valuec#34;:" (cn (json.stringify (hd (dc.reply I)) []) "}")))]
          ["run-while-awaiting-host" "NotRunning@3 exit 3" true (/. Seq (fc.frame "H" "R" Seq (fc.run-payload 1)))]]))

(define dc.host-row
  I [Name Expected ToWait Make] -> (fc.negative-row [Name Expected (dc.bad-reply I ToWait Make)]))

\\ ---------- tape negatives specific to v2 ----------

\\ Base: a tape whose exchange has a Reply (A) at frame position P (counting Hello as 0).
(define dc.reply-position
  [] _ -> none
  [[_ "A" | _] | _] N -> N
  [_ | Fs] N -> (dc.reply-position Fs (+ N 1)))

(define dc.tape-negatives
  Base -> (let T (fc.split-tape Base)
               H (hd T)
               Fs (hd (tl T))
               P (dc.reply-position Fs 0)
               Reply (fc.at P Fs)
               RJ (fc.decode (nth 4 Reply))
               Edited (fc.replace-at P (fc.set-payload "value" (dc.other-value (fh.member "value" RJ)) Reply) Fs)
               Dropped (fc.renumber (fc.remove-at P (fc.remove-at P Fs)))
               AsRun (fc.replace-at 3 ["H" "A" (nth 3 (fc.at 3 Fs)) (nth 4 (fc.at 3 Fs))] Fs)
            [["edited-reply-value" (cn "Diverged:frame " (str (+ P 1))) (fc.text-of H Edited)]
             ["dropped-reply-renumbered" "Structure:AfterTerminal" (fc.text-of H Dropped)]
             ["reply-while-running" "Structure:ReplyNotAwaited" (fc.text-of H AsRun)]]))

\\ A different well-typed I64 reply: n+1 (the fixtures' first replies are I64).
(define dc.other-value
  ["int" N] -> ["int" (str (+ 1 (fc.number N)))]
  V -> V)

\\ ---------- the specification's v2 byte vectors ----------

(define dc.host-vector
  "reply-seq-5" -> (fc.frame "H" "A" 5 (dc.reply-payload 0 ["int" "1"]))
  "reply-data-seq-7" -> (fc.frame "H" "A" 7 (dc.reply-payload 2 ["data" "Answer" "Busy"]))
  _ -> "")

(define dc.vector-row
  [Name "host" _ Hex] -> (fc.negative-row [Name "encoded-identically" (if (= (dc.host-vector Name) (fc.unhex Hex)) "encoded-identically" "different")])
  L -> (fc.vector-row L))

(define dc.vectors
  -> (map (/. L (dc.vector-row (fc.words L "" [])))
          (fc.filter (/. L (and (not (= L "")) (not (fh.starts? "#" L))))
                     (fh.lines (read-file-as-string (cn (value fh.*root*) "spec/solo5/pure-call-control-v2.vectors"))))))

\\ ---------- the check ----------

(define dc.count-x
  X Rows -> (fc.count-if (/. R (= (nth 6 R) X)) Rows 0))

(define dc.main
  -> (let Start (clock.monotonic)
          Runs (map (/. I (trap-error (dc.controlled I "normal") (/. E [failed (fc.classify E) "?" [] [] "?"]))) (value fc.*indices*))
          Agreed (fc.count-if (/. R (= (hd R) agreed)) Runs 0)
          Steps (fc.count-if (/. X true) (fc.flatten (map (/. R (nth 4 R)) Runs)) 0)
          Frames (fc.count-if (/. X true) (fc.flatten (map (/. R (nth 5 R)) Runs)) 0)
          Replies (fc.count-if (/. F (= (nth 2 F) "A")) (map (/. Raw (fc.parsed-any Raw)) (fc.flatten (map (/. R (nth 5 R)) Runs))) 0)
          ControlMs (- (clock.monotonic) Start)
          Tapes (map (/. P (fc.seal (fc.tape-header (hd P) "normal") (nth 5 (hd (tl P))))) (fc.pairs-of (value fc.*indices*) Runs))
          _ (fc.write-tapes (value fc.*indices*) Tapes)
          Boots (if (value dc.*quick*) 1 (value fc.*replay-boots*))
          Replays (map (/. T (fc.repeat Boots (freeze (fc.replay-result T)) [])) Tapes)
          ReplayExact (fc.count-if (/. Rs (fc.every? (/. R (= R "Exact")) Rs)) Replays 0)
          Rerecorded (if (value dc.*quick*) Tapes
                         (map (/. I (fc.seal (fc.tape-header I "normal") (nth 5 (dc.controlled I "normal")))) (value fc.*indices*)))
          Identical (fc.count-if (/. P (= (hd P) (hd (tl P)))) (fc.pairs-of Tapes Rerecorded) 0)
          WithReply (fc.filter (/. P (not (= (dc.reply-position (hd (tl (fc.split-tape (hd (tl P))))) 0) none)))
                               (fc.pairs-of (value fc.*indices*) Tapes))
          Base (if (value dc.*quick*) [] (hd WithReply))
          TapeRows (if (value dc.*quick*) []
                       (map (/. N (fc.negative-row [(fc.at 0 N) (fc.at 1 N) (fc.replay-result (fc.at 2 N))])) (dc.tape-negatives (hd (tl Base)))))
          HostRows (if (value dc.*quick*) [] (map (/. C (dc.host-row (hd Base) C)) (dc.host-cases (hd Base))))
          VectorRows (dc.vectors)
          Pass (and (= Agreed (value fc.*count*)) (= ReplayExact (length Tapes)) (= Identical (length Tapes))
                    (fc.rows-pass? TapeRows) (fc.rows-pass? HostRows) (fc.rows-pass? VectorRows) (> (length VectorRows) 0))
          Report [object ["schema" "fenrir.harness.solo5-durable/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["protocol" (value fc.*protocol*)] ["machine_profile" (value fc.*profile*)]
                         ["transport" "stock solo5-spt; net devices ctlin=@0 (host->guest pipe) and ctlout=@2 (guest->host pipe); console separate"]
                         ["tender_sha256" (fc.b "tender_sha256")] ["control_sha256" (fc.b "control_sha256")] ["batch_sha256" (fc.b "batch_sha256")]
                         ["programs" (str (value fc.*count*))] ["families" (fc.b "families")] ["fuel" (str (value fc.*fuel*))]
                         ["programs_agreeing_with_model" (str Agreed)]
                         ["executions" [object ["Completed" (str (dc.count-x "Completed" Runs))] ["AwaitingHost" (str (dc.count-x "AwaitingHost" Runs))]
                                               ["HostViolation_refused_by_guest" (str (dc.count-x "HostViolation" Runs))]
                                               ["BudgetExhausted" (str (dc.count-x "BudgetExhausted" Runs))]]]
                         ["steps_agreed" (str Steps)] ["frames_exchanged" (str Frames)] ["host_replies_sent" (str Replies)]
                         ["failures" (map (/. P [object ["program" (str (hd P))] ["name" (fc.identity (hd P) "name")] ["result" (str (hd (hd (tl P))))]
                                                        ["detail" (fc.detail (hd (tl P)))]])
                                          (fc.filter (/. P (not (= (hd (hd (tl P))) agreed))) (fc.pairs-of (value fc.*indices*) Runs)))]
                         ["controlled_milliseconds" (str ControlMs)]
                         ["replay" [object ["tapes" (str (length Tapes))] ["cold_boots_per_tape" (str Boots)]
                                           ["tapes_exact_on_every_boot" (str ReplayExact)]
                                           ["independent_rerecordings_byte_identical" (if (value dc.*quick*) "not run (quick)" (str Identical))]]]
                         ["tape_negatives" TapeRows]
                         ["hostile_host" HostRows]
                         ["vectors" VectorRows]
                         ["total_boots" (str (value fc.*boots*))]
                         ["milliseconds" (str (- (clock.monotonic) Start))]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 16777216]]))
           (shen-jit.exit (if Pass 0 1)))))

(define fc.parsed-any
  Raw -> (let F (fc.next-frame (fc.scripted Raw) ["H" "G"] ["H" "I" "R" "A" "D" "X" "Y" "S" "B" "E"] any 1048576)
           [(nth 1 F) (nth 2 F) (nth 3 F) (nth 4 F)]))

(define fc.detail
  [failed C | _] -> (make-string "~A" C)
  [_ At | _] -> (make-string "diverged at ~A" At))

(dc.main)
