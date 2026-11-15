\\ Fenrir harness: the handler step kinds of spec/tc1/EFFECTS.md section 6, and the
\\ classification of one step of a trace under them, using only the program and the
\\ step records. Load after common.shen. Shared by tc1-coverage.shen (hand fixtures and
\\ the exhaustive-small family) and tc1-random.shen (the generated family).
\\ A measure, not a verdict.

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
