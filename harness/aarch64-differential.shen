\\ Fenrir harness, in Shen: does the AArch64 lane's source semantics agree with
\\ the Shen pure-call model on the lane's programs? Development evidence only;
\\ qualification UNKNOWN.
\\
\\   shen-jit script harness/aarch64-differential.shen LIBDIR ROOT OUTDIR
\\
\\ The lane's semantics is local to the lane: eval_expr in
\\ verification/aarch64/Core.v (profile fenrir-aarch64-checked-unary/1) and
\\ eval_main in verification/aarch64/Expr.v (fenrir-aarch64-checked-expr/1), and
\\ ceval in verification/aarch64/CallCompile.v (fenrir-aarch64-checked-call/1). This
\\ program checks it against models/tc0/pure-call-machine.shen on every program
\\ the lane proves and runs, over the I64 boundary inputs. It is a test, not a
\\ proof of agreement.
\\
\\ node tools/aarch64/differential-programs.mjs writes the programs: each artifact
\\ and the Rocq term that the lane's projection (tools/aarch64, unverified, the
\\ same code the compiler uses) makes of it. The model runs every artifact on
\\ every input here, in this process. This program then writes the model's
\\ outcomes into a Rocq file as expected values; Rocq evaluates the lane's own
\\ definitions on the same terms inside its kernel (vm_compute, no extraction)
\\ and must prove that no case disagrees. A second file, with three expected
\\ values deliberately falsified, must be refuted at exactly those three cases.

(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(set fh.*out* (cn (hd (tl (tl (tl (value *argv*))))) "/"))
(load (cn (value fh.*root*) "harness/common.shen"))

\\ ---------- the model ----------

\\ The model's initial state with the entry parameter bound to Input (a canonical
\\ I64 string), the way fh.state binds the demo input "0".
(define fh.arm-state
  Artifact Input ->
    (let Rows (map (/. F (fh.function-row F)) (fh.field "functions" Artifact))
         Names (map (/. R [(fh.function-name (hd (tl R))) (hd R)]) Rows)
         Entry (fh.entry-row (fh.field "entry" Artifact) Rows)
      [pure-call-state [evaluate (hd (tl Entry)) true] [[(hd Entry) [int Input]]] [] (fh.function-codes Rows) Names]))

\\ Step the model to its terminal outcome, [ok V] or [trap Code], or budget.
(define fh.arm-final
  _ 0 -> budget
  [pure-call-state [terminal Outcome] | _] _ -> Outcome
  State Fuel -> (fh.arm-final (hd (tl (tc0.pc.step State))) (- Fuel 1)))

\\ Model step budget per case (the call programs recurse a few thousand times).
(define fh.arm-budget -> 5000000)

\\ ---------- Rocq text ----------

(define fh.arm-join
  [] -> ""
  [S | Ss] -> (cn S (fh.arm-join Ss)))

(define fh.arm-sep
  [] _ -> ""
  [S] _ -> S
  [S | Ss] Sep -> (cn S (cn Sep (fh.arm-sep Ss Sep))))

(define fh.zlit
  S -> (cn "(" (cn S ")")) where (= (pos S 0) "-")
  S -> S)

\\ The model's outcome as a value of the lane's result type.
(define fh.rocq-want
  "expr" [ok [int N]] -> (cn "Some (ROk (VInt " (cn (fh.zlit N) "))"))
  "expr" [ok [bool true]] -> "Some (ROk (VBool true))"
  "expr" [ok [bool false]] -> "Some (ROk (VBool false))"
  "expr" [trap overflow] -> "Some (RTrap TOverflow)"
  "expr" [trap div-zero] -> "Some (RTrap TDivZero)"
  "call" O -> (fh.rocq-want "expr" O)
  "unary" [ok [int N]] -> (cn "Core.Ok " (fh.zlit N))
  "unary" [trap overflow] -> "Core.Overflow"
  _ X -> (error "harness: outcome outside the lane's profiles ~S" X))

