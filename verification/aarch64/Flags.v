(* What the modelled instructions compute, proved from the pseudocode
   transcriptions in Machine.v against mathematical specifications: the
   flags of AddWithCarry, the conditions B.cond/CSINC test, the SMULH/MUL
   overflow test, SDIV, and the MOVZ/MOVK constant sequence.  Nothing here is
   defined as its answer; each statement relates a pseudocode result to
   integer arithmetic. *)
From Stdlib Require Import ZArith List Bool Lia.
From FenrirARM Require Core Machine.
Import Machine.
Open Scope Z_scope.

Ltac consts := unfold Core.lo, Core.hi, Core.modulus in *.

Lemma signed_eqb_fits : forall s, (signed s =? s) = fits s.
Proof.
  intros s. destruct (fits s) eqn:E.
  - rewrite (Core.signed_fits s E). apply Z.eqb_refl.
  - apply Z.eqb_neq. intros H. pose proof (signed_range s) as R. rewrite H in R.
    apply fits_spec in R. congruence.
Qed.

Lemma uint_signed : forall z, uint (signed z) = z mod modulus.
Proof.
  intros. unfold uint, Core.signed. consts.
  rewrite <- (Z.mod_add _ (-1) 18446744073709551616) at 1 by lia.
  Z.div_mod_to_equations. lia.
Qed.

Lemma signed_out : forall s, -modulus <= s <= modulus - 1 -> fits s = false ->
  (hi < s /\ signed s = s - modulus) \/ (s < lo /\ signed s = s + modulus).
Proof.
  intros s Hr Hf. destruct (Z_lt_ge_dec s lo) as [L|L].
  - right. split; auto. apply Core.signed_lower. consts. lia.
  - destruct (Z_le_gt_dec s hi) as [U|U].
    + assert (fits s = true) by (apply fits_spec; lia). congruence.
    + left. split; [lia|]. apply Core.signed_upper. lia.
Qed.

(* AddWithCarry for ADD/ADDS (carry 0) and SUB/SUBS (NOT y, carry 1). *)
Definition addsub_math (sub : bool) (x y : Z) : Z := if sub then x - y else x + y.

Lemma addsub_fst : forall sub x y, fst (addsub sub x y) = signed (addsub_math sub x y).
Proof.
  intros [|] x y; unfold addsub, add_with_carry, addsub_math, bnot, uint; cbn [fst];
  apply signed_congr; consts; Z.div_mod_to_equations; lia.
Qed.

Lemma addsub_N : forall sub x y, fN (snd (addsub sub x y)) = (signed (addsub_math sub x y) <? 0).
Proof. intros. pose proof (addsub_fst sub x y) as F. destruct sub; cbn in F |- *; rewrite F; reflexivity. Qed.

Lemma addsub_Z : forall sub x y, fZ (snd (addsub sub x y)) = (signed (addsub_math sub x y) =? 0).
Proof. intros. pose proof (addsub_fst sub x y) as F. destruct sub; cbn in F |- *; rewrite F; reflexivity. Qed.

Lemma addsub_V : forall sub x y, fV (snd (addsub sub x y)) = negb (fits (addsub_math sub x y)).
Proof.
  intros. pose proof (addsub_fst sub x y) as F.
  destruct sub; unfold addsub, add_with_carry, addsub_math, bnot in *; cbn [fst snd fV] in *;
  rewrite F; f_equal; [replace (x + (- y - 1) + 1) with (x - y) by ring|replace (x + y + 0) with (x + y) by ring];
  apply signed_eqb_fits.
Qed.

(* ConditionHolds on the condition codes used, by computation. *)
Lemma cond_EQ : forall f, condition_holds EQ f = fZ f. Proof. reflexivity. Qed.
Lemma cond_NE : forall f, condition_holds NE f = negb (fZ f). Proof. reflexivity. Qed.
Lemma cond_VC : forall f, condition_holds VC f = negb (fV f). Proof. reflexivity. Qed.
Lemma cond_GE : forall f, condition_holds GE f = Bool.eqb (fN f) (fV f). Proof. reflexivity. Qed.
Lemma cond_LT : forall f, condition_holds LT f = negb (Bool.eqb (fN f) (fV f)). Proof. reflexivity. Qed.
Lemma cond_GT : forall f, condition_holds GT f = Bool.eqb (fN f) (fV f) && negb (fZ f). Proof. reflexivity. Qed.
Lemma cond_LE : forall f, condition_holds LE f = negb (Bool.eqb (fN f) (fV f) && negb (fZ f)). Proof. reflexivity. Qed.

