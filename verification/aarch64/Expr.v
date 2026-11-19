(* Fenrir AArch64 lane, profile fenrir-aarch64-checked-expr/1.

   Source: first-order checked-I64/Bool expressions over one I64 parameter:
   literals, the parameter and let-bound variables, neg, add/sub/mul/div between
   arbitrary subexpressions, lt/le/gt/ge/eq, not, if and let.  The semantics is
   LOCAL TO THIS LANE.  Each rule cites the function of the Shen model
   (models/tc0/pure-call-machine.shen, models/tc0/i64.shen) it transcribes;
   agreement with that model is TESTED (harness/aarch64-differential.shen), not
   proved.

   Target: a handwritten model of a small AArch64 instruction profile, stated
   from the Arm Architecture Reference Manual's pseudocode (AddWithCarry,
   ConditionHolds, ShiftReg, the MADD/SMULH/SDIV/CSINC/MOVZ/MOVK/LDR/STR/B/B.cond
   /CBZ/CBNZ/RET descriptions).  It is NOT checked against Arm's machine-readable
   specification (ARM-03 is open).  No axioms are used; see Print Assumptions at
   the end. *)
From Stdlib Require Import ZArith List Bool Lia.
From FenrirARM Require Core.
Import ListNotations.
Open Scope Z_scope.

(* ------------------------------------------------------------------ *)
(* 1. Integers                                                          *)

Abbreviation lo := Core.lo.
Abbreviation hi := Core.hi.
Abbreviation modulus := Core.modulus.
Abbreviation fits := Core.fits.
Abbreviation signed := Core.signed.

Lemma fits_spec : forall x, fits x = true <-> lo <= x <= hi.
Proof. exact Core.fits_spec. Qed.
Lemma signed_fits : forall x, lo <= x <= hi -> signed x = x.
Proof. intros. apply Core.signed_fits, fits_spec. exact H. Qed.
Lemma signed_range : forall x, lo <= signed x <= hi.
Proof. intros. unfold Core.signed. pose proof (Z.mod_pos_bound (x - lo) modulus).
 unfold Core.lo, Core.hi, Core.modulus in *. lia. Qed.
Lemma signed_congr : forall a b, a mod modulus = b mod modulus -> signed a = signed b.
Proof. intros a b H. unfold Core.signed. f_equal.
 rewrite (Zminus_mod a), (Zminus_mod b), H. reflexivity. Qed.
Lemma signed_mod : forall a, signed (a mod modulus) = signed a.
Proof. intros. apply signed_congr. rewrite Zmod_mod. reflexivity. Qed.
Lemma signed_not_fits : forall x, -modulus <= x <= 2*modulus -> fits x = false -> signed x <> x.
Proof. intros x Hr H Heq. pose proof (signed_range x). rewrite Heq in H0.
 assert (fits x = true) by (apply fits_spec; exact H0). congruence. Qed.

(* ------------------------------------------------------------------ *)
(* 2. Source syntax and semantics                                       *)

Inductive trap := TOverflow | TDivZero.
Inductive value := VInt (n : Z) | VBool (b : bool).
Inductive result := ROk (v : value) | RTrap (t : trap).
Inductive binop := OAdd | OSub | OMul | ODiv.
Inductive cmpop := CLt | CLe | CGt | CGe | CEq.

(* Variables are de Bruijn indices: 0 is the innermost let, the parameter is
   the outermost binding.  The projection from artifact binding IDs is done by
   tools/aarch64/compile.mjs and is NOT verified (open obligation ARM-02). *)
Inductive expr :=
| EInt (n : Z) | EBool (b : bool) | EVar (i : nat)
| ENeg (a : expr) | EBin (op : binop) (a b : expr)
| ECmp (op : cmpop) (a b : expr) | ENot (a : expr)
| EIf (c t f : expr) | ELet (init body : expr).

(* tc0.i64.checked: an exact result inside I64 or Overflow. *)
Definition checked (n : Z) : result :=
  if fits n then ROk (VInt n) else RTrap TOverflow.

(* tc0.arithmetic: add, sub, mul; div tests a zero divisor first
   (`div [_ "0"] -> [trap div-zero]`), then truncates toward zero (tc0.i64.div)
   and checks the result, so MIN / -1 is Overflow. *)
Definition arith (op : binop) (a b : Z) : result :=
  match op with
  | OAdd => checked (a + b)
  | OSub => checked (a - b)
  | OMul => checked (a * b)
  | ODiv => if b =? 0 then RTrap TDivZero else checked (Z.quot a b)
  end.

(* tc0.pc.pure: lt/le/gt/ge through tc0.i64.compare on two I64 values; eq is
   structural equality (`(= A B)`); here restricted to two I64 or two Bool
   operands, which is what the closed validator admits.  not on a Bool. *)