\\ A deliberately wrong expected value of the same profile.
(define fh.rocq-wrong
  "unary" [ok _] -> "Core.Overflow"
  "unary" _ -> "Core.Ok 0"
  "expr" [ok _] -> "Some (RTrap TDivZero)"
  "expr" _ -> "Some (ROk (VInt 0))"
  "call" O -> (fh.rocq-wrong "expr" O))

(define fh.check-text
  "unary" K X Want -> (make-string "unary_agree U.p~A ~A ~A" K (fh.zlit X) (fh.parens Want))
  "expr" K X Want -> (make-string "expr_agree q~A ~A ~A" K (fh.zlit X) (fh.parens Want))
  "call" K X Want -> (make-string "call_agree c~A m~A ~A ~A" K K (fh.zlit X) (fh.parens Want)))

(define fh.parens
  S -> (cn "(" (cn S ")")))

(define fh.definition
  "unary" K Row -> (make-string "Definition p~A : expr := ~A.c#10;" K (fh.field "rocq" Row))
  "expr" K Row -> (make-string "Definition q~A : expr := ~A.c#10;" K (fh.field "rocq" Row))
  "call" K Row -> (make-string "Definition c~A : list stmt := ~A.c#10;Definition m~A : nat := ~A%nat.c#10;"
                               K (fh.field "rocq" Row) K (fh.field "main" Row)))

(define fh.rocq-file
  UnaryDefs ExprDefs CallDefs Checks Count Claim ->
    (fh.arm-join
      ["From Stdlib Require Import ZArith List Bool.c#10;"
       "From FenrirARM Require Core Expr CallCompile.c#10;"
       "Import ListNotations.c#10;Open Scope Z_scope.c#10;"
       "Module U.c#10;Import FenrirARM.Core.c#10;" UnaryDefs "End U.c#10;"
       "Import FenrirARM.Expr.c#10;" ExprDefs "Import FenrirARM.CallCompile.c#10;" CallDefs
       "Definition unary_agree (e : Core.expr) (x : Z) (want : Core.outcome) : bool :=c#10;"
       "  match Core.eval_expr e x, want with Core.Ok a, Core.Ok b => Z.eqb a b | Core.Overflow, Core.Overflow => true | _, _ => false end.c#10;"
       "Definition value_eqb (a b : value) : bool :=c#10;"
       "  match a, b with VInt x, VInt y => Z.eqb x y | VBool x, VBool y => Bool.eqb x y | _, _ => false end.c#10;"
       "Definition result_eqb (a b : option result) : bool :=c#10;"
       "  match a, b with Some (ROk x), Some (ROk y) => value_eqb x yc#10;"
       "  | Some (RTrap TOverflow), Some (RTrap TOverflow) => truec#10;"
       "  | Some (RTrap TDivZero), Some (RTrap TDivZero) => truec#10;"
       "  | None, None => true | _, _ => false end.c#10;"
       "Definition expr_agree (e : expr) (x : Z) (want : option result) : bool := result_eqb (eval_main e x) want.c#10;"
       "Definition call_agree (p : list stmt) (m : nat) (x : Z) (want : option result) : bool := result_eqb (ceval (Z.to_nat 20000) p m x) want.c#10;"
       "Definition checks : list bool := [c#10;" (fh.arm-sep Checks ";c#10;") "].c#10;"
       "Fixpoint failures_from (n : nat) (l : list bool) : list nat :=c#10;"
       "  match l with [] => [] | b :: r => if b then failures_from (S n) r else n :: failures_from (S n) r end.c#10;"
       "Definition failures : list nat := failures_from 0 checks.c#10;"
       (make-string "Lemma check_count : length checks = ~A%nat.c#10;Proof. vm_compute. reflexivity. Qed.c#10;" Count)
       (make-string "Lemma claim : failures = (~A)%nat.c#10;Proof. vm_compute. reflexivity. Qed.c#10;" Claim)]))

