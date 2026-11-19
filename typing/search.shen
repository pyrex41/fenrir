\\ Fenrir typing: derivation search. UNTRUSTED. Rules: spec/tc1/TYPING.md.
\\
\\   (ts.derive A V Budget)  a derivation that artifact A with input V is well typed,
\\                           in the format typing/checker.shen checks, or
\\                           [no-derivation Where] or [unknown Why]
\\
\\ A is the decoded artifact as typing/structure.shen gives it, structurally valid.
\\ The search is Shen's own sequent machinery: the datatype fenrir-typing below
\\ states each rule of TYPING.md as a Shen sequent rule over the judgment form
\\ "E : (ts.j G T F K D)", and shen.typecheck proves it for a function body with
\\ the effects F, uses K and derivation D unknown, by Shen's proof search. The D a
\\ proof binds is the derivation: each rule's last premise (ts.close) builds the
\\ node [Rule Conclusion Premises] of the TYPING.md rule it states.
\\
\\ How this rule set R_S relates to the rules R of TYPING.md (§9 there):
\\  - one Shen rule per expression rule and per plain rule of R, with the same name
\\    in the node it builds; Program and Function nodes are assembled by
\\    ts.assemble, which has nothing to choose;
\\  - side conditions that inspect premise results (unions, use lists, tables) are
\\    stated as auxiliary judgments, because a Shen side condition can only see what
\\    the conclusion has bound; variable-length premise lists (operands, arms,
\\    clauses, fields) are auxiliary list judgments. Neither appears in a derivation;
\\  - R_S checks less than R in places (function signatures are left to the
\\    checker, for example). Nothing R_S concludes is trusted: the checker accepts
\\    or rejects what it builds. R_S being wrong can only make search fail or
\\    produce a derivation the checker rejects.
\\ Terms and types inside a typecheck are "quoted" lists (ts.q): [cons X Y] for
\\ [X | Y], which is how Shen's checker holds both. A budget of inferences bounds
\\ each proof; running out is UNKNOWN, never acceptance.

\\ ---------- quoting ----------

(define ts.q
  [X | Y] -> [cons (ts.q X) (ts.q Y)]
  X -> X)

(define ts.uq
  [cons X Y] -> [(ts.uq X) | (ts.uq Y)]
  X -> X)

\\ ---------- the artifact's tables, plain data ----------

(set ts.*functions* [])
(set ts.*datatypes* [])
(set ts.*effects* [])
(set ts.*artifact* [])

(define ts.f
  K [object | Ms] -> (ts.member K Ms)
  _ _ -> (simple-error "ts: not an object"))

(define ts.member
  K [[K V] | _] -> V
  K [_ | Ms] -> (ts.member K Ms)
  _ _ -> (simple-error "ts: missing member"))

(define ts.find
  K [[K V] | _] -> V
  K [_ | Rows] -> (ts.find K Rows)
  _ _ -> none)

(define ts.load
  A -> (do (set ts.*functions* (map (/. F [(ts.f "name" F) [(ts.f "argument_type" F) (ts.f "result_type" F) (ts.f "effects" F)]])
                                    (ts.f "functions" A)))
           (set ts.*datatypes* (map (/. D [(ts.f "name" D) (map (/. C [(ts.f "name" C) (ts.f "fields" C)]) (ts.f "constructors" D))])
                                    (ts.f "datatypes" A)))
           (set ts.*effects* (map (/. D [(ts.f "name" D) (map (/. O [(ts.f "name" O) [(ts.f "argument_type" O) (ts.f "result_type" O)]]) (ts.f "operations" D))])
                                  (ts.f "effects" A)))
           (set ts.*artifact* A)))

(define ts.data? -> (tc.data? (value ts.*artifact*)))
(define ts.handlers? -> (tc.handlers? (value ts.*artifact*)))
(define ts.resumptions? -> (tc.resumptions? (value ts.*artifact*)))

