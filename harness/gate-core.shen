\\ Gate machinery shared by the gate evaluators: harness/gate.shen (TC0-A) and
\\ harness/tc1-gate.shen (TC1). Load after setting fh.*lib* and fh.*root*; the
\\ remaining arguments are read here:
\\
\\   shen-jit script GATE.shen LIBDIR ROOT OUTDIR SHEN_JIT_EXECUTABLE [NONCE CHECK_ID SOURCE_SHA256 CONFIG_SHA256]
\\
\\ A gate file supplies three things and then calls fh.gate-main:
\\   fh.check        Name Memo -> row     its row checks, by the manifest's check names
\\   fh.registered?  Manifest -> boolean  whether the legacy check is registered
\\   its manifest path, manifest schema, report schema, evaluator path and label
\\ Here: the row format, the checks every gate needs (source identity, pinned
\\ toolchain, unit suite, Solo5 guest batches), row evaluation, aggregation, the
\\ report and the workflow controller's check record.
\\
\\ Aggregation: any required FAIL gives FAIL; else any BLOCKED gives BLOCKED; else
\\ any UNKNOWN gives UNKNOWN; else PASS. An evaluator error, a check that does not
\\ report, or a check the gate does not know is UNKNOWN. A verdict counts as a
\\ qualification only while fh.registered? holds on the legacy Linux x86-64
\\ runner; otherwise the report says authority UNREGISTERED and qualification UNKNOWN.
\\ The comparisons themselves are the other harness programs, each run as its
\\ own process so one cannot disturb another.
\\ With the four controller arguments the controller's check record is printed too.

(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*jit* (hd (tl (tl (tl (tl (value *argv*)))))))
(set fh.*controller* (tl (tl (tl (tl (tl (value *argv*)))))))
(load (cn (value fh.*root*) "harness/common.shen"))
(set fh.*capture* [])

(define fh.capture-binding
  ["arm-development/1" Role Nonce Source Profile Manifest G1] ->
    [object ["role" Role] ["nonce" Nonce] ["source_sha256" Source]
            ["profile_sha256" Profile] ["manifest_sha256" Manifest] ["g1_manifest_sha256" G1]]
  ["arm-development/1" | _] -> (error "Invalid ARM development capture arguments")
  _ -> [])

(define fh.capture-args
  Role Binding Manifest ->
    ["arm-development/1" Role (fh.field "nonce" Binding) (fh.field "source_sha256" Binding)
      (fh.field "profile_sha256" Binding) Manifest (fh.field "g1_manifest_sha256" Binding)])

(define fh.capture-valid?
  [] _ _ _ -> true
  B Manifest Evaluator Host ->
    (and (= (hd Host) 0) (= (hd (tl Host)) "Linux aarch64c#10;")
         (= (fh.field "profile_sha256" B) (fh.sha256 (cn (value fh.*root*) "campaigns/arm64/profile-v1.json")))
         (= (fh.field "manifest_sha256" B) (fh.sha256 (cn (value fh.*root*) Manifest)))
         (= (fh.field "g1_manifest_sha256" B) (fh.sha256 (cn (value fh.*root*) "spec/tc0/tc0-a-requirements.json")))
         (if (= Evaluator "harness/tc1-gate.shen")
             (= (fh.field "role" B) "tc1")
             (element? (fh.field "role" B) ["g1" "nested-g1"]))))

(define fh.capture-frame
  [] _ _ -> skip
  B Verdict Path ->
    (if (= (fh.field "role" B) "nested-g1") skip
        (output "FENRIR_ARM_CAPTURE ~A~%"
          (json.stringify [object ["schema" "fenrir.arm-development-frame/1"]
              ["binding" B] ["verdict" Verdict] ["report_sha256" (fh.sha256 Path)]] []))))

\\ ---------- rows and the checks every gate needs ----------
\\ A check returns [Status Reasons Detail Memo]. Detail is a list of [Key String].
\\ Memo carries results later rows depend on.