\\ ---------- cases ----------

\\ One row per program and input: [Profile ProgramIndex Input Outcome].
(define fh.arm-runs
  _ [] _ Acc -> (reverse Acc)
  Inputs [Row | Rows] K Acc ->
    (let Profile (fh.field "profile" Row)
         Artifact (fh.field "artifact" Row)
         New (map (/. X [Profile K X (fh.arm-final (fh.arm-state Artifact X) (fh.arm-budget))]) Inputs)
      (fh.arm-runs Inputs Rows (+ K 1) (append (reverse New) Acc))))

(define fh.defs-of
  _ [] _ -> []
  P [Row | Rows] K -> [(fh.definition P K Row) | (fh.defs-of P Rows (+ K 1))] where (= (fh.field "profile" Row) P)
  P [_ | Rows] K -> (fh.defs-of P Rows (+ K 1)))

(define fh.outcome-name
  [ok [int _]] -> "Ok:int"
  [ok [bool _]] -> "Ok:bool"
  [trap overflow] -> "Trap:Overflow"
  [trap div-zero] -> "Trap:DivZero"
  budget -> "Incomplete"
  _ -> "Other")

(define fh.arm-bump
  Key [] -> [[Key 1]]
  Key [[Key N] | Rest] -> [[Key (+ N 1)] | Rest]
  Key [P | Rest] -> [P | (fh.arm-bump Key Rest)])

(define fh.arm-tally
  [] Acc -> Acc
  [[_ _ _ O] | Runs] Acc -> (fh.arm-tally Runs (fh.arm-bump (fh.outcome-name O) Acc)))

(define fh.first-index
  _ [] _ -> -1
  F [X | Xs] I -> I where (F X)
  F [_ | Xs] I -> (fh.first-index F Xs (+ I 1)))

(define fh.wanted
  [[P K X O] | Runs] I Bad -> [(fh.check-text P K X (if (element? I Bad) (fh.rocq-wrong P O) (fh.rocq-want P O))) | (fh.wanted Runs (+ I 1) Bad)]
  [] _ _ -> [])

(define fh.rocq-list
  Ns -> (cn "[" (cn (fh.arm-sep (map (/. N (str N)) Ns) "; ") "]")))

(define fh.insert-sorted
  X [] -> [X]
  X [Y | Ys] -> [X Y | Ys] where (< X Y)
  X [Y | Ys] -> [Y | (fh.insert-sorted X Ys)])

(define fh.nonzero
  [] -> []
  [[0 | _] | Rs] -> (fh.nonzero Rs)
  [R | Rs] -> [R | (fh.nonzero Rs)])

(define fh.copy
  From To -> (write-to-file To (read-file-as-string From)))

(define fh.rocq
  File -> (fh.exec "rocq" ["compile" "-Q" (value fh.*out*) "FenrirARM" File] 900))