\\ ---------- side-condition helpers: quoted in, quoted out, none for no answer ----------

(define ts.lookup
  X G -> (ts.q (ts.find X (ts.uq G))))

(define ts.value-type?
  T -> (and (not (= T none)) (not (tc.resumption? (ts.uq T)))))

(define ts.resumption-type?
  T -> (tc.resumption? (ts.uq T)))

(define ts.nth-of
  0 [X | _] -> X
  N [_ | Xs] -> (ts.nth-of (- N 1) Xs)
  _ _ -> none)

(define ts.first X -> (ts.q (ts.nth-of 0 (ts.uq X))))
(define ts.second X -> (ts.q (ts.nth-of 1 (ts.uq X))))
(define ts.third X -> (ts.q (ts.nth-of 2 (ts.uq X))))

(define ts.signature
  Op -> (ts.q (ts.find Op (append [["add" [["I64" "I64"] "I64"]] ["sub" [["I64" "I64"] "I64"]] ["mul" [["I64" "I64"] "I64"]]
                                   ["div" [["I64" "I64"] "I64"]] ["neg" [["I64"] "I64"]] ["lt" [["I64" "I64"] "Bool"]]
                                   ["le" [["I64" "I64"] "Bool"]] ["gt" [["I64" "I64"] "Bool"]] ["ge" [["I64" "I64"] "Bool"]]
                                   ["not" [["Bool"] "Bool"]]]
                                  (if (ts.data?) [["bytes_length" [["Bytes"] "I64"]] ["bytes_index" [["Bytes" "I64"] "I64"]]
                                                  ["bytes_concat" [["Bytes" "Bytes"] "Bytes"]]] [])))))

(define ts.function
  Name -> (ts.q (ts.find Name (value ts.*functions*))))

(define ts.operations
  Eff -> (ts.q (ts.find Eff (value ts.*effects*))))

(define ts.operation
  Eff Op -> (let Ops (ts.find Eff (value ts.*effects*))
              (if (= Ops none) none (ts.op Op (ts.q Ops)))))

(define ts.op
  Op Ops -> (ts.q (ts.find Op (ts.uq Ops))))

(define ts.table-of
  "TrapCode" -> (map (/. C [C []]) ["Overflow" "DivZero" "Bounds" "InvalidDuration" "TaskLimit" "ChildFailed"])
  ["Data" D] -> (ts.find D (value ts.*datatypes*))
  _ -> none)

(define ts.table
  S -> (ts.q (ts.table-of (ts.uq S))))

(define ts.named-type
  "TrapCode" -> "TrapCode"
  D -> (ts.q ["Data" D]) where (not (= (ts.find D (value ts.*datatypes*)) none))
  _ -> none)

(define ts.fields
  T C -> (let Table (ts.table-of (ts.uq T))
           (if (= Table none) none (ts.q (ts.find C Table)))))

(define ts.all-fields
  D -> (ts.q (tc.concat (map (/. Row (hd (tl Row))) (ts.find D (value ts.*datatypes*))))))

(define ts.base?
  T -> (element? T ["Unit" "Bool" "I64" "Bytes" "TrapCode"]))

(define ts.member?
  X L -> (element? X (ts.uq L)))

(define ts.union
  F1 F2 -> (ts.q (tc.union (ts.uq F1) (ts.uq F2))))

(define ts.append
  K1 K2 -> (ts.q (append (ts.uq K1) (ts.uq K2))))

(define ts.handled
  Eff F0 Fs -> (ts.q (tc.union (tc.remove Eff (ts.uq F0)) (tc.unions (ts.uq Fs)))))

(define ts.subset?
  F Ef -> (tc.subset? (ts.uq F) (ts.uq Ef)))

(define ts.one?
  K -> (= (length (ts.uq K)) 1))

(define ts.nth
  I Ts -> (let N (ts.index I ["0" "1" "2" "3" "4" "5" "6" "7"] 0)
            (if (= N none) none (ts.q (ts.nth-of N (ts.uq Ts))))))

