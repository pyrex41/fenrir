\\ PROPOSED TC0-A gate evaluator, in Shen. NOT the registered evaluator: that is
\\ tools/check-tc0-a-gate.py with spec/tc0/tc0-a-requirements.json until the
\\ owner accepts this one. Whatever its rows say, this program reports
\\ authority UNREGISTERED and qualification UNKNOWN.
\\
\\   shen-jit script harness/gate.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE
\\
\\ It reads spec/tc0/tc0-a-requirements-shen.json, evaluates each row, and
\\ aggregates exactly as the registered gate does: any required FAIL gives FAIL;
\\ else any BLOCKED gives BLOCKED; else any UNKNOWN gives UNKNOWN; else PASS.
\\ A row whose check has not been moved to the Shen harness yet is UNKNOWN, so
\\ an incomplete port can never produce PASS. An evaluator error is UNKNOWN.
\\ The comparisons themselves are the other harness programs, each run as its
\\ own process so one cannot disturb another.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*jit* (hd (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ ---------- processes and text ----------

(define fh.exit-code
  [exited N] -> N
  _ -> -1)

\\ [ExitCode Stdout Stderr]; -1 when the process did not exit normally in time.
(define fh.exec
  Program Args Seconds ->
    (let R (process.run Program Args (buffer.from-string "")
                        [[cwd (value fh.*root*)] [timeout (* Seconds 1000)] [stdout-limit 67108864] [stderr-limit 4194304]])
      (if (= (hd R) ok)
          [(fh.exit-code (process.status (hd (tl R))))
           (buffer.string (process.output-bytes (hd (tl R))))
           (buffer.string (process.error-bytes (hd (tl R))))]
          [-1 "" "process did not complete within its time or output limits"])))

(define fh.view-lines
  V I End Acc -> (reverse Acc) where (>= I End)
  V I End Acc ->
    (let Next (fh.next-line V I End)
         Count (- (- Next I) (if (and (> Next I) (= (buffer.u8 V (- Next 1)) 10)) 1 0))
      (fh.view-lines V Next End [(buffer.string (buffer.slice V I Count)) | Acc])))

(define fh.lines
  S -> (let V (buffer.from-string S) (fh.view-lines V 0 (buffer.length V) [])))

(define fh.starts?
  "" _ -> true
  _ "" -> false
  (@s A As) (@s B Bs) -> (and (= A B) (fh.starts? As Bs)))

(define fh.drop
  "" S -> S
  (@s _ Ps) (@s _ Ss) -> (fh.drop Ps Ss))

\\ The text after Prefix on the last line that starts with it, or [].
(define fh.last-after
  Prefix [] Found -> Found
  Prefix [L | Ls] Found -> (fh.last-after Prefix Ls (if (fh.starts? Prefix L) (fh.drop Prefix L) Found)))

(define fh.last-nonempty
  [] Found -> Found
  ["" | Ls] Found -> (fh.last-nonempty Ls Found)
  [L | Ls] _ -> (fh.last-nonempty Ls L))

\\ The last line that is a JSON object, decoded, or [].
(define fh.last-report
  Text -> (let Line (fh.last-after "{" (fh.lines Text) [])
            (if (= Line []) [] (trap-error (json.parse (cn "{" Line) [[byte-limit 4194304]]) (/. E [])))))

(define fh.member
  Key [object | Members] -> (fh.member-in Key Members)
  _ _ -> [])

(define fh.member-in
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.member-in Key Rest)
  _ [] -> [])

(define fh.trim
  S -> (fh.last-nonempty (fh.lines S) ""))

\\ ---------- rows ----------
\\ A check returns [Status Reasons Detail Memo]. Detail is a list of [Key String].
\\ Memo carries results later rows depend on.

(define fh.row
  Status Reasons Detail Memo -> [Status Reasons Detail Memo])

(define fh.not-ported
  What Memo -> (fh.row "UNKNOWN" [(cn What " is not yet moved to the Shen harness")] [] Memo))

\\ Run one harness program and decode its report.
(define fh.harness
  Script Args Seconds ->
    (fh.last-report (hd (tl (fh.exec (value fh.*jit*) (append ["script" (cn (value fh.*root*) (cn "harness/" Script)) (value fh.*lib*) (value fh.*root*)] Args) Seconds)))))

(define fh.subdir
  Name -> (let Dir (cn (value fh.*out*) Name)
               Made (fh.exec "mkdir" ["-p" Dir] 30)
            Dir))

(define fh.source-identity
  Memo ->
    (let Dirty (fh.exec "git" ["status" "--porcelain"] 60)
         Head (fh.trim (hd (tl (fh.exec "git" ["rev-parse" "HEAD"] 60))))
         Memo2 [["head" Head] | Memo]
      (if (not (= (hd Dirty) 0))
          (fh.row "UNKNOWN" ["git status failed; the source could not be identified"] [] Memo)
          (if (= (fh.trim (hd (tl Dirty))) "")
              (fh.row "PASS" [] [["head" Head]] Memo2)
              (fh.row "UNKNOWN" ["Worktree has uncommitted changes; evidence would not be source-bound"] [["head" Head]] Memo2)))))

(define fh.toolchain-pinned
  Memo -> (fh.row "BLOCKED" ["Shen/JIT and its libraries are built by hand and are not pinned in the flake"]
                  [["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]] Memo))

(define fh.unit-suite
  Memo ->
    (let R (fh.exec "sh" ["-c" "node --test tests/tc0/*.test.mjs"] 900)
         Lines (fh.lines (hd (tl R)))
         Fail (fh.last-after "# fail " Lines [])
         Skip (fh.last-after "# skipped " Lines [])
         Pass (fh.last-after "# pass " Lines [])
      (if (= (hd R) -1)
          (fh.row "UNKNOWN" ["Test runner timed out or did not complete"] [] Memo)
          (if (or (= Fail []) (= Skip []) (= Pass []))
              (fh.row "FAIL" ["Test runner printed no summary"] [] Memo)
              (if (or (not (= Fail "0")) (not (= (hd R) 0)))
                  (fh.row "FAIL" [(cn Fail " failing tests")] [] Memo)
                  (if (not (= Skip "0"))
                      (fh.row "UNKNOWN" [(cn Skip " skipped tests are missing evidence")] [] Memo)
                      (fh.row "PASS" [] [["passed" Pass]] Memo)))))))

(define fh.hand-agreement-and-replay
  Memo ->
    (let Report (fh.harness "hand-cases.shen" [(fh.subdir "hand") "sandbox"] 600)
         Status (fh.member "status" Report)
      (if (= Status "development-fail")
          (fh.row "FAIL" ["Hand cases: model, implementation or hand expectations disagree"] [["failures" (json.stringify (fh.member "failures" Report) [])]] Memo)
          (if (= Status "development-pass")
              (fh.row "UNKNOWN" ["Hand cases agree; strict replay is not yet moved to the Shen harness"]
                      [["cases" (fh.member "cases" Report)] ["expectations_checked" (fh.member "expectations_checked" Report)]]
                      [["hand" Report] | Memo])
              (fh.row "UNKNOWN" ["The hand-case harness did not report"] [] Memo)))))

\\ Build a guest batch with the JavaScript builder and compare it in Shen.
(define fh.guest-batch
  BuilderArgs ->
    (let Built (fh.exec "node" (append [(cn (value fh.*root*) "tools/solo5/freerun-pure-call.mjs")] (append BuilderArgs ["--build-only"])) 1800)
      (if (= (hd Built) 0)
          (fh.harness "solo5-pure-call.shen" [(fh.trim (hd (tl Built)))] 1800)
          blocked)))

(define fh.guest-row
  blocked Memo -> (fh.row "BLOCKED" ["The Solo5 guest batch could not be built (is build/vendor/solo5 built at the pinned commit?)"] [] Memo)
  Report Memo ->
    (let Status (fh.member "status" Report)
      (if (= Status "development-pass")
          (fh.row "PASS" [] [["programs" (fh.member "programs" Report)] ["steps" (fh.member "model_steps" Report)]
                             ["defects_detected" (json.stringify (fh.member "defects_detected" Report) [])]] Memo)
          (if (= Status "development-fail")
              (fh.row "FAIL" [(cn (fh.member "programs_differing" Report) " programs differ between the model and the Solo5 guest, or a guest defect went undetected")] [] Memo)
              (fh.row "UNKNOWN" ["The Solo5 harness did not report"] [] Memo)))))

(define fh.exact-arithmetic
  Memo -> (fh.guest-row (fh.guest-batch ["--exact-arithmetic"]) Memo))

(define fh.solo5-guest-agreement
  Memo -> (fh.guest-row (fh.guest-batch ["--exhaustive-nodes" "5"]) Memo))

(define fh.exhaustive-small
  Memo ->
    (let Report (fh.harness "model-vs-candidate.shen" ["5" (fh.subdir "exhaustive") "sandbox"] 1800)
         Status (fh.member "status" Report)
         Agreeing (fh.member "agreeing" Report)
         Programs (fh.member "programs" Report)
      (if (= Report [])
          (fh.row "UNKNOWN" ["The exhaustive harness did not report"] [] Memo)
          (if (not (= (fh.member "scope_complete" Report) true))
              (fh.row "UNKNOWN" ["The enumerated scope was truncated or incomplete"] [] Memo)
              (if (not (= Agreeing Programs))
                  (fh.row "FAIL" [(make-string "~A of ~A programs agree with the model" Agreeing Programs)]
                          [["disagreements" (json.stringify (fh.member "disagreements" Report) [])]] [["exhaustive" Report] | Memo])
                  (fh.row "PASS" [] [["programs" Programs] ["steps" (fh.member "model_steps" Report)]] [["exhaustive" Report] | Memo]))))))

\\ Killed means: completed with a trace different from the model's. Crashes are never kills.
(define fh.mutant
  Name Memo ->
    (let Counts (fh.member Name (fh.member-in "exhaustive" Memo))
         Killed (fh.member "killed" Counts)
      (if (= Counts [])
          (fh.row "UNKNOWN" ["No exhaustive report in this run"] [] Memo)
          (if (= Killed "0")
              (fh.row "FAIL" [(make-string "Mutant ~A survived every program (~A crashes are not kills)" Name (fh.member "crashed" Counts))] [] Memo)
              (fh.row "PASS" [] [["killed" Killed] ["survived" (fh.member "survived" Counts)] ["crashed" (fh.member "crashed" Counts)]] Memo)))))

(define fh.candidate-boundary
  Memo ->
    (let R (fh.exec "node" [(cn (value fh.*root*) "tools/tc0/check-sandbox.mjs") (cn (value fh.*out*) "sandbox.json")] 300)
      (if (= (hd R) 2)
          (fh.row "BLOCKED" [(fh.trim (hd (tl (tl R))))] [] Memo)
          (if (= (hd R) 0)
              (fh.row "PASS" [] [] Memo)
              (fh.row "FAIL" ["A boundary probe was not denied in the sandbox, or the probe run failed"] [] Memo)))))

(define fh.requirement-ledger
  Memo ->
    (let R (fh.exec "node" [(cn (value fh.*root*) "tools/tc0/check-requirement-ledger.mjs")] 120)
      (if (= (hd R) 0)
          (fh.row "PASS" [] [] Memo)
          (fh.row "FAIL" ["The ledger checker reports problems"] [["output" (fh.trim (hd (tl R)))]] Memo))))

(define fh.sha256
  Path -> (let R (fh.exec "sha256sum" [Path] 60)
            (if (= (hd R) 0) (fh.take-string 64 (hd (tl R))) "")))

(define fh.take-string
  0 _ -> ""
  _ "" -> ""
  N (@s C Cs) -> (cn C (fh.take-string (- N 1) Cs)))

(define fh.repair-isolation
  Path Memo ->
    (let Text (trap-error (read-file-as-string (cn (value fh.*root*) Path)) (/. E ""))
         A (if (= Text "") [] (trap-error (json.parse Text []) (/. E [])))
         Patch (fh.member "patch" A)
         By (fh.member "accepted_by" A)
      (if (= A [])
          (fh.row "UNKNOWN" [(cn "No isolation record at " Path)] [] Memo)
          (if (or (not (string? Patch)) (not (= (fh.sha256 (cn (value fh.*root*) Patch)) (fh.member "patch_sha256" A))))
              (fh.row "UNKNOWN" [(cn Path " does not match the retained patch")] [] Memo)
              (if (or (not (string? By)) (= By ""))
                  (fh.row "UNKNOWN" [(cn Path " names no reviewer")] [] Memo)
                  (if (= (fh.member "isolation" A) "enforced")
                      (fh.row "PASS" [] [["isolation" "enforced"] ["accepted_by" By]] Memo)
                      (if (and (= (fh.member "isolation" A) "instruction-only") (= (fh.member "decision" A) "owner-waiver"))
                          (let Waiver (make-string "Repair isolation: instruction-only accepted by ~A on ~A; revisit: ~A" By (fh.member "accepted_on" A) (fh.member "revisit" A))
                            (fh.row "PASS" [] [["isolation" "instruction-only"] ["waiver" Waiver]] [["waiver" Waiver] | Memo]))
                          (fh.row "UNKNOWN" [(cn Path " records neither enforced isolation nor an owner waiver")] [] Memo))))))))

(define fh.check
  "source-identity" Memo -> (fh.source-identity Memo)
  "toolchain-pinned" Memo -> (fh.toolchain-pinned Memo)
  "unit-suite" Memo -> (fh.unit-suite Memo)
  "hand-agreement-and-replay" Memo -> (fh.hand-agreement-and-replay Memo)
  "exact-arithmetic" Memo -> (fh.exact-arithmetic Memo)
  "exhaustive-small" Memo -> (fh.exhaustive-small Memo)
  "mutant:reverse_operands" Memo -> (fh.mutant "reverse_operands" Memo)
  "mutant:wrap_overflow" Memo -> (fh.mutant "wrap_overflow" Memo)
  "mutant:arm_by_position" Memo -> (fh.mutant "arm_by_position" Memo)
  "catalog-coverage" Memo -> (fh.not-ported "Catalog coverage" Memo)
  "discovery-reduction-replay" Memo -> (fh.not-ported "Generated discovery, reduction and failure replay" Memo)
  "candidate-boundary" Memo -> (fh.candidate-boundary Memo)
  "requirement-ledger" Memo -> (fh.requirement-ledger Memo)
  "independent-repair-fresh" Memo -> (fh.not-ported "The fresh repair evaluation" Memo)
  "repair-isolation:campaigns/tc0/s3/repair-isolation-acceptance.json" Memo -> (fh.repair-isolation "campaigns/tc0/s3/repair-isolation-acceptance.json" Memo)
  "exact-arithmetic-shaken" Memo -> (fh.row "DEFERRED" ["Optional second port: the harness runs on Shen/JIT only"] [] Memo)
  "solo5-guest-agreement" Memo -> (fh.solo5-guest-agreement Memo)
  Name Memo -> (fh.row "UNKNOWN" [(cn "The evaluator has no check named " Name)] [] Memo))

\\ An evaluator fault is never a pass.
(define fh.safe-check
  Name Memo -> (trap-error (fh.check Name Memo) (/. E (fh.row "UNKNOWN" [(cn "Evaluator error: " (error-to-string E))] [] Memo))))

\\ Evaluate rows in manifest order. Result: [RowObjects Memo], rows oldest first.
(define fh.evaluate
  [] Memo Acc -> [(reverse Acc) Memo]
  [Spec | Specs] Memo Acc ->
    (let R (fh.safe-check (fh.field "check" Spec) Memo)
         Out (do (output "~A: ~A~%" (fh.field "id" Spec) (hd R)) skip)
      (fh.evaluate Specs (nth 4 R)
        [[object ["id" (fh.field "id" Spec)] ["required" (fh.field "required" Spec)] ["status" (hd R)]
                 ["reasons" (nth 2 R)] ["detail" [object | (nth 3 R)]]] | Acc])))

\\ ---------- aggregation ----------

(define fh.any-required?
  Status [] -> false
  Status [Row | Rows] -> (or (and (= (fh.field "required" Row) true) (= (fh.field "status" Row) Status))
                             (fh.any-required? Status Rows)))

(define fh.verdict
  Rows -> "FAIL" where (fh.any-required? "FAIL" Rows)
  Rows -> "BLOCKED" where (fh.any-required? "BLOCKED" Rows)
  Rows -> "UNKNOWN" where (fh.any-required? "UNKNOWN" Rows)
  _ -> "PASS")

(define fh.status-of
  Id [] -> "ABSENT"
  Id [Row | Rows] -> (if (= (fh.field "id" Row) Id) (fh.field "status" Row) (fh.status-of Id Rows)))

(define fh.all-pass?
  [] _ -> true
  [Id | Ids] Rows -> (and (= (fh.status-of Id Rows) "PASS") (fh.all-pass? Ids Rows)))

\\ A claim is credited only when every one of its rows and every prerequisite passed.
(define fh.claims
  [] _ _ -> []
  [[Claim Ids] | Rest] Prerequisites Rows ->
    (if (fh.all-pass? (append Ids Prerequisites) Rows)
        [Claim | (fh.claims Rest Prerequisites Rows)]
        (fh.claims Rest Prerequisites Rows)))

(define fh.waivers
  [] -> []
  [["waiver" W] | Memo] -> [W | (fh.waivers Memo)]
  [_ | Memo] -> (fh.waivers Memo))

(define fh.count-status
  Status Required [] N -> N
  Status Required [Row | Rows] N ->
    (fh.count-status Status Required Rows
      (if (and (= (fh.field "status" Row) Status) (or (not Required) (= (fh.field "required" Row) true))) (+ N 1) N)))

(define fh.ledger-ids
  Ledger -> (map (/. R (fh.field "id" R)) (fh.field "rows" Ledger)))

(define fh.unknown-references
  [] _ -> []
  [Spec | Specs] Ids -> (append (fh.missing (fh.field "ledger" Spec) Ids) (fh.unknown-references Specs Ids)))

(define fh.missing
  [] _ -> []
  [X | Xs] Ids -> (if (element? X Ids) (fh.missing Xs Ids) [X | (fh.missing Xs Ids)]))

(define fh.exit-status
  "PASS" -> 0
  "FAIL" -> 1
  _ -> 2)

(define fh.main
  -> (let ManifestPath "spec/tc0/tc0-a-requirements-shen.json"
          Manifest (json.parse (read-file-as-string (cn (value fh.*root*) ManifestPath)) [[byte-limit 4194304]])
          Ledger (json.parse (read-file-as-string (cn (value fh.*root*) (fh.field "ledger" Manifest))) [[byte-limit 4194304]])
          Valid (if (and (= (fh.field "schema" Manifest) "tc0-a-requirement-manifest/1")
                         (empty? (fh.unknown-references (fh.field "rows" Manifest) (fh.ledger-ids Ledger))))
                    true (error "gate: manifest invalid or it names unknown ledger rows"))
          Result (fh.evaluate (fh.field "rows" Manifest) [] [])
          Rows0 (hd Result)
          Memo (hd (tl Result))
          \\ Read HEAD directly and compare it with the head recorded when the source-identity
          \\ row ran. If that row never ran there is nothing to compare with: UNKNOWN.
          HeadNow (fh.trim (hd (tl (fh.exec "git" ["rev-parse" "HEAD"] 60))))
          DirtyNow (fh.trim (hd (tl (fh.exec "git" ["status" "--porcelain"] 60))))
          Drift (or (not (= HeadNow (fh.member-in "head" Memo))) (not (= DirtyNow "")))
          Rows (if Drift
                   (append Rows0 [[object ["id" "source-drift"] ["required" true] ["status" "UNKNOWN"]
                                          ["reasons" ["Source changed during evaluation, or was never identified"]] ["detail" [object]]]])
                   Rows0)
          Verdict (fh.verdict Rows)
          Claims (fh.claims (tl (fh.field "claims" Manifest)) (fh.field "claim_prerequisites" Manifest) Rows)
          Report [object ["schema" "tc0-a-gate-run/shen-proposed-1"]
                         ["authority" "UNREGISTERED"]
                         ["qualification" "UNKNOWN"]
                         ["verdict" Verdict]
                         ["claims" Claims]
                         ["waivers" (fh.waivers Memo)]
                         ["head" (fh.member-in "head" Memo)]
                         ["manifest" ManifestPath]
                         ["evaluator" "harness/gate.shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["aggregation" (fh.field "aggregation" Manifest)]
                         ["required_rows_passing" (make-string "~A/~A" (fh.count-status "PASS" true Rows 0)
                                                               (- (length Rows) (fh.count-optional Rows 0)))]
                         ["rows" Rows]]
          Text (json.stringify Report [[byte-limit 4194304]])
          Written (write-to-file (cn (value fh.*out*) "gate.json") (cn Text "c#10;"))
       (do (output "~A~%" Text)
           (shen-jit.exit (fh.exit-status Verdict)))))

(define fh.count-optional
  [] N -> N
  [Row | Rows] N -> (fh.count-optional Rows (if (= (fh.field "required" Row) true) N (+ N 1))))

(fh.main)