(define fh.main
  -> (let Programs (cn (value fh.*out*) "programs.jsonl")
          Made (fh.exec "node" [(cn (value fh.*root*) "tools/aarch64/differential-programs.mjs") Programs] 300)
          Ran (if (= (hd Made) 0) true (error "harness: the program writer failed: ~A" (nth 3 Made)))
          View (buffer.from-string (read-file-as-string Programs))
          Lines (fh.json-lines View 0 (buffer.length View) [])
          Header (hd Lines)
          Rows (tl Lines)
          Inputs (fh.field "inputs" Header)
          Runs (fh.arm-runs Inputs Rows 0 [])
          Count (length Runs)
          Tally (fh.arm-tally Runs [])
          Incomplete (fh.first-index (/. R (= (nth 4 R) budget)) Runs 0)
          UnaryDefs (fh.arm-join (fh.defs-of "unary" Rows 0))
          ExprDefs (fh.arm-join (fh.defs-of "expr" Rows 0))
          CallDefs (fh.arm-join (fh.defs-of "call" Rows 0))
          \\ Negative controls: the first unary case, the first expr Ok, the first expr trap,
          \\ the first call-profile case.
          B1 (fh.first-index (/. R (= (hd R) "unary")) Runs 0)
          B2 (fh.first-index (/. R (and (= (hd R) "expr") (= (hd (nth 4 R)) ok))) Runs 0)
          B3 (fh.first-index (/. R (and (= (hd R) "expr") (= (hd (nth 4 R)) trap))) Runs 0)
          B4 (fh.first-index (/. R (= (hd R) "call")) Runs 0)
          Bad (fh.insert-sorted B1 (fh.insert-sorted B2 (fh.insert-sorted B3 [B4])))
          Copied (do (fh.copy (cn (value fh.*root*) "verification/aarch64/Core.v") (cn (value fh.*out*) "Core.v"))
                     (map (/. M (fh.copy (cn (value fh.*root*) (cn "verification/aarch64/" M)) (cn (value fh.*out*) M)))
                          ["Expr.v" "Machine.v" "Flags.v" "Encode.v" "Compile.v" "CallCompile.v"]))
          Base (map (/. M (fh.rocq (cn (value fh.*out*) M))) ["Core.v" "Expr.v" "Machine.v" "Flags.v" "Encode.v" "Compile.v" "CallCompile.v"])
          BaseOk (empty? (fh.nonzero Base))
          Good (write-to-file (cn (value fh.*out*) "Agreement.v")
                 (fh.rocq-file UnaryDefs ExprDefs CallDefs (fh.wanted Runs 0 []) Count "[]"))
          GoodRun (fh.rocq (cn (value fh.*out*) "Agreement.v"))
          Neg (write-to-file (cn (value fh.*out*) "Control.v")
                (fh.rocq-file UnaryDefs ExprDefs CallDefs (fh.wanted Runs 0 Bad) Count (fh.rocq-list Bad)))
          NegRun (fh.rocq (cn (value fh.*out*) "Control.v"))
          Version (hd (tl (fh.exec "rocq" ["--version"] 60)))
          Agree (= (hd GoodRun) 0)
          Caught (= (hd NegRun) 0)
          Pass (and BaseOk Agree Caught (= Incomplete -1) (> B1 -1) (> B2 -1) (> B3 -1) (> B4 -1))
          Report [object ["schema" "fenrir.harness.aarch64-differential/1"]
                         ["status" (if Pass "development-pass" "development-fail")]
                         ["qualification" "UNKNOWN"]
                         ["harness" "Shen"]
                         ["shen" (make-string "~A ~A ~A" (value *implementation*) (value *port*) (version))]
                         ["rocq" (hd (fh.lines Version))]
                         ["claim" "The lane-local source semantics (Core.v eval_expr, Expr.v eval_main, CallCompile.v ceval) agrees with models/tc0/pure-call-machine.shen on these cases; tested, not proved"]
                         ["projection" "tools/aarch64/compile.mjs, expr.mjs and call.mjs, unverified (ARM-02); the same projection the compiler uses"]
                         ["programs" (str (length Rows))]
                         ["inputs" (str (length Inputs))]
                         ["cases" (str Count)]
                         ["model_outcomes" [object | (map (/. P [(hd P) (str (hd (tl P)))]) Tally)]]
                         ["model_incomplete" (if (= Incomplete -1) "0" (str Incomplete))]
                         ["rocq_agreement" (if Agree (make-string "Agreement.v: failures = [] proved over ~A cases" Count) (nth 3 GoodRun))]
                         ["negative_control" (if Caught (make-string "Control.v: failures = ~A proved (exactly the falsified cases)" (fh.rocq-list Bad)) (nth 3 NegRun))]]
          Text (json.stringify Report [[byte-limit 1048576]])
          Written (write-to-file (cn (value fh.*out*) "report.json") (cn Text "c#10;"))
       (do (output "~A~%" Text)
           (shen-jit.exit (if Pass 0 1)))))

(fh.main)
