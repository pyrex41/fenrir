(* Profile fenrir-aarch64-checked-expr/1: compiler from Expr.v syntax to the
   instruction model of Machine.v, and its correctness. *)
From Stdlib Require Import ZArith List Bool Lia.
From FenrirARM Require Core Machine Encode Flags Expr.
Import ListNotations Machine Flags Expr.
Open Scope Z_scope.

(* ------------------------------------------------------------------ *)
(* Compiler                                                             *)

(* Result/trap convention fenrir-aarch64-result-abi/1 (ABI.md). *)
Definition trap_code (t : trap) : Z := match t with TOverflow => 1 | TDivZero => 2 end.
Definition repr (v : value) : Z := match v with VInt n => n | VBool b => if b then 1 else 0 end.

Definition push0 : instr := StrPre 0 (-16).        (* str x0, [sp, #-16]! *)
Definition pop1 : instr := LdrPost 1 16.           (* ldr x1, [sp], #16 *)
(* mov sp, x9 ; mov x1, #code ; ret *)
Definition trap_seq (c : Z) : list instr := [AddSubImm false false 31 9 0; Movz 1 c 0; Ret 30].
(* movz x0, #h0 ; movk x0, #h1, lsl 16 ; movk x0, #h2, lsl 32 ; movk x0, #h3, lsl 48 *)
Definition load_imm (n : Z) : list instr :=
  [Movz 0 (half n 0) 0; Movk 0 (half n 1) 1; Movk 0 (half n 2) 2; Movk 0 (half n 3) 3].

(* Operands: x1 = left, x0 = right.  Result in x0. *)
Definition binop_code (op : binop) : list instr :=
  match op with
  | OAdd => [AddSubReg false true 0 1 0 LSL 0; Bcond VC 4] ++ trap_seq 1
  | OSub => [AddSubReg true true 0 1 0 LSL 0; Bcond VC 4] ++ trap_seq 1
  (* smulh x3, x1, x0 ; mul x0, x1, x0 ; cmp x3, x0, asr #63 ; b.eq ok *)
  | OMul => [Smulh 3 1 0; Madd 0 1 0 31; AddSubReg true true 31 3 0 ASR 63; Bcond EQ 4] ++ trap_seq 1
  (* cbnz x0, nz ; trap DivZero ; nz: cmn x0, #1 ; b.ne ok ; negs xzr, x1 ; b.vc ok ;
     trap Overflow ; ok: sdiv x0, x1, x0 *)
  | ODiv => [Cbz true 0 4] ++ trap_seq 2 ++
            [AddSubImm false true 31 0 1; Bcond NE 6; AddSubReg true true 31 31 1 LSL 0; Bcond VC 4] ++
            trap_seq 1 ++ [Sdiv 0 1 0]
  end.

(* cset x0, cond is csinc x0, xzr, xzr, invert(cond). *)
Definition cset_inv (op : cmpop) : Z :=
  match op with CLt => GE | CLe => GT | CGt => LE | CGe => LT | CEq => NE end.

(* ctx maps each de Bruijn variable to its stack slot j, at address base - 16 (j + 1);
   d is the number of slots in use below base. *)
Fixpoint comp (ctx : list Z) (d : Z) (e : expr) : list instr :=
  match e with
  | EInt n => load_imm n
  | EBool b => [Movz 0 (if b then 1 else 0) 0]
  | EVar i => match nth_error ctx i with Some j => [LdrUoff 0 (2 * (d - 1 - j))] | None => [] end
  | ENeg a => comp ctx d a ++ [AddSubReg true true 0 31 0 LSL 0; Bcond VC 4] ++ trap_seq 1
  | EBin op a b => comp ctx d a ++ [push0] ++ comp ctx (d + 1) b ++ [pop1] ++ binop_code op
  | ECmp op a b => comp ctx d a ++ [push0] ++ comp ctx (d + 1) b ++ [pop1] ++
                   [AddSubReg true true 31 1 0 LSL 0; Csinc 0 31 31 (cset_inv op)]
  | ENot a => comp ctx d a ++ [AddSubImm true true 31 0 0; Csinc 0 31 31 NE]
  | EIf c t f =>
      comp ctx d c ++ [Cbz false 0 (Z.of_nat (length (comp ctx d t)) + 2)] ++ comp ctx d t ++
      [Bimm (Z.of_nat (length (comp ctx d f)) + 1)] ++ comp ctx d f
  | ELet i b => comp ctx d i ++ [push0] ++ comp (d :: ctx) (d + 1) b ++ [AddSubImm false false 31 31 16]
  end.

(* mov x9, sp ; str x0, [sp, #-16]! ; body ; add sp, sp, #16 ; mov x1, #0 ; ret *)
Definition prologue : list instr := [AddSubImm false false 9 31 0; push0].
Definition epilogue : list instr := [AddSubImm false false 31 31 16; Movz 1 0 0; Ret 30].
Definition compile_fn (e : expr) : list instr := prologue ++ comp [0] 1 e ++ epilogue.

(* Extra stack slots used while evaluating e. *)
Fixpoint depth (e : expr) : Z :=
  match e with
  | EInt _ | EBool _ | EVar _ => 0
  | ENeg a | ENot a => depth a
  | EBin _ a b | ECmp _ a b => Z.max (depth a) (1 + depth b)
  | EIf c t f => Z.max (depth c) (Z.max (depth t) (depth f))
  | ELet i b => Z.max (depth i) (1 + depth b)
  end.

Lemma depth_nonneg : forall e, 0 <= depth e.
Proof. induction e; cbn; lia. Qed.

(* ------------------------------------------------------------------ *)
(* Code placement                                                       *)

Definition code_at (code : list instr) (p : Z) (frag : list instr) : Prop :=
  exists pre post, code = pre ++ frag ++ post /\ p = 4 * Z.of_nat (length pre).

Lemma code_at_fetch : forall code p i rest, code_at code p (i :: rest) -> fetch code p = Some i.
Proof.
  intros code p i rest [pre [post [-> ->]]]. unfold fetch.
  replace ((4 * Z.of_nat (length pre) <? 0) || negb ((4 * Z.of_nat (length pre)) mod 4 =? 0)) with false.
  2: { symmetry. apply orb_false_iff. split; [apply Z.ltb_ge; lia|].
       rewrite Z.mul_comm, Z.mod_mul by lia. reflexivity. }
  replace (Z.to_nat (4 * Z.of_nat (length pre) / 4)) with (length pre)
    by (rewrite Z.mul_comm, Z.div_mul by lia; lia).
  rewrite nth_error_app2 by lia. rewrite Nat.sub_diag. reflexivity.
Qed.

Lemma code_at_app_l : forall code p a b, code_at code p (a ++ b) -> code_at code p a.
Proof. intros code p a b [pre [post [-> ->]]]. exists pre, (b ++ post). split; auto. rewrite <- app_assoc. reflexivity. Qed.

Lemma code_at_app_r : forall code p a b, code_at code p (a ++ b) ->
  code_at code (p + 4 * Z.of_nat (length a)) b.
Proof. intros code p a b [pre [post [-> ->]]]. exists (pre ++ a), post. split.
  - rewrite <- (app_assoc pre a), <- (app_assoc a b). reflexivity.
  - rewrite length_app. lia. Qed.

Lemma code_at_cons : forall code p i b, code_at code p (i :: b) -> code_at code (p + 4) b.
Proof. intros. apply (code_at_app_r code p [i] b) in H. exact H. Qed.

(* ------------------------------------------------------------------ *)
(* Reachability with a step bound                                       *)

Definition reach (code : list instr) (s : mstate) (m : nat) (P : mstate -> Prop) : Prop :=
  exists n s', steps code n s s' /\ (n <= m)%nat /\ P s'.

Lemma reach_now : forall code s m (P : mstate -> Prop), P s -> reach code s m P.
Proof. intros. exists 0%nat, s. split; [constructor|split; [lia|auto]]. Qed.

Lemma reach_step : forall code s s1 m P, step code s = Some (Next s1) -> reach code s1 m P -> reach code s (S m) P.
Proof. intros code s s1 m P H [n [s' [Hs [Hn HP]]]]. exists (S n), s'. split; [econstructor; eauto|split; [lia|auto]]. Qed.

Lemma reach_seq : forall code s m1 m2 (Q P : mstate -> Prop),
  reach code s m1 Q -> (forall s1, Q s1 -> reach code s1 m2 P) -> reach code s (m1 + m2) P.
Proof.
  intros code s m1 m2 Q P [n1 [s1 [H1 [Hn1 HQ]]]] HK. destruct (HK s1 HQ) as [n2 [s2 [H2 [Hn2 HP]]]].
  exists (n1 + n2)%nat, s2. split; [eapply steps_trans; eauto|split; [lia|auto]].
Qed.

Lemma reach_weaken : forall code s m m' (P P' : mstate -> Prop),
  reach code s m P -> (m <= m')%nat -> (forall x, P x -> P' x) -> reach code s m' P'.
Proof. intros code s m m' P P' [n [s' [H [Hn HP]]]] Hm HPP. exists n, s'. split; [auto|split; [lia|auto]]. Qed.

Lemma step_at : forall code p i rest s, code_at code p (i :: rest) -> pc s = p -> step code s = exec i s.
Proof. intros. unfold step. rewrite H0, (code_at_fetch _ _ _ _ H). reflexivity. Qed.

(* ------------------------------------------------------------------ *)
(* Effects of the instructions the compiler emits                       *)

Ltac consts := unfold Core.lo, Core.hi, Core.modulus in *.

Lemma sp_aligned_true : forall s, sp s mod 16 = 0 -> sp_aligned s = true.
Proof. intros s H. unfold sp_aligned. rewrite H. reflexivity. Qed.

Lemma wf_sp : forall s, wf s -> lo <= sp s <= hi. Proof. intros s [_ [_ H]]. exact H. Qed.
Lemma wf_gpr : forall s r, wf s -> lo <= gpr s r <= hi. Proof. intros s r [H _]. apply H. Qed.
Lemma wf_mem : forall s a, wf s -> lo <= mem s a <= hi. Proof. intros s a [_ [H _]]. apply H. Qed.

Lemma reach_step_wf : forall code s s1 m P, wf s -> step code s = Some (Next s1) ->
  (wf s1 -> reach code s1 m P) -> reach code s (S m) P.
Proof. intros. eapply reach_step; eauto. apply H1. eapply step_wf; eauto. Qed.

Lemma reach_wf : forall code s m P, wf s -> reach code s m P -> reach code s m (fun s' => wf s' /\ P s').
Proof. intros code s m P W [n [s' [H [Hn HP]]]]. exists n, s'. split; auto. split; auto.
  split; auto. eapply steps_wf; eauto. Qed.

Lemma exec_push : forall s, wf s -> sp s mod 16 = 0 -> lo <= sp s - 16 ->
  exec push0 s = Some (Next (MState (pc s + 4) (gpr s) (sp s - 16) (nzcv s) (upd (mem s) (sp s - 16) (gpr s 0)))).
Proof.
  intros s W Ha Hl. pose proof (wf_sp s W). unfold push0, exec. rewrite sp_aligned_true by assumption.
  cbv zeta. rewrite (signed_fits (sp s + -16)) by lia. replace (sp s + -16) with (sp s - 16) by ring.
  reflexivity.
Qed.

Lemma exec_pop : forall s, wf s -> sp s mod 16 = 0 -> sp s + 16 <= hi ->
  exec pop1 s = Some (Next (MState (pc s + 4) (upd (gpr s) 1 (mem s (sp s))) (sp s + 16) (nzcv s) (mem s))).
Proof.
  intros s W Ha Hh. pose proof (wf_sp s W). unfold pop1, exec. rewrite sp_aligned_true by assumption.
  cbv zeta. rewrite (signed_fits (sp s + 16)) by lia. reflexivity.
Qed.

Lemma exec_ldr : forall s k, sp s mod 16 = 0 -> lo <= sp s + k * 8 <= hi ->
  exec (LdrUoff 0 k) s = Some (Next (MState (pc s + 4) (upd (gpr s) 0 (mem s (sp s + k * 8))) (sp s) (nzcv s) (mem s))).
Proof.
  intros s k Ha Hr. unfold exec. rewrite sp_aligned_true by assumption.
  rewrite (signed_fits (sp s + k * 8)) by lia. reflexivity.
Qed.

Lemma exec_addsp : forall s, wf s -> sp s + 16 <= hi ->
  exec (AddSubImm false false 31 31 16) s = Some (Next (MState (pc s + 4) (gpr s) (sp s + 16) (nzcv s) (mem s))).
Proof.
  intros s W Hh. pose proof (wf_sp s W). unfold exec. cbv zeta.
  change (rd_sp s 31) with (sp s). rewrite addsub_fst. unfold addsub_math.
  rewrite signed_fits by lia. reflexivity.
Qed.

Lemma exec_movsp9 : forall s, wf s ->
  exec (AddSubImm false false 31 9 0) s = Some (Next (MState (pc s + 4) (gpr s) (gpr s 9) (nzcv s) (mem s))).
Proof.
  intros s W. pose proof (wf_gpr s 9 W). unfold exec. cbv zeta.
  change (rd_sp s 9) with (gpr s 9). rewrite addsub_fst. unfold addsub_math.
  rewrite Z.add_0_r, signed_fits by lia. reflexivity.
Qed.

Lemma exec_mov9sp : forall s, wf s ->
  exec (AddSubImm false false 9 31 0) s = Some (Next (MState (pc s + 4) (upd (gpr s) 9 (sp s)) (sp s) (nzcv s) (mem s))).
Proof.
  intros s W. pose proof (wf_sp s W). unfold exec. cbv zeta.
  change (rd_sp s 31) with (sp s). rewrite addsub_fst. unfold addsub_math.
  rewrite Z.add_0_r, signed_fits by lia. reflexivity.
Qed.

Lemma exec_movz : forall s r imm hw, (r =? 31) = false ->
  exec (Movz r imm hw) s = Some (Next (MState (pc s + 4) (upd (gpr s) r (signed (imm * 2 ^ (16 * hw)))) (sp s) (nzcv s) (mem s))).
Proof. intros s r imm hw H. unfold exec, wr_zr. rewrite H. reflexivity. Qed.

Lemma movz_small : forall imm, 0 <= imm < 65536 -> signed (imm * 2 ^ (16 * 0)) = imm.
Proof. intros. change (2 ^ (16 * 0)) with 1. rewrite Z.mul_1_r. apply signed_fits. consts. lia. Qed.

Lemma exec_movk : forall s imm hw,
  exec (Movk 0 imm hw) s = Some (Next (MState (pc s + 4) (upd (gpr s) 0 (movk_val (gpr s 0) imm hw)) (sp s) (nzcv s) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_ret : forall s, exec (Ret 30) s = Some (Halt (set_pc s (gpr s 30))).
Proof. reflexivity. Qed.

(* ADDS/SUBS (shifted register, LSL #0) into a register, and into XZR (CMP). *)
Lemma exec_sreg : forall s sub rd rn rm, wf s -> (rd =? 31) = false ->
  exec (AddSubReg sub true rd rn rm LSL 0) s =
  Some (Next (MState (pc s + 4) (upd (gpr s) rd (signed (addsub_math sub (rd_zr s rn) (rd_zr s rm))))
                     (sp s) (snd (addsub sub (rd_zr s rn) (rd_zr s rm))) (mem s))).
Proof.
  intros s sub rd rn rm W H. unfold exec. cbv zeta.
  rewrite (lsl0 (rd_zr s rm)) by (apply rd_zr_range; exact W).
  rewrite addsub_fst. unfold wr_zr. rewrite H. reflexivity.
Qed.

Lemma exec_sreg_cmp : forall s sub rn rm, wf s ->
  exec (AddSubReg sub true 31 rn rm LSL 0) s =
  Some (Next (MState (pc s + 4) (gpr s) (sp s) (snd (addsub sub (rd_zr s rn) (rd_zr s rm))) (mem s))).
Proof.
  intros s sub rn rm W. unfold exec. cbv zeta.
  rewrite (lsl0 (rd_zr s rm)) by (apply rd_zr_range; exact W). reflexivity.
Qed.

Lemma exec_cmp_asr : forall s,
  exec (AddSubReg true true 31 3 0 ASR 63) s =
  Some (Next (MState (pc s + 4) (gpr s) (sp s) (snd (addsub true (gpr s 3) (shift_reg (gpr s 0) ASR 63))) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_simm_cmp : forall s sub rn imm,
  exec (AddSubImm sub true 31 rn imm) s =
  Some (Next (MState (pc s + 4) (gpr s) (sp s) (snd (addsub sub (rd_sp s rn) imm)) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_bcond : forall s c k,
  exec (Bcond c k) s = Some (Next (MState (if condition_holds c (nzcv s) then pc s + k * 4 else pc s + 4)
                                          (gpr s) (sp s) (nzcv s) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_cbz : forall s nz rt k,
  exec (Cbz nz rt k) s = Some (Next (MState (if xorb (rd_zr s rt =? 0) nz then pc s + k * 4 else pc s + 4)
                                            (gpr s) (sp s) (nzcv s) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_b : forall s k, exec (Bimm k) s = Some (Next (MState (pc s + k * 4) (gpr s) (sp s) (nzcv s) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_smulh : forall s,
  exec (Smulh 3 1 0) s = Some (Next (MState (pc s + 4)
    (upd (gpr s) 3 (signed (((gpr s 1 * gpr s 0) mod 2 ^ 128) / 2 ^ 64))) (sp s) (nzcv s) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_mul : forall s,
  exec (Madd 0 1 0 31) s = Some (Next (MState (pc s + 4)
    (upd (gpr s) 0 (signed (gpr s 1 * gpr s 0))) (sp s) (nzcv s) (mem s))).
Proof. intros. unfold exec. rewrite <- madd_low. reflexivity. Qed.

Lemma exec_sdiv : forall s,
  exec (Sdiv 0 1 0) s = Some (Next (MState (pc s + 4)
    (upd (gpr s) 0 (if gpr s 0 =? 0 then 0 else signed (Z.quot (gpr s 1) (gpr s 0)))) (sp s) (nzcv s) (mem s))).
Proof. reflexivity. Qed.

Lemma exec_cset : forall s c,
  exec (Csinc 0 31 31 c) s = Some (Next (MState (pc s + 4)
    (upd (gpr s) 0 (if condition_holds c (nzcv s) then 0 else 1)) (sp s) (nzcv s) (mem s))).
Proof.
  intros. unfold exec. replace (signed (uint (rd_zr s 31) + 1)) with 1 by reflexivity. reflexivity.
Qed.

(* ------------------------------------------------------------------ *)
(* Straight-line pieces                                                 *)

Ltac cpc := cbn [pc gpr sp mem nzcv] in *.
(* One step of instruction i, given Hc : code_at code p (i :: rest). *)
Ltac step_with L Hc :=
  eapply reach_step_wf;
  [ assumption
  | erewrite (step_at _ _ _ _ _ Hc);
    [ apply L; repeat (first [reflexivity | assumption | (cpc; lia) | (cpc; Z.div_mod_to_equations; lia)]) | cpc; lia ]
  | intros ].

Lemma run_trap : forall code p s c, code_at code p (trap_seq c) -> pc s = p -> wf s -> 0 <= c < 65536 ->
  reach code s 2 (fun s' => fetch code (pc s') = Some (Ret 30) /\ gpr s' 1 = c /\ sp s' = gpr s 9 /\
                            (forall r, r <> 1 -> gpr s' r = gpr s r) /\ mem s' = mem s).
Proof.
  intros code p s c H Hpc W Hc. unfold trap_seq in H.
  pose proof (code_at_cons _ _ _ _ H) as H1. pose proof (code_at_cons _ _ _ _ H1) as H2.
  eapply reach_step_wf; [exact W| erewrite step_at; [apply exec_movsp9; exact W | exact H | exact Hpc] |]. intros W1.
  eapply reach_step.
  { erewrite step_at; [| exact H1 | cbn [pc]; lia]. apply exec_movz. reflexivity. }
  apply reach_now. cpc. repeat split.
  - apply (code_at_fetch _ _ _ []). replace (pc s + 4 + 4) with (p + 4 + 4) by lia. exact H2.
  - unfold upd. cbn [Z.eqb Pos.eqb]. apply movz_small. exact Hc.
  - intros r Hr. unfold upd. destruct (Z.eqb_spec r 1); [contradiction|reflexivity].
Qed.

Definition keeps (s s' : mstate) : Prop := forall r, (r < 0 \/ 3 < r) -> gpr s' r = gpr s r.
Definition mem_above (s s' : mstate) : Prop := forall a, sp s <= a -> mem s' a = mem s a.

Lemma upd_other : forall f k v a, a <> k -> upd f k v a = f a.
Proof. intros. unfold upd. destruct (Z.eqb_spec a k); [contradiction|reflexivity]. Qed.
Lemma upd_same : forall f k v, upd f k v k = v.
Proof. intros. unfold upd. rewrite Z.eqb_refl. reflexivity. Qed.

(* The arithmetic tail: x1 holds the left operand, x0 the right. *)
Definition op_post (code : list instr) (p len base : Z) (s : mstate) (r : result) (s' : mstate) : Prop :=
  keeps s s' /\ mem s' = mem s /\
  match r with
  | ROk v => pc s' = p + 4 * len /\ gpr s' 0 = repr v /\ sp s' = sp s
  | RTrap t => fetch code (pc s') = Some (Ret 30) /\ gpr s' 1 = trap_code t /\ sp s' = base
  end.


Ltac trap_tail H9 :=
  let s' := fresh "s'" in let Hf := fresh "Hf" in let Hx := fresh "Hx" in
  let Hs := fresh "Hs" in let Hk := fresh "Hk" in let Hm := fresh "Hm" in
  intros s' [Hf [Hx [Hs [Hk Hm]]]]; unfold op_post; cpc;
  split; [intros ? ?; rewrite Hk by lia; cpc; rewrite ?upd_other by lia; reflexivity|];
  split; [rewrite Hm; reflexivity|];
  split; [exact Hf|]; split; [exact Hx|];
  rewrite Hs; cpc; rewrite ?upd_other by lia; exact H9.

Ltac ok_tail :=
  apply reach_now; unfold op_post; cpc;
  split; [intros ? ?; cpc; rewrite ?upd_other by lia; reflexivity|];
  split; [reflexivity|];
  split; [cbn; lia|]; split; [rewrite ?upd_same|reflexivity].

Lemma binop_correct : forall code p s op x y base,
  code_at code p (binop_code op) -> pc s = p -> wf s ->
  gpr s 1 = x -> gpr s 0 = y -> gpr s 9 = base ->
  reach code s (length (binop_code op)) (op_post code p (Z.of_nat (length (binop_code op))) base s (arith op x y)).
Proof.
  intros code p s op x y base H Hpc W H1 H0 H9.
  assert (Rx : lo <= x <= hi) by (rewrite <- H1; apply wf_gpr; exact W).
  assert (Ry : lo <= y <= hi) by (rewrite <- H0; apply wf_gpr; exact W).
  destruct op; cbn [binop_code app] in H |- *.
  - (* add *)
    pose proof (code_at_cons _ _ _ _ H) as Hb. pose proof (code_at_cons _ _ _ _ Hb) as Ht.
    step_with exec_sreg H. step_with exec_bcond Hb. cpc.
    unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *.
    rewrite H1, H0 in *. rewrite vc_condition. unfold addsub_math, arith, checked.
    destruct (fits (x + y)) eqn:F.
    + ok_tail. cbn [repr]. apply Core.signed_fits. exact F.
    + eapply reach_weaken.
      { apply (run_trap code (p + 4 + 4) _ 1 Ht); [cpc; lia|assumption|lia]. }
      { cbn. lia. }
      { trap_tail H9. }
  - (* sub *)
    pose proof (code_at_cons _ _ _ _ H) as Hb. pose proof (code_at_cons _ _ _ _ Hb) as Ht.
    step_with exec_sreg H. step_with exec_bcond Hb. cpc.
    unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *.
    rewrite H1, H0 in *. rewrite vc_condition. unfold addsub_math, arith, checked.
    destruct (fits (x - y)) eqn:F.
    + ok_tail. cbn [repr]. apply Core.signed_fits. exact F.
    + eapply reach_weaken.
      { apply (run_trap code (p + 4 + 4) _ 1 Ht); [cpc; lia|assumption|lia]. }
      { cbn. lia. }
      { trap_tail H9. }
  - (* mul *)
    pose proof (code_at_cons _ _ _ _ H) as Ha. pose proof (code_at_cons _ _ _ _ Ha) as Hb.
    pose proof (code_at_cons _ _ _ _ Hb) as Hc. pose proof (code_at_cons _ _ _ _ Hc) as Ht.
    step_with exec_smulh H. step_with exec_mul Ha. step_with exec_cmp_asr Hb. step_with exec_bcond Hc. cpc.
    rewrite ?upd_same in *. rewrite (upd_other _ 3 _ 1), (upd_other _ 3 _ 0) in * by lia.
    rewrite H1, H0 in *. rewrite (upd_other _ 0 _ 3), upd_same by lia. rewrite (mul_check x y Rx Ry). unfold arith, checked.
    destruct (fits (x * y)) eqn:F.
    + ok_tail. cbn [repr]. apply Core.signed_fits. exact F.
    + eapply reach_weaken.
      { apply (run_trap code (p + 4 + 4 + 4 + 4) _ 1 Ht); [cpc; lia|assumption|lia]. }
      { cbn. lia. }
      { trap_tail H9. }
  - (* div *)
    pose proof (code_at_cons _ _ _ _ H) as H01.
    pose proof (code_at_app_r _ _ (trap_seq 2) _ H01) as H04. replace (Z.of_nat (length (trap_seq 2))) with 3 in H04 by reflexivity.
    pose proof (code_at_cons _ _ _ _ H04) as H05. pose proof (code_at_cons _ _ _ _ H05) as H06.
    pose proof (code_at_cons _ _ _ _ H06) as H07. pose proof (code_at_cons _ _ _ _ H07) as H08.
    pose proof (code_at_app_r _ _ (trap_seq 1) _ H08) as H11. replace (Z.of_nat (length (trap_seq 1))) with 3 in H11 by reflexivity.
    pose proof (code_at_app_l _ _ (trap_seq 2) _ H01) as T2.
    pose proof (code_at_app_l _ _ (trap_seq 1) _ H08) as T1.
    unfold arith.
    step_with exec_cbz H. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *. rewrite H0 in *.
    destruct (Z.eqb_spec y 0) as [Y0|Y0]; cbn [xorb negb].
    + (* divisor zero *)
      eapply reach_weaken.
      { apply (run_trap code (p + 4) _ 2 T2); [cpc; lia|assumption|lia]. }
      { cbn. lia. }
      { trap_tail H9. }
    + step_with exec_simm_cmp H04. step_with exec_bcond H05. cpc.
      unfold rd_sp in *. cbn [Z.eqb Pos.eqb] in *. cpc. rewrite ?H0 in *. rewrite ne_condition. unfold addsub_math.
      assert (E1 : (signed (y + 1) =? 0) = (y =? -1)).
      { destruct (Z.eqb_spec y (-1)) as [->|N]; [reflexivity|].
        apply Z.eqb_neq. destruct (Z.eq_dec y hi) as [->|N2].
        - rewrite Core.signed_upper by (consts; lia). consts. lia.
        - rewrite signed_fits by lia. lia. }
      rewrite E1.
      assert (Hq : forall s4, pc s4 = p + 4 * 11 -> wf s4 -> gpr s4 1 = x -> gpr s4 0 = y ->
                     (forall r, (r < 0 \/ 3 < r) -> gpr s4 r = gpr s r) -> sp s4 = sp s -> mem s4 = mem s ->
                     ~ (x = lo /\ y = -1) ->
                     reach code s4 1 (op_post code p 12 base s (checked (Z.quot x y)))).
      { intros s4 P4 W4 X4 Y4 K4 S4 M4 N4.
        step_with exec_sdiv H11. apply reach_now. unfold op_post, checked. cpc. rewrite X4, Y4.
        replace (y =? 0) with false by (symmetry; apply Z.eqb_neq; exact Y0).
        rewrite (proj2 (fits_spec (Z.quot x y))) by (apply quot_fits; auto).
        split; [intros r Hr; cpc; rewrite upd_other by lia; apply K4; exact Hr|].
        split; [exact M4|]. split; [lia|]. split; [|exact S4].
        rewrite upd_same. cbn [repr]. apply signed_fits, quot_fits; auto. }
      destruct (Z.eqb_spec y (-1)) as [Ym|Ym]; cbn [negb].
      * (* divisor -1: test the dividend *)
        step_with exec_sreg_cmp H06. step_with exec_bcond H07. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *.
        cpc. rewrite ?H1 in *. rewrite vc_condition. unfold addsub_math.
        destruct (Z.eqb_spec x lo) as [Xl|Xl].
        -- replace (fits (0 - x)) with false by (rewrite Xl; reflexivity).
           eapply reach_weaken.
           { apply (run_trap code _ _ 1 T1); [cpc; lia|assumption|lia]. }
           { cbn. lia. }
           { replace (checked (Z.quot x y)) with (RTrap TOverflow) by (rewrite Xl, Ym; reflexivity). trap_tail H9. }
        -- replace (fits (0 - x)) with true by (symmetry; apply fits_spec; consts; lia).
           eapply reach_weaken. { apply Hq; cpc; auto; try lia; tauto. } { cbn. lia. } { auto. }
      * (* any other non-zero divisor *)
        eapply reach_weaken. { apply Hq; cpc; auto; try lia; tauto. } { cbn. lia. } { auto. }
Qed.

(* ------------------------------------------------------------------ *)
(* Unary and comparison tails                                           *)

Lemma neg_correct : forall code p s x base,
  code_at code p ([AddSubReg true true 0 31 0 LSL 0; Bcond VC 4] ++ trap_seq 1) -> pc s = p -> wf s ->
  gpr s 0 = x -> gpr s 9 = base ->
  reach code s 5 (op_post code p 5 base s (checked (- x))).
Proof.
  intros code p s x base H Hpc W H0 H9. cbn [app] in H.
  assert (Rx : lo <= x <= hi) by (rewrite <- H0; apply wf_gpr; exact W).
  pose proof (code_at_cons _ _ _ _ H) as Hb. pose proof (code_at_cons _ _ _ _ Hb) as Ht.
  step_with exec_sreg H. step_with exec_bcond Hb. cpc.
  unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *.
  rewrite H0 in *. rewrite vc_condition. unfold addsub_math, checked.
  replace (0 - x) with (- x) by ring.
  destruct (fits (- x)) eqn:F.
  - ok_tail. cbn [repr]. apply Core.signed_fits. exact F.
  - eapply reach_weaken.
    { apply (run_trap code (p + 4 + 4) _ 1 Ht); [cpc; lia|assumption|lia]. }
    { lia. }
    { trap_tail H9. }
Qed.

Lemma cmp_correct : forall code p s op va vb c base,
  code_at code p [AddSubReg true true 31 1 0 LSL 0; Csinc 0 31 31 (cset_inv op)] -> pc s = p -> wf s ->
  gpr s 1 = repr va -> gpr s 0 = repr vb -> compare op va vb = Some c ->
  reach code s 2 (op_post code p 2 base s (ROk (VBool c))).
Proof.
  intros code p s op va vb c base H Hpc W H1 H0 Hc.
  pose proof (code_at_cons _ _ _ _ H) as Hb.
  assert (Ra : lo <= repr va <= hi) by (rewrite <- H1; apply wf_gpr; exact W).
  assert (Rb : lo <= repr vb <= hi) by (rewrite <- H0; apply wf_gpr; exact W).
  step_with exec_sreg_cmp H. step_with exec_cset Hb. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *.
  rewrite H1, H0 in *.
  destruct (cmp_conditions (repr va) (repr vb) Ra Rb) as [Ge [Lt [Gt [Le [Eq Ne]]]]].
  apply reach_now. unfold op_post. cpc.
  split; [intros r Hr; cpc; rewrite upd_other by lia; reflexivity|].
  split; [reflexivity|]. split; [lia|]. split; [|reflexivity].
  rewrite upd_same. clear - Hc Ge Gt Le Lt Ne.
  destruct op; cbn [cset_inv]; [rewrite Ge|rewrite Gt|rewrite Le|rewrite Lt|rewrite Ne];
  destruct va as [x|bx], vb as [y|by']; cbn [compare] in Hc; try discriminate;
  inversion Hc; subst c; cbn [repr].
  - destruct (Z.leb_spec y x), (Z.ltb_spec x y); reflexivity || lia.
  - destruct (Z.ltb_spec y x), (Z.leb_spec x y); reflexivity || lia.
  - destruct (Z.leb_spec x y), (Z.ltb_spec y x); reflexivity || lia.
  - destruct (Z.ltb_spec x y), (Z.leb_spec y x); reflexivity || lia.
  - destruct (Z.eqb_spec x y); reflexivity.
  - destruct bx, by'; reflexivity.
Qed.

Lemma not_correct : forall code p s b base,
  code_at code p [AddSubImm true true 31 0 0; Csinc 0 31 31 NE] -> pc s = p -> wf s ->
  gpr s 0 = repr (VBool b) ->
  reach code s 2 (op_post code p 2 base s (ROk (VBool (negb b)))).
Proof.
  intros code p s b base H Hpc W H0.
  pose proof (code_at_cons _ _ _ _ H) as Hb.
  step_with exec_simm_cmp H. step_with exec_cset Hb. cpc. unfold rd_sp in *. cbn [Z.eqb Pos.eqb] in *.
  rewrite H0 in *. rewrite ne_condition. unfold addsub_math.
  apply reach_now. unfold op_post. cpc.
  split; [intros r Hr; cpc; rewrite upd_other by lia; reflexivity|].
  split; [reflexivity|]. split; [lia|]. split; [|reflexivity].
  rewrite upd_same. destruct b; reflexivity.
Qed.

(* ------------------------------------------------------------------ *)
(* Fragment correctness                                                 *)

Definition env_ok (base : Z) (ctx : list Z) (env : list value) (m : Z -> Z) : Prop :=
  Forall2 (fun v j => m (base - 16 * (j + 1)) = repr v) env ctx.

Definition post (code : list instr) (p : Z) (len : nat) (base : Z) (s : mstate) (r : result) (s' : mstate) : Prop :=
  keeps s s' /\ mem_above s s' /\
  match r with
  | ROk v => pc s' = p + 4 * Z.of_nat len /\ gpr s' 0 = repr v /\ sp s' = sp s
  | RTrap t => fetch code (pc s') = Some (Ret 30) /\ gpr s' 1 = trap_code t /\ sp s' = base
  end.

Definition frame (base d : Z) (ctx : list Z) (env : list value) (s : mstate) : Prop :=
  wf s /\ sp s = base - 16 * d /\ gpr s 9 = base /\ env_ok base ctx env (mem s) /\
  Forall (fun j => 0 <= j < d) ctx /\ base mod 16 = 0 /\ base <= hi /\ 1 <= d.

Definition correct (e : expr) : Prop :=
  forall env ctx d base code p s r,
    eval env e = Some r -> code_at code p (comp ctx d e) -> pc s = p -> frame base d ctx env s ->
    lo <= base - 16 * (d + depth e) ->
    reach code s (length (comp ctx d e)) (post code p (length (comp ctx d e)) base s r).

Lemma keeps_refl : forall s, keeps s s. Proof. intros s r _. reflexivity. Qed.
Lemma keeps_trans : forall s1 s2 s3, keeps s1 s2 -> keeps s2 s3 -> keeps s1 s3.
Proof. intros s1 s2 s3 A B r Hr. rewrite B, A by exact Hr. reflexivity. Qed.
Lemma mem_above_trans : forall s1 s2 s3, mem_above s1 s2 -> mem_above s2 s3 -> sp s2 <= sp s1 -> mem_above s1 s3.
Proof. intros s1 s2 s3 A B Hs a Ha. rewrite B, A by lia. reflexivity. Qed.

(* A trap inside a sub-fragment is the trap of the whole fragment. *)
Lemma post_trap_lift : forall code p p' len len' base s s1 t s',
  keeps s s1 -> mem_above s s1 -> sp s1 <= sp s ->
  post code p' len' base s1 (RTrap t) s' -> post code p len base s (RTrap t) s'.
Proof.
  intros code p p' len len' base s s1 t s' K M S [K' [M' T]].
  split; [eapply keeps_trans; eauto|]. split; [eapply mem_above_trans; eauto|]. exact T.
Qed.

Lemma chain_op : forall code p la lb base s s1 v r s',
  post code p la base s (ROk v) s1 -> op_post code (p + 4 * Z.of_nat la) (Z.of_nat lb) base s1 r s' ->
  post code p (la + lb) base s r s'.
Proof.
  intros code p la lb base s s1 v r s' [K [M [P [X S]]]] [K' [M' R]].
  split; [eapply keeps_trans; eauto|].
  split; [intros a Ha; rewrite M'; apply M; exact Ha|].
  destruct r; destruct R as [R1 [R2 R3]]; repeat split; auto; try congruence.
  rewrite R1. lia.
Qed.

Lemma frame_keep : forall base d ctx env s s',
  frame base d ctx env s -> wf s' -> keeps s s' -> mem_above s s' -> sp s' = sp s -> frame base d ctx env s'.
Proof.
  intros base d ctx env s s' [W [Sp [X9 [E [F [A [B D]]]]]]] W' K M S.
  refine (conj W' (conj _ (conj _ (conj _ (conj F (conj A (conj B D))))))).
  - congruence.
  - rewrite K by lia. exact X9.
  - unfold env_ok in *. clear - E F M Sp S.
    induction E; constructor; inversion F; subst; auto.
    rewrite M by lia. exact H.
Qed.

Lemma env_lookup : forall base ctx env m i v, env_ok base ctx env m -> nth_error env i = Some v ->
  exists j, nth_error ctx i = Some j /\ m (base - 16 * (j + 1)) = repr v.
Proof.
  intros base ctx env m i v E. revert i. induction E; intros [|i] Hi; cbn in Hi |- *; try discriminate.
  - inversion Hi; subst. eexists; split; [reflexivity|exact H].
  - apply IHE. exact Hi.
Qed.

Lemma Forall_nth : forall (P : Z -> Prop) l i j, Forall P l -> nth_error l i = Some j -> P j.
Proof. intros P l i j F H. apply nth_error_In in H. rewrite Forall_forall in F. auto. Qed.


(* ------------------------------------------------------------------ *)
(* Stack pushes and pops                                                *)

Definition pushed (s : mstate) : mstate :=
  MState (pc s + 4) (gpr s) (sp s - 16) (nzcv s) (upd (mem s) (sp s - 16) (gpr s 0)).

Lemma pushed_keeps : forall s, keeps s (pushed s). Proof. intros s r _. reflexivity. Qed.
Lemma pushed_mem_above : forall s, mem_above s (pushed s).
Proof. intros s a Ha. cbn [pushed mem]. apply upd_other. lia. Qed.

Lemma frame_pushed : forall base d ctx env s, frame base d ctx env s -> lo <= base - 16 * (d + 1) ->
  frame base (d + 1) ctx env (pushed s).
Proof.
  intros base d ctx env s [[G [M S]] [Sp [X9 [E [F [A [B D]]]]]]] L.
  refine (conj _ (conj _ (conj X9 (conj _ (conj _ (conj A (conj B _))))))).
  - split; [exact G|split]; cbn [pushed gpr mem sp]; [apply upd_range; auto|lia].
  - cbn [pushed sp]. lia.
  - unfold env_ok in *. cbn [pushed mem]. clear - E F Sp.
    induction E; constructor; inversion F; subst; auto. rewrite upd_other by lia. exact H.
  - eapply Forall_impl; [|exact F]. intros j Hj. cbn in Hj. lia.
  - lia.
Qed.

Lemma frame_pushed_let : forall base d ctx env s v, frame base d ctx env s -> lo <= base - 16 * (d + 1) ->
  gpr s 0 = repr v -> frame base (d + 1) (d :: ctx) (v :: env) (pushed s).
Proof.
  intros base d ctx env s v Fr L X.
  destruct (frame_pushed _ _ _ _ _ Fr L) as [W [Sp [X9 [E [F [A [B D]]]]]]].
  destruct Fr as [_ [Sp0 _]].
  refine (conj W (conj Sp (conj X9 (conj _ (conj _ (conj A (conj B D))))))).
  - constructor; [|exact E]. cbn [pushed mem].
    replace (base - 16 * (d + 1)) with (sp s - 16) by lia. rewrite upd_same. exact X.
  - constructor; [lia|exact F].
Qed.

Lemma push_step : forall code p rest base d ctx env s,
  code_at code p (push0 :: rest) -> pc s = p -> frame base d ctx env s -> lo <= base - 16 * (d + 1) ->
  step code s = Some (Next (pushed s)).
Proof.
  intros code p rest base d ctx env s H Hp [W [Sp [_ [_ [_ [A [B D]]]]]]] L.
  rewrite (step_at _ _ _ _ _ H Hp). apply exec_push; auto.
  - rewrite Sp. Z.div_mod_to_equations. lia.
  - lia.
Qed.

Lemma pop_step : forall code p rest s,
  code_at code p (pop1 :: rest) -> pc s = p -> wf s -> sp s mod 16 = 0 -> sp s + 16 <= hi ->
  step code s = Some (Next (MState (pc s + 4) (upd (gpr s) 1 (mem s (sp s))) (sp s + 16) (nzcv s) (mem s))).
Proof. intros. rewrite (step_at _ _ _ _ _ H H0). apply exec_pop; auto. Qed.

Lemma lift_trap : forall code p len base s r s',
  post code p len base s (RTrap r) s' ->
  forall len', post code p len' base s (RTrap r) s'.
Proof. intros code p len base s r s' [K [M T]] len'. split; [exact K|split; [exact M|exact T]]. Qed.

(* Two operands left to right: x1 := left, x0 := right, stack restored. *)
Lemma operands : forall e1 e2 env ctx d base code p s va vb rest lrest r,
  correct e1 -> correct e2 -> eval env e1 = Some (ROk va) -> eval env e2 = Some (ROk vb) ->
  code_at code p (comp ctx d e1 ++ [push0] ++ comp ctx (d + 1) e2 ++ [pop1] ++ rest) -> pc s = p ->
  frame base d ctx env s -> lo <= base - 16 * (d + Z.max (depth e1) (1 + depth e2)) ->
  (forall s4, pc s4 = p + 4 * Z.of_nat (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1) -> wf s4 ->
     gpr s4 1 = repr va -> gpr s4 0 = repr vb -> gpr s4 9 = base ->
     reach code s4 lrest (op_post code (p + 4 * Z.of_nat (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1))
                                  (Z.of_nat lrest) base s4 r)) ->
  reach code s (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + lrest)
    (post code p (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + lrest) base s r).
Proof.
  intros e1 e2 env ctx d base code p s va vb rest lrest r IH1 IH2 E1 E2 H Hp Fr L Tail.
  pose proof (depth_nonneg e1). pose proof (depth_nonneg e2).
  set (la := length (comp ctx d e1)) in *. set (lb := length (comp ctx (d + 1) e2)) in *.
  pose proof (code_at_app_l _ _ _ _ H) as Ha.
  pose proof (code_at_app_r _ _ _ _ H) as Hpush. cbn [app] in Hpush.
  pose proof (code_at_cons _ _ _ _ Hpush) as Hr.
  pose proof (code_at_app_l _ _ _ _ Hr) as Hb.
  pose proof (code_at_app_r _ _ _ _ Hr) as Hpop. cbn [app] in Hpop.
  pose proof (code_at_cons _ _ _ _ Hpop) as Hrest.
  pose proof Fr as [W [Sp [X9 [En [Fa [A16 [Bh D1]]]]]]].
  replace (la + 1 + lb + 1 + lrest)%nat with (la + (S (lb + (S lrest))))%nat by lia.
  eapply reach_seq.
  { apply reach_wf; [exact W|]. exact (IH1 env ctx d base code p s _ E1 Ha Hp Fr ltac:(lia)). }
  intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
  assert (Fr1 : frame base d ctx env s1) by (eapply frame_keep; eauto).
  eapply reach_step. { eapply push_step; [exact Hpush|exact Pc1|exact Fr1|lia]. }
  assert (Fr2 : frame base (d + 1) ctx env (pushed s1)) by (apply frame_pushed; [exact Fr1|lia]).
  assert (W2 : wf (pushed s1)) by apply Fr2.
  eapply reach_seq.
  { apply reach_wf; [exact W2|].
    exact (IH2 env ctx (d + 1) base code _ (pushed s1) _ E2 Hb ltac:(cbn [pushed pc]; lia) Fr2 ltac:(lia)). }
  intros s3 [W3 P3]. pose proof P3 as [K3 [M3 [Pc3 [X3 S3]]]].
  cbn [pushed sp pc gpr mem] in *.
  eapply reach_step_wf; [exact W3| eapply pop_step; [exact Hpop|lia|exact W3| |] |].
  { rewrite S3, S1, Sp. Z.div_mod_to_equations. lia. }
  { rewrite S3, S1, Sp. lia. }
  intros W4.
  eapply reach_weaken.
  { apply Tail; cpc.
    - lia.
    - exact W4.
    - rewrite upd_same. rewrite S3. rewrite M3 by (cbn; lia). cbn [pushed mem]. rewrite upd_same. exact X1.
    - rewrite upd_other by lia. exact X3.
    - rewrite upd_other by lia. rewrite K3 by lia. cbn [pushed gpr]. rewrite K1 by lia. exact X9. }
  { lia. }
  intros s' Q.
  assert (P4 : post code p (la + 1 + lb + 1) base s (ROk vb)
                 (MState (pc s3 + 4) (upd (gpr s3) 1 (mem s3 (sp s3))) (sp s3 + 16) (nzcv s3) (mem s3))).
  { split; [|split].
    - intros k Hk. cpc. rewrite upd_other by lia. rewrite K3 by lia. cbn [pushed gpr]. apply K1. exact Hk.
    - intros a Ha'. cpc. rewrite M3 by (cbn [pushed sp]; lia). cbn [pushed mem].
      rewrite upd_other by lia. apply M1. exact Ha'.
    - cpc. split; [|split].
      + rewrite Pc3. lia.
      + rewrite upd_other by lia. exact X3.
      + rewrite S3, S1. lia. }
  replace (la + S (lb + S lrest))%nat with ((la + 1 + lb + 1) + lrest)%nat by lia.
  eapply chain_op; [exact P4|]. exact Q.
Qed.

Lemma operands_trap1 : forall e1 e2 env ctx d base code p s t rest lrest,
  correct e1 -> eval env e1 = Some (RTrap t) ->
  code_at code p (comp ctx d e1 ++ [push0] ++ comp ctx (d + 1) e2 ++ [pop1] ++ rest) -> pc s = p ->
  frame base d ctx env s -> lo <= base - 16 * (d + Z.max (depth e1) (1 + depth e2)) ->
  reach code s (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + lrest)
    (post code p (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + lrest) base s (RTrap t)).
Proof.
  intros e1 e2 env ctx d base code p s t rest lrest IH1 E1 H Hp Fr L.
  eapply reach_weaken.
  - exact (IH1 env ctx d base code p s _ E1 (code_at_app_l _ _ _ _ H) Hp Fr ltac:(lia)).
  - lia.
  - intros s' Q. eapply lift_trap. exact Q.
Qed.

Lemma operands_trap2 : forall e1 e2 env ctx d base code p s va t rest lrest,
  correct e1 -> correct e2 -> eval env e1 = Some (ROk va) -> eval env e2 = Some (RTrap t) ->
  code_at code p (comp ctx d e1 ++ [push0] ++ comp ctx (d + 1) e2 ++ [pop1] ++ rest) -> pc s = p ->
  frame base d ctx env s -> lo <= base - 16 * (d + Z.max (depth e1) (1 + depth e2)) ->
  reach code s (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + lrest)
    (post code p (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + lrest) base s (RTrap t)).
Proof.
  intros e1 e2 env ctx d base code p s va t rest lrest IH1 IH2 E1 E2 H Hp Fr L.
  pose proof (depth_nonneg e1). pose proof (depth_nonneg e2).
  pose proof (code_at_app_l _ _ _ _ H) as Ha.
  pose proof (code_at_app_r _ _ _ _ H) as Hpush. cbn [app] in Hpush.
  pose proof (code_at_cons _ _ _ _ Hpush) as Hr.
  pose proof (code_at_app_l _ _ _ _ Hr) as Hb.
  pose proof Fr as [W _].
  eapply reach_weaken with (m := (length (comp ctx d e1) + S (length (comp ctx (d + 1) e2)))%nat); [|lia|].
  2: { intros s' Q. exact Q. }
  eapply reach_seq.
  { apply reach_wf; [exact W|]. exact (IH1 env ctx d base code p s _ E1 Ha Hp Fr ltac:(lia)). }
  intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
  assert (Fr1 : frame base d ctx env s1) by (eapply frame_keep; eauto).
  eapply reach_step. { eapply push_step; [exact Hpush|exact Pc1|exact Fr1|lia]. }
  assert (Fr2 : frame base (d + 1) ctx env (pushed s1)) by (apply frame_pushed; [exact Fr1|lia]).
  eapply reach_weaken.
  { exact (IH2 env ctx (d + 1) base code _ (pushed s1) _ E2 Hb ltac:(cbn [pushed pc]; lia) Fr2 ltac:(lia)). }
  { lia. }
  intros s' Q. eapply post_trap_lift with (s1 := pushed s1); [| | |exact Q].
  - eapply keeps_trans; [exact K1|apply pushed_keeps].
  - eapply mem_above_trans; [exact M1|apply pushed_mem_above|lia].
  - cbn [pushed sp]. lia.
Qed.

Ltac lengths := repeat rewrite length_app; cbn [length trap_seq].

Theorem comp_correct : forall e, correct e.
Proof.
  induction e; unfold correct; intros env ctx d base code p s r Ev H Hp Fr Ld;
  pose proof Fr as [W [Sp [X9 [En [Fa [A16 [Bh D1]]]]]]]; cbn [eval depth] in Ev, Ld.
  - (* EInt *)
    destruct (fits n) eqn:F; [|discriminate]. inversion Ev; subst r. cbn [comp load_imm] in H |- *.
    pose proof (code_at_cons _ _ _ _ H) as H1. pose proof (code_at_cons _ _ _ _ H1) as H2.
    pose proof (code_at_cons _ _ _ _ H2) as H3.
    step_with exec_movz H. step_with exec_movk H1. step_with exec_movk H2. step_with exec_movk H3.
    apply reach_now. unfold post. cpc. rewrite !upd_same.
    split; [intros k Hk; cpc; rewrite !upd_other by lia; reflexivity|].
    split; [intros a _; reflexivity|].
    split; [cbn; lia|]. split; [|reflexivity].
    cbn [repr]. apply load_imm_value. apply fits_spec. exact F.
  - (* EBool *)
    inversion Ev; subst r. cbn [comp] in H |- *.
    step_with exec_movz H. apply reach_now. unfold post. cpc.
    split; [intros k Hk; cpc; rewrite upd_other by lia; reflexivity|].
    split; [intros a _; reflexivity|].
    split; [cbn; lia|]. split; [|reflexivity].
    rewrite upd_same. destruct b; [apply (movz_small 1)|apply (movz_small 0)]; lia.
  - (* EVar *)
    destruct (nth_error env i) as [v|] eqn:Ei; [|discriminate]. inversion Ev; subst r.
    destruct (env_lookup _ _ _ _ _ _ En Ei) as [j [Ej Mj]].
    pose proof (Forall_nth _ _ _ _ Fa Ej) as Jr. cbn beta in Jr. cbn [comp] in H |- *. rewrite Ej in H |- *.
    step_with exec_ldr H.
    apply reach_now. unfold post. cpc.
    split; [intros k Hk; cpc; rewrite upd_other by lia; reflexivity|].
    split; [intros a _; reflexivity|].
    split; [cbn; lia|]. split; [|reflexivity].
    rewrite upd_same. rewrite <- Mj. f_equal. rewrite Sp. lia.
  - (* ENeg *)
    cbn [comp] in H |- *. lengths.
    destruct (eval env e) as [[[x|bx]|t]|] eqn:Ea; cbn [bind] in Ev; try discriminate.
    + inversion Ev; subst r.
      eapply reach_seq.
      { apply reach_wf; [exact W|]. exact (IHe env ctx d base code p s _ Ea (code_at_app_l _ _ _ _ H) Hp Fr Ld). }
      intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
      eapply reach_weaken.
      { apply (neg_correct code _ s1 x base (code_at_app_r _ _ _ _ H) Pc1 W1 X1).
        rewrite K1 by lia. exact X9. }
      { lia. }
      intros s' Q. exact (chain_op code p _ 5 base s s1 (VInt x) _ s' P1 Q).
    + inversion Ev; subst r. eapply reach_weaken.
      { exact (IHe env ctx d base code p s _ Ea (code_at_app_l _ _ _ _ H) Hp Fr Ld). }
      { lia. }
      intros s' Q. eapply lift_trap. exact Q.
  - (* EBin *)
    cbn [comp] in H |- *.
    replace (length (comp ctx d e1 ++ [push0] ++ comp ctx (d + 1) e2 ++ [pop1] ++ binop_code op))
      with (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + length (binop_code op))%nat
      by (lengths; lia).
    destruct (eval env e1) as [[va|t]|] eqn:E1; cbn [bind] in Ev; try discriminate.
    2: { inversion Ev; subst r. eapply operands_trap1; eauto. }
    destruct (eval env e2) as [[vb|t]|] eqn:E2; cbn [bind] in Ev; try discriminate.
    2: { inversion Ev; subst r. eapply operands_trap2; eauto. }
    destruct va as [x|bx]; destruct vb as [y|by']; try discriminate. inversion Ev; subst r.
    eapply operands; eauto.
    intros s4 P4 W4 X1 X0 X9'.
    pose proof (code_at_app_r _ _ _ _ H) as Hr. cbn [app] in Hr.
    apply code_at_cons in Hr. apply code_at_app_r in Hr. cbn [app] in Hr. apply code_at_cons in Hr.
    replace (p + 4 * Z.of_nat (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1)) with
      (p + 4 * Z.of_nat (length (comp ctx d e1)) + 4 + 4 * Z.of_nat (length (comp ctx (d + 1) e2)) + 4) by lia.
    eapply binop_correct; [exact Hr|rewrite P4; lia|exact W4|exact X1|exact X0|exact X9'].
  - (* ECmp *)
    cbn [comp] in H |- *.
    replace (length (comp ctx d e1 ++ [push0] ++ comp ctx (d + 1) e2 ++ [pop1] ++
                     [AddSubReg true true 31 1 0 LSL 0; Csinc 0 31 31 (cset_inv op)]))
      with (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1 + 2)%nat
      by (lengths; lia).
    destruct (eval env e1) as [[va|t]|] eqn:E1; cbn [bind] in Ev; try discriminate.
    2: { inversion Ev; subst r. eapply operands_trap1; eauto. }
    destruct (eval env e2) as [[vb|t]|] eqn:E2; cbn [bind] in Ev; try discriminate.
    2: { inversion Ev; subst r. eapply operands_trap2; eauto. }
    destruct (compare op va vb) as [c|] eqn:Ec; try discriminate. inversion Ev; subst r.
    eapply operands; eauto.
    intros s4 P4 W4 X1 X0 X9'.
    pose proof (code_at_app_r _ _ _ _ H) as Hr. cbn [app] in Hr.
    apply code_at_cons in Hr. apply code_at_app_r in Hr. cbn [app] in Hr. apply code_at_cons in Hr.
    replace (p + 4 * Z.of_nat (length (comp ctx d e1) + 1 + length (comp ctx (d + 1) e2) + 1)) with
      (p + 4 * Z.of_nat (length (comp ctx d e1)) + 4 + 4 * Z.of_nat (length (comp ctx (d + 1) e2)) + 4) by lia.
    eapply cmp_correct; [exact Hr|rewrite P4; lia|exact W4|exact X1|exact X0|exact Ec].
  - (* ENot *)
    cbn [comp] in H |- *. lengths.
    destruct (eval env e) as [[[x|bx]|t]|] eqn:Ea; cbn [bind] in Ev; try discriminate.
    + inversion Ev; subst r.
      eapply reach_seq.
      { apply reach_wf; [exact W|]. exact (IHe env ctx d base code p s _ Ea (code_at_app_l _ _ _ _ H) Hp Fr Ld). }
      intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
      eapply reach_weaken.
      { exact (not_correct code _ s1 bx base (code_at_app_r _ _ _ _ H) Pc1 W1 X1). }
      { lia. }
      intros s' Q. exact (chain_op code p _ 2 base s s1 (VBool bx) _ s' P1 Q).
    + inversion Ev; subst r. eapply reach_weaken.
      { exact (IHe env ctx d base code p s _ Ea (code_at_app_l _ _ _ _ H) Hp Fr Ld). }
      { lia. }
      intros s' Q. eapply lift_trap. exact Q.
  - (* EIf *)
    cbn [comp] in H |- *.
    set (lc := length (comp ctx d e1)) in *. set (lt := length (comp ctx d e2)) in *.
    set (lf := length (comp ctx d e3)) in *.
    replace (length (comp ctx d e1 ++ [Cbz false 0 (Z.of_nat lt + 2)] ++ comp ctx d e2 ++
                     [Bimm (Z.of_nat lf + 1)] ++ comp ctx d e3))
      with (lc + S (lt + S lf))%nat by (lengths; lia).
    pose proof (code_at_app_l _ _ _ _ H) as Hc.
    pose proof (code_at_app_r _ _ _ _ H) as Hcbz. cbn [app] in Hcbz.
    pose proof (code_at_cons _ _ _ _ Hcbz) as Hr.
    pose proof (code_at_app_l _ _ _ _ Hr) as Ht.
    pose proof (code_at_app_r _ _ _ _ Hr) as Hb. cbn [app] in Hb.
    pose proof (code_at_cons _ _ _ _ Hb) as Hf.
    destruct (eval env e1) as [[[x|[|]]|t]|] eqn:Ec; cbn [bind] in Ev; try discriminate.
    + (* then *)
      eapply reach_seq.
      { apply reach_wf; [exact W|]. exact (IHe1 env ctx d base code p s _ Ec Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
      step_with exec_cbz Hcbz. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *. rewrite X1. cbn [repr Z.eqb xorb].
      assert (Fr1 : frame base d ctx env (MState (pc s1 + 4) (gpr s1) (sp s1) (nzcv s1) (mem s1))).
      { eapply frame_keep; [exact Fr|assumption| | |cbn; exact S1].
        - intros k Hk. apply K1. exact Hk.
        - intros a Ha. apply M1. exact Ha. }
      destruct r as [v|t].
      * eapply reach_seq.
        { apply reach_wf; [assumption|].
          exact (IHe2 env ctx d base code _ (MState (pc s1 + 4) (gpr s1) (sp s1) (nzcv s1) (mem s1)) _ Ev Ht ltac:(cbn [pc]; lia) Fr1 ltac:(lia)). }
        intros s3 [W3 P3]. pose proof P3 as [K3 [M3 [Pc3 [X3 S3]]]].
        eapply reach_step. { rewrite (step_at _ _ _ _ s3 Hb ltac:(lia)). apply exec_b. }
        apply reach_now. unfold post. cpc.
        split; [intros k Hk; cpc; rewrite K3 by lia; cbn [gpr]; apply K1; exact Hk|].
        split; [intros a Ha; cpc; rewrite M3 by (cbn [sp]; lia); apply M1; exact Ha|].
        split; [lia|]. split; [exact X3|]. rewrite S3. exact S1.
      * eapply reach_weaken.
        { exact (IHe2 env ctx d base code _ (MState (pc s1 + 4) (gpr s1) (sp s1) (nzcv s1) (mem s1)) _ Ev Ht ltac:(cbn [pc]; lia) Fr1 ltac:(lia)). }
        { lia. }
        intros s' Q. eapply post_trap_lift with (s1 := MState (pc s1 + 4) (gpr s1) (sp s1) (nzcv s1) (mem s1));
          [| | |exact Q].
        { intros k Hk. apply K1. exact Hk. }
        { intros a Ha. apply M1. exact Ha. }
        { cbn. lia. }
    + (* else *)
      eapply reach_seq.
      { apply reach_wf; [exact W|]. exact (IHe1 env ctx d base code p s _ Ec Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
      step_with exec_cbz Hcbz. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *. rewrite X1. cbn [repr Z.eqb xorb].
      assert (Fr1 : frame base d ctx env (MState (pc s1 + (Z.of_nat lt + 2) * 4) (gpr s1) (sp s1) (nzcv s1) (mem s1))).
      { eapply frame_keep; [exact Fr|assumption| | |cbn; exact S1].
        - intros k Hk. apply K1. exact Hk.
        - intros a Ha. apply M1. exact Ha. }
      eapply reach_weaken.
      { exact (IHe3 env ctx d base code _ (MState (pc s1 + (Z.of_nat lt + 2) * 4) (gpr s1) (sp s1) (nzcv s1) (mem s1)) _ Ev Hf ltac:(cbn [pc]; lia) Fr1 ltac:(lia)). }
      { lia. }
      intros s' Q. destruct r as [v|t].
      * destruct Q as [K3 [M3 [Pc3 [X3 S3]]]]. unfold post.
        split; [intros k Hk; cpc; rewrite K3 by lia; cbn [gpr]; apply K1; exact Hk|].
        split; [intros a Ha; cpc; rewrite M3 by (cbn [sp]; lia); apply M1; exact Ha|].
        split; [rewrite Pc3; lia|]. split; [exact X3|]. rewrite S3. exact S1.
      * eapply post_trap_lift with (s1 := MState (pc s1 + (Z.of_nat lt + 2) * 4) (gpr s1) (sp s1) (nzcv s1) (mem s1));
          [| | |exact Q].
        { intros k Hk. apply K1. exact Hk. }
        { intros a Ha. apply M1. exact Ha. }
        { cbn. lia. }
    + (* condition traps *)
      inversion Ev; subst r. eapply reach_weaken.
      { exact (IHe1 env ctx d base code p s _ Ec Hc Hp Fr ltac:(lia)). }
      { lia. }
      intros s' Q. eapply lift_trap. exact Q.
  - (* ELet *)
    cbn [comp] in H |- *.
    set (li := length (comp ctx d e1)) in *. set (lb := length (comp (d :: ctx) (d + 1) e2)) in *.
    replace (length (comp ctx d e1 ++ [push0] ++ comp (d :: ctx) (d + 1) e2 ++ [AddSubImm false false 31 31 16]))
      with (li + S (lb + 1))%nat by (lengths; lia).
    pose proof (depth_nonneg e1). pose proof (depth_nonneg e2).
    pose proof (code_at_app_l _ _ _ _ H) as Hi.
    pose proof (code_at_app_r _ _ _ _ H) as Hpush. cbn [app] in Hpush.
    pose proof (code_at_cons _ _ _ _ Hpush) as Hr.
    pose proof (code_at_app_l _ _ _ _ Hr) as Hb.
    pose proof (code_at_app_r _ _ _ _ Hr) as Hadd. cbn [app] in Hadd.
    destruct (eval env e1) as [[vi|t]|] eqn:Ei; cbn [bind] in Ev; try discriminate.
    + eapply reach_seq.
      { apply reach_wf; [exact W|]. exact (IHe1 env ctx d base code p s _ Ei Hi Hp Fr ltac:(lia)). }
      intros s1 [W1 P1]. pose proof P1 as [K1 [M1 [Pc1 [X1 S1]]]].
      assert (Fr1 : frame base d ctx env s1) by (eapply frame_keep; eauto).
      eapply reach_step. { eapply push_step; [exact Hpush|exact Pc1|exact Fr1|lia]. }
      assert (Fr2 : frame base (d + 1) (d :: ctx) (vi :: env) (pushed s1))
        by (apply frame_pushed_let; [exact Fr1|lia|exact X1]).
      destruct r as [v|t].
      * eapply reach_seq.
        { apply reach_wf; [apply Fr2|].
          exact (IHe2 (vi :: env) (d :: ctx) (d + 1) base code _ (pushed s1) _ Ev Hb ltac:(cbn [pushed pc]; lia) Fr2 ltac:(lia)). }
        intros s3 [W3 P3]. pose proof P3 as [K3 [M3 [Pc3 [X3 S3]]]]. cbn [pushed sp pc gpr mem] in *.
        eapply reach_step. { rewrite (step_at _ _ _ _ s3 Hadd ltac:(lia)). apply exec_addsp; [exact W3|lia]. }
        apply reach_now. unfold post. cpc.
        split; [intros k Hk; cpc; rewrite K3 by lia; cbn [pushed gpr]; apply K1; exact Hk|].
        split; [intros a Ha; cpc; rewrite M3 by (cbn [pushed sp]; lia); cbn [pushed mem]; rewrite upd_other by lia;
                apply M1; exact Ha|].
        split; [lia|]. split; [exact X3|]. lia.
      * eapply reach_weaken.
        { exact (IHe2 (vi :: env) (d :: ctx) (d + 1) base code _ (pushed s1) _ Ev Hb ltac:(cbn [pushed pc]; lia) Fr2 ltac:(lia)). }
        { lia. }
        intros s' Q. eapply post_trap_lift with (s1 := pushed s1); [| | |exact Q].
        { eapply keeps_trans; [exact K1|apply pushed_keeps]. }
        { eapply mem_above_trans; [exact M1|apply pushed_mem_above|cbn [pushed sp]; lia]. }
        { cbn [pushed sp]. lia. }
    + inversion Ev; subst r. eapply reach_weaken.
      { exact (IHe1 env ctx d base code p s _ Ei Hi Hp Fr ltac:(lia)). }
      { lia. }
      intros s' Q. eapply lift_trap. exact Q.
Qed.

(* ------------------------------------------------------------------ *)
(* The whole function                                                   *)

(* What the caller observes at RET (fenrir-aarch64-result-abi/1). *)
Definition observed (r : result) (f : mstate) : Prop :=
  match r with
  | ROk v => gpr f 1 = 0 /\ gpr f 0 = repr v
  | RTrap t => gpr f 1 = trap_code t
  end.

Definition returns (s f : mstate) : Prop :=
  pc f = gpr s 30 /\ sp f = sp s /\
  (forall k, k <> 0 -> k <> 1 -> k <> 2 -> k <> 3 -> k <> 9 -> gpr f k = gpr s k) /\
  (forall a, sp s <= a -> mem f a = mem s a).

Theorem compile_correct : forall e x s r,
  eval_main e x = Some r -> wf s -> pc s = 0 -> gpr s 0 = x ->
  sp s mod 16 = 0 -> lo <= sp s - 16 * (1 + depth e) ->
  exists f, (forall fuel, (length (compile_fn e) <= fuel)%nat -> run fuel (compile_fn e) s = Some f) /\
            returns s f /\ observed r f.
Proof.
  intros e x s r Ev W Hpc X A L.
  pose proof (depth_nonneg e) as De.
  set (code := compile_fn e).
  assert (Hall : code_at code 0 code) by (exists [], []; rewrite app_nil_r; split; reflexivity).
  assert (Hp : code_at code 0 (AddSubImm false false 9 31 0 :: push0 :: comp [0] 1 e ++ epilogue))
    by exact Hall.
  pose proof (code_at_cons _ _ _ _ Hp) as Hpush.
  pose proof (code_at_cons _ _ _ _ Hpush) as Hbody.
  pose proof (code_at_app_l _ _ _ _ Hbody) as Hc.
  pose proof (code_at_app_r _ _ _ _ Hbody) as He. unfold epilogue in He.
  pose proof (code_at_cons _ _ _ _ He) as He1. pose proof (code_at_cons _ _ _ _ He1) as He2.
  set (len := length (comp [0] 1 e)) in *.
  assert (Len : length code = (2 + len + 3)%nat).
  { unfold code, compile_fn, prologue, epilogue. rewrite !length_app. cbn [length]. lia. }
  pose proof (wf_sp s W) as Ws. pose proof (wf_gpr s 0 W) as Wx.
  (* mov x9, sp *)
  set (s1 := MState (pc s + 4) (upd (gpr s) 9 (sp s)) (sp s) (nzcv s) (mem s)).
  assert (S1 : step code s = Some (Next s1)) by (rewrite (step_at _ _ _ _ _ Hp Hpc); apply exec_mov9sp; exact W).
  assert (W1 : wf s1) by (eapply step_wf; eauto).
  (* str x0, [sp, #-16]! *)
  assert (S2 : step code s1 = Some (Next (pushed s1))).
  { rewrite (step_at _ _ _ _ s1 Hpush ltac:(unfold s1; cbn [pc]; lia)). apply exec_push; [exact W1| |];
    cbn [s1 sp]; [exact A|lia]. }
  assert (W2 : wf (pushed s1)) by (eapply step_wf; eauto).
  assert (Fr : frame (sp s) 1 [0] [VInt x] (pushed s1)).
  { refine (conj W2 (conj _ (conj _ (conj _ (conj _ (conj A (conj (proj2 Ws) (Z.le_refl 1)))))))).
    - cbn. lia.
    - try unfold s1 in *; cbn [pushed gpr pc gpr sp mem nzcv]. apply upd_same.
    - constructor; [|constructor]. try unfold s1 in *; cbn [pushed mem gpr sp pc gpr sp mem nzcv].
      replace (sp s - 16 * (0 + 1)) with (sp s - 16) by lia. rewrite upd_same.
      rewrite upd_other by lia. exact X.
    - repeat constructor; lia. }
  destruct (comp_correct e [VInt x] [0] 1 (sp s) code 8 (pushed s1) r Ev Hc ltac:(cbn; lia) Fr ltac:(lia))
    as [n [s3 [St3 [N3 [K3 [M3 R3]]]]]].
  pose proof (steps_wf _ _ _ _ St3 W2) as W3.
  assert (Pre : steps code (2 + n) s s3) by (econstructor; [exact S1|econstructor; [exact S2|exact St3]]).
  (* Registers and memory the caller can see, from s to s3. *)
  assert (K : forall k, k <> 0 -> k <> 1 -> k <> 2 -> k <> 3 -> k <> 9 -> gpr s3 k = gpr s k).
  { intros k H0 H1 H2 H3 H9. rewrite K3 by lia. try unfold s1 in *; cbn [pushed gpr pc gpr sp mem nzcv]. apply upd_other. exact H9. }
  assert (M : forall a, sp s <= a -> mem s3 a = mem s a).
  { intros a Ha. rewrite M3 by (try unfold s1 in *; cbn [pushed sp pc gpr sp mem nzcv]; lia). try unfold s1 in *; cbn [pushed mem pc gpr sp mem nzcv]. apply upd_other. lia. }
  destruct r as [v|t]; destruct R3 as [P3 [X3 Sp3]]; try unfold s1 in *; cbn [pushed sp pc gpr sp mem nzcv] in Sp3.
  - (* add sp, sp, #16 ; mov x1, #0 ; ret *)
    set (s4 := MState (pc s3 + 4) (gpr s3) (sp s3 + 16) (nzcv s3) (mem s3)).
    assert (S4 : step code s3 = Some (Next s4)).
    { rewrite (step_at _ _ _ _ s3 He ltac:(lia)). apply exec_addsp; [exact W3|lia]. }
    set (s5 := MState (pc s4 + 4) (upd (gpr s4) 1 (signed (0 * 2 ^ (16 * 0)))) (sp s4) (nzcv s4) (mem s4)).
    assert (S5 : step code s4 = Some (Next s5)).
    { rewrite (step_at _ _ _ _ s4 He1 ltac:(unfold s4; cbn [pc]; lia)). apply exec_movz. reflexivity. }
    set (f := set_pc s5 (gpr s5 30)).
    assert (S6 : step code s5 = Some (Halt f)).
    { rewrite (step_at _ _ _ _ s5 He2 ltac:(unfold s5, s4; cbn [pc]; lia)). apply exec_ret. }
    exists f. split; [|split].
    + intros fuel Hf. eapply run_steps with (n := (2 + n + 2)%nat).
      * eapply steps_trans; [exact Pre|]. econstructor; [exact S4|econstructor; [exact S5|constructor]].
      * exact S6.
      * fold code in Hf. lia.
    + unfold returns. cbn [f s5 s4 set_pc pc sp gpr mem]. split; [|split; [|split]].
      * rewrite upd_other by lia. apply K; lia.
      * lia.
      * intros k H0 H1 H2 H3 H9. rewrite upd_other by exact H1. apply K; auto.
      * exact M.
    + unfold observed. cbn [f s5 s4 set_pc gpr]. split.
      * rewrite upd_same. reflexivity.
      * rewrite upd_other by lia. exact X3.
  - (* the trap path stops at its own ret *)
    set (f := set_pc s3 (gpr s3 30)).
    assert (S6 : step code s3 = Some (Halt f)) by (unfold step; rewrite P3; apply exec_ret).
    exists f. split; [|split].
    + intros fuel Hf. eapply run_steps with (n := (2 + n)%nat); [exact Pre|exact S6|]. fold code in Hf. lia.
    + unfold returns. cbn [f set_pc pc sp gpr mem]. split; [|split; [|split]].
      * apply K; lia.
      * exact Sp3.
      * exact K.
      * exact M.
    + exact X3.
Qed.

(* With the closed validator's typing: every well-typed program of the profile
   compiles to code that returns its checked result or its trap. *)
Theorem compile_correct_typed : forall e t x s,
  typeof [TInt] e = Some t -> lo <= x <= hi -> wf s -> pc s = 0 -> gpr s 0 = x ->
  sp s mod 16 = 0 -> lo <= sp s - 16 * (1 + depth e) ->
  exists r f, eval_main e x = Some r /\ result_ty r t /\
    (forall fuel, (length (compile_fn e) <= fuel)%nat -> run fuel (compile_fn e) s = Some f) /\
    returns s f /\ observed r f.
Proof.
  intros e t x s Ht Hx W Hpc X A L.
  destruct (type_safety e [TInt] [VInt x] t Ht ltac:(constructor; [exact Hx|constructor])) as [r [Ev Hr]].
  destruct (compile_correct e x s r Ev W Hpc X A L) as [f [R [Ret Obs]]].
  exists r, f. auto.
Qed.

Print Assumptions compile_correct.
Print Assumptions compile_correct_typed.
