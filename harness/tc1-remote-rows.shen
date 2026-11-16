\\ Rows of the TC1 gate for remote perform (contract spec/tc1/EFFECTS.md §12):
\\   remote-model  bounded exploration of the model models/tc1/remote-system.shen,
\\                 its mutants, hand schedules and a negative control
\\                 (harness/tc1-remote.shen, as harness/run-tc1-remote.sh runs it);
\\   remote-run    the real system, an Erlang/OTP supervisor and two Solo5 guests on
\\                 the spt tender, under schedules, each recorded run judged by the
\\                 model (harness/tc1-remote-run.shen, as
\\                 harness/run-tc1-remote-run.sh runs it). The caller image is
\\                 built from the source file examples/remote/ledger-caller.fen
\\                 through the frontend (tools/solo5/remote-build.mjs).
\\ Also the Erlang half of the gate's toolchain row. Load after gate-core.shen.
\\ Each check runs as its own process. In both rows the negative control runs
\\ first and its result is handed to the check, which passes only if the control
\\ failed, with a failure exit status.

\\ ---------- the scope the gate requires ----------
\\ The numbers of systems explored, model mutants and hand schedules of the model
\\ check, and of hand schedules, seeds, free runs and defect switches of the run
\\ check. A report with other numbers is not this gate's check: UNKNOWN. The
\\ manifest's acceptance text states the same numbers.

(define fh.remote-model-systems -> 10)
(define fh.remote-model-mutants -> 13)
(define fh.remote-model-hand -> 19)
(define fh.remote-run-hand -> 24)
(define fh.remote-run-seeds -> 40)
(define fh.remote-run-free -> 4)
(define fh.remote-run-defects -> 8)

\\ ---------- Erlang/OTP ----------

\\ [Erl Erlc] as harness/find-erlang.sh finds them, or [].
(define fh.erlang
  -> (let R (fh.exec "sh" [(cn (value fh.*root*) "harness/find-erlang.sh")] 1800)
          Lines (fh.remote-nonempty (map (/. L (fh.trim L)) (fh.lines (hd (tl R)))))
       (if (and (= (hd R) 0) (= (length Lines) 2)) Lines [])))

(define fh.remote-nonempty
  [] -> []
  ["" | Ls] -> (fh.remote-nonempty Ls)
  [L | Ls] -> [L | (fh.remote-nonempty Ls)])

(define fh.real
  Path -> (fh.trim (hd (tl (fh.exec "realpath" [Path] 30)))))

\\ The toolchain row of this gate: the shared Shen/JIT check, and then the
\\ Erlang/OTP the supervisor would be compiled and run with must be the flake's
\\ erlang output. No nix, no such output, or no Erlang at all: BLOCKED. Another
\\ Erlang (FENRIR_ERLANG, or one on PATH): UNKNOWN.
(define fh.tc1-toolchain-pinned
  Memo -> (fh.erlang-pinned (fh.toolchain-pinned Memo)))

(define fh.erlang-pinned
  ["PASS" Reasons Detail Memo] ->
    (let Built (fh.exec "nix" ["build" "--no-link" "--print-out-paths" ".#erlang"] 1800)
         Pinned (fh.trim (hd (tl Built)))
         Found (fh.erlang)
      (if (not (= (hd Built) 0))
          (fh.row "BLOCKED" ["nix could not build the flake's erlang output"] Detail Memo)
          (if (= Found [])
              (fh.row "BLOCKED" ["Erlang/OTP is not available (FENRIR_ERLANG, the flake's erlang output, or erl and erlc on PATH)"] Detail Memo)
              (if (and (= (fh.real (hd Found)) (fh.real (cn Pinned "/bin/erl")))
                       (= (fh.real (hd (tl Found))) (fh.real (cn Pinned "/bin/erlc"))))
                  (fh.row "PASS" Reasons (append Detail [["erlang" Pinned]]) Memo)
                  (fh.row "UNKNOWN" [(make-string "The supervisor would be built and run with ~A, not the pinned ~A" (hd Found) Pinned)] Detail Memo)))))
  Row -> Row)

\\ ---------- negative controls ----------

\\ Run a check in its control mode. It must report failure and exit with status 1.
(define fh.remote-control
  Script Args Seconds ->
    (let R (fh.exec (value fh.*jit*) (append ["script" (cn (value fh.*root*) (cn "harness/" Script)) (value fh.*lib*) (value fh.*root*)] Args) Seconds)
      (if (and (= (hd R) 1) (= (fh.member "status" (fh.last-report (hd (tl R)))) "development-fail"))
          "failed-as-required"
          "not-failed")))