(* The integer conditions a compare (SUBS) leaves for B.cond/CSINC. *)
Lemma sub_conditions : forall x y, lo <= x <= hi -> lo <= y <= hi ->
  Bool.eqb (fN (snd (addsub true x y))) (fV (snd (addsub true x y))) = (y <=? x) /\
  fZ (snd (addsub true x y)) = (x =? y).
Proof.
  intros x y Hx Hy.
  rewrite addsub_N, addsub_Z, addsub_V. unfold addsub_math.
  destruct (fits (x - y)) eqn:F.
  - rewrite (Core.signed_fits _ F). apply fits_spec in F.
    repeat split;
    repeat match goal with
           | |- context [Z.ltb ?a ?b] => destruct (Z.ltb_spec a b)
           | |- context [Z.leb ?a ?b] => destruct (Z.leb_spec a b)
           | |- context [Z.eqb ?a ?b] => destruct (Z.eqb_spec a b)
           end; cbn; try reflexivity; consts; lia.
  - destruct (signed_out (x - y)) as [[L E]|[L E]]; auto; try (consts; lia); rewrite E;
    repeat split;
    repeat match goal with
           | |- context [Z.ltb ?a ?b] => destruct (Z.ltb_spec a b)
           | |- context [Z.leb ?a ?b] => destruct (Z.leb_spec a b)
           | |- context [Z.eqb ?a ?b] => destruct (Z.eqb_spec a b)
           end; cbn; try reflexivity; consts; lia.
Qed.

Lemma cmp_conditions : forall x y, lo <= x <= hi -> lo <= y <= hi ->
  let f := snd (addsub true x y) in
  condition_holds GE f = (y <=? x) /\ condition_holds LT f = (x <? y) /\
  condition_holds GT f = (y <? x) /\ condition_holds LE f = (x <=? y) /\
  condition_holds EQ f = (x =? y) /\ condition_holds NE f = negb (x =? y).
Proof.
  intros x y Hx Hy f. destruct (sub_conditions x y Hx Hy) as [Hge Hz].
  rewrite (cond_GE f), (cond_LT f), (cond_GT f), (cond_LE f), (cond_EQ f), (cond_NE f).
  unfold f. rewrite Hge, Hz.
  destruct (Z.leb_spec y x); destruct (Z.ltb_spec x y); destruct (Z.ltb_spec y x);
  destruct (Z.leb_spec x y); destruct (Z.eqb_spec x y); cbn; repeat split; lia.
Qed.

Lemma vc_condition : forall sub x y, condition_holds VC (snd (addsub sub x y)) = fits (addsub_math sub x y).
Proof.
  intros. rewrite cond_VC, addsub_V. destruct (fits _); reflexivity.
Qed.

Lemma ne_condition : forall sub x y, condition_holds NE (snd (addsub sub x y)) = negb (signed (addsub_math sub x y) =? 0).
Proof.
  intros. rewrite cond_NE, addsub_Z. reflexivity.
Qed.

Lemma eq_condition : forall sub x y, condition_holds EQ (snd (addsub sub x y)) = (signed (addsub_math sub x y) =? 0).
Proof.
  intros. rewrite cond_EQ, addsub_Z. reflexivity.
Qed.

