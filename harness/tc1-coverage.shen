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

\\ ---------- the step kinds of EFFECTS.md section 6 ----------

(define fh.kinds
  -> ["Dispatch handle -> Eval"
      "Dispatch perform -> Eval"
      "Dispatch resume -> Eval"
      "Ready perform, clause op(x) -> Eval"
      "Ready perform, clause op(x,k) -> Eval"
      "ClauseReturn -> Value"
      "ClauseExitReturn -> Value"
      "Ready resume, not in tail position -> Value"
      "Ready resume, in tail position -> Value"
      "ResumeReturn -> Value"
      "Ready discontinue -> Abandon"
      "AbandonFrame -> Abandon"
      "DiscontinueReturn -> Value"
      "HandleReturn -> Value"
      "UnwindFrame at a clause frame -> Unwind"])

\\ ---------- the program's shape, from the decoded artifact ----------
\\ Facts is [Forms Roots]. Forms maps the node of each handler form to "handle",
\\ "perform", "discontinue", "resume, in tail position" or "resume, not in tail
\\ position". Roots maps the root node of each clause body to its clause form.
\\ Tail is whether the expression is entered with its own return destination: a
\\ function, lambda or clause body, a handle body, and the body of a let or a branch
\\ of an if or match in such a position (EFFECTS.md section 4, tail positions).

(define fh.c-note
  Node Form [Forms Roots] -> [[[Node Form] | Forms] Roots])

(define fh.c-all
  [] _ Facts -> Facts
  [E | Es] Tail Facts -> (fh.c-all Es Tail (fh.c-walk E Tail Facts)))

(define fh.c-clauses
  [] Facts -> Facts
  [[_ _ Body] | Clauses] [Forms Roots] -> (fh.c-clauses Clauses (fh.c-walk Body true [Forms [[(hd (tl Body)) "op(x)"] | Roots]]))
  [[_ _ _ Body] | Clauses] [Forms Roots] -> (fh.c-clauses Clauses (fh.c-walk Body true [Forms [[(hd (tl Body)) "op(x,k)"] | Roots]])))

(define fh.c-arms
  [] _ Facts -> Facts
  [[_ _ Body] | Arms] Tail Facts -> (fh.c-arms Arms Tail (fh.c-walk Body Tail Facts)))

(define fh.c-walk
  ["handle" Node _ Clauses Body] _ Facts -> (fh.c-walk Body true (fh.c-clauses Clauses (fh.c-note Node "handle" Facts)))
  ["perform" Node _ _ Arg] _ Facts -> (fh.c-walk Arg false (fh.c-note Node "perform" Facts))
  ["resume" Node _ Arg] Tail Facts ->
    (fh.c-walk Arg false (fh.c-note Node (if Tail "resume, in tail position" "resume, not in tail position") Facts))
  ["discontinue" Node _] _ Facts -> (fh.c-note Node "discontinue" Facts)
  ["let" _ _ Init Body] Tail Facts -> (fh.c-walk Body Tail (fh.c-walk Init false Facts))
  ["if" _ C Y N] Tail Facts -> (fh.c-walk N Tail (fh.c-walk Y Tail (fh.c-walk C false Facts)))
  ["match" _ E | Arms] Tail Facts -> (fh.c-arms Arms Tail (fh.c-walk E false Facts))
  ["lambda" _ _ _ _ _ _ Body] _ Facts -> (fh.c-walk Body true Facts)
  ["call" _ _ Arg] _ Facts -> (fh.c-walk Arg false Facts)
  ["emit" _ _ Arg] _ Facts -> (fh.c-walk Arg false Facts)
  ["project" _ E _] _ Facts -> (fh.c-walk E false Facts)
  ["apply" _ | Es] _ Facts -> (fh.c-all Es false Facts)
  ["tuple" _ | Es] _ Facts -> (fh.c-all Es false Facts)
  ["prim" _ _ | Es] _ Facts -> (fh.c-all Es false Facts)
  ["construct" _ _ _ | Es] _ Facts -> (fh.c-all Es false Facts)
  _ _ Facts -> Facts)

