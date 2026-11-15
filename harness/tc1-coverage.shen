\\ Fenrir harness, in Shen: catalog coverage for TC1 handlers. Maps every handler
\\ step of the model's traces on the hand fixtures, the exhaustive-small family and the
\\ generated family to a transition of the versioned handler catalog
\\ (spec/tc1/handler-catalog.json), using only the program and the step records,
\\ checks each step's depth change against its transition, and lists the transitions
\\ no trace exercised. A measure, not a verdict: it does not decide which traces are
\\ evidence.
\\
\\   shen-jit script harness/tc1-coverage.shen LIBDIR ROOT CATALOG SHA256 HAND.jsonl EXHAUSTIVE_DIR GENERATED_DIR
\\
\\ CATALOG is read only when its file digest is SHA256, the digest the caller pins: an
\\ edited catalog is not measured against. HAND.jsonl is the file harness/tc1-handlers.shen
\\ wrote, EXHAUSTIVE_DIR and GENERATED_DIR the batch directories harness/tc1-exhaustive.shen
\\ and harness/tc1-generated.shen filled, in the same run; their programs are re-run on
\\ the model here.
\\
\\ Status: catalog-mismatch (digest or version differs), outside-catalog (a handler step
\\ with no transition, or a step whose depth change contradicts its transition),
\\ incomplete (a transition no trace exercised), complete.
\\ Steps at TC0-A forms and frames are the TC0-A catalog's (spec/tc0/pure-call-demo.json):
\\ they are counted as inherited and not classified here.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*args* (tl (tl (tl (value *argv*)))))
(set fh.*catalog* (nth 1 (value fh.*args*)))
(set fh.*catalog-sha* (nth 2 (value fh.*args*)))
(set fh.*hand* (nth 3 (value fh.*args*)))
(set fh.*exhaustive* (cn (nth 4 (value fh.*args*)) "/"))
(set fh.*generated* (cn (nth 5 (value fh.*args*)) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

(define fh.c-version -> "tc1-handler-catalog/1")
(define fh.c-fuel -> 1000)

\\ ---------- the program's shape, from the decoded artifact ----------
\\ Facts is [Forms Roots]. Forms maps each node to its form: "handle", "perform",
\\ "resume, in tail position", "resume, not in tail position", "discontinue", "let", "if",
\\ "match", "strict" (prim, tuple, project, construct, emit) or "call" (call, apply).
\\ Roots maps the root node of each clause body to its clause form.
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
  ["let" Node _ Init Body] Tail Facts -> (fh.c-walk Body Tail (fh.c-walk Init false (fh.c-note Node "let" Facts)))
  ["if" Node C Y N] Tail Facts -> (fh.c-walk N Tail (fh.c-walk Y Tail (fh.c-walk C false (fh.c-note Node "if" Facts))))
  ["match" Node E | Arms] Tail Facts -> (fh.c-arms Arms Tail (fh.c-walk E false (fh.c-note Node "match" Facts)))
  ["lambda" _ _ _ _ _ _ Body] _ Facts -> (fh.c-walk Body true Facts)
  ["call" Node _ Arg] _ Facts -> (fh.c-walk Arg false (fh.c-note Node "call" Facts))
  ["apply" Node | Es] _ Facts -> (fh.c-all Es false (fh.c-note Node "call" Facts))
  ["emit" Node _ Arg] _ Facts -> (fh.c-walk Arg false (fh.c-note Node "strict" Facts))
  ["project" Node E _] _ Facts -> (fh.c-walk E false (fh.c-note Node "strict" Facts))
  ["tuple" Node | Es] _ Facts -> (fh.c-all Es false (fh.c-note Node "strict" Facts))
  ["prim" Node _ | Es] _ Facts -> (fh.c-all Es false (fh.c-note Node "strict" Facts))
  ["construct" Node _ _ | Es] _ Facts -> (fh.c-all Es false (fh.c-note Node "strict" Facts))
  _ _ Facts -> Facts)

(define fh.c-functions
  [] Facts -> Facts
  [F | Fs] Facts -> (fh.c-functions Fs (fh.c-walk (fh.field "body" F) true Facts)))

\\ ---------- one step to its transition ----------

\\ The value under Key, or [] when there is none.
(define fh.c-find
  _ [] -> []
  Key [[Key V] | _] -> V
  Key [_ | Rest] -> (fh.c-find Key Rest))

(define fh.c-node
  Step -> (fh.member "node" (fh.field "site" Step)))

(define fh.c-resume?
  Form -> (element? Form ["resume, in tail position" "resume, not in tail position"]))

\\ A catalog key, spelled as in the catalog; [outside Description] for a step at a handler
\\ form, or an AbandonFrame step, that the catalog cannot have; [] for a TC0-A step.
\\ Before is the depth before the step; Next is the following step, or [].
(define fh.c-kind
  "Dispatch" Form Step _ _ _ -> (make-string "Dispatch ~A -> ~A" Form (fh.field "after" Step))
    where (element? Form ["handle" "perform" "discontinue"])
  "Dispatch" Form Step _ _ _ -> (make-string "Dispatch resume -> ~A" (fh.field "after" Step)) where (fh.c-resume? Form)
  "CollectReturn" "perform" Step _ _ _ -> (make-string "CollectReturn perform -> ~A" (fh.field "after" Step))
  "CollectReturn" Form Step _ _ _ -> (make-string "CollectReturn resume -> ~A" (fh.field "after" Step)) where (fh.c-resume? Form)
  "Ready" "perform" Step _ Next Roots ->
    (let Clause (if (= Next []) [] (fh.c-find (fh.c-node Next) Roots))
      (if (= Clause []) [outside "Ready perform that enters no clause body"]
          (make-string "Ready perform, clause ~A -> ~A" Clause (fh.field "after" Step))))
  "Ready" Form Step _ _ _ -> (make-string "Ready ~A -> ~A" Form (fh.field "after" Step))
    where (or (fh.c-resume? Form) (= Form "discontinue"))
  Rule _ Step _ _ _ -> (make-string "~A -> ~A" Rule (fh.field "after" Step))
    where (element? Rule ["ClauseReturn" "ClauseExitReturn" "ResumeReturn" "DiscontinueReturn" "HandleReturn"])
  "AbandonFrame" Form Step Before _ _ -> (fh.c-frame "AbandonFrame" Form Step Before)
  "UnwindFrame" Form Step Before _ _ -> (fh.c-frame "UnwindFrame" Form Step Before)
    where (or (element? Form ["handle" "perform" "discontinue"]) (fh.c-resume? Form))
  _ Form _ _ _ _ -> [outside (cn "a step at a node of form " Form)] where (or (element? Form ["handle" "perform" "discontinue"]) (fh.c-resume? Form))
  _ _ _ _ _ _ -> [])

\\ AbandonFrame (any frame) and UnwindFrame (handler frames) by the form of the frame's node.
(define fh.c-frame
  Rule Form Step Before ->
    (let After (fh.field "after" Step)
         Kind (fh.c-frame-kind Form Step Before)
      (if (= Kind []) [outside (make-string "~A at a node of form ~A" Rule Form)]
          (make-string "~A at ~A -> ~A" Rule Kind After))))

(define fh.c-frame-kind
  "let" _ _ -> "a let frame"
  "if" _ _ -> "an if frame"
  "match" _ _ -> "a match frame"
  "strict" _ _ -> "an operand collection of a strict form"
  "call" _ _ -> "a call or apply node, collection or return frame"
  "handle" _ _ -> "a handler frame"
  "perform" Step Before -> (if (>= (tc0.i64.small (fh.field "depth" Step)) Before)
                               "a clause frame" "a perform node, collection or clause-exit frame")
  Form _ _ -> "a resume node, collection or resume-return frame" where (fh.c-resume? Form)
  _ _ _ -> [])

\\ ---------- the depth change a transition allows ----------

(define fh.c-depth-ok?
  "+1" D -> (= D 1)
  "0" D -> (= D 0)
  "-1" D -> (= D -1)
  "<=0" D -> (<= D 0)
  ">=0" D -> (>= D 0)
  ">=+1" D -> (>= D 1)
  ">=+2" D -> (>= D 2)
  _ _ -> false)

\\ Counts is [Covered Outside Violations Inherited]: Covered and Outside lists of [Key N],
\\ Violations a list of descriptions, Inherited a number.
(define fh.c-count
  [] _ _ [C O V I] -> [C O V (+ I 1)]
  [outside Description] _ _ [C O V I] -> [C (fh.count-key Description O) V I]
  Key Delta Catalog [C O V I] ->
    (let Depth (fh.c-find Key Catalog)
      (if (= Depth [])
          [C (fh.count-key Key O) V I]
          (if (fh.c-depth-ok? Depth Delta)
              [(fh.count-key Key C) O V I]
              [C O (if (> (length V) 20) V [(make-string "~A with depth change ~A, allowed ~A" Key Delta Depth) | V]) I]))))

(define fh.c-steps
  [] _ _ _ Counts -> Counts
  [Step | Steps] Before [Forms Roots] Catalog Counts ->
    (let Node (fh.c-node Step)
         Form (if (= Node []) [] (fh.c-find Node Forms))
         Depth (tc0.i64.small (fh.field "depth" Step))
         Kind (fh.c-kind (fh.field "rule" (fh.field "site" Step)) Form Step Before (if (= Steps []) [] (hd Steps)) Roots)
      (fh.c-steps Steps Depth [Forms Roots] Catalog (fh.c-count Kind (- Depth Before) Catalog Counts))))

\\ Re-run each row's program on the model and count its steps by transition.
(define fh.c-rows
  [] _ Counts -> Counts
  [Row | Rows] Catalog Counts ->
    (let Program (fh.field "program" Row)
         Steps (hd (tl (fh.run (fh.state Program) (fh.c-fuel) 0 [])))
      (fh.c-rows Rows Catalog (fh.c-steps Steps 0 (fh.c-functions (fh.field "functions" Program) [[] []]) Catalog Counts))))

(define fh.c-file
  Path Catalog Counts -> (let View (buffer.from-string (read-file-as-string Path))
                           (fh.c-rows (fh.json-lines View 0 (buffer.length View) []) Catalog Counts)))

(define fh.c-chunks
  Dir I Chunks Catalog Counts -> Counts where (>= I Chunks)
  Dir I Chunks Catalog Counts -> (fh.c-chunks Dir (+ I 1) Chunks Catalog (fh.c-file (cn Dir (cn "chunk-" (cn (str I) ".jsonl"))) Catalog Counts)))

(define fh.c-batch
  Dir Catalog -> (let Header (json.parse (read-file-as-string (cn Dir "family.json")) [[byte-limit 1048576]])
                   (fh.c-chunks Dir 0 (tc0.i64.small (fh.field "chunks" Header)) Catalog [[] [] [] 0])))

\\ ---------- report ----------

(define fh.c-number
  Key Counts -> (let N (fh.c-find Key Counts) (if (= N []) 0 N)))

(define fh.c-table
  Keys Hand Exhaustive Generated ->
    (map (/. K [K [object ["hand" (str (fh.c-number K (hd Hand)))] ["exhaustive" (str (fh.c-number K (hd Exhaustive)))]
                          ["generated" (str (fh.c-number K (hd Generated)))]]]) Keys))

(define fh.c-missing
  [] _ -> []
  [K | Ks] Sets -> (if (= 0 (fh.c-sum K Sets)) [K | (fh.c-missing Ks Sets)] (fh.c-missing Ks Sets)))

(define fh.c-sum
  _ [] -> 0
  K [Counts | Sets] -> (+ (fh.c-number K (hd Counts)) (fh.c-sum K Sets)))

(define fh.c-pairs
  Counts -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) Counts)])