(define fh.remote-listed
  What [] -> []
  What Names -> [(cn What (fh.join (map (/. N (if (string? N) N (json.stringify N []))) Names) ", "))])

\\ ---------- remote-model ----------

(define fh.remote-violating
  [] -> []
  [System | Systems] -> (if (= (fh.member "violations" System) "0")
                            (fh.remote-violating Systems)
                            [(fh.member "system" System) | (fh.remote-violating Systems)]))

(define fh.remote-model-reasons
  Report ->
    (append (fh.remote-listed "A property of EFFECTS.md section 12.8 fails in the model on: " (fh.remote-violating (fh.member "systems" Report)))
            (fh.remote-listed "Model mutants not killed on the property they are aimed at: " (fh.member "mutants_not_killed" Report))
            (fh.remote-listed "Step kinds no explored schedule takes: " (fh.member "step_kinds_not_exercised" Report))
            (fh.remote-listed "Hand schedules failed: " (fh.member "hand_schedules_failed" Report))
            (if (= (fh.member "negative_control" Report) "failed-as-required") [] ["The negative control did not fail: the checker passed a non-idempotent peer"])))

(define fh.remote-states
  Systems -> (json.stringify (map (/. S [object ["system" (fh.member "system" S)] ["states" (fh.member "states" S)]
                                               ["transitions" (fh.member "transitions" S)] ["schedules" (fh.member "schedules" S)]])
                                  Systems) []))

(define fh.tc1-remote-model
  Memo ->
    (let Control (fh.remote-control "tc1-remote.shen" ["negative-control"] 900)
         Report (fh.harness "tc1-remote.shen" ["check" Control] 1800)
         Status (fh.member "status" Report)
      (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.tc1-remote/1")))
          (fh.row "UNKNOWN" ["The remote-perform model check did not report"] [] Memo)
          (let Reasons (fh.remote-model-reasons Report)
            (if (or (= Status "development-fail") (not (empty? Reasons)))
                (fh.row "FAIL" (if (empty? Reasons) ["The remote-perform model check reports failure"] Reasons) [] Memo)
                (if (or (not (= (length (fh.member "systems" Report)) (fh.remote-model-systems)))
                        (not (= (length (fh.member "mutants" Report)) (fh.remote-model-mutants)))
                        (not (= (fh.member "hand_schedules" Report) (str (fh.remote-model-hand)))))
                    (fh.row "UNKNOWN" ["The model check did not cover the required systems, mutants and hand schedules"] [] Memo)
                    (if (= Status "development-pass")
                        (fh.row "PASS" []
                                [["evidence" "model-level bounded exploration; no implementation is run"]
                                 ["systems" (fh.remote-states (fh.member "systems" Report))]
                                 ["mutants_killed" (str (length (fh.member "mutants" Report)))]
                                 ["hand_schedules" (fh.member "hand_schedules" Report)]
                                 ["negative_control" Control]]
                                Memo)
                        (fh.row "UNKNOWN" ["The remote-perform model check did not report a status"] [] Memo))))))))

\\ ---------- remote-run ----------

(define fh.remote-free-failed
  [] -> []
  [Run | Runs] -> (if (= (fh.member "passed" Run) true) (fh.remote-free-failed Runs) [(fh.member "run" Run) | (fh.remote-free-failed Runs)]))

(define fh.remote-run-reasons
  Report ->
    (append (fh.remote-listed "Hand schedules not accepted: " (fh.member "hand_schedules_failed" Report))
            (fh.remote-listed "Seeded schedules not accepted: " (fh.member "seeded_failed" Report))
            (fh.remote-listed "Free-running runs not accepted: " (fh.remote-free-failed (fh.member "free_runs" Report)))
            (fh.remote-listed "Defects of the real system not killed: " (fh.member "defects_not_killed" Report))
            (fh.remote-listed "Step kinds no recorded run takes: " (fh.member "step_kinds_not_exercised" Report))
            (if (= (fh.member "negative_control" Report) "failed-as-required") [] ["The negative control did not fail: the checker passed a non-idempotent peer image"])))

(define fh.remote-run-scope?
  Report -> (let Hand (fh.remote-run-hand)
                 Seeds (fh.remote-run-seeds)
                 Free (fh.remote-run-free)
              (and (= (fh.member "hand_schedules" Report) (str Hand))
                   (= (fh.member "seeded_schedules" Report) (str Seeds))
                   (= (length (fh.member "free_runs" Report)) Free)
                   (= (length (fh.member "defects" Report)) (fh.remote-run-defects))
                   (= (fh.member "schedules_accepted" Report) (str (+ Hand (+ Seeds Free))))
                   (= (fh.member "abi" Report) "spt"))))