Definition compare (op : cmpop) (a b : value) : option bool :=
  match op, a, b with
  | CLt, VInt x, VInt y => Some (x <? y)
  | CLe, VInt x, VInt y => Some (x <=? y)
  | CGt, VInt x, VInt y => Some (y <? x)
  | CGe, VInt x, VInt y => Some (y <=? x)
  | CEq, VInt x, VInt y => Some (x =? y)
  | CEq, VBool x, VBool y => Some (Bool.eqb x y)
  | _, _, _ => None
  end.

(* Trap propagation: tc0.pc.step's `unwind` rules discard pending frames, so a
   trap in an operand is the trap of the whole expression. *)
Definition bind (r : option result) (k : value -> option result) : option result :=
  match r with
  | Some (ROk v) => k v
  | Some (RTrap t) => Some (RTrap t)
  | None => None
  end.

(* None is a stuck (ill-typed or out-of-range) program, which the closed
   validator rejects; see type_safety below. *)
Fixpoint eval (env : list value) (e : expr) : option result :=
  match e with
  (* tc0.pc.dispatch [int ...] / [bool ...]: literals are values *)
  | EInt n => if fits n then Some (ROk (VInt n)) else None
  | EBool b => Some (ROk (VBool b))
  (* tc0.pc.dispatch [var ...]: tc0.pc.lookup in the environment *)
  | EVar i => match nth_error env i with Some v => Some (ROk v) | None => None end
  (* tc0.pc.collect then tc0.pc.pure -> tc0.arithmetic neg *)
  | ENeg a => bind (eval env a) (fun v =>
      match v with VInt x => Some (checked (- x)) | _ => None end)
  (* tc0.pc.collect evaluates operands left to right; then tc0.arithmetic *)
  | EBin op a b => bind (eval env a) (fun va => bind (eval env b) (fun vb =>
      match va, vb with VInt x, VInt y => Some (arith op x y) | _, _ => None end))
  | ECmp op a b => bind (eval env a) (fun va => bind (eval env b) (fun vb =>
      match compare op va vb with Some c => Some (ROk (VBool c)) | None => None end))
  | ENot a => bind (eval env a) (fun v =>
      match v with VBool c => Some (ROk (VBool (negb c))) | _ => None end)
  (* tc0.pc.dispatch [if ...] pushes a branch frame; the step on
     [value [bool B]] selects one arm, the other is never evaluated *)
  | EIf c t f => bind (eval env c) (fun v =>
      match v with VBool true => eval env t | VBool false => eval env f | _ => None end)
  (* tc0.pc.dispatch [let ...] pushes a bind frame; the body runs with
     [[Id V] | OldEnv] *)
  | ELet i b => bind (eval env i) (fun v => eval (v :: env) b)
  end.

(* The entry function: one I64 parameter. *)
Definition eval_main (e : expr) (x : Z) : option result := eval [VInt x] e.

(* Types, as the closed validator assigns them. *)
Inductive ty := TInt | TBool.
Definition ty_eqb (a b : ty) : bool :=
  match a, b with TInt, TInt | TBool, TBool => true | _, _ => false end.

Fixpoint typeof (G : list ty) (e : expr) : option ty :=
  match e with
  | EInt n => if fits n then Some TInt else None
  | EBool _ => Some TBool
  | EVar i => nth_error G i
  | ENeg a => match typeof G a with Some TInt => Some TInt | _ => None end
  | EBin _ a b => match typeof G a, typeof G b with Some TInt, Some TInt => Some TInt | _, _ => None end
  | ECmp CEq a b => match typeof G a, typeof G b with
                    | Some ta, Some tb => if ty_eqb ta tb then Some TBool else None
                    | _, _ => None end
  | ECmp _ a b => match typeof G a, typeof G b with Some TInt, Some TInt => Some TBool | _, _ => None end
  | ENot a => match typeof G a with Some TBool => Some TBool | _ => None end
  | EIf c t f => match typeof G c, typeof G t, typeof G f with
                 | Some TBool, Some t1, Some t2 => if ty_eqb t1 t2 then Some t1 else None
                 | _, _, _ => None end
  | ELet i b => match typeof G i with Some ti => typeof (ti :: G) b | None => None end
  end.

Definition has_ty (v : value) (t : ty) : Prop :=
  match v, t with VInt n, TInt => lo <= n <= hi | VBool _, TBool => True | _, _ => False end.
Definition result_ty (r : result) (t : ty) : Prop :=
  match r with ROk v => has_ty v t | RTrap _ => True end.

Lemma ty_eqb_eq : forall a b, ty_eqb a b = true -> a = b.
Proof. destruct a, b; cbn; congruence. Qed.

Lemma checked_ty : forall n, result_ty (checked n) TInt.
Proof. intros. unfold checked. destruct (fits n) eqn:E; cbn; auto. apply fits_spec; exact E. Qed.

(* Well-typed programs never get stuck: eval is total on them, and results
   have the static type. *)