(define fh.c-functions
  [] Facts -> Facts
  [F | Fs] Facts -> (fh.c-functions Fs (fh.c-walk (fh.field "body" F) true Facts)))

\\ ---------- one step to its kind ----------

\\ The value under Key, or [] when there is none.
(define fh.c-find
  _ [] -> []
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.c-find Key Rest))

(define fh.c-node
  Step -> (fh.member "node" (fh.field "site" Step)))

\\ A kind of section 6 is returned as it is spelled in fh.kinds; a step at a handler form
\\ that section 6 does not tabulate as [other Description]; any other step as [].
\\ Before is the depth before the step; Next is the following step, or [].
\\   Ready perform: the clause form is that of the clause whose body the next step enters.
\\   UnwindFrame at a perform node: a clause frame gives back its segment, at least the
\\     handler frame, so the depth does not fall; a collect or clause-exit frame is popped.
(define fh.c-kind
  "Dispatch" Form Step _ _ _ -> (make-string "Dispatch ~A -> ~A" Form (fh.field "after" Step)) where (element? Form ["handle" "perform"])
  "Dispatch" "discontinue" _ _ _ _ -> [other "Dispatch discontinue -> Ready"]
  "Dispatch" Form Step _ _ _ -> (make-string "Dispatch resume -> ~A" (fh.field "after" Step)) where (not (= Form []))
  "Ready" "perform" Step _ Next Roots ->
    (let Clause (if (= Next []) [] (fh.c-find (fh.c-node Next) Roots))
      (if (= Clause []) [other "Ready perform that enters no clause body"]
          (make-string "Ready perform, clause ~A -> ~A" Clause (fh.field "after" Step))))
  "Ready" "discontinue" Step _ _ _ -> (make-string "Ready discontinue -> ~A" (fh.field "after" Step))
  "Ready" Form Step _ _ _ -> (make-string "Ready ~A -> ~A" Form (fh.field "after" Step)) where (not (element? Form [[] "handle"]))
  "UnwindFrame" "perform" Step Before _ _ ->
    (if (>= (tc0.i64.small (fh.field "depth" Step)) Before)
        "UnwindFrame at a clause frame -> Unwind"
        [other "UnwindFrame at a perform node, collect or clause-exit frame"])
  "UnwindFrame" Form _ _ _ _ -> [other (cn "UnwindFrame at a frame of " Form)] where (not (= Form []))
  "CollectReturn" Form Step _ _ _ -> [other (make-string "CollectReturn ~A -> ~A" Form (fh.field "after" Step))] where (not (= Form []))
  "AbandonFrame" _ _ _ _ _ -> "AbandonFrame -> Abandon"
  Rule _ Step _ _ _ -> (make-string "~A -> ~A" Rule (fh.field "after" Step))
    where (element? Rule ["ClauseReturn" "ClauseExitReturn" "ResumeReturn" "DiscontinueReturn" "HandleReturn"])
  _ _ _ _ _ _ -> [])

\\ Counts is [Tabulated Other], each a list of [Kind N].
(define fh.c-count
  [] Counts -> Counts
  [other Description] [Tabulated Other] -> [Tabulated (fh.count-key Description Other)]
  Kind [Tabulated Other] -> [(fh.count-key Kind Tabulated) Other])

(define fh.c-steps
  [] _ _ Counts -> Counts
  [Step | Steps] Before [Forms Roots] Counts ->
    (let Node (fh.c-node Step)
         Form (if (= Node []) [] (fh.c-find Node Forms))
         Kind (fh.c-kind (fh.field "rule" (fh.field "site" Step)) Form Step Before (if (= Steps []) [] (hd Steps)) Roots)
      (fh.c-steps Steps (tc0.i64.small (fh.field "depth" Step)) [Forms Roots] (fh.c-count Kind Counts))))

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