(define fh.c-catalog
  Transitions -> (map (/. T [(fh.field "key" T) (fh.field "depth" T)]) Transitions))

(define fh.c-measure
  Catalog Keys ->
    (let Hand (fh.c-file (value fh.*hand*) Catalog [[] [] [] 0])
         Exhaustive (fh.c-batch (value fh.*exhaustive*) Catalog)
         Generated (fh.c-batch (value fh.*generated*) Catalog)
         Sets [Hand Exhaustive Generated]
         Missing (fh.c-missing Keys Sets)
         Outside (append (nth 2 Hand) (append (nth 2 Exhaustive) (nth 2 Generated)))
         Violations (append (nth 3 Hand) (append (nth 3 Exhaustive) (nth 3 Generated)))
         Status (if (or (not (empty? Outside)) (not (empty? Violations))) "outside-catalog" (if (empty? Missing) "complete" "incomplete"))
      [Status
       [["transitions" (str (length Keys))]
        ["covered" (str (- (length Keys) (length Missing)))]
        ["missing" Missing]
        ["outside_catalog" [object ["hand" (fh.c-pairs (nth 2 Hand))] ["exhaustive" (fh.c-pairs (nth 2 Exhaustive))] ["generated" (fh.c-pairs (nth 2 Generated))]]]
        ["depth_violations" Violations]
        ["inherited_tc0_a_steps" [object ["hand" (str (nth 4 Hand))] ["exhaustive" (str (nth 4 Exhaustive))] ["generated" (str (nth 4 Generated))]]]
        ["steps_by_transition" [object | (fh.c-table Keys Hand Exhaustive Generated)]]]]))

(define fh.main
  -> (let Digest (fh.sha256 (value fh.*catalog*))
          Catalog (json.parse (read-file-as-string (value fh.*catalog*)) [[byte-limit 1048576]])
          Matches (and (= Digest (value fh.*catalog-sha*)) (= (fh.field "version" Catalog) (fh.c-version)))
          Transitions (fh.c-catalog (fh.field "transitions" Catalog))
          Measured (if Matches (fh.c-measure Transitions (map (/. T (hd T)) Transitions)) ["catalog-mismatch" []])
          Status (hd Measured)
          Report [object ["schema" "fenrir.harness.tc1-coverage/2"]
                         ["status" Status]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["catalog" (fh.relative-path (value fh.*catalog*))]
                         ["catalog_version" (fh.field "version" Catalog)]
                         ["catalog_sha256" Digest]
                         ["catalog_sha256_pinned" (value fh.*catalog-sha*)]
                         | (hd (tl Measured))]
       (do (output "~A~%" (json.stringify Report [[byte-limit 1048576]]))
           (shen-jit.exit (if (= Status "complete") 0 1)))))

(define fh.relative-path
  Path -> (if (fh.starts? (value fh.*root*) Path) (fh.drop (value fh.*root*) Path) Path))

(fh.main)
