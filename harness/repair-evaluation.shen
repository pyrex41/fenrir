\\ Fenrir harness, in Shen: evaluate a repair of the implementation.
\\ A repairer was given a workspace containing a defective implementation and
\\ two retained failures, and may have changed one file. This program decides
\\ whether that change is an acceptable repair. Development tier.
\\
\\   shen-jit script harness/repair-evaluation.shen LIBDIR ROOT OUTDIR SHEN_JIT PACKET WORKSPACE
\\ PACKET and WORKSPACE come from tools/tc0/s3-prepare.mjs; WORKSPACE has the repair applied.
\\
\\ Steps, all required, in this order:
\\  1 protected-inputs      only the allowed file changed; everything else is byte-identical
\\  2 candidate-changed     the implementation differs from the preserved defective original
\\  3 original-replay       the defective original still reproduces each retained failure,
\\                          stopping at its recorded first divergence
\\  4 repaired-replay       the repaired implementation replays each retained failure and is admitted
\\  5 hand-case-agreement   the hand cases, against the model
\\  6 regressions           the workspace's own test suite
\\  7 held-out generated families and the exhaustive scope to 5 nodes, never shown to the repairer
\\  8 mutation-control      the same checks must reject the defective original (at 4 nodes)
\\
\\ The repaired implementation is untrusted code: every step that runs it (4, 5, 7)
\\ runs it in tools/tc0/sandbox.mjs. Step 6 spawns processes, so it gets network and
\\ environment isolation only. Steps 3 to 8 use trusted exports of the start
\\ revision with one implementation file substituted, never the workspace's tools.
\\ The evaluator cannot establish who wrote the patch.
\\ Shen version of tools/check-tc0-s3-repair.py.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*jit* (hd (tl (tl (tl (tl (value *argv*)))))))
(set fh.*packet* (cn (hd (tl (tl (tl (tl (tl (value *argv*))))))) "/"))
(set fh.*workspace* (cn (hd (tl (tl (tl (tl (tl (tl (value *argv*)))))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

(define fh.json-file
  Path -> (json.parse (read-file-as-string Path) [[byte-limit 67108864]]))

\\ ---------- step 1: what changed in the workspace ----------

\\ "HASH  ./path" lines from sha256sum, as [Path Hash] pairs.
(define fh.hash-lines
  [] -> []
  ["" | Ls] -> (fh.hash-lines Ls)
  [L | Ls] -> [[(fh.drop-n 68 L) (fh.take-string 64 L)] | (fh.hash-lines Ls)])

(define fh.drop-n
  0 S -> S
  _ "" -> ""
  N (@s _ S) -> (fh.drop-n (- N 1) S))

(define fh.workspace-hashes
  -> (let R (fh.exec "sh" ["-c" (cn "cd " (cn (value fh.*workspace*)
               " && find . -type f ! -path './build/*' ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum"))] 300)
       (if (= (hd R) 0) (fh.hash-lines (fh.lines (hd (tl R)))) (error "repair: could not hash the workspace"))))

(define fh.lookup
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.lookup Key Rest)
  _ [] -> absent)

\\ Paths, outside Allowed, whose hash in A is not their hash in B.
(define fh.changed
  [] _ _ -> []
  [[Path Hash] | Rest] B Allowed ->
    (if (or (element? Path Allowed) (= (fh.lookup Path B) Hash))
        (fh.changed Rest B Allowed)
        [Path | (fh.changed Rest B Allowed)]))

(define fh.violations
  Manifest ->
    (let Expected (tl (fh.field "files" Manifest))
         Current (fh.workspace-hashes)
         Allowed (fh.field "allowed_paths" Manifest)
      (append (fh.changed Expected Current Allowed) (fh.changed Current Expected Allowed))))

\\ ---------- trusted trees ----------

\\ An export of the start revision with one implementation file substituted.
(define fh.tree
  Revision Implementation Name ->
    (let Dir (cn (value fh.*out*) Name)
         R (fh.exec "sh" ["-c" (make-string "mkdir -p '~A' && git archive --format=tar ~A | tar -x -C '~A' && cp '~A' '~A/runtime/tc0/pure-call-machine.mjs'"
                                            Dir Revision Dir Implementation Dir)] 300)
      (if (= (hd R) 0) (cn Dir "/") (error "repair: could not export the start revision"))))

\\ ---------- steps ----------

(define fh.step
  Name true Detail -> [object ["step" Name] ["status" "PASS"] | Detail]
  Name _ Detail -> [object ["step" Name] ["status" "FAIL"] | Detail])

(define fh.replay-step
  Tree Bundle Implementation Mode ->
    (let Out (cn (value fh.*out*) (cn Mode "-replay.json"))
         Script (cn Tree "tools/tc0/s3-replay.mjs")
         Args (if (= Mode "repaired")
                  \\ The replay also reads the catalog and the node binary for the tape header.
                  [(cn Tree "tools/tc0/sandbox.mjs") "--read" (cn Tree "tools/tc0") (cn Tree "spec/tc0") Implementation Bundle Out (fh.node-path)
                   "--write" Out "--" Script Bundle Implementation Mode Out]
                  [Script Bundle Implementation Mode Out])
         R (fh.exec "node" Args 600)
      (fh.step (cn Mode "-replay") (= (hd R) 0)
               [["boundary" (if (= Mode "repaired") "sandbox" "trusted defective original")] ["output" (fh.trim (hd (tl R)))]])))

(define fh.agreement-step
  Name Tree Options Dir ->
    (let Report (fh.harness-in Tree "hand-cases.shen" [(fh.subdir Dir) "sandbox" | Options] 900)
      (fh.step Name (= (fh.member "status" Report) "development-pass")
               [["boundary" "sandbox"] ["cases" (fh.member "cases" Report)] ["failures" (fh.member "failures" Report)]])))

(define fh.regressions
  -> (let R (process.run "unshare" ["-n" "--" "sh" "-c" (cn (fh.node-path) " --test tests/tc0/*.test.mjs")] (buffer.from-string "")
                         [[cwd (value fh.*workspace*)] [clear-environment true] [environment [["PATH" "/usr/bin:/bin"]]]
                          [timeout 900000] [stdout-limit 16777216]])
          Ok (and (= (hd R) ok) (process.success? (hd (tl R))))
          Lines (if (= (hd R) ok) (fh.lines (buffer.string (process.output-bytes (hd (tl R))))) [])
       (fh.step "regressions" Ok [["boundary" "network namespace and empty environment only"]
                                  ["passed" (fh.last-after "# pass " Lines "")] ["failed" (fh.last-after "# fail " Lines "")]])))

\\ Judged by agreement alone: the repaired implementation has no defect switches, so
\\ the mutant counts of this report are not meaningful here.
(define fh.exhaustive-step
  Name Tree Bound Sandbox WantClean ->
    (let Report (fh.harness-in Tree "model-vs-candidate.shen" (append [Bound (fh.subdir Name)] (if Sandbox ["sandbox"] [])) 1800)
         Programs (fh.member "programs" Report)
         Agreeing (fh.member "agreeing" Report)
         Complete (= (fh.member "scope_complete" Report) true)
         Clean (and Complete (string? Programs) (= Programs Agreeing))
         Rejected (and Complete (string? Programs) (string? Agreeing) (not (= Programs Agreeing)))
      (fh.step Name (if WantClean Clean Rejected)
               [["boundary" (if Sandbox "sandbox" "trusted defective original")] ["programs" Programs] ["agreeing" Agreeing]])))

(define fh.all-passed?
  [] -> true
  [S | Ss] -> (and (= (fh.field "status" S) "PASS") (fh.all-passed? Ss)))

(define fh.evaluate
  -> (let Manifest (fh.json-file (cn (value fh.*packet*) "workspace-manifest.json"))
          BundlePath (cn (value fh.*packet*) "failure-bundle.json")
          Bundle (fh.json-file BundlePath)
          Defective (cn (value fh.*packet*) "defective-pure-call-machine.mjs")
          Candidate (cn (value fh.*workspace*) (fh.field "candidate_path" Bundle))
          Violations (fh.violations Manifest)
          S1 (fh.step "protected-inputs"
                      (and (empty? Violations) (= (fh.sha256 (cn (value fh.*workspace*) "s3/failure-bundle.json")) (fh.sha256 BundlePath)))
                      [["violation_count" (str (length Violations))] ["violations" (fh.take 50 Violations)]])
          CandidateHash (fh.sha256 Candidate)
          S2 (fh.step "candidate-changed"
                      (and (not (= CandidateHash "")) (not (= CandidateHash (fh.field "defective_candidate_sha256" Bundle)))
                           (= (fh.sha256 Defective) (fh.field "defective_candidate_sha256" Bundle)))
                      [["candidate_sha256" CandidateHash]])
       (if (not (fh.all-passed? [S1 S2]))
           [S1 S2]
           (let Revision (fh.field "start_revision" Manifest)
                Repaired (fh.tree Revision Candidate "repaired-tree")
                Control (fh.tree Revision Defective "defective-tree")
             [S1 S2
              (fh.replay-step Repaired BundlePath Defective "original")
              (fh.replay-step Repaired BundlePath Candidate "repaired")
              (fh.agreement-step "hand-case-agreement" Repaired [] "hand")
              (fh.regressions)
              (fh.agreement-step "held-out-generated-pure-call" Repaired ["pure-call"] "generated-pure-call")
              (fh.agreement-step "held-out-generated-pure-data" Repaired ["pure-data"] "generated-pure-data")
              (fh.exhaustive-step "held-out-exhaustive-5" Repaired "5" true true)
              (fh.exhaustive-step "mutation-control-defective-4" Control "4" false false)]))))

(define fh.step-names
  Steps -> (map (/. S (fh.field "step" S)) Steps))

(define fh.main
  -> (let Steps (fh.evaluate)
          Required ["protected-inputs" "candidate-changed" "original-replay" "repaired-replay" "hand-case-agreement" "regressions"
                    "held-out-generated-pure-call" "held-out-generated-pure-data" "held-out-exhaustive-5" "mutation-control-defective-4"]
          Verdict (if (and (= (fh.step-names Steps) Required) (fh.all-passed? Steps)) "DEVELOPMENT-PASS" "FAIL")
          Report [object ["schema" "fenrir.harness.repair-evaluation/1"] ["qualification" "UNKNOWN"] ["harness" "Shen"]
                         ["verdict" Verdict]
                         ["independent_repair" "UNKNOWN: the evaluator cannot establish who authored the patch"]
                         ["steps" Steps]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 4194304]]))
           (shen-jit.exit (if (= Verdict "DEVELOPMENT-PASS") 0 1)))))

(fh.main)