(define fh.tc1-remote-run
  Memo -> (fh.remote-run-with (fh.erlang) Memo))

\\ No Erlang, or images that cannot be built (no Solo5 at the pinned commit): BLOCKED,
\\ as the guest rows are without Solo5. A supervisor that does not compile with the
\\ Erlang found, or a check that does not report: UNKNOWN.
(define fh.remote-run-with
  [] Memo -> (fh.row "BLOCKED" ["Erlang/OTP is not available (FENRIR_ERLANG, the flake's erlang output, or erl and erlc on PATH)"] [] Memo)
  [Erl Erlc] Memo ->
    (let Out (fh.subdir "tc1-remote-run")
         Images (fh.exec "node" [(cn (value fh.*root*) "tools/solo5/remote-build.mjs") "--out" (cn Out "/images")] 900)
      (if (not (= (hd Images) 0))
          (fh.row "BLOCKED" ["The remote-perform images could not be built (is build/vendor/solo5 built at the pinned commit? does the frontend elaborate examples/remote/ledger-caller.fen?)"] [] Memo)
          (let Compiled (fh.exec "sh" [(cn (value fh.*root*) "supervisor/build.sh") Erlc (cn Out "/ebin")] 600)
            (if (not (= (hd Compiled) 0))
                (fh.row "UNKNOWN" ["The supervisor did not compile with the Erlang/OTP found"] [["erlc" Erlc]] Memo)
                (fh.remote-run-judged Erl Out Memo))))))

(define fh.remote-run-judged
  Erl Out Memo ->
    (let Common [(cn Out "/images") (cn Out "/ebin") Erl]
         Control (fh.remote-control "tc1-remote-run.shen" (append Common [(fh.subdir "tc1-remote-run/control") "negative-control"]) 600)
         Report (fh.harness "tc1-remote-run.shen" (append Common [(fh.subdir "tc1-remote-run/check") "check" Control]) 1800)
         Status (fh.member "status" Report)
      (if (or (= Report []) (not (= (fh.member "schema" Report) "fenrir.harness.tc1-remote-run/1")))
          (fh.row "UNKNOWN" ["The remote-perform run check did not report"] [] Memo)
          (let Reasons (fh.remote-run-reasons Report)
            (if (or (= Status "development-fail") (not (empty? Reasons)))
                (fh.row "FAIL" (if (empty? Reasons) ["The remote-perform run check reports failure"] Reasons)
                        [["defects" (json.stringify (fh.member "defects" Report) [])]] Memo)
                (if (not (fh.remote-run-scope? Report))
                    (fh.row "UNKNOWN" ["The run check did not cover the required schedules and defects on the spt tender, or not every schedule was accepted"] [] Memo)
                    (if (= Status "development-pass")
                        (fh.row "PASS" []
                                [["evidence" "observed histories on spt accepted by the model; no hvt run; no proof"]
                                 ["schedules_accepted" (fh.member "schedules_accepted" Report)]
                                 ["hand_schedules" (fh.member "hand_schedules" Report)]
                                 ["seeded_schedules" (fh.member "seeded_schedules" Report)]
                                 ["seeded_steps" (fh.member "seeded_steps" Report)]
                                 ["free_runs" (str (length (fh.member "free_runs" Report)))]
                                 ["defects_killed" (str (length (fh.member "defects" Report)))]
                                 ["steps_by_kind" (json.stringify (fh.member "steps_by_kind" Report) [])]
                                 ["negative_control" Control]
                                 ["solo5_commit" (fh.member "solo5_commit" Report)]
                                 ["tender_sha256" (fh.member "tender_sha256" Report)]
                                 ["caller_source" (fh.member "caller_source" Report)]
                                 ["caller_source_sha256" (fh.member "caller_source_sha256" Report)]
                                 ["caller_declaration" (fh.member "caller_declaration" Report)]
                                 ["peer_declaration" (fh.member "peer_declaration" Report)]
                                 ["caller_sha256" (fh.member "caller_sha256" Report)]
                                 ["peer_sha256" (fh.member "peer_sha256" Report)]
                                 ["erl" Erl]]
                                Memo)
                        (fh.row "UNKNOWN" ["The remote-perform run check did not report a status"] [] Memo))))))))