(* Shifted-register operand with LSL #0 is the register itself. *)
Lemma lsl0 : forall v, lo <= v <= hi -> shift_reg v LSL 0 = v.
Proof. intros. cbn [shift_reg]. rewrite Z.mul_1_r. unfold uint.
  rewrite <- (signed_fits v) at 2 by assumption. apply signed_congr. apply Zmod_mod. Qed.

(* MUL low half, SMULH high half, and the test CMP Xhi, Xlo, ASR #63. *)
Lemma madd_low : forall a b, signed (uint 0 + uint a * uint b) = signed (a * b).
Proof. intros. apply signed_congr. unfold uint. rewrite Zmod_0_l, Z.add_0_l, <- Z.mul_mod by (consts; lia). reflexivity. Qed.

Lemma mul_check : forall a b, lo <= a <= hi -> lo <= b <= hi ->
  condition_holds EQ (snd (addsub true (signed (((a * b) mod 2 ^ 128) / 2 ^ 64))
                                       (shift_reg (signed (a * b)) ASR 63)))
  = fits (a * b).
Proof.
  intros a b Ha Hb. rewrite eq_condition. unfold addsub_math. cbn [shift_reg].
  assert (HP : -85070591730234615865843651857942052864 <= a * b <= 85070591730234615865843651857942052864)
    by (consts; nia).
  revert HP. generalize (a * b). intros P HP. clear a b Ha Hb.
  change (2 ^ 128) with 340282366920938463463374607431768211456.
  change (2 ^ 64) with 18446744073709551616. change (2 ^ 63) with 9223372036854775808.
  unfold Core.fits, Core.signed. consts.
  destruct (Z.leb_spec (-9223372036854775808) P); destruct (Z.leb_spec P 9223372036854775807);
  cbn [andb]; Z.div_mod_to_equations;
  match goal with |- context [Z.eqb ?u 0] => destruct (Z.eqb_spec u 0) end; lia.
Qed.

(* SDIV result when the divisor is non-zero and the pair is not MIN / -1. *)
Lemma quot_fits : forall a b, lo <= a <= hi -> lo <= b <= hi -> b <> 0 -> ~ (a = lo /\ b = -1) ->
  lo <= Z.quot a b <= hi.
Proof.
  intros a b Ha Hb Hb0 Hn.
  destruct (Z.eq_dec b (-1)) as [->|Hm1].
  - replace (Z.quot a (-1)) with (- Z.quot a 1) by (symmetry; apply (Z.quot_opp_r a 1); lia).
    rewrite Z.quot_1_r. consts. lia.
  - assert (Habs : Z.abs (Z.quot a b) <= Z.abs a).
    { rewrite <- Z.quot_abs by lia. apply Z.quot_le_upper_bound; [lia|]. nia. }
    destruct (Z.eq_dec b 1) as [->|H1].
    + rewrite Z.quot_1_r. assumption.
    + assert (Habs2 : Z.abs (Z.quot a b) <= Z.abs a / 2).
      { rewrite <- Z.quot_abs by lia.
        rewrite Z.quot_div_nonneg by lia.
        apply Z.div_le_compat_l; lia. }
      consts. Z.div_mod_to_equations. lia.
Qed.

Lemma quot_overflow : forall a b, lo <= a <= hi -> lo <= b <= hi -> b <> 0 ->
  fits (Z.quot a b) = negb ((a =? lo) && (b =? -1)).
Proof.
  intros a b Ha Hb Hb0.
  destruct (Z.eqb_spec a lo); destruct (Z.eqb_spec b (-1)); cbn [andb negb].
  - subst. reflexivity.
  - apply fits_spec, quot_fits; auto; tauto.
  - apply fits_spec, quot_fits; auto; tauto.
  - apply fits_spec, quot_fits; auto; tauto.
Qed.

(* MOVZ then three MOVK insert the four 16-bit halves of a constant. *)
Definition half (n k : Z) : Z := (uint n / 2 ^ (16 * k)) mod 2 ^ 16.

Definition movk_val (x imm hw : Z) : Z :=
  let u := uint x in let p := 2 ^ (16 * hw) in signed (u - ((u / p) mod 2 ^ 16) * p + imm * p).

Lemma load_imm_value : forall n, lo <= n <= hi ->
  movk_val (movk_val (movk_val (signed (half n 0 * 2 ^ (16 * 0))) (half n 1) 1) (half n 2) 2) (half n 3) 3 = n.
Proof.
  intros n Hn. unfold movk_val, half. rewrite !uint_signed.
  transitivity (signed n); [|apply signed_fits; assumption].
  apply signed_congr. unfold uint.
  change (2 ^ (16 * 0)) with 1. change (2 ^ (16 * 1)) with 65536.
  change (2 ^ (16 * 2)) with 4294967296. change (2 ^ (16 * 3)) with 281474976710656.
  change (2 ^ 16) with 65536. consts.
  generalize (n mod 18446744073709551616) (Z.mod_pos_bound n 18446744073709551616 ltac:(lia)).
  intros U HU. Z.div_mod_to_equations. lia.
Qed.