(define ts.index
  I [I | _] N -> N
  I [_ | Is] N -> (ts.index I Is (+ N 1))
  _ _ _ -> none)

\\ Every constructor has exactly one arm.
(define ts.covers?
  Table Arms -> (let Cs (map (/. Arm (hd Arm)) (ts.uq Arms))
                  (and (tc.distinct? Cs) (= (length Cs) (length (ts.uq Table))) (tc.every? (/. C (not (= (ts.find C (ts.uq Table)) none))) Cs))))

(define ts.covers-operations?
  Ops Clauses -> (and (not (= Ops none)) (ts.covers? Ops Clauses)))

(define ts.arm-fields
  C Table -> (ts.q (ts.find C (ts.uq Table))))

(define ts.fit?
  Xs Fs -> (and (not (= Fs none)) (= (length (ts.uq Xs)) (length (ts.uq Fs)))))

(define ts.extend
  Xs Fs G -> (ts.q (append (tc.zip (ts.uq Xs) (ts.uq Fs)) (ts.uq G))))

(define ts.values
  G -> (ts.q (tc.values (ts.uq G))))

\\ The uses of the first arm, when every arm uses the resumption as often.
(define ts.arm-uses
  Ks -> (let Ls (ts.uq Ks) (if (tc.same-lengths? Ls) (ts.q (hd Ls)) none)))

(define ts.tuple-size?
  Es -> (tc.between? 1 8 (length (ts.uq Es))))

(define ts.type? T -> (tc.type? (value ts.*artifact*) (ts.uq T)))
(define ts.effects? Ef -> (tc.effects? (value ts.*artifact*) (ts.uq Ef)))

\\ ---------- the rules, as Shen sequent rules ----------
\\ Judgments: "E : (ts.j G T F K D)", expression E has type T with effects F and use
\\ sites K in context G, by derivation D; "T : (ts.p Ds D)", type T is serializable
\\ assuming the datatypes Ds, by D. (ts.rows ...), (ts.arms ...), (ts.clauses ...) and
\\ (ts.plains ...) are their list forms; (ts.is V) and ts.ok are the auxiliary
\\ computations. Each rule's last premise builds its derivation node: a rule whose
\\ conclusion spelled the node out as a type pattern takes Shen about a second to
\\ compile, this way a few milliseconds.