Theorem type_safety : forall e G env t,
  typeof G e = Some t -> Forall2 has_ty env G ->
  exists r, eval env e = Some r /\ result_ty r t.
Proof.
  induction e; intros G env t Ht Henv; cbn in Ht |- *.
  - destruct (fits n) eqn:E; inversion Ht; subst. eexists; split; [reflexivity|].
    cbn. apply fits_spec; exact E.
  - inversion Ht; subst. eexists; split; [reflexivity|exact I].
  - revert i t Ht. induction Henv; intros [|i] t Ht; cbn in Ht |- *; try discriminate.
    + inversion Ht; subst. eexists; split; [reflexivity|exact H].
    + apply IHHenv in Ht. exact Ht.
  - destruct (typeof G e) as [[|]|] eqn:Ea; inversion Ht; subst.
    destruct (IHe _ _ _ Ea Henv) as [ra [Hra Hty]]. rewrite Hra.
    destruct ra as [[x|b]|tr]; cbn in Hty |- *; try contradiction.
    + eexists; split; [reflexivity|apply checked_ty].
    + eexists; split; [reflexivity|exact I].
  - destruct (typeof G e1) as [[|]|] eqn:Ea; try discriminate;
    destruct (typeof G e2) as [[|]|] eqn:Eb; inversion Ht; subst.
    destruct (IHe1 _ _ _ Ea Henv) as [ra [Hra Hta]]. rewrite Hra.
    destruct ra as [[x|b]|tr]; cbn in Hta |- *; try contradiction;
      [|eexists; split; [reflexivity|exact I]].
    destruct (IHe2 _ _ _ Eb Henv) as [rb [Hrb Htb]]. rewrite Hrb.
    destruct rb as [[y|b]|tr]; cbn in Htb |- *; try contradiction;
      [|eexists; split; [reflexivity|exact I]].
    eexists; split; [reflexivity|]. destruct op; cbn; try apply checked_ty.
    destruct (y =? 0); [exact I|apply checked_ty].
  - assert (Hcase : forall ta tb, typeof G e1 = Some ta -> typeof G e2 = Some tb ->
              (op = CEq /\ ta = tb) \/ (ta = TInt /\ tb = TInt) -> t = TBool ->
              exists r, bind (eval env e1) (fun va => bind (eval env e2) (fun vb =>
                match compare op va vb with Some c => Some (ROk (VBool c)) | None => None end)) = Some r
                /\ result_ty r t).
    { intros ta tb Ea Eb Hops ->.
      destruct (IHe1 _ _ _ Ea Henv) as [ra [Hra Hta]]. rewrite Hra.
      destruct ra as [va|tr]; cbn; [|eexists; split; [reflexivity|exact I]].
      destruct (IHe2 _ _ _ Eb Henv) as [rb [Hrb Htb]]. rewrite Hrb.
      destruct rb as [vb|tr]; cbn; [|eexists; split; [reflexivity|exact I]].
      destruct Hops as [[? ?]|[? ?]]; subst;
      repeat match goal with T : ty |- _ => destruct T end;
      destruct va, vb; cbn in Hta, Htb; try contradiction;
      try (destruct op); cbn; eexists; split; try reflexivity; exact I. }
    destruct op;
    destruct (typeof G e1) as [[|]|] eqn:Ea; try discriminate;
    destruct (typeof G e2) as [[|]|] eqn:Eb; cbn in Ht; inversion Ht; subst;
    eapply Hcase; eauto.
  - destruct (typeof G e) as [[|]|] eqn:Ea; inversion Ht; subst.
    destruct (IHe _ _ _ Ea Henv) as [ra [Hra Hty]]. rewrite Hra.
    destruct ra as [[x|b]|tr]; cbn in Hty |- *; try contradiction;
      eexists; split; try reflexivity; exact I.
  - destruct (typeof G e1) as [[|]|] eqn:Ec; try discriminate;
    destruct (typeof G e2) as [t1|] eqn:Et; try discriminate;
    destruct (typeof G e3) as [t2|] eqn:Ef; try discriminate.
    destruct (ty_eqb t1 t2) eqn:Eq; inversion Ht; subst.
    apply ty_eqb_eq in Eq; subst.
    destruct (IHe1 _ _ _ Ec Henv) as [rc [Hrc Htc]]. rewrite Hrc.
    destruct rc as [[x|[|]]|tr]; cbn in Htc |- *; try contradiction.
    + eapply IHe2; eauto.
    + eapply IHe3; eauto.
    + eexists; split; [reflexivity|exact I].
  - destruct (typeof G e1) as [ti|] eqn:Ei; try discriminate.
    destruct (IHe1 _ _ _ Ei Henv) as [ri [Hri Hti]]. rewrite Hri.
    destruct ri as [vi|tr]; cbn in Hti |- *; [|eexists; split; [reflexivity|exact I]].
    eapply IHe2; eauto.
Qed.
