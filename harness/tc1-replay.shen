\\ Fenrir harness: strict replay of the JavaScript handler machine against model
\\ traces. Load after common.shen. Shared by tc1-strict-replay.shen and
\\ tc1-reduction.shen. The TC1 counterpart of fh.replay in common.shen: the same
\\ request format, run through tools/tc1/replay-reference.mjs, whose tapes bind the
\\ handler catalog (spec/tc1/handler-catalog.json).

\\ Cases is a list of [Name Program ReferenceSteps Mutant], Mutant a defect report key
\\ or null. Tag names the request and result files in Dir, so one directory can hold
\\ several requests. Returns the decoded result rows, or [] when the run failed.
(define fh.tc1-replay
  Tag Cases Dir Sandbox ->
    (let In (cn Dir (cn Tag "-replay-input.jsonl"))
         Out (cn Dir (cn Tag "-replay-output.jsonl"))
         Identity (json.stringify [object ["identity" [object ["evaluator" "Shen harness"]
                                    ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]]]] [])
         Written (write-to-file In (cn Identity (cn "c#10;" (fh.replay-lines Cases))))
         \\ The tape header binds the node executable's identity, so the sandbox must let it be read.
         Node (if Sandbox (fh.node-path) "")
         R (process.run "node" (fh.node-arguments "tools/tc1/replay-reference.mjs" [In Out]
                                                  (if Sandbox ["runtime/tc1" "tools/tc1" "spec/tc1" In Node] []) Out Sandbox)
                        (buffer.from-string "") [[timeout 300000]])
      (if (and (= (hd R) ok) (process.success? (hd (tl R))))
          (let View (buffer.from-string (read-file-as-string Out)) (fh.json-lines View 0 (buffer.length View) []))
          [])))

(define fh.admitted?
  R -> (and (= (fh.member "replay" R) "Exact") (= (fh.member "conformance" R) "Admitted") (= (fh.member "execution" R) "Completed")))

(define fh.diverged-at?
  Epoch R -> (and (= (fh.member "replay" R) "Exact") (= (fh.member "conformance" R) "Diverged")
                  (= (fh.member "execution" R) "StoppedAtDivergence") (= (fh.member "divergence_epoch" R) Epoch)))
