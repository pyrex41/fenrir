\\ Fenrir typing, development runner: Shen-side validation (typing/structure.shen,
\\ typing/search.shen, typing/checker.shen) against the JavaScript validator on every
\\ program family the repository has, and bounded evidence about the checker.
\\ Development evidence only; no qualification verdict. Contract: spec/tc1/TYPING.md.
\\
\\   shen-jit script typing/run.shen LIBDIR ROOT OUTDIR
\\
\\ OUTDIR must exist and be empty. Steps:
\\  1 elaborate every program under examples/, tests/frontend/programs/ and
\\    tests/frontend/roundtrip/ with the frontend's elaborator (no validation), into
\\    OUTDIR/elaborated/;
\\  2 launch node on typing/families.mjs, which writes every family with the
\\    JavaScript validator's verdict on the exact bytes (OUTDIR/families.jsonl);
\\  3 validate every program here and compare, family by family;
\\  4 run every program Shen accepts on the Shen model and count stuck states;
\\  5 corrupt the derivations of a sample of valid programs and require the checker to
\\    reject each corruption; transplant valid derivations onto ill-typed mutants; and
\\    search with each unsound rule of typing/unsound.shen on every ill-typed program,
\\    requiring the checker to reject whatever that search builds.
\\ The report is one JSON line on standard output, also written to OUTDIR/report.json;
\\ the derivation of each frontend program is written to OUTDIR/derivations/.
\\ The probes family (typing/probes.mjs) is judged against the contract text each
\\ probe states: the Shen side must agree with every probe, and where the
\\ JavaScript side does not, the report lists it.
\\
\\ Pass requires: every program of a valid family accepted by both validators; every
\\ program of an invalid family rejected by both; the validators agreeing on every
\\ mutant; no search running out of budget; no program Shen accepts getting stuck on
\\ the model; and every forged derivation rejected.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))
(load (cn (value fh.*root*) "frontend/reader.shen"))
(load (cn (value fh.*root*) "frontend/elaborate.shen"))
(load (cn (value fh.*root*) "typing/validate.shen"))
(load (cn (value fh.*root*) "typing/unsound.shen"))

(set tr.*budget* 2000000)
(set tr.*input* ["int" "0"])
(set tr.*clock* (get-time unix))

(define tr.seconds
  -> (let Now (get-time unix) Then (value tr.*clock*) Set (set tr.*clock* Now)
       (tr.whole (str (- Now Then)))))

(define tr.whole
  (@s "." _) -> ""
  (@s C S) -> (cn C (tr.whole S))
  "" -> "")

\\ ---------- 1 frontend programs ----------

(define tr.basename
  S -> (tr.basename-in S ""))

(define tr.basename-in
  "" Acc -> Acc
  (@s "/" S) _ -> (tr.basename-in S "")
  (@s C S) Acc -> (tr.basename-in S (cn Acc C)))

(define tr.strip-fen
  ".fen" -> ""
  (@s C S) -> (cn C (tr.strip-fen S)))

(define tr.elaborate
  Dir Source -> (let Module (tr.strip-fen (tr.basename Source))
                     Cleared (set fe.*diagnostic* [])
                     Artifact (trap-error (fe.elaborate Source Module (read-file-as-bytelist (cn (value fh.*root*) Source))) (/. E []))
                  (if (= Artifact [])
                      []
                      (do (write-to-file (cn Dir (cn (tr.flat Source) ".json")) (json.stringify Artifact [[byte-limit 16777216]]))
                          [Source]))))

\\ examples/x.fen as examples-x: the three directories share some names.
(define tr.flat
  ".fen" -> ""
  (@s "/" S) -> (cn "-" (tr.flat S))
  (@s C S) -> (cn C (tr.flat S)))

(define tr.frontend
  -> (let Dir (cn (fh.subdir "elaborated") "/")
          Listing (fh.exec "sh" ["-c" "ls examples/*.fen tests/frontend/programs/*.fen tests/frontend/roundtrip/*.fen"] 60)
          Sources (tr.filter (/. L (not (= L ""))) (fh.lines (hd (tl Listing))))
          Done (tc.concat (map (/. S (tr.elaborate Dir S)) Sources))
       [Dir (length Sources) (length Done)]))

(define tr.filter
  _ [] -> []
  P [X | Xs] -> (if (P X) [X | (tr.filter P Xs)] (tr.filter P Xs)))

\\ ---------- 3 the differential ----------

\\ The Shen side's coarse class, as the JavaScript side's is written in families.mjs.
(define tr.class
  [valid _] -> "valid"
  [invalid "typing" _] -> "typing"
  [invalid "checker" _] -> "typing"
  [invalid Check _] -> (cn "structure:" Check)
  [limit Check _] -> (cn "limit:" Check)
  [unknown _] -> "unknown")

