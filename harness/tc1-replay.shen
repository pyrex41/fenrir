\\ Fenrir harness, in Shen: replay the reduced TC1 handler failures that
\\ harness/tc1-reduce.shen recorded, in a fresh process. Development evidence only.
\\
\\   shen-jit script harness/tc1-replay.shen LIBDIR ROOT OUTDIR REDUCED.jsonl [sandbox]
\\
\\ OUTDIR must exist and be empty. For each recorded defect, and for both its original
\\ and its shrunk choice list:
\\   the generator gives a program of the recorded size from the list, and for the
\\     shrunk list exactly the recorded program;
\\   the validator accepts it;
\\   the model and the undefective implementation agree on it (both complete, same
\\     steps and outcome);
\\   the defective implementation completes with a different trace, and on the shrunk
\\     program first differs from the model at the recorded step.
\\ A defective run that crashes or reaches the step bound is not a replayed failure.
\\ Pass requires all of that for each of the six defects; a defect with no record fails.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(set fh.*reduced* (hd (tl (tl (tl (tl (value *argv*)))))))
(set fh.*sandbox* (= (tl (tl (tl (tl (tl (value *argv*)))))) ["sandbox"]))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "harness/tc1-defects.shen"))
(load (cn (value fh.*root*) "harness/tc1-generate.shen"))

(define fh.p-choices
  Record Which -> (map (/. C (tc0.i64.small C)) (fh.field "choices" (fh.field Which Record))))

\\ Two programs per record: [Name Artifact Nodes Choices HelperNodes].
(define fh.p-programs
  [] -> []
  [R | Rs] -> (let Defect (fh.field "defect" R)
                   Original (cn "tc1-replay-original-" Defect)
                   Shrunk (cn "tc1-replay-shrunk-" Defect)
                [[Original | (fh.generate Original (fh.p-choices R "original"))]
                 [Shrunk | (fh.generate Shrunk (fh.p-choices R "shrunk"))]
                 | (fh.p-programs Rs)]))

\\ The module name is the program's name, which differs between the runs.
(define fh.p-unnamed
  [object | Members] -> [object | (map (/. M (if (= (hd M) "module") ["module" ""] M)) Members)])

\\ The reasons a replayed program does not show the recorded failure; [] when it does.
(define fh.p-reasons
  Defect Row Nodes Recorded Epoch ->
    (if (not (= (fh.field "valid" Row) true)) ["the validator rejected the regenerated program"]
        (let Model (fh.run (fh.state (fh.field "program" Row)) (tc0.i64.small Recorded) 0 [])
             Steps (fh.canon (hd (tl Model)))
             Run (fh.member Defect (fh.field "mutants" Row))
             Verdict (fh.verdict (hd (tl Model)) Run)
          (append (if (= (fh.disagreement (fh.field "name" Row) Model (fh.field "candidate" Row)) []) []
                      ["the model and the undefective implementation do not agree"])
                  (if (= Verdict killed) [] [(make-string "the defective run is ~A, not a completed run with a different trace" Verdict)])
                  (if (or (= Epoch any) (not (= Verdict killed)) (= (fh.first-divergence Steps (fh.canon (fh.field "steps" Run)) 0) Epoch)) []
                      [(make-string "first difference at step ~A, recorded ~A" (fh.first-divergence Steps (fh.canon (fh.field "steps" Run)) 0) Epoch)])))))

\\ Rows and Generated hold the original and then the shrunk program of each record.
(define fh.p-check
  [] [] [] -> []
  [R | Rs] [Original Shrunk | Rows] [[_ _ OriginalNodes _ _] [_ Artifact ShrunkNodes _ _] | Generated] ->
    (let Defect (fh.field "defect" R)
         Reasons (append (if (= (str OriginalNodes) (fh.field "nodes" (fh.field "original" R))) [] ["the original choices no longer give a program of the recorded size"])
                         (if (= (fh.canon (fh.p-unnamed Artifact)) (fh.canon (fh.p-unnamed (fh.field "program" (fh.field "shrunk" R))))) []
                             ["the shrunk choices no longer give the recorded program"])
                         (map (/. S (cn "original: " S)) (fh.p-reasons Defect Original OriginalNodes (fh.field "step_bound" R) any))
                         (map (/. S (cn "shrunk: " S)) (fh.p-reasons Defect Shrunk ShrunkNodes (fh.field "step_bound" R) (fh.field "first_divergent_epoch" R))))
      [[Defect [object ["replayed" (empty? Reasons)] ["original_nodes" (str OriginalNodes)] ["shrunk_nodes" (str ShrunkNodes)]
                       ["first_divergent_epoch" (fh.field "first_divergent_epoch" R)] ["reasons" Reasons]]]
       | (fh.p-check Rs Rows Generated)]))

(define fh.p-failed
  [] -> []
  [[Defect Result] | Rest] -> (if (= (fh.field "replayed" Result) true) (fh.p-failed Rest) [Defect | (fh.p-failed Rest)]))

(define fh.p-absent
  [] _ -> []
  [D | Ds] Results -> (if (fh.tallied? D Results) (fh.p-absent Ds Results) [D | (fh.p-absent Ds Results)]))

(define fh.main
  -> (let View (buffer.from-string (read-file-as-string (value fh.*reduced*)))
          Records (fh.json-lines View 0 (buffer.length View) [])
          Generated (fh.p-programs Records)
          File (cn (value fh.*out*) "replay.jsonl")
          Written (fh.g-write Generated File)
          Out (cn (value fh.*out*) "js/")
          Header (if (empty? Generated) [] (fh.g-implementation File Out 1000 "mutants" (value fh.*sandbox*)))
          Results (if (empty? Generated) [] (fh.p-check Records (fh.g-rows Out Header) Generated))
          Absent (fh.p-absent (fh.defect-names) Results)
          Failed (fh.p-failed Results)
          Pass (and (empty? Absent) (empty? Failed))
          Report [object ["schema" "fenrir.harness.tc1-replay/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["reduced" (value fh.*reduced*)]
                         ["implementation_sandboxed" (value fh.*sandbox*)]
                         ["records" (str (length Records))]
                         ["programs_replayed" (str (length Generated))]
                         ["defects_without_a_record" Absent]
                         ["defects_not_replayed" Failed]
                         ["defects" [object | Results]]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