(define fh.row
  Status Reasons Detail Memo -> [Status Reasons Detail Memo])

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

\\ The executable and library directory this gate is running on must be the flake's
\\ shen-jit output. No nix, or no such output: BLOCKED. Anything else running: UNKNOWN.
(define fh.toolchain-pinned
  Memo ->
    (let Built (fh.exec "nix" ["build" "--no-link" "--print-out-paths" ".#shen-jit"] 1800)
         Pinned (fh.trim (hd (tl Built)))
         Executable (fh.trim (hd (tl (fh.exec "realpath" [(value fh.*jit*)] 30))))
         Library (fh.trim (hd (tl (fh.exec "realpath" [(value fh.*lib*)] 30))))
      (if (not (= (hd Built) 0))
          (fh.row "BLOCKED" ["nix is unavailable or could not build the flake's shen-jit output"] [] Memo)
          (if (and (= Executable (cn Pinned "/bin/shen-jit")) (= Library (cn Pinned "/lib")))
              (fh.row "PASS" [] [["shen_jit" Pinned] ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]] Memo)
              (fh.row "UNKNOWN" [(make-string "The gate is running on ~A with libraries ~A, not the pinned ~A" Executable Library Pinned)] [] Memo)))))

\\ node --test over Globs (shell patterns relative to the repository root).
(define fh.unit-suite
  Globs Memo ->
    (let R (fh.exec "sh" ["-c" (cn "node --test " Globs)] 900)
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

\\ Build a guest batch and compare it in Shen: the comparison's report, or blocked.
(define fh.guest-batch
  BuilderArgs ->
    (let Directory (fh.guest-build BuilderArgs)
      (if (= Directory blocked) blocked (fh.harness "solo5-pure-call.shen" [Directory] 1800))))

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

\\ Neither a host flake output nor Pi registration expands the reviewed platform.
\\ Be strict about the successful uname result: missing, partial or malformed
\\ output is not evidence. This is a trusted-runner observation, not attestation.
(define fh.legacy-runner?
  [0 "Linux x86_64c#10;" _] -> true
  _ -> false)

\\ Evaluate the manifest at ManifestPath and report. ManifestSchema is the schema the
\\ manifest must declare, ReportSchema the schema of the report, Evaluator the gate
\\ file, Label the gate's name in the controller's summary.
(define fh.gate-main
  ManifestPath ManifestSchema ReportSchema Evaluator Label ->
    (let Binding (fh.capture-binding (value fh.*controller*))
          Capture (not (empty? Binding))
          Host (if Capture (fh.exec "uname" ["-sm"] 30) [])
          Admission (if (fh.capture-valid? Binding ManifestPath Evaluator Host)
                        (set fh.*capture* Binding) (error "ARM development platform, profile or manifest mismatch"))
          Manifest (json.parse (read-file-as-string (cn (value fh.*root*) ManifestPath)) [[byte-limit 4194304]])
          Ledger (json.parse (read-file-as-string (cn (value fh.*root*) (fh.field "ledger" Manifest))) [[byte-limit 4194304]])
          Valid (if (and (= (fh.field "schema" Manifest) ManifestSchema)
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
          Verdict (if (fh.capture-valid? Binding ManifestPath Evaluator Host) (fh.verdict Rows)
                      (error "ARM development profile or manifest drift"))
          Claims (fh.claims (tl (fh.field "claims" Manifest)) (fh.field "claim_prerequisites" Manifest) Rows)
           Host (trap-error (fh.exec "uname" ["-sm"] 30) (/. E [-1 "" "platform probe failed"]))
           Supported (fh.legacy-runner? Host)
           Registered (and (not Capture) Supported (fh.registered? Manifest))
           Controller (if Capture [] (value fh.*controller*))
          Passing (make-string "~A/~A" (fh.count-status "PASS" true Rows 0) (- (length Rows) (fh.count-optional Rows 0)))
          Report [object | (append [["schema" ReportSchema]
                         ["authority" (if Registered "owner-accepted, registered" "UNREGISTERED")]
                          ["qualification" (if Registered Verdict "UNKNOWN")]
                          ["runner" [object ["uname_sm" (hd (tl Host))] ["uname_exit" (str (hd Host))]
                                            ["legacy_qualification_platform" Supported]]]
                         ["verdict" Verdict]
                          ["claims" (if Supported Claims [])]
                          ["development_claims" (if Supported [] Claims)]
                         ["waivers" (fh.waivers Memo)]
                         ["head" (fh.member-in "head" Memo)]
                         ["manifest" ManifestPath]
                         ["evaluator" Evaluator]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["aggregation" (fh.field "aggregation" Manifest)]
                         ["required_rows_passing" Passing]
                          ["rows" Rows]] (if Capture [["capture" Binding]] []))]
          Text (json.stringify Report [[byte-limit 4194304]])
          Path (cn (value fh.*out*) "gate.json")
          Written (write-to-file Path (cn Text "c#10;"))
       (do (if (or (not Capture) (= (fh.field "role" Binding) "nested-g1")) (output "~A~%" Text) skip)
            (fh.controller-record Controller
              (if Supported Label (cn Label " (legacy qualification requires Linux x86_64)"))
              Registered Verdict Claims Passing (fh.waivers Memo))
            (fh.capture-frame Binding Verdict Path)
            \\ A bare run has a development verdict, including when TC1 calls G1.
            \\ A framed run must exit consistently with its credited verdict.
            (shen-jit.exit (fh.exit-status (if (and (cons? Controller) (not Registered)) "UNKNOWN" Verdict))))))

\\ The registration rule both gates use: the manifest is owner-accepted and the workflow
\\ configuration has a check named CheckId whose command runs Runner.
(define fh.registered-as
  CheckId Runner Manifest ->
    (let Config (trap-error (json.parse (read-file-as-string (cn (value fh.*root*) ".pi/fenrir-workflow.json")) [[byte-limit 4194304]]) (/. E []))
         Command (fh.member "command" (fh.member CheckId (fh.member "checks" Config)))
      (and (= (fh.field "status" Manifest) "owner-accepted") (cons? Command) (element? Runner Command))))

\\ A path below the repository root, without the root.
(define fh.relative
  Path -> (if (fh.starts? (value fh.*root*) Path) (fh.drop (value fh.*root*) Path) Path))

(define fh.join
  [] _ -> ""
  [X] _ -> X
  [X | Xs] Sep -> (cn X (cn Sep (fh.join Xs Sep))))

\\ The workflow controller's check record, printed last when it supplied its nonce.
\\ An unregistered evaluator credits no verdict and no claims.
(define fh.controller-record
  [Nonce CheckId SourceHash ConfigHash] Label Registered Verdict Claims Passing Waivers ->
    (output "~A~%"
      (json.stringify
        [object ["schema" "fenrir.check.v1"] ["nonce" Nonce] ["checkId" CheckId] ["sourceHash" SourceHash] ["configHash" ConfigHash]
                ["verdict" (if Registered Verdict "UNKNOWN")] ["cleanup" "confirmed"] ["claims" (if Registered Claims [])]
                ["evidence" [(fh.relative (cn (value fh.*out*) "gate.json"))]]
                ["summary" (make-string "~A: ~A; ~A required rows PASS; claims ~A~A"
                                        Label Verdict Passing (if (empty? Claims) "none" (fh.join Claims ", "))
                                        (if (empty? Waivers) "" (cn "; waivers: " (fh.join Waivers " | "))))]]
        [[byte-limit 1048576]]))
  _ _ _ _ _ _ _ -> skip)

(define fh.count-optional
  [] N -> N
  [Row | Rows] N -> (fh.count-optional Rows (if (= (fh.field "required" Row) true) N (+ N 1))))