(define tr.coarse
  (@s "structure:" _) -> "structure"
  (@s "typing" _) -> "typing"
  (@s "limit:" _) -> "limit"
  "valid" -> "valid"
  X -> X)

(define tr.js-class
  Js -> (if (= (fh.field "status" Js) "valid") "valid" (fh.field "class" Js)))

\\ A family's tally: [Name Programs Agree JsValid ShenValid ClassAgree Kinds Disagreements ClassMismatches]
(define tr.tally-row
  Name [] -> [Name 0 0 0 0 0 [] [] []]
  Name [[Name | Row] | _] -> [Name | Row]
  Name [_ | Rows] -> (tr.tally-row Name Rows))

(define tr.put-row
  Row [] -> [Row]
  [Name | Row] [[Name | _] | Rows] -> [[Name | Row] | Rows]
  Row [R | Rows] -> [R | (tr.put-row Row Rows)])

(define tr.note
  Limit X Xs -> (if (< (length Xs) Limit) [X | Xs] Xs))

\\ Whether the two verdicts agree: both accept, or both reject (invalid or limit alike),
\\ and for rejections whether the coarse classes agree.
(define tr.agree?
  "valid" "valid" -> true
  "valid" _ -> false
  _ "valid" -> false
  Js Shen -> (and (not (= Shen "unknown")) (= (= (tr.coarse Js) "limit") (= (tr.coarse Shen) "limit"))))

(define tr.record
  Family Name Js Shen Verdict Rows -> (tr.record-in (tr.tally-row Family Rows) Name Js Shen Verdict Rows))

(define tr.record-in
  [Family Programs Agree JsValid ShenValid ClassAgree Kinds Bad Mismatch] Name Js Shen Verdict Rows ->
    (let Agrees (tr.agree? Js Shen)
         Same (= (tr.coarse Js) (tr.coarse Shen))
         Item [object ["name" Name] ["javascript" Js] ["shen" Shen] ["shen_detail" (tr.detail Verdict)]]
      (tr.put-row [Family (+ Programs 1) (if Agrees (+ Agree 1) Agree) (if (= Js "valid") (+ JsValid 1) JsValid)
                   (if (= Shen "valid") (+ ShenValid 1) ShenValid) (if Same (+ ClassAgree 1) ClassAgree)
                   (fh.count-key Shen Kinds)
                   (if Agrees Bad (tr.note 20 Item Bad))
                   (if (or (not Agrees) Same) Mismatch (tr.note 20 Item Mismatch))]
                  Rows)))

(define tr.detail
  [valid _] -> "accepted"
  [_ A B] -> (make-string "~A: ~A" A B)
  [_ A] -> (make-string "~A" A))

\\ ---------- 4 type safety on the model ----------

(define tr.model-run
  A -> (trap-error (hd (fh.run (fh.state A) 200 0 [])) (/. E "Stuck")))

\\ ---------- 5 forged derivations ----------

\\ Every path to a node of D, as lists of premise indices.
(define tr.paths
  [R C Ps] Prefix -> [(reverse Prefix) | (tr.paths-in Ps 0 Prefix)])

(define tr.paths-in
  [] _ _ -> []
  [P | Ps] I Prefix -> (append (tr.paths P [I | Prefix]) (tr.paths-in Ps (+ I 1) Prefix)))

(define tr.replace
  D [] F -> (F D)
  [R C Ps] [I | Is] F -> [R C (tr.replace-nth Ps I Is F)])

(define tr.replace-nth
  [P | Ps] 0 Is F -> [(tr.replace P Is F) | Ps]
  [P | Ps] I Is F -> [P | (tr.replace-nth Ps (- I 1) Is F)])

(define tr.other-type
  "Bool" -> "I64"
  _ -> "Bool")