(datatype fenrir-typing

  ["ts.close" "T-Unit" G ["unit" N] "Unit" [] [] []] : (ts.out F K D);
  _______________________________________________________
  ["unit" N] : (ts.j G "Unit" F K D);

  if (boolean? B)
  ["ts.close" "T-Bool" G ["bool" N B] "Bool" [] [] []] : (ts.out F K D);
  _______________________________________________________
  ["bool" N B] : (ts.j G "Bool" F K D);

  if (tc.i64? I)
  ["ts.close" "T-Int" G ["int" N I] "I64" [] [] []] : (ts.out F K D);
  _______________________________________________________
  ["int" N I] : (ts.j G "I64" F K D);

  if (ts.data?)
  if (tc.hex? H)
  ["ts.close" "T-Bytes" G ["bytes" N H] "Bytes" [] [] []] : (ts.out F K D);
  _______________________________________________________
  ["bytes" N H] : (ts.j G "Bytes" F K D);

  let T (ts.lookup X G)
  if (ts.value-type? T)
  ["ts.close" "T-Var" G ["var" N X] T [] [] []] : (ts.out F K D);
  _______________________________________________________
  ["var" N X] : (ts.j G T F K D);

  E1 : (ts.j G T1 F1 K1 D1);
  E2 : (ts.j [[X T1] | G] T F2 K2 D2);
  ["ts.close" "T-Let" G ["let" N X E1 E2] T [F1 F2] [K1 K2] [D1 D2]] : (ts.out F K D);
  _______________________________________________________
  ["let" N X E1 E2] : (ts.j G T F K D);

  C : (ts.j G "Bool" F0 K0 D0);
  E1 : (ts.j G T F1 K1 D1);
  E2 : (ts.j G T F2 K2 D2);
  ["ts.same-length" K1 K2] : ts.ok;
  ["ts.close" "T-If" G ["if" N C E1 E2] T [F0 F1 F2] [K0 K1] [D0 D1 D2]] : (ts.out F K D);
  _______________________________________________________
  ["if" N C E1 E2] : (ts.j G T F K D);

  let S (ts.signature Op)
  if (not (= S none))
  let Ts (ts.first S)
  let T (ts.second S)
  Es : (ts.rows G Ts Ds Fs Ks);
  ["ts.close" "T-Prim" G ["prim" N Op | Es] T Fs Ks Ds] : (ts.out F K D);
  _______________________________________________________
  ["prim" N Op | Es] : (ts.j G T F K D);

  if (ts.data?)
  E1 : (ts.j G T F1 K1 D1);
  E2 : (ts.j G T F2 K2 D2);
  T : (ts.p [] D3);
  ["ts.close" "T-Eq" G ["prim" N "eq" E1 E2] "Bool" [F1 F2] [K1 K2] [D1 D2 D3]] : (ts.out F K D);
  _______________________________________________________
  ["prim" N "eq" E1 E2] : (ts.j G "Bool" F K D);

  if (ts.data?)
  if (ts.tuple-size? Es)
  Es : (ts.rows G Ts Ds Fs Ks);
  ["ts.close" "T-Tuple" G ["tuple" N | Es] ["Tuple" | Ts] Fs Ks Ds] : (ts.out F K D);
  _______________________________________________________
  ["tuple" N | Es] : (ts.j G ["Tuple" | Ts] F K D);

  if (ts.data?)
  E : (ts.j G ["Tuple" | Ts] F1 K1 D1);
  ["ts.nth" I Ts] : (ts.is T);
  ["ts.close" "T-Project" G ["project" N E I] T [F1] [K1] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["project" N E I] : (ts.j G T F K D);

  if (ts.data?)
  let T (ts.named-type Dt)
  if (not (= T none))
  let Ts (ts.fields T C)
  if (not (= Ts none))
  Es : (ts.rows G Ts Ds Fs Ks);
  ["ts.close" "T-Construct" G ["construct" N Dt C | Es] T Fs Ks Ds] : (ts.out F K D);
  _______________________________________________________
  ["construct" N Dt C | Es] : (ts.j G T F K D);

  if (ts.data?)
  E : (ts.j G S F0 K0 D0);
  ["ts.table" S] : (ts.is Table);
  ["ts.covers" Table Arms] : ts.ok;
  Arms : (ts.arms G Table T Ds Fs Ks);
  ["ts.arm-uses" Ks] : (ts.is K1);
  ["ts.close" "T-Match" G ["match" N E | Arms] T [F0 | Fs] [K0 K1] [D0 | Ds]] : (ts.out F K D);
  _______________________________________________________
  ["match" N E | Arms] : (ts.j G T F K D);

  if (string? L)
  E : (ts.j G T F1 K1 D1);
  T : (ts.p [] D2);
  ["ts.close" "T-Emit" G ["emit" N L E] "Unit" [F1 ["Emit"]] [K1] [D1 D2]] : (ts.out F K D);
  _______________________________________________________
  ["emit" N L E] : (ts.j G "Unit" F K D);

  if (ts.type? Ta)
  if (ts.type? Tr)
  if (ts.effects? Ef)
  let G1 (ts.values G)
  B : (ts.j [[X Ta] | G1] Tr F1 K1 D1);
  ["ts.lambda" F1 Ef K1] : ts.ok;
  ["ts.close" "T-Lambda" G ["lambda" N X Ta Tr Ef [] B] ["Arrow" Ta Tr Ef] [] [] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["lambda" N X Ta Tr Ef [] B] : (ts.j G ["Arrow" Ta Tr Ef] F K D);

  E1 : (ts.j G ["Arrow" Ta T Ef] F1 K1 D1);
  E2 : (ts.j G Ta F2 K2 D2);
  ["ts.close" "T-Apply" G ["apply" N E1 E2] T [F1 F2 Ef] [K1 K2] [D1 D2]] : (ts.out F K D);
  _______________________________________________________
  ["apply" N E1 E2] : (ts.j G T F K D);

  let Sig (ts.function Name)
  if (not (= Sig none))
  let Ta (ts.first Sig)
  let T (ts.second Sig)
  let Ef (ts.third Sig)
  E : (ts.j G Ta F1 K1 D1);
  ["ts.close" "T-Call" G ["call" N Name E] T [F1 Ef] [K1] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["call" N Name E] : (ts.j G T F K D);

  if (ts.handlers?)
  let O (ts.operation Eff Op)
  if (not (= O none))
  let Ta (ts.first O)
  let T (ts.second O)
  E : (ts.j G Ta F1 K1 D1);
  ["ts.close" "T-Perform" G ["perform" N Eff Op E] T [F1 [Eff]] [K1] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["perform" N Eff Op E] : (ts.j G T F K D);

  if (ts.handlers?)
  let Ops (ts.operations Eff)
  if (ts.covers-operations? Ops Clauses)
  let G1 (ts.values G)
  B : (ts.j G T F0 K0 D0);
  Clauses : (ts.clauses G1 T Ops Ds Fs);
  ["ts.handled" Eff F0 Fs] : (ts.is F1);
  ["ts.close" "T-Handle" G ["handle" N Eff Clauses B] T [F1] [K0] [D0 | Ds]] : (ts.out F K D);
  _______________________________________________________
  ["handle" N Eff Clauses B] : (ts.j G T F K D);

  if (ts.resumptions?)
  let Kt (ts.lookup Kv G)
  if (ts.resumption-type? Kt)
  let Tb (ts.second Kt)
  let T (ts.third Kt)
  E : (ts.j G Tb F1 K1 D1);
  ["ts.close" "T-Resume" G ["resume" N Kv E] T [F1] [K1 [N]] [D1]] : (ts.out F K D);
  _______________________________________________________
  ["resume" N Kv E] : (ts.j G T F K D);

  if (ts.resumptions?)
  if (ts.resumption-type? (ts.lookup Kv G))
  ["ts.close" "T-Discontinue" G ["discontinue" N Kv] "Unit" [] [[N]] []] : (ts.out F K D);
  _______________________________________________________
  ["discontinue" N Kv] : (ts.j G "Unit" F K D);

  \\ plain types
  if (ts.base? T)
  ["ts.pnode" "P-Base" Ps T []] : (ts.is D);
  _______________________________________________________
  T : (ts.p Ps D);

  Ts : (ts.plains Ps Ds);
  ["ts.pnode" "P-Tuple" Ps ["Tuple" | Ts] Ds] : (ts.is D);
  _______________________________________________________
  ["Tuple" | Ts] : (ts.p Ps D);

  if (ts.member? Dt Ps)
  ["ts.pnode" "P-Assumed" Ps ["Data" Dt] []] : (ts.is D);
  _______________________________________________________
  ["Data" Dt] : (ts.p Ps D);

  if (not (ts.member? Dt Ps))
  if (not (= (ts.find Dt (value ts.*datatypes*)) none))
  let Fs (ts.all-fields Dt)
  Fs : (ts.plains [Dt | Ps] Ds);
  ["ts.pnode" "P-Data" Ps ["Data" Dt] Ds] : (ts.is D);
  _______________________________________________________
  ["Data" Dt] : (ts.p Ps D);

  \\ lists: the operands' derivations, effect sets and use lists, in order
  _______________________________________________________
  [] : (ts.rows G [] [] [] []);

  E : (ts.j G T F K D);
  Es : (ts.rows G Ts Ds Fs Ks);
  _______________________________________________________
  [E | Es] : (ts.rows G [T | Ts] [D | Ds] [F | Fs] [K | Ks]);

  _______________________________________________________
  [] : (ts.arms G Table T [] [] []);

  let Fields (ts.arm-fields C Table)
  if (ts.fit? Xs Fields)
  let G1 (ts.extend Xs Fields G)
  B : (ts.j G1 T F K D);
  Arms : (ts.arms G Table T Ds Fs Ks);
  _______________________________________________________
  [[C Xs B] | Arms] : (ts.arms G Table T [D | Ds] [F | Fs] [K | Ks]);

  _______________________________________________________
  [] : (ts.clauses G T Ops [] []);

  let O (ts.op Op Ops)
  if (not (= O none))
  let Ta (ts.first O)
  let Tr (ts.second O)
  C : (ts.j [[X Ta] | G] Tr F K D);
  ["ts.none" K] : ts.ok;
  Cs : (ts.clauses G T Ops Ds Fs);
  _______________________________________________________
  [[Op X C] | Cs] : (ts.clauses G T Ops [D | Ds] [F | Fs]);

  if (ts.resumptions?)
  let O (ts.op Op Ops)
  if (not (= O none))
  let Ta (ts.first O)
  let Tr (ts.second O)
  C : (ts.j [[Kv ["Resumption" Tr T]] [X Ta] | G] T F K D);
  ["ts.one" K] : ts.ok;
  Cs : (ts.clauses G T Ops Ds Fs);
  _______________________________________________________
  [[Op X Kv C] | Cs] : (ts.clauses G T Ops [D | Ds] [F | Fs]);

  _______________________________________________________
  [] : (ts.plains Ps []);

  T : (ts.p Ps D);
  Ts : (ts.plains Ps Ds);
  _______________________________________________________
  [T | Ts] : (ts.plains Ps [D | Ds]);

  \\ auxiliary computations
  let V (ts.close Rule G E T Fs Ks Ds)
  let F (ts.out-f V)
  let K (ts.out-k V)
  let D (ts.out-d V)
  _______________________________________________________
  ["ts.close" Rule G E T Fs Ks Ds] : (ts.out F K D);

  let V (ts.pnode Rule Ps T Ds)
  _______________________________________________________
  ["ts.pnode" Rule Ps T Ds] : (ts.is V);

  let V (ts.handled Eff F0 Fs)
  _______________________________________________________
  ["ts.handled" Eff F0 Fs] : (ts.is V);

  let V (ts.nth I Ts)
  if (not (= V none))
  _______________________________________________________
  ["ts.nth" I Ts] : (ts.is V);

  let V (ts.table S)
  if (not (= V none))
  _______________________________________________________
  ["ts.table" S] : (ts.is V);

  let V (ts.arm-uses Ks)
  if (not (= V none))
  _______________________________________________________
  ["ts.arm-uses" Ks] : (ts.is V);

  if (ts.covers? Table Arms)
  _______________________________________________________
  ["ts.covers" Table Arms] : ts.ok;

  if (= (length (ts.uq K1)) (length (ts.uq K2)))
  _______________________________________________________
  ["ts.same-length" K1 K2] : ts.ok;

  if (and (ts.subset? F Ef) (= K []))
  _______________________________________________________
  ["ts.lambda" F Ef K] : ts.ok;

  if (= K [])
  _______________________________________________________
  ["ts.none" K] : ts.ok;

  if (ts.one? K)
  _______________________________________________________
  ["ts.one" K] : ts.ok;)

\\ ---------- the driver ----------

(set ts.*budget* 0)
\\ Prove Term : Goal by Shen's checker within the budget: the derivation in the
\\ proved type, unquoted, or false when there is no proof, or budget when the
\\ budget ran out. A goal is a judgment form, (ts.j ...) or (ts.p ...), whose
\\ arguments are quoted: a type written (f X) in a rule is a list, one written
\\ [X | Y] is quoted, so the goal is built the same way.
(define ts.prove
  Term Goal -> (trap-error (do (maxinferences (+ (inferences) (value ts.*budget*)))
                               (let T (shen.typecheck (ts.q Term) Goal)
                                 (if (= T false) false (ts.uq (ts.derivation T)))))
                           (/. E (if (ts.budget-error? (error-to-string E)) budget (simple-error (error-to-string E))))))

(define ts.budget-error?
  "" -> false
  (@s "maximum inferences exceeded" _) -> true
  (@s _ S) -> (ts.budget-error? S))

\\ A rule instance closed: the effects are the union of the effect sets Fs, the uses
\\ the concatenation of the use lists Ks, and the node is built; all quoted.
(define ts.close
  Rule G E T Fs Ks Ds -> (let F (tc.unions (ts.uq Fs))
                              K (tc.concat (ts.uq Ks))
                            [(ts.q F) (ts.q K) (ts.q [Rule ["expr" (ts.uq G) (ts.uq E) (ts.uq T) F K] (ts.uq Ds)])]))

(define ts.out-f [F _ _] -> F)
(define ts.out-k [_ K _] -> K)
(define ts.out-d [_ _ D] -> D)

(define ts.pnode
  Rule Ps T Ds -> (ts.q [Rule ["plain" (ts.uq Ps) (ts.uq T)] (ts.uq Ds)]))

(define ts.expr-goal
  G T -> [ts.j (ts.q G) (ts.q T) (protect F) (protect K) (protect D)])

(define ts.plain-goal
  -> [ts.p [] (protect D)])

\\ The derivation in a proved judgment's type.
(define ts.derivation
  [ts.j _ _ _ _ D] -> D
  [ts.p _ D] -> D
  X -> X)

(define ts.derive
  A V Budget -> (do (set ts.*budget* Budget) (ts.load A)
                    (trap-error (ts.assemble A V) (/. E (ts.failure (error-to-string E))))))

(define ts.failure
  (@s "ts:budget " Where) -> [unknown (cn "inference budget exhausted at " Where)]
  (@s "ts:none " Where) -> [no-derivation Where]
  Message -> [unknown (cn "search error: " Message)])

(define ts.need
  budget Where -> (simple-error (cn "ts:budget " Where))
  false Where -> (simple-error (cn "ts:none " Where))
  D _ -> D)

(define ts.plain
  T Where -> (ts.need (ts.prove T (ts.plain-goal)) Where))

(define ts.function-derivation
  F -> (let Where (cn "function " (ts.f "name" F))
            B (ts.f "body" F)
            D (ts.need (ts.prove B (ts.expr-goal [[(ts.f "parameter_id" F) (ts.f "argument_type" F)]] (ts.f "result_type" F))) Where)
         ["Function" ["function" F] [D]]))

(define ts.entry
  Name [F | Fs] -> (if (= (ts.f "name" F) Name) F (ts.entry Name Fs))
  _ _ -> (simple-error "ts:none the entry function"))

(define ts.assemble
  A V -> (let Ops (tc.concat (map (/. D (tc.concat (map (/. O [[(ts.f "argument_type" O) (cn "operation " (ts.f "name" O))]
                                                              [(ts.f "result_type" O) (cn "operation " (ts.f "name" O))]])
                                                        (ts.f "operations" D))))
                                  (ts.f "effects" A)))
              OpPlains (map (/. P (ts.plain (hd P) (hd (tl P)))) Ops)
              Functions (map (/. F (ts.function-derivation F)) (ts.f "functions" A))
              Entry (ts.entry (ts.f "entry" A) (ts.f "functions" A))
              EntryPlains [(ts.plain (ts.f "argument_type" Entry) "the entry argument") (ts.plain (ts.f "result_type" Entry) "the entry result")]
           ["Program" ["well-typed" A V] (append OpPlains Functions EntryPlains)]))
