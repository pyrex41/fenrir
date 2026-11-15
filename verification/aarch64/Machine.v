(* Handwritten model of the AArch64 instructions used by profile
   fenrir-aarch64-checked-expr/1.

   Every definition below is transcribed from the Arm Architecture Reference
   Manual for A-profile (DDI 0487) shared pseudocode and instruction
   descriptions, by hand.  It is NOT generated from or proved against Arm's
   machine-readable specification or Sail: that correspondence is the open
   obligation ARM-03 (route: Buri's Sail/Islaris foundation).

   Representation (what "registers are mathematical integers" means here):
   - X0..X30 and SP each hold a 64-bit pattern, represented by its two's-
     complement value SInt, an integer in [-2^63, 2^63).  UInt is recovered as
     the value mod 2^64.  `wf` states the range invariant; every instruction
     preserves it (step_wf).
   - The PC is a byte offset from the start of the code image.  The image's
     load address is not modelled (ARM-04); fetch requires a 4-aligned offset
     inside the image.
   - Memory is a map from addresses (SInt of the address) to doublewords.
     Only aligned 64-bit accesses are made; byte layout, overlapping accesses,
     permissions, faults and other agents are not modelled.  Loads and stores
     with SP as base check SP 16-byte alignment (CheckSPAlignment) and fault
     (None) otherwise.
   - PSTATE.NZCV is modelled; nothing else of PSTATE, no exceptions, no
     system registers.
   - RET ends the modelled execution (Halt) with PC := X[n]; the caller is not
     modelled. *)
From Stdlib Require Import ZArith List Bool Lia.
From FenrirARM Require Core.
Import ListNotations.
Open Scope Z_scope.

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

Definition uint (v : Z) : Z := v mod modulus.
Lemma uint_congr : forall v, uint v mod modulus = v mod modulus.
Proof. intros. unfold uint. apply Zmod_mod. Qed.

(* ------------------------------------------------------------------ *)
(* State                                                                *)

Record flags := Flags { fN : bool; fZ : bool; fC : bool; fV : bool }.
Record mstate := MState {
  pc : Z;
  gpr : Z -> Z;
  sp : Z;
  nzcv : flags;
  mem : Z -> Z
}.

Definition upd (f : Z -> Z) (k v : Z) : Z -> Z := fun a => if a =? k then v else f a.

(* X[n] with register 31 read as XZR, and the SP-selecting form. *)
Definition rd_zr (s : mstate) (r : Z) : Z := if r =? 31 then 0 else gpr s r.
Definition rd_sp (s : mstate) (r : Z) : Z := if r =? 31 then sp s else gpr s r.
Definition wr_zr (s : mstate) (r v : Z) : mstate :=
  if r =? 31 then s else MState (pc s) (upd (gpr s) r v) (sp s) (nzcv s) (mem s).
Definition wr_sp (s : mstate) (r v : Z) : mstate :=
  if r =? 31 then MState (pc s) (gpr s) v (nzcv s) (mem s)
  else MState (pc s) (upd (gpr s) r v) (sp s) (nzcv s) (mem s).
Definition set_flags (s : mstate) (f : flags) : mstate :=
  MState (pc s) (gpr s) (sp s) f (mem s).
Definition set_pc (s : mstate) (p : Z) : mstate :=
  MState p (gpr s) (sp s) (nzcv s) (mem s).
Definition set_sp (s : mstate) (v : Z) : mstate :=
  MState (pc s) (gpr s) v (nzcv s) (mem s).
Definition store (s : mstate) (a v : Z) : mstate :=
  MState (pc s) (gpr s) (sp s) (nzcv s) (upd (mem s) a v).
Definition advance (s : mstate) : mstate := set_pc s (pc s + 4).

(* ------------------------------------------------------------------ *)
(* Shared pseudocode                                                    *)

(* AddWithCarry(x, y, carry_in), N = 64:
     unsigned_sum = UInt(x) + UInt(y) + UInt(carry_in);
     signed_sum   = SInt(x) + SInt(y) + UInt(carry_in);
     result = unsigned_sum<N-1:0>;
     n = result<N-1>; z = IsZero(result);
     c = UInt(result) != unsigned_sum; v = SInt(result) != signed_sum. *)
Definition add_with_carry (x y cin : Z) : Z * flags :=
  let usum := uint x + uint y + cin in
  let ssum := x + y + cin in
  let r := signed usum in
  (r, Flags (r <? 0) (r =? 0) (negb (uint r =? usum)) (negb (r =? ssum))).

(* NOT(y) of the pattern whose SInt is y. *)
Definition bnot (y : Z) : Z := - y - 1.

(* ADD/SUB: SUB computes AddWithCarry(operand1, NOT(operand2), '1'). *)
Definition addsub (sub : bool) (x y : Z) : Z * flags :=
  if sub then add_with_carry x (bnot y) 1 else add_with_carry x y 0.

Inductive shift := LSL | ASR.
(* ShiftReg(m, type, amount): LSL keeps the low 64 bits; ASR shifts the SInt. *)
Definition shift_reg (v : Z) (sh : shift) (amt : Z) : Z :=
  match sh with LSL => signed (uint v * 2 ^ amt) | ASR => v / 2 ^ amt end.

(* ConditionHolds(cond). *)
Definition condition_holds (cond : Z) (f : flags) : bool :=
  let base := match cond / 2 with
              | 0 => fZ f
              | 1 => fC f
              | 2 => fN f
              | 3 => fV f
              | 4 => fC f && negb (fZ f)
              | 5 => Bool.eqb (fN f) (fV f)
              | 6 => Bool.eqb (fN f) (fV f) && negb (fZ f)
              | _ => true
              end in
  if (cond mod 2 =? 1) && negb (cond =? 15) then negb base else base.

Definition EQ := 0. Definition NE := 1. Definition VS := 6. Definition VC := 7.
Definition GE := 10. Definition LT := 11. Definition GT := 12. Definition LE := 13.

(* ------------------------------------------------------------------ *)
(* Instructions (64-bit forms only)                                     *)

Inductive instr :=
(* ADD/ADDS/SUB/SUBS (immediate), shift 0: Rd is SP when 31 and not S, XZR
   when S; Rn is SP when 31. *)
| AddSubImm (sub setflags : bool) (rd rn imm12 : Z)
(* ADD/ADDS/SUB/SUBS (shifted register): 31 is XZR everywhere. *)
| AddSubReg (sub setflags : bool) (rd rn rm : Z) (sh : shift) (amt : Z)
(* MADD Xd, Xn, Xm, Xa (MUL is Xa = XZR). *)
| Madd (rd rn rm ra : Z)
| Smulh (rd rn rm : Z)
| Sdiv (rd rn rm : Z)
| Csinc (rd rn rm cond : Z)
| Movz (rd imm16 hw : Z)
| Movk (rd imm16 hw : Z)
(* STR Xt, [SP, #imm9]!   LDR Xt, [SP], #imm9   LDR Xt, [SP, #imm12*8] *)
| StrPre (rt imm9 : Z)
| LdrPost (rt imm9 : Z)
| LdrUoff (rt imm12 : Z)
| Bcond (cond imm19 : Z)
| Bimm (imm26 : Z)
| Cbz (nonzero : bool) (rt imm19 : Z)
| Ret (rn : Z).

Inductive outcome := Next (s : mstate) | Halt (s : mstate).

Definition sp_aligned (s : mstate) : bool := sp s mod 16 =? 0.

Definition exec (i : instr) (s : mstate) : option outcome :=
  match i with
  | AddSubImm sub sf rd rn imm =>
      let rf := addsub sub (rd_sp s rn) imm in
      Some (Next (advance (if sf then set_flags (wr_zr s rd (fst rf)) (snd rf)
                           else wr_sp s rd (fst rf))))
  | AddSubReg sub sf rd rn rm sh amt =>
      let rf := addsub sub (rd_zr s rn) (shift_reg (rd_zr s rm) sh amt) in
      Some (Next (advance (if sf then set_flags (wr_zr s rd (fst rf)) (snd rf)
                           else wr_zr s rd (fst rf))))
  (* result = UInt(operand3) + UInt(operand1) * UInt(operand2); X[d] = result<63:0> *)
  | Madd rd rn rm ra =>
      Some (Next (advance (wr_zr s rd
        (signed (uint (rd_zr s ra) + uint (rd_zr s rn) * uint (rd_zr s rm))))))
  (* result = SInt(operand1) * SInt(operand2); X[d] = result<127:64> *)
  | Smulh rd rn rm =>
      Some (Next (advance (wr_zr s rd
        (signed (((rd_zr s rn * rd_zr s rm) mod 2 ^ 128) / 2 ^ 64)))))
  (* if IsZero(operand2) then 0 else RoundTowardsZero(SInt(op1) / SInt(op2)); <63:0> *)
  | Sdiv rd rn rm =>
      let y := rd_zr s rm in
      Some (Next (advance (wr_zr s rd
        (if y =? 0 then 0 else signed (Z.quot (rd_zr s rn) y)))))
  | Csinc rd rn rm c =>
      Some (Next (advance (wr_zr s rd
        (if condition_holds c (nzcv s) then rd_zr s rn else signed (uint (rd_zr s rm) + 1)))))
  | Movz rd imm hw =>
      Some (Next (advance (wr_zr s rd (signed (imm * 2 ^ (16 * hw))))))
  | Movk rd imm hw =>
      let u := uint (rd_zr s rd) in
      let p := 2 ^ (16 * hw) in
      Some (Next (advance (wr_zr s rd (signed (u - ((u / p) mod 2 ^ 16) * p + imm * p)))))
  | StrPre rt imm9 =>
      if sp_aligned s then
        let a := signed (sp s + imm9) in
        Some (Next (advance (set_sp (store s a (rd_zr s rt)) a)))
      else None
  | LdrPost rt imm9 =>
      if sp_aligned s then
        let a := sp s in
        Some (Next (advance (set_sp (wr_zr s rt (mem s a)) (signed (a + imm9)))))
      else None
  | LdrUoff rt imm12 =>
      if sp_aligned s then
        Some (Next (advance (wr_zr s rt (mem s (signed (sp s + imm12 * 8))))))
      else None
  | Bcond c imm19 =>
      Some (Next (set_pc s (if condition_holds c (nzcv s) then pc s + imm19 * 4 else pc s + 4)))
  | Bimm imm26 => Some (Next (set_pc s (pc s + imm26 * 4)))
  | Cbz nz rt imm19 =>
      let zero := rd_zr s rt =? 0 in
      Some (Next (set_pc s (if xorb zero nz then pc s + imm19 * 4 else pc s + 4)))
  | Ret rn => Some (Halt (set_pc s (rd_zr s rn)))
  end.

Definition fetch (code : list instr) (p : Z) : option instr :=
  if (p <? 0) || negb (p mod 4 =? 0) then None else nth_error code (Z.to_nat (p / 4)).

Definition step (code : list instr) (s : mstate) : option outcome :=
  match fetch code (pc s) with Some i => exec i s | None => None end.

(* The executable interpreter: Some s' when RET is reached within fuel. *)
Fixpoint run (fuel : nat) (code : list instr) (s : mstate) : option mstate :=
  match fuel with
  | O => None
  | S f => match step code s with
           | Some (Next s') => run f code s'
           | Some (Halt s') => Some s'
           | None => None
           end
  end.

Inductive steps (code : list instr) : nat -> mstate -> mstate -> Prop :=
| steps_refl s : steps code 0 s s
| steps_cons n s s1 s2 : step code s = Some (Next s1) -> steps code n s1 s2 -> steps code (S n) s s2.

Lemma steps_trans : forall code n1 n2 s1 s2 s3,
  steps code n1 s1 s2 -> steps code n2 s2 s3 -> steps code (n1 + n2) s1 s3.
Proof. intros code n1 n2 s1 s2 s3 H1. induction H1; intros; cbn; auto. econstructor; eauto. Qed.

Lemma run_steps : forall code n s s' f, steps code n s s' -> step code s' = Some (Halt f) ->
  forall fuel, (n < fuel)%nat -> run fuel code s = Some f.
Proof. intros code n s s' f H. induction H; intros Hh fuel Hf; destruct fuel; try lia; cbn.
 - rewrite Hh. reflexivity.
 - rewrite H. apply IHsteps; auto. lia. Qed.

(* ------------------------------------------------------------------ *)
(* Range invariant                                                      *)

Definition wf (s : mstate) : Prop :=
  (forall r, lo <= gpr s r <= hi) /\ (forall a, lo <= mem s a <= hi) /\ lo <= sp s <= hi.

Lemma rd_zr_range : forall s r, wf s -> lo <= rd_zr s r <= hi.
Proof. intros s r [Hg [Hm Hs]]. unfold rd_zr. destruct (r =? 31); auto.
 unfold Core.lo, Core.hi; lia. Qed.
Lemma rd_sp_range : forall s r, wf s -> lo <= rd_sp s r <= hi.
Proof. intros s r [Hg [Hm Hs]]. unfold rd_sp. destruct (r =? 31); auto. Qed.
Lemma add_with_carry_range : forall x y c, lo <= fst (add_with_carry x y c) <= hi.
Proof. intros. apply signed_range. Qed.
Lemma addsub_range : forall b x y, lo <= fst (addsub b x y) <= hi.
Proof. intros [|]; intros; apply add_with_carry_range. Qed.

Lemma upd_range : forall f k v, (forall a, lo <= f a <= hi) -> lo <= v <= hi ->
  forall a, lo <= upd f k v a <= hi.
Proof. intros f k v Hf Hv a. unfold upd. destruct (a =? k); auto. Qed.
Lemma wf_wr_zr : forall s r v, wf s -> lo <= v <= hi -> wf (wr_zr s r v).
Proof. intros s r v [Hg [Hm Hs]] Hv. unfold wr_zr. destruct (r =? 31).
 - split; auto. - split; [|split]; cbn; auto. apply upd_range; auto. Qed.
Lemma wf_wr_sp : forall s r v, wf s -> lo <= v <= hi -> wf (wr_sp s r v).
Proof. intros s r v [Hg [Hm Hs]] Hv. unfold wr_sp. destruct (r =? 31).
 - split; [|split]; cbn; auto.
 - split; [|split]; cbn; auto. apply upd_range; auto. Qed.
Lemma wf_set_flags : forall s f, wf s -> wf (set_flags s f). Proof. auto. Qed.
Lemma wf_set_pc : forall s p, wf s -> wf (set_pc s p). Proof. auto. Qed.
Lemma wf_advance : forall s, wf s -> wf (advance s). Proof. auto. Qed.
Lemma wf_set_sp : forall s v, wf s -> lo <= v <= hi -> wf (set_sp s v).
Proof. intros s v [Hg [Hm Hs]] Hv. split; [|split]; cbn; auto. Qed.
Lemma wf_store : forall s a v, wf s -> lo <= v <= hi -> wf (store s a v).
Proof. intros s a v [Hg [Hm Hs]] Hv. split; [|split]; cbn; auto. apply upd_range; auto. Qed.

Lemma exec_wf : forall i s s', wf s -> exec i s = Some (Next s') \/ exec i s = Some (Halt s') -> wf s'.
Proof.
  intros i s s' Hw Hex.
  assert (Hm : forall a, lo <= mem s a <= hi) by apply Hw.
  assert (Hr : forall r, lo <= rd_zr s r <= hi) by (intros; apply rd_zr_range; exact Hw).
  destruct i; cbn [exec] in Hex;
  repeat match goal with H : context [if ?b then _ else _] |- _ => destruct b end;
  destruct Hex as [Hex|Hex]; inversion Hex; subst; clear Hex;
  repeat match goal with
         | |- wf (advance _) => apply wf_advance
         | |- wf (set_pc _ _) => apply wf_set_pc
         | |- wf (set_flags _ _) => apply wf_set_flags
         | |- wf (set_sp _ _) => apply wf_set_sp
         | |- wf (store _ _ _) => apply wf_store
         | |- wf (wr_zr _ _ _) => apply wf_wr_zr
         | |- wf (wr_sp _ _ _) => apply wf_wr_sp
         end;
  try assumption; try apply signed_range; try apply addsub_range; try apply Hr; try apply Hm;
  unfold Core.lo, Core.hi; lia.
Qed.

Lemma step_wf : forall code s s', wf s -> step code s = Some (Next s') -> wf s'.
Proof. intros code s s' Hw H. unfold step in H. destruct (fetch code (pc s)); try discriminate.
 eapply exec_wf; eauto. Qed.
Lemma steps_wf : forall code n s s', steps code n s s' -> wf s -> wf s'.
Proof. intros code n s s' H. induction H; auto. intros. apply IHsteps. eapply step_wf; eauto. Qed.