\\ The corruptions of one node, as [Kind Node'] pairs; a corruption that leaves the
\\ node as it was is dropped by the caller.
(define tr.corruptions
  [R C Ps] -> (append [["wrong-rule-name" ["T-Bogus" C Ps]] ["other-rule-name" [(tr.next-rule R) C Ps]]]
                      (tr.premise-corruptions R C Ps)
                      (tr.conclusion-corruptions R C Ps)))

(define tr.next-rule
  R -> (tr.after R ["Program" "Function" "P-Base" "P-Tuple" "P-Data" "P-Assumed" "T-Unit" "T-Bool" "T-Int" "T-Bytes" "T-Var" "T-Let" "T-If"
                    "T-Prim" "T-Eq" "T-Tuple" "T-Project" "T-Construct" "T-Match" "T-Emit" "T-Lambda" "T-Apply" "T-Call" "T-Perform"
                    "T-Handle" "T-Resume" "T-Discontinue" "Program"]))

(define tr.after
  R [R Next | _] -> Next
  R [_ | Rs] -> (tr.after R Rs)
  _ [] -> "Program")

(define tr.premise-corruptions
  R C [P1 P2 | Ps] -> [["swapped-premises" [R C [P2 P1 | Ps]]] ["dropped-premise" [R C [P2 | Ps]]] ["extra-premise" [R C [P1 P1 P2 | Ps]]]]
  R C [P] -> [["dropped-premise" [R C []]] ["extra-premise" [R C [P P]]]]
  R C [] -> [["extra-premise" [R C [["T-Unit" ["expr" [] ["unit" "0"] "Unit" [] []] []]]]]])

(define tr.conclusion-corruptions
  R ["expr" G E T F K] Ps ->
    (append [["altered-type" [R ["expr" G E (tr.other-type T) F K] Ps]]
             ["weakened-context" [R ["expr" [["999999" "I64"] | G] E T F K] Ps]]
             ["added-use" [R ["expr" G E T F (append K ["999999"])] Ps]]
             ["added-effect" [R ["expr" G E T (tc.union F ["Emit"]) K] Ps]]]
            (if (cons? F) [["dropped-effect" [R ["expr" G E T (tl F) K] Ps]]] [])
            (if (cons? K) [["dropped-use" [R ["expr" G E T F (tl K)] Ps]]] []))
  R ["plain" Ds T] Ps -> [["altered-type" [R ["plain" Ds ["Tuple" T (tr.other-type T)]] Ps]]]
  _ _ _ -> [])

\\ Check every corruption of every node of D against A: [Total Rejected Kinds Accepted]
(define tr.forge
  A D Acc -> (tr.forge-paths A D (tr.paths D []) Acc))

(define tr.forge-paths
  _ _ [] Acc -> Acc
  A D [Path | Paths] Acc ->
    (tr.forge-paths A D Paths (tr.forge-node A D Path (tr.corruptions (tr.at D Path)) Acc)))

(define tr.at
  D [] -> D
  [_ _ Ps] [I | Is] -> (tr.at (nth (+ I 1) Ps) Is))

(define tr.forge-node
  _ _ _ [] Acc -> Acc
  A D Path [[Kind Node] | Cs] Acc ->
    (let Forged (tr.replace D Path (/. Old Node))
      (tr.forge-node A D Path Cs (if (= Forged D) Acc (tr.forged Kind (tc.check A (value tr.*input*) Forged) Path Acc)))))

(define tr.forged
  Kind Accepted Where [Total Rejected Kinds Bad] ->
    [(+ Total 1) (if Accepted Rejected (+ Rejected 1)) (fh.count-key Kind Kinds)
     (if Accepted (tr.note 20 [object ["kind" Kind] ["path" (map (/. I (str I)) Where)]] Bad) Bad)])

\\ The derivation of program S placed on artifact M: root and function conclusions rewritten.
(define tr.transplant
  ["Program" ["well-typed" _ V] Ps] M -> ["Program" ["well-typed" M V] (tr.transplant-functions Ps (tc.f "functions" M))])

(define tr.transplant-functions
  [["Function" ["function" _] Body] | Ps] [F | Fs] -> [["Function" ["function" F] Body] | (tr.transplant-functions Ps Fs)]
  [P | Ps] Fs -> [P | (tr.transplant-functions Ps Fs)]
  [] _ -> [])

(define tr.seed-name
  (@s " " _) -> ""
  (@s C S) -> (cn C (tr.seed-name S))
  "" -> "")

\\ ---------- the main loop ----------

\\ The sample: the hand fixtures, the generated and frontend programs, and every 97th
\\ exhaustive program, which are also the seeds of typing/mutate.mjs.
(define tr.sample?
  Family Name -> (or (element? Family ["tc0-hand" "tc1-hand" "generated-pure-call" "generated-pure-data" "frontend"])
                     (and (element? Family ["exhaustive-5" "tc1-exhaustive-7"]) (= 0 (tr.mod (tr.suffix Name 0) 97)))))

(define tr.suffix
  "" N -> N
  (@s "-" S) _ -> (tr.suffix S 0)
  (@s D S) N -> (tr.suffix S (+ (* N 10) (- (string->n D) 48))))

(define tr.mod
  N M -> (if (< N M) N (tr.mod (- N M) M)))

\\ State: [Rows Model Seeds Forge Transplant Unsound Index Unknowns]
(define tr.step
  L [Rows Model Seeds Forge Transplant Unsound Index Unknowns] ->
    (let Family (fh.field "family" L)
         Name (fh.field "name" L)
         Text (fh.field "text" L)
         Verdict (tv.validate Text (value tr.*input*) (value tr.*budget*))
         Js (tr.js-class (fh.field "js" L))
         Shen (tr.class Verdict)
         Rows1 (tr.record Family Name Js Shen Verdict Rows)
         A (if (= (hd Verdict) valid) (hd (tl (st.check Text))) [])
         Model1 (if (= (hd Verdict) valid) (fh.count-key (tr.model-run A) Model) Model)
         Sampled (and (= (hd Verdict) valid) (tr.sample? Family Name))
         Seeds1 (if Sampled [[Name (hd (tl Verdict))] | Seeds] Seeds)
         Forge1 (if Sampled (tr.forge A (hd (tl Verdict)) Forge) Forge)
         IllTyped (and (= Shen "typing") (= (tr.coarse Js) "typing"))
         Transplant1 (if IllTyped (tr.transplant-one Name Text Seeds1 Transplant) Transplant)
         Unsound1 (if IllTyped (tr.unsound-all Text Unsound) Unsound)
         Written (if (and (= Family "frontend") (= (hd Verdict) valid))
                     (write-to-file (cn (value tr.*derivations*) (cn Name ".json")) (json.stringify (hd (tl Verdict)) [[byte-limit 67108864]]))
                     skip)
         Probe (if (= Family "probes") (tr.probe Name (fh.field "contract" L) (fh.field "status" (fh.field "js" L)) Verdict) skip)
      [Rows1 Model1 Seeds1 Forge1 Transplant1 Unsound1 (+ Index 1) (if (= Shen "unknown") (+ Unknowns 1) Unknowns)]))

\\ A probe's verdicts against what the contract text makes of it.
(set tr.*probes* [])

(define tr.status
  [valid _] -> "valid"
  [limit _ _] -> "limit"
  [unknown _] -> "unknown"
  _ -> "invalid")

(define tr.probe
  Name Contract Js Verdict ->
    (set tr.*probes* [[object ["name" Name] ["contract" Contract] ["javascript" Js] ["shen" (tr.status Verdict)]
                              ["shen_detail" (tr.detail Verdict)]] | (value tr.*probes*)]))

(define tr.probe-departs?
  Side [object ["name" _] ["contract" C] ["javascript" J] ["shen" S] _] -> (not (= C (if (= Side javascript) J S))))

(define tr.transplant-one
  Name Text Seeds [Total Rejected] ->
    (let D (fh.assoc-or (tr.seed-name Name) Seeds)
         M (hd (tl (st.check Text)))
      (if (= D none) [Total Rejected]
          [(+ Total 1) (if (tc.check M (value tr.*input*) (tr.transplant D M)) Rejected (+ Rejected 1))])))

(define fh.assoc-or
  K [[K V] | _] -> V
  K [_ | Rows] -> (fh.assoc-or K Rows)
  _ [] -> none)

\\ Unsound: [[Rule Searched Found Rejected] ...]
(define tr.unsound-all
  Text Rows -> (map (/. Row (tr.unsound-one Text Row)) Rows))

(define tr.unsound-one
  Text [Rule Searched Found Rejected] ->
    (let A (hd (tl (st.check Text)))
         On (include [Rule])
         D (ts.derive A (value tr.*input*) (value tr.*budget*))
         Off (preclude [Rule])
         Built (not (element? (hd D) [no-derivation unknown]))
      [Rule (+ Searched 1) (if Built (+ Found 1) Found)
       (if (and Built (not (tc.check A (value tr.*input*) D))) (+ Rejected 1) Rejected)]))

(define tr.lines
  V I End State -> State where (>= I End)
  V I End State ->
    (let Next (fh.next-line V I End)
         Count (- (- Next I) (if (and (> Next I) (= (buffer.u8 V (- Next 1)) 10)) 1 0))
      (tr.lines V Next End (if (= Count 0) State (tr.step (json.decode (buffer.slice V I Count) [[byte-limit 16777216]]) State)))))

(define tr.families-row
  [Name Programs Agree JsValid ShenValid ClassAgree Kinds Bad Mismatch] ->
    [object ["family" Name] ["programs" (str Programs)] ["agreeing" (str Agree)]
            ["javascript_valid" (str JsValid)] ["shen_valid" (str ShenValid)] ["same_rejection_class" (str ClassAgree)]
            ["shen_verdicts" (fh.counts Kinds)] ["disagreements" (reverse Bad)] ["class_mismatches" (reverse Mismatch)]])

(define fh.counts
  Pairs -> [object | (map (/. P [(hd P) (str (hd (tl P)))]) Pairs)])

\\ Probes are judged against the contract text instead (tr.probe-departs?).
(define tr.expected-ok?
  _ "probe" -> true
  [Name Programs Agree JsValid ShenValid _ _ _ _] Expect ->
    (and (= Agree Programs)
         (if (= Expect "valid") (and (= JsValid Programs) (= ShenValid Programs))
             (if (= Expect "invalid") (and (= JsValid 0) (= ShenValid 0)) true))))

(define tr.expect
  "pure-data-invalid" -> "invalid"
  "handler-test-rejections" -> "invalid"
  "invalid-resynced" -> "invalid"
  "mutants" -> "mutant"
  "probes" -> "probe"
  _ -> "valid")

(define tr.main
  -> (let Frontend (tr.frontend)
          Derivations (set tr.*derivations* (cn (fh.subdir "derivations") "/"))
          T1 (tr.seconds)
          Families (fh.exec "node" [(cn (value fh.*root*) "typing/families.mjs") (value fh.*out*) (hd Frontend)] 900)
          Ran (if (= (hd Families) 0) true (error "typing: typing/families.mjs did not complete: ~A" (hd (tl (tl Families)))))
          T2 (tr.seconds)
          View (buffer.from-string (read-file-as-string (cn (value fh.*out*) "families.jsonl")))
          Unsound [[fenrir-unsound-anything 0 0 0] [fenrir-unsound-resume 0 0 0] [fenrir-unsound-perform 0 0 0]]
          State (tr.lines View 0 (buffer.length View) [[] [] [] [0 0 [] []] [0 0] Unsound 0 0])
          T3 (tr.seconds)
       (tr.report Frontend T1 T2 T3 State)))

(define tr.report
  Frontend T1 T2 T3 [Rows Model Seeds [FTotal FRejected FKinds FBad] [TTotal TRejected] UnsoundRows _ Unknowns] ->
     (let FamiliesOk (tc.every? (/. Row (tr.expected-ok? Row (tr.expect (hd Row)))) Rows)
          Stuck (fh.assoc-or "Stuck" Model)
          UnsoundOk (tc.every? (/. Row (= (nth 3 Row) (nth 4 Row))) UnsoundRows)
          Probes (reverse (value tr.*probes*))
          ShenDeparts (tr.filter (/. P (tr.probe-departs? shen P)) Probes)
          JsDeparts (tr.filter (/. P (tr.probe-departs? javascript P)) Probes)
          Pass (and (= (nth 2 Frontend) (nth 3 Frontend)) FamiliesOk (= Unknowns 0) (= Stuck none) (= ShenDeparts [])
                    (= FTotal FRejected) (= TTotal TRejected) UnsoundOk)
          Report [object ["schema" "fenrir.typing.differential/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["claim" "derivable under rule set R (spec/tc1/TYPING.md), soundness not yet proved"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["frontend_programs" [object ["sources" (str (nth 2 Frontend))] ["elaborated" (str (nth 3 Frontend))]]]
                         ["families" (map (/. Row (tr.families-row Row)) (reverse Rows))]
                         ["probes" [object ["count" (str (length Probes))]
                                           ["shen_departs_from_contract" ShenDeparts]
                                           ["javascript_departs_from_contract" JsDeparts]
                                           ["all" Probes]]]
                         ["search_budget_inferences" (str (value tr.*budget*))]
                         ["search_unknown" (str Unknowns)]
                         ["model_runs_of_accepted_programs" (fh.counts Model)]
                         ["forged_derivations" [object ["seeds" (str (length Seeds))] ["corruptions" (str FTotal)] ["rejected" (str FRejected)]
                                                       ["by_kind" (fh.counts FKinds)] ["accepted" (reverse FBad)]]]
                         ["transplanted_derivations" [object ["programs" (str TTotal)] ["rejected" (str TRejected)]]]
                         ["unsound_search" (map (/. Row [object ["rule" (str (hd Row))] ["ill_typed_programs" (str (nth 2 Row))]
                                                                ["derivations_built" (str (nth 3 Row))] ["rejected_by_checker" (str (nth 4 Row))]])
                                                UnsoundRows)]
                         ["seconds" [object ["elaboration" T1] ["javascript" T2] ["shen" T3]]]]
          Text (json.stringify Report [[byte-limit 16777216]])
       (do (write-to-file (cn (value fh.*out*) "report.json") Text)
           (output "~A~%" Text)
           (shen-jit.exit (if Pass 0 1)))))


(tr.main)
