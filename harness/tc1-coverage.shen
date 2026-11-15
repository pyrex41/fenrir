\\ Fenrir harness, in Shen: which handler reference steps the TC1 traces exercise.
\\ Maps every step of the model's traces on the hand fixtures and on the
\\ exhaustive-small family to a step kind of spec/tc1/EFFECTS.md section 6, using only the
\\ program and the step records, and lists the kinds no trace exercised.
\\ A measure, not a verdict: it does not decide which traces are evidence.
\\
\\   shen-jit script harness/tc1-coverage.shen LIBDIR ROOT HAND.jsonl EXHAUSTIVE_DIR
\\
\\ HAND.jsonl is the file harness/tc1-handlers.shen wrote and EXHAUSTIVE_DIR the batch
\\ directory harness/tc1-exhaustive.shen filled, in the same run; their programs are
\\ re-run on the model here.
\\
\\ section 6 is a table of thirteen rows. A row that names two cases is two kinds here
\\ (perform and resume dispatch; resume in and not in tail position), which gives the
\\ fifteen kinds of fh.kinds. Steps at handler forms that section 6 does not tabulate (for
\\ example unwinding a handler frame) are counted separately and never as coverage.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*hand* (hd (tl (tl (tl (value *argv*))))))
(set fh.*exhaustive* (cn (hd (tl (tl (tl (tl (value *argv*)))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))
\\ The step kinds and the classification of a step: shared with the generated family.
(load (cn (value fh.*root*) "harness/tc1-step-kinds.shen"))

\\ ---------- counting over the two batches ----------

\\ Re-run each row's program on the model and count its steps by kind.
(define fh.c-rows
  [] Counts -> Counts
  [Row | Rows] Counts ->
    (let Program (fh.field "program" Row)
         Steps (hd (tl (fh.run (fh.state Program) 200 0 [])))
      (fh.c-rows Rows (fh.c-steps Steps 0 (fh.c-functions (fh.field "functions" Program) [[] []]) Counts))))

(define fh.c-file
  Path Counts -> (let View (buffer.from-string (read-file-as-string Path))
                   (fh.c-rows (fh.json-lines View 0 (buffer.length View) []) Counts)))

(define fh.c-chunks
  I Chunks Counts -> Counts where (>= I Chunks)
  I Chunks Counts -> (fh.c-chunks (+ I 1) Chunks (fh.c-file (cn (value fh.*exhaustive*) (cn "chunk-" (cn (str I) ".jsonl"))) Counts)))

\\ ---------- report ----------

(define fh.c-number
  Kind Counts -> (let N (fh.c-find Kind Counts) (if (= N []) 0 N)))

\\ One [Kind {hand, exhaustive}] member per kind of section 6, in the table's order.
(define fh.c-table
  Hand Exhaustive -> (map (/. K [K [object ["hand" (str (fh.c-number K Hand))] ["exhaustive" (str (fh.c-number K Exhaustive))]]]) (fh.kinds)))

(define fh.c-missing
  [] _ _ -> []
  [K | Ks] Hand Exhaustive -> (if (= (+ (fh.c-number K Hand) (fh.c-number K Exhaustive)) 0)
                                  [K | (fh.c-missing Ks Hand Exhaustive)]
                                  (fh.c-missing Ks Hand Exhaustive)))

\\ Tabulated counts under a spelling that is not a kind of section 6: the classification and
\\ the table disagree, which must be looked at, not ignored.
(define fh.c-unknown
  [] -> []
  [[K _] | Rest] -> (if (element? K (fh.kinds)) (fh.c-unknown Rest) [K | (fh.c-unknown Rest)]))

(define fh.c-others
  Counts -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) Counts)])

(define fh.main
  -> (let Hand (fh.c-file (value fh.*hand*) [[] []])
          Header (json.parse (read-file-as-string (cn (value fh.*exhaustive*) "family.json")) [[byte-limit 1048576]])
          Exhaustive (fh.c-chunks 0 (tc0.i64.small (fh.field "chunks" Header)) [[] []])
          Missing (fh.c-missing (fh.kinds) (hd Hand) (hd Exhaustive))
          Unknown (append (fh.c-unknown (hd Hand)) (fh.c-unknown (hd Exhaustive)))
          Report [object ["schema" "fenrir.harness.tc1-coverage/1"]
                         ["status" (if (not (empty? Unknown)) "outside-table" (if (empty? Missing) "complete" "incomplete"))]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["table" "spec/tc1/EFFECTS.md section 6, reference steps"]
                         ["kinds" (str (length (fh.kinds)))]
                         ["covered" (str (- (length (fh.kinds)) (length Missing)))]
                         ["missing" Missing]
                         ["unknown_observed" Unknown]
                         ["steps_by_kind" [object | (fh.c-table (hd Hand) (hd Exhaustive))]]
                         ["untabulated_handler_steps" [object ["hand" (fh.c-others (hd (tl Hand)))] ["exhaustive" (fh.c-others (hd (tl Exhaustive)))]]]]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if (and (empty? Missing) (empty? Unknown)) 0 1)))))

(fh.main)
