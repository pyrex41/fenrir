\\ Certificates for the TC0 checked-`add` property, run through Búri's executable
\\ checker buri.contract-check (shen/contract-cert.shen at Búri 47491e2).
\\
\\ Load AFTER Búri's shen/base.shen and shen/contract-cert.shen, on Búri's pinned
\\ host (Shen-Scheme v0.52, kernel 43.1), with fu.extracted set to the path of
\\ extracted.kl, fu.rocq-out to the Rocq file to write (the same certificates
\\ for Búri's Rocq checker) and fu.cert-out to the file that receives the
\\ accepted fragment certificate as data (check.sh does this):
\\   scripts/shen -l shen/base.shen -l shen/contract-cert.shen \
\\     -e '(set fu.extracted "...")' -e '(set fu.rocq-out "...")' \
\\     -e '(set fu.cert-out "...")' -l certify.shen
\\
\\ Nothing here decides validity. Skeletons are synthesised (deterministically,
\\ from the syntax of each body), handed to buri.contract-check as inert data, and
\\ the verdicts are compared with the expected ones. Every verdict line starts
\\ with FU-RESULT; the run ends with FU-CERT-OK N or FU-CERT-FAIL.

\\ ---------------------------------------------------------------------------
\\ Reading extracted.kl (written by extract.shen on Shen/JIT).
(define fu.section
  Tag [fu-begin Tag | Rest] -> (fu.section-defs Rest)
  Tag [_ | Rest] -> (fu.section Tag Rest)
  Tag [] -> (simple-error "certify: section missing"))
(define fu.section-defs
  [fu-end | _] -> []
  [fu-def _ D | Rest] -> [D | (fu.section-defs Rest)]
  [_ | Rest] -> (fu.section-defs Rest)
  [] -> (simple-error "certify: unterminated section"))
(define fu.section-covered
  Tag [fu-begin Tag | Rest] -> (fu.covered-defs Rest)
  Tag [_ | Rest] -> (fu.section-covered Tag Rest))
(define fu.covered-defs
  [fu-end | _] -> []
  [fu-def covered D | Rest] -> [D | (fu.covered-defs Rest)]
  [_ | Rest] -> (fu.covered-defs Rest))

(define fu.say Fmt X -> (do (set *maximum-print-sequence-size* 1000000) (output Fmt X) (set *maximum-print-sequence-size* 20) done))
\\ The reader turns each printed [...] into a (cons ...) form; undo that, so
\\ the data is exactly the list structure extract.shen printed.
(define fu.unread [cons A B] -> [(fu.unread A) | (fu.unread B)] X -> X)
(set fu.data (map (/. F (fu.unread F)) (read-file (value fu.extracted))))
(set fu.all-defs (fu.section arithmetic (value fu.data)))
(set fu.covered (fu.section-covered add (value fu.data)))
(define fu.names Defs -> (map (/. D (hd D)) Defs))

\\ ---------------------------------------------------------------------------
\\ Skeleton synthesis. Leaf choice: a KLambda primitive is discharged by its
\\ proved primitive contract; a function of the program is a recursive leaf;
\\ every other callee (kernel functions, and model functions left out of the
\\ program) is a named host contract, i.e. a premise. `cond`, `and` and `or`
\\ have no rule in BURI/KL-CONTRACT-1, so synthesis yields `no-rule` there.
(define fu.leaf
  Names F -> [rule aj_ctx [[prim F]]] where (buri.member? F (buri.cc-prim-names))
  Names F -> [rule aj_ctx [[rec F]]] where (buri.member? F Names)
  Names F -> [rule aj_ctx [[hyp F]]])
(define fu.sk
  Leaf [let _ A B] -> [rule r_let [(fu.sk Leaf A) (fu.sk Leaf B)]]
  Leaf [if C A B] -> [rule r_if [(fu.sk Leaf C) (fu.sk Leaf A) (fu.sk Leaf B)]]
  Leaf [type A] -> [rule r_type [(fu.sk Leaf A)]]
  Leaf [call F []] -> [rule r_call0 [(Leaf F)]]
  Leaf [call F Args] -> [rule r_call [(Leaf F) | (map (/. A (fu.sk Leaf A)) Args)]]
  Leaf [app H []] -> [rule r_app0 [(fu.sk Leaf H) [rule aj_sem [[side "application"]]]]]
  Leaf [app H Args] -> [rule r_app [(fu.sk Leaf H) [rule aj_sem [[side "application"]]] | (map (/. A (fu.sk Leaf A)) Args)]]
  Leaf [trap A H] -> [rule r_trap [(fu.sk Leaf A) (fu.sk Leaf H) [rule aj_sem [[side "handler"]]]]]
  Leaf [defun _ _ _] -> [rule r_defun []]
  Leaf [cond _] -> no-rule
  Leaf [and _ _] -> no-rule
  Leaf [or _ _] -> no-rule
  Leaf E -> [rule r_val []] where (buri.cc-atomic? E)
  _ _ -> no-rule)
(define fu.leaves Sk -> (if (= Sk no-rule) [] (buri.cc-leaves Sk)))
(define fu.hyps Sks -> (fu.dedup (buri.cc-select hyp (fu.concat (map (/. S (fu.leaves S)) Sks))) []))
(define fu.recs Sks -> (fu.dedup (buri.cc-select rec (fu.concat (map (/. S (fu.leaves S)) Sks))) []))
(define fu.concat [] -> [] [X | Xs] -> (buri.append X (fu.concat Xs)))
(define fu.dedup [] Acc -> (buri.rev Acc)
  [X | Xs] Acc -> (fu.dedup Xs Acc) where (buri.member? X Acc)
  [X | Xs] Acc -> (fu.dedup Xs [X | Acc]))

\\ The ground instance of checked addition, written exactly as the `add`
\\ clause of tc0.arithmetic computes it, on a literal pair.
(define fu.add-main A B ->
  [call "tc0.i64.checked" [[call "tc0.i64.add" [[call "tc0.i64.parse" [[str A]]] [call "tc0.i64.parse" [[str B]]]]]]])
(define fu.arith-main A B ->
  [call "tc0.arithmetic" [[sym "add"] [call "cons" [[str A] [call "cons" [[str B] [nil]]]]]]])
(set fu.max "9223372036854775807")

(define fu.program Defs Main -> [program Defs Main])
(define fu.cert-for Stmt Leaf Hyps [program Defs Main] ->
  (let Bodies (map (/. D [(hd D) (fu.sk Leaf (hd (tl (tl D))))]) Defs)
       MainSk (fu.sk Leaf Main)
       Sks [MainSk | (map (/. B (hd (tl B))) Bodies)]
       Recs (fu.recs Sks)
    [contract-certificate "buri-contract-1" (buri.cc-theory)
      [program "fenrir-tc0-add" (buri.cc-fingerprint [program Defs Main])] (buri.cc-evaluator)
      [statement Stmt total] [hypotheses Hyps] [measures (map (/. F [F "fenrir-unused-measure"]) Recs)]
      [bodies Bodies] [main MainSk]]))
(define fu.std-leaf Defs -> (/. F (fu.leaf (fu.names Defs) F)))
(define fu.cert Stmt Prog ->
  (let Defs (hd (tl Prog)) Leaf (fu.std-leaf Defs)
       Sks [(fu.sk Leaf (hd (tl (tl Prog)))) | (map (/. D (fu.sk Leaf (hd (tl (tl D))))) Defs)]
    (fu.cert-for Stmt Leaf (fu.hyps Sks) Prog)))

\\ Certificate surgery for the negative controls.
(define fu.set-field
  Tag V [contract-certificate | Fields] -> [contract-certificate | (fu.set-in Tag V Fields)])
(define fu.set-in
  _ _ [] -> []
  Tag V [[Tag | _] | Fs] -> [[Tag | V] | Fs]
  Tag V [F | Fs] -> [F | (fu.set-in Tag V Fs)])
(define fu.get-field
  Tag [contract-certificate | Fields] -> (fu.get-in Tag Fields))
(define fu.get-in
  Tag [[Tag | V] | _] -> V
  Tag [_ | Fs] -> (fu.get-in Tag Fs))
(define fu.replace-def
  Name Body [] -> []
  Name Body [[Name Ps _] | Ds] -> [[Name Ps Body] | Ds]
  Name Body [D | Ds] -> [D | (fu.replace-def Name Body Ds)])
(define fu.subst-tree
  Old New Old -> New
  Old New [X | Xs] -> [(fu.subst-tree Old New X) | (fu.subst-tree Old New Xs)]
  _ _ X -> X)
(define fu.digits-expr [] -> [nil]
  [D | Ds] -> [call "cons" [[num D] (fu.digits-expr Ds)]])

\\ ---------------------------------------------------------------------------
\\ Results.
(set fu.count 0)
(set fu.failed false)
(define fu.verdict-head [accepted | _] -> accepted [rejected R] -> [rejected R] X -> X)
(define fu.report Name Want Got ->
  (do (set *maximum-print-sequence-size* 1000000) (output "FU-RESULT ~A ~S~%" Name Got)
      (set *maximum-print-sequence-size* 20)
      (if (= Want (fu.verdict-head Got))
          (set fu.count (+ (value fu.count) 1))
          (do (set fu.failed true) (output "FU-MISMATCH ~A wanted ~S~%" Name Want)))))
(define fu.premises [accepted _ Hyps _ _] -> Hyps _ -> none)
(define fu.obligations [accepted _ _ _ Os] -> Os _ -> none)

\\ (1) The largest fragment that goes through: every rule-covered definition in
\\     the closure of tc0.arithmetic, and the ground `add` instance at the
\\     overflow boundary as main. The other 22 model functions and the kernel
\\     functions are host contracts (premises).
(set fu.frag (fu.program (value fu.covered) (fu.add-main (value fu.max) "1")))
(set fu.frag-cert (fu.cert "fenrir-tc0-checked-add-in-i64-or-overflow" (value fu.frag)))
(set fu.frag-verdict (buri.contract-check (value fu.frag) (value fu.frag-cert)))
(fu.report fragment accepted (value fu.frag-verdict))
(fu.say "FU-PREMISES ~S~%" (fu.premises (value fu.frag-verdict)))
(fu.say "FU-OBLIGATIONS ~S~%" (fu.obligations (value fu.frag-verdict)))

\\ (2) The whole closure: 32 definitions, main = (tc0.arithmetic add [max "1"]).
(set fu.full (fu.program (value fu.all-defs) (fu.arith-main (value fu.max) "1")))
(define fu.contains X X -> true
  X [Y | Ys] -> (or (fu.contains X Y) (fu.contains X Ys))
  _ _ -> false)
(define fu.no-rule? B -> (fu.contains no-rule (fu.sk (/. X [hyp X]) B)))
(define fu.uncovered-names [] -> []
  [[F _ B] | Ds] -> [F | (fu.uncovered-names Ds)] where (fu.no-rule? B)
  [_ | Ds] -> (fu.uncovered-names Ds))
(fu.say "FU-NO-RULE ~S~%" (fu.uncovered-names (value fu.all-defs)))
\\ Synthesis gives no skeleton for cond/and/or; give those bodies a placeholder
\\ and let the checker judge the whole certificate.
(define fu.full-cert Prog ->
  (let C (fu.cert "fenrir-tc0-checked-add-in-i64-or-overflow" Prog)
    (fu.subst-tree no-rule [rule r_conseq [[rule r_val []]]] C)))
(fu.report full-closure [rejected body-shape] (buri.contract-check (value fu.full) (fu.full-cert (value fu.full))))
\\ Everything as premise: the program is empty and tc0.arithmetic itself is a
\\ host contract. Accepted; it says only that the main expression is a call.
(fu.report arithmetic-as-premise accepted
  (buri.contract-check (fu.program [] (fu.arith-main (value fu.max) "1"))
     (fu.subst-tree no-rule [rule r_conseq [[rule r_val []]]]
        (fu.cert "s" (fu.program [] (fu.arith-main (value fu.max) "1"))))))

\\ Bounded search: no skeleton of the enumerated class (every rule at the root
\\ with up to three children from five leaf shapes, and every rule over one
\\ such skeleton) fits any of the cond/and/or bodies. (The reason is in buri.cc-fits: no clause matches
\\ [cond ...], [and ...] or [or ...] except the structural rules, which pass
\\ the same expression down; so no skeleton of any size fits.)
(set fu.rules (map (/. R (intern R)) (buri.cc-rules)))
(set fu.l0 [[rule r_val []] [side "s"] [prim "cons"] [hyp "h"] [rec "tc0.i64.digit"]])
(define fu.lists 0 _ -> [[]]
  N Xs -> [[] | (fu.concat (map (/. X (map (/. T [X | T]) (fu.lists (- N 1) Xs))) Xs))])
(define fu.dedup-lists Ls -> (fu.dedup Ls []))
(set fu.subs3 (fu.dedup-lists (fu.lists 3 (value fu.l0))))
(set fu.s1 (fu.concat (map (/. R (map (/. S [rule R S]) (value fu.subs3))) (value fu.rules))))
(set fu.s2 (fu.concat (map (/. R (map (/. S [rule R [S]]) (value fu.s1))) (value fu.rules))))
(set fu.candidates (buri.append (value fu.s1) (value fu.s2)))
(define fu.fitting Bs E [] N -> N
  Bs E [S | Ss] N -> (fu.fitting Bs E Ss (if (buri.cc-fits Bs S [some E]) (+ N 1) N)))
(define fu.search [] _ -> 0
  [[F _ B] | Ds] Bs -> (+ (fu.fitting Bs B (value fu.candidates) 0) (fu.search Ds Bs))
    where (fu.no-rule? B)
  [_ | Ds] Bs -> (fu.search Ds Bs))
(set fu.found (fu.search (value fu.all-defs) (buri.cc-closure-bodies (value fu.full))))
(output "FU-SEARCH ~A candidate skeletons per body, ~A bodies, ~A fit~%" (length (value fu.candidates))
  (length (fu.uncovered-names (value fu.all-defs))) (value fu.found))
(if (= 0 (value fu.found)) (set fu.count (+ (value fu.count) 1)) (set fu.failed true))

\\ (3) Negative controls.
\\ (3a) A false statement: the same skeletons under the name of a false contract.
(fu.report false-statement-same-skeletons accepted
  (buri.contract-check (value fu.frag)
    (fu.set-field statement ["fenrir-tc0-checked-add-can-return-2^63" total] (value fu.frag-cert))))
\\ (3b) The injected off-by-one I64 bound (README: max-mag = 2^63 instead of
\\      2^63 - 1). A certificate for the mutated model, built the same way.
(set fu.mutant-defs (fu.replace-def "tc0.i64.max-mag"
   (fu.digits-expr [8 0 8 5 7 7 4 5 8 6 3 0 2 7 3 3 2 2 9]) (value fu.covered)))
(set fu.mutant (fu.program (value fu.mutant-defs) (fu.add-main (value fu.max) "1")))
(fu.report off-by-one-model-own-certificate accepted
  (buri.contract-check (value fu.mutant) (fu.cert "fenrir-tc0-checked-add-in-i64-or-overflow" (value fu.mutant))))
(fu.report off-by-one-model-original-certificate [rejected stale-program]
  (buri.contract-check (value fu.mutant) (value fu.frag-cert)))
\\ (3c) Corrupted certificates.
(set fu.fp (hd (tl (fu.get-field program (value fu.frag-cert)))))
(fu.report corrupt-fingerprint [rejected stale-program]
  (buri.contract-check (value fu.frag) (fu.set-field program ["fenrir-tc0-add" (+ 1 (value fu.fp))] (value fu.frag-cert))))
(fu.report corrupt-theory [rejected stale-theory]
  (buri.contract-check (value fu.frag) (fu.set-field theory ["BURI/KL-CONTRACT-1" 1] (value fu.frag-cert))))
(fu.report corrupt-rule [rejected body-shape]
  (buri.contract-check (value fu.frag) (fu.subst-tree r_call r_if (value fu.frag-cert))))
(fu.report undeclared-premise [rejected undeclared-hypothesis]
  (buri.contract-check (value fu.frag) (fu.set-field hypotheses [(tl (hd (fu.get-field hypotheses (value fu.frag-cert))))] (value fu.frag-cert))))
(fu.report unknown-primitive [rejected unknown-primitive]
  (buri.contract-check (value fu.frag) (fu.subst-tree [prim "cons"] [prim "launch"] (value fu.frag-cert))))
(fu.report missing-measures [rejected missing-measure]
  (buri.contract-check (value fu.frag) (fu.set-field measures [[]] (value fu.frag-cert))))
(fu.report forged-label [rejected forged-label]
  (buri.contract-check (value fu.frag) (fu.set-field hypotheses [[accepted]] (value fu.frag-cert))))
\\ (3d) Leaf naming is not checked: a call to ANY global function may be
\\      discharged by a primitive's contract. Discharging every host callee with
\\      [prim "cons"] yields an acceptance that reports no premises at all.
(set fu.cons-leaf (/. F (if (buri.member? F (fu.names (value fu.covered))) [rule aj_ctx [[rec F]]] [rule aj_ctx [[prim "cons"]]])))
(set fu.mislabel (fu.cert-for "fenrir-tc0-checked-add-in-i64-or-overflow" (value fu.cons-leaf) [] (value fu.frag)))
(set fu.mislabel-verdict (buri.contract-check (value fu.frag) (value fu.mislabel)))
(fu.report host-calls-discharged-as-cons accepted (value fu.mislabel-verdict))
(fu.say "FU-MISLABEL-PREMISES ~S~%" (fu.premises (value fu.mislabel-verdict)))
(set fu.launch (fu.program (value fu.covered) [call "launch-missiles" [[num 1]]]))
(set fu.launch-verdict (buri.contract-check (value fu.launch)
   (fu.cert-for "harmless" (value fu.cons-leaf) [] (value fu.launch))))
(fu.report undefined-function-discharged-as-cons accepted (value fu.launch-verdict))
(fu.say "FU-LAUNCH-PREMISES ~S~%" (fu.premises (value fu.launch-verdict)))

\\ ---------------------------------------------------------------------------
\\ The same certificates as Rocq terms, for ContractCert.check (Búri's Rocq checker).
(define fu.cat [] -> "" [S | Ss] -> (cn S (fu.cat Ss)))
(define fu.find-def F [[F | R] | _] -> [F | R]
  F [_ | Ds] -> (fu.find-def F Ds))
(define fu.z N -> (if (< N 0) (fu.cat ["(" (str N) ")%Z"]) (cn (str N) "%Z")))
(define fu.seq F [] -> "[]"
  F [X | Xs] -> (fu.cat ["[" (F X) (fu.seq-rest F Xs) "]"]))
(define fu.seq-rest F [] -> "" F [X | Xs] -> (fu.cat ["; " (F X) (fu.seq-rest F Xs)]))
(define fu.rq S -> (fu.cat ["(t c#34;" S "c#34;)"]))
(define fu.res Es -> (fu.seq (/. E (fu.re E)) Es))
(define fu.re
  [num Z] -> (fu.cat ["(ENum (NInt " (fu.z Z) "))"])
  [str S] -> (fu.cat ["(EStr " (fu.rq S) ")"])
  [sym S] -> (fu.cat ["(ESym " (fu.rq S) ")"])
  [bool true] -> "(EBool true)"
  [bool false] -> "(EBool false)"
  [nil] -> "ENil"
  [var X] -> (fu.cat ["(EVar " (fu.rq X) ")"])
  [lambda X B] -> (fu.cat ["(ELam " (fu.rq X) " " (fu.re B) ")"])
  [let X A B] -> (fu.cat ["(ELet " (fu.rq X) " " (fu.re A) " " (fu.re B) ")"])
  [if C A B] -> (fu.cat ["(EIf " (fu.re C) " " (fu.re A) " " (fu.re B) ")"])
  [and A B] -> (fu.cat ["(EAnd " (fu.re A) " " (fu.re B) ")"])
  [or A B] -> (fu.cat ["(EOr " (fu.re A) " " (fu.re B) ")"])
  [cond Cs] -> (fu.cat ["(ECond " (fu.seq (/. C (fu.cat ["(" (fu.re (hd C)) ", " (fu.re (hd (tl C))) ")"])) Cs) ")"])
  [trap A H] -> (fu.cat ["(ETrap " (fu.re A) " " (fu.re H) ")"])
  [freeze A] -> (fu.cat ["(EFreeze " (fu.re A) ")"])
  [type A] -> (fu.cat ["(EType " (fu.re A) ")"])
  [app H As] -> (fu.cat ["(EApp " (fu.re H) " " (fu.res As) ")"])
  [call F As] -> (fu.cat ["(ECall " (fu.rq F) " " (fu.res As) ")"]))
(define fu.rdef [F Ps B] -> (fu.cat ["(" (fu.rq F) ", " (fu.seq (/. P (fu.rq P)) Ps) ", " (fu.re B) ")"]))
(define fu.rprog [program Defs Main] -> (fu.cat ["(Program " (fu.seq (/. D (fu.rdef D)) Defs) " " (fu.re Main) ")"]))
(define fu.rname
  r_val -> "RVal" r_unbound -> "RUnbound" r_let -> "RLet" r_if -> "RIf" r_type -> "RType"
  r_defun -> "RDefun" r_defun_bad -> "RDefunBad" r_trap -> "RTrap" r_app -> "RApp" r_app0 -> "RApp0"
  r_call -> "RCall" r_call0 -> "RCall0" r_conseq -> "RConseq" r_exists -> "RExists" r_frame -> "RFrame"
  aj_sem -> "AjSem" aj_ctx -> "AjCtx" aj_partial -> "AjPartial" aj_lam -> "AjLam" aj_frozen -> "AjFrozen")
(define fu.rsk
  [rule R Subs] -> (fu.cat ["(SRule " (fu.rname R) " " (fu.seq (/. S (fu.rsk S)) Subs) ")"])
  [hyp S] -> (fu.cat ["(SHyp " (fu.rq S) ")"])
  [prim S] -> (fu.cat ["(SPrim " (fu.rq S) ")"])
  [rec S] -> (fu.cat ["(SRec " (fu.rq S) ")"])
  [side S] -> (fu.cat ["(SSide " (fu.rq S) ")"]))
(define fu.rpair [A B] -> (fu.cat ["(" (fu.rq A) ", " (fu.z B) ")"]))
(define fu.rtext-pair [A B] -> (fu.cat ["(" (fu.rq A) ", " (fu.rq B) ")"]))
(define fu.rbody [F Sk] -> (fu.cat ["(" (fu.rq F) ", " (fu.rsk Sk) ")"]))
(define fu.rmode total -> "CTotal" partial -> "CPartial" always -> "CAlways")
(define fu.rcert
  [contract-certificate Format [theory TN TZ] [program PN PZ] [evaluator EN EZ] [statement SN M]
                        [hypotheses Hs] [measures Ms] [bodies Bs] [main Mk]] ->
  (fu.cat ["(Cert " (fu.rq Format) " " (fu.rpair [TN TZ]) " " (fu.rpair [PN PZ]) " " (fu.rpair [EN EZ])
           " (" (fu.rq SN) ", " (fu.rmode M) ") " (fu.seq (/. H (fu.rq H)) Hs)
           " " (fu.seq (/. P (fu.rtext-pair P)) Ms) " " (fu.seq (/. B (fu.rbody B)) Bs) " " (fu.rsk Mk) ")"]))
(set fu.nl (n->string 10))
(define fu.rcase Name Prog Cert Want ->
  (fu.cat ["Definition " Name "_p := " (fu.rprog Prog) "." (value fu.nl)
           "Definition " Name "_c := " (fu.rcert Cert) "." (value fu.nl)
           "Example " Name " : tag (check " Name "_p " Name "_c) = t c#34;" Want "c#34; := ltac:(vm_compute; reflexivity)." (value fu.nl)]))
(set fu.rocq (fu.cat [
  "(* Generated by verification/universal/certify.shen from extracted.kl. Do not edit. *)" (value fu.nl)
  "From Coq Require Import List ZArith String." (value fu.nl)
  "From Buri Require Import Observation KLSyntax KLValue KLSemantics ContractCert." (value fu.nl)
  "Import ListNotations." (value fu.nl)
  "Import Observation.Observation KLSyntax.KLSyntax KLValue.KLValue KLSemantics.KLSemantics ContractCert.ContractCert." (value fu.nl)
  "Open Scope string_scope." (value fu.nl)
  "Definition tag (v : verdict) : text := match v with Accepted _ _ _ _ => t c#34;acceptedc#34; | Rejected w => w end." (value fu.nl)
  "Definition premises (v : verdict) : list text := match v with Accepted _ hs _ _ => hs | Rejected _ => [] end." (value fu.nl)
  (fu.rcase "fragment" (value fu.frag) (value fu.frag-cert) "accepted")
  (fu.rcase "false_statement" (value fu.frag)
     (fu.set-field statement ["fenrir-tc0-checked-add-can-return-2^63" total] (value fu.frag-cert)) "accepted")
  (fu.rcase "off_by_one_own" (value fu.mutant) (fu.cert "fenrir-tc0-checked-add-in-i64-or-overflow" (value fu.mutant)) "accepted")
  (fu.rcase "off_by_one_original" (value fu.mutant) (value fu.frag-cert) "stale-program")
  (fu.rcase "corrupt_rule" (value fu.frag) (fu.subst-tree r_call r_if (value fu.frag-cert)) "body-shape")
  (fu.rcase "full_closure" (value fu.full) (fu.full-cert (value fu.full)) "body-shape")
  (fu.rcase "mislabel" (value fu.frag) (value fu.mislabel) "accepted")
  "Example mislabel_no_premises : premises (check mislabel_p mislabel_c) = [] := ltac:(vm_compute; reflexivity)." (value fu.nl)
  (fu.rcase "launch" (value fu.launch) (fu.cert-for "harmless" (value fu.cons-leaf) [] (value fu.launch)) "accepted")
  "Example launch_no_premises : premises (check launch_p launch_c) = [] := ltac:(vm_compute; reflexivity)." (value fu.nl)
  "(* Extracted definitions used by HelperLemmas.v. *)" (value fu.nl)
  "Definition extracted_digit : text * list text * expr := " (fu.rdef (fu.find-def "tc0.i64.digit" (value fu.covered))) "." (value fu.nl)
  "Definition extracted_checked : text * list text * expr := " (fu.rdef (fu.find-def "tc0.i64.checked" (value fu.covered))) "." (value fu.nl)]))
(write-to-file (value fu.rocq-out) (value fu.rocq))

\\ The accepted fragment certificate and its program, as inert data, for review.
(set *maximum-print-sequence-size* 1000000)
(write-to-file (value fu.cert-out)
  (make-string "\\ Program and certificate of the accepted fragment (generated by certify.shen).~%~S~%~S~%~%\\ Verdict of buri.contract-check:~%\\ ~S~%"
    (value fu.frag) (value fu.frag-cert) (value fu.frag-verdict)))
(set *maximum-print-sequence-size* 20)

(if (value fu.failed) (output "FU-CERT-FAIL~%") (output "FU-CERT-OK ~A~%" (value fu.count)))
