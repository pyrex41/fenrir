(* Profile fenrir-aarch64-checked-call/1: first-order functions, calls and
   tail calls, on a machine where RET is a jump.

   Machine.  The profiles checked-unary/1 and checked-expr/1 keep their
   machine (Machine.step, where RET ends execution) and their theorems.  This
   file adds step_c, identical to Machine.step except that RET jumps to X[n];
   execution of a whole program ends when the PC reaches the entry link
   address, which lies outside the image.  The two machines agree on every
   step that is not a RET (sim_step), so the expression fragment proof
   Compile.comp_correct is reused unchanged through a simulation lemma
   instead of being re-proved; only RET steps are reasoned about anew.

   Source.  Function bodies are statements over the expr profile's
   call-free expressions: return an expression, let, if, let x = call f a,
   and a call in tail position.  The projection rejects calls anywhere else.
   The semantics is fuel-indexed (fuel = calls allowed); a result is
   claimed only when the source evaluates within some fuel, and it also
   returns the stack slots the evaluation needs, which is the stack
   hypothesis of the theorem.  It is LOCAL TO THIS LANE and transcribes the
   Shen model (models/tc0/pure-call-machine.shen); agreement is tested by
   harness/aarch64-differential.shen, not proved. *)
From Stdlib Require Import ZArith List Bool Lia.
From FenrirARM Require Core Machine Encode Flags Expr Compile.
Import ListNotations Machine Flags Expr Compile.
Open Scope Z_scope.

(* ------------------------------------------------------------------ *)
(* Machine with RET as a jump                                           *)

Definition exec_c (i : instr) (s : mstate) : option outcome :=
  match i with
  | Ret rn => Some (Next (set_pc s (rd_zr s rn)))
  | _ => exec i s
  end.

Definition step_c (code : list instr) (s : mstate) : option outcome :=
  match fetch code (pc s) with Some i => exec_c i s | None => None end.

Inductive steps_c (code : list instr) : nat -> mstate -> mstate -> Prop :=
| steps_c_refl s : steps_c code 0 s s
| steps_c_cons n s s1 s2 : step_c code s = Some (Next s1) -> steps_c code n s1 s2 -> steps_c code (S n) s s2.

(* The run ends when the PC is the exit address. *)
Fixpoint run_c (fuel : nat) (code : list instr) (exit : Z) (s : mstate) : option mstate :=
  match fuel with
  | O => None
  | S f => if pc s =? exit then Some s
           else match step_c code s with Some (Next s') => run_c f code exit s' | _ => None end
  end.

Lemma steps_c_trans : forall code n1 n2 s1 s2 s3,
  steps_c code n1 s1 s2 -> steps_c code n2 s2 s3 -> steps_c code (n1 + n2) s1 s3.
Proof. intros code n1 n2 s1 s2 s3 H1. induction H1; intros; cbn; auto. econstructor; eauto. Qed.

(* Every non-RET step of the expr machine is a step of this machine. *)
Lemma sim_step : forall code s s', step code s = Some (Next s') -> step_c code s = Some (Next s').
Proof.
  intros code s s' H. unfold step, step_c in *. destruct (fetch code (pc s)) as [i|]; [|discriminate].
  destruct i; cbn [exec_c]; auto. cbn in H. discriminate.
Qed.

Lemma sim_steps : forall code n s s', steps code n s s' -> steps_c code n s s'.
Proof. intros code n s s' H. induction H; econstructor; eauto using sim_step. Qed.

Lemma step_c_wf : forall code s s', wf s -> step_c code s = Some (Next s') -> wf s'.
Proof.
  intros code s s' W H. unfold step_c in H. destruct (fetch code (pc s)) as [i|]; [|discriminate].
  destruct i; cbn [exec_c] in H; try (eapply exec_wf; eauto; fail).
  inversion H; subst. apply wf_set_pc. exact W.
Qed.

Lemma steps_c_wf : forall code n s s', steps_c code n s s' -> wf s -> wf s'.
Proof. intros code n s s' H. induction H; auto. intros. apply IHsteps_c. eapply step_c_wf; eauto. Qed.

Lemma fetch_inside : forall code p i, fetch code p = Some i -> 0 <= p < 4 * Z.of_nat (length code).
Proof.
  intros code p i H. unfold fetch in H.
  destruct ((p <? 0) || negb (p mod 4 =? 0)) eqn:E; [discriminate|].
  apply orb_false_iff in E as [E1 E2]. apply Z.ltb_ge in E1. apply negb_false_iff, Z.eqb_eq in E2.
  assert (L : (Z.to_nat (p / 4) < length code)%nat) by (apply nth_error_Some; rewrite H; discriminate).
  Z.div_mod_to_equations. lia.
Qed.

Lemma run_c_steps : forall code exit n s s',
  steps_c code n s s' -> pc s' = exit -> (exit < 0 \/ 4 * Z.of_nat (length code) <= exit) ->
  forall fuel, (n < fuel)%nat -> run_c fuel code exit s = Some s'.
Proof.
  intros code exit n s s' H. induction H; intros Hp Hx fuel Hf; destruct fuel; try lia; cbn.
  - rewrite Hp, Z.eqb_refl. reflexivity.
  - assert (pc s <> exit).
    { unfold step_c in H. destruct (fetch code (pc s)) as [i|] eqn:F; [|discriminate].
      apply fetch_inside in F. lia. }
    replace (pc s =? exit) with false by (symmetry; apply Z.eqb_neq; exact H1).
    rewrite H. apply IHsteps_c; auto. lia.
Qed.

Definition reach_c (code : list instr) (s : mstate) (P : mstate -> Prop) : Prop :=
  exists n s', steps_c code n s s' /\ P s'.

Lemma reach_c_now : forall code s (P : mstate -> Prop), P s -> reach_c code s P.
Proof. intros. exists 0%nat, s. split; [constructor|auto]. Qed.
Lemma reach_c_step : forall code s s1 P, step_c code s = Some (Next s1) -> reach_c code s1 P -> reach_c code s P.
Proof. intros code s s1 P H [n [s' [Hs HP]]]. exists (S n), s'. split; [econstructor; eauto|auto]. Qed.
Lemma reach_c_seq : forall code s (Q P : mstate -> Prop),
  reach_c code s Q -> (forall s1, Q s1 -> reach_c code s1 P) -> reach_c code s P.
Proof.
  intros code s Q P [n1 [s1 [H1 HQ]]] K. destruct (K s1 HQ) as [n2 [s2 [H2 HP]]].
  exists (n1 + n2)%nat, s2. split; [eapply steps_c_trans; eauto|auto].
Qed.
Lemma reach_lift : forall code s m (P : mstate -> Prop), wf s -> reach code s m P -> reach_c code s (fun s' => wf s' /\ P s').
Proof.
  intros code s m P W [n [s' [H [_ HP]]]]. exists n, s'. split; [apply sim_steps; exact H|].
  split; [eapply steps_wf; eauto|exact HP].
Qed.
Lemma reach_c_step_wf : forall code s s1 P, wf s -> step_c code s = Some (Next s1) ->
  (wf s1 -> reach_c code s1 P) -> reach_c code s P.
Proof. intros. eapply reach_c_step; eauto. apply H1. eapply step_c_wf; eauto. Qed.

Lemma step_c_at : forall code p i rest s, code_at code p (i :: rest) -> pc s = p -> step_c code s = exec_c i s.
Proof. intros. unfold step_c. rewrite H0, (code_at_fetch _ _ _ _ H). reflexivity. Qed.

(* ------------------------------------------------------------------ *)
(* Source: statements and fuel-indexed semantics                        *)

Inductive stmt :=
| SRet (e : expr)                    (* the value of e *)
| SLet (e : expr) (k : stmt)         (* let x = e in k *)
| SIf (c : expr) (t f : stmt)        (* if c then t else f *)
| SCall (g : nat) (a : expr) (k : stmt)  (* let x = call g a in k *)
| STail (g : nat) (a : expr).        (* call g a, in tail position *)

(* A call oracle answers (result, stack slots the callee needs below its own
   entry SP).  sexec answers the same for a statement entered with d slots
   in use below the function's entry SP.  The rules transcribe
   tc0.pc.dispatch/step for let and if (as in Expr.eval), and for call:
   tc0.pc.collect evaluates the argument (Tail false) before
   tc0.pc.enter runs the named function's body with environment [[Id Arg]]
   and no captures; an unwinding trap passes every frame, so a callee trap
   is the caller's trap. *)
Fixpoint sexec (call : nat -> value -> option (result * Z)) (d : Z) (env : list value) (st : stmt)
  : option (result * Z) :=
  match st with
  | SRet e => match eval env e with Some r => Some (r, d + depth e) | None => None end
  | SLet e k =>
      match eval env e with
      | Some (ROk v) => match sexec call (d + 1) (v :: env) k with
                        | Some (r, m) => Some (r, Z.max (d + depth e) m) | None => None end
      | Some (RTrap t) => Some (RTrap t, d + depth e)
      | None => None
      end
  | SIf c t f =>
      match eval env c with
      | Some (ROk (VBool b)) => match sexec call d env (if b then t else f) with
                                | Some (r, m) => Some (r, Z.max (d + depth c) m) | None => None end
      | Some (RTrap t') => Some (RTrap t', d + depth c)
      | _ => None
      end
  | SCall g a k =>
      match eval env a with
      | Some (ROk v) =>
          match call g v with
          | Some (ROk w, n) => match sexec call (d + 1) (w :: env) k with
                               | Some (r, m) => Some (r, Z.max (Z.max (d + depth a) (d + n)) m)
                               | None => None end
          | Some (RTrap t, n) => Some (RTrap t, Z.max (d + depth a) (d + n))
          | None => None
          end
      | Some (RTrap t) => Some (RTrap t, d + depth a)
      | None => None
      end
  | STail g a =>
      match eval env a with
      | Some (ROk v) => match call g v with
                        | Some (r, n) => Some (r, Z.max (d + depth a) n) | None => None end
      | Some (RTrap t) => Some (RTrap t, d + depth a)
      | None => None
      end
  end.

(* Each call consumes one unit of fuel; a body starts with 2 slots in use
   (the parameter and the saved link register). *)
Fixpoint fcall (fuel : nat) (fns : list stmt) (g : nat) (v : value) : option (result * Z) :=
  match fuel with
  | O => None
  | S k => match nth_error fns g with Some b => sexec (fcall k fns) 2 [v] b | None => None end
  end.

Definition ceval (fuel : nat) (fns : list stmt) (main : nat) (x : Z) : option result :=
  match fcall fuel fns main (VInt x) with Some (r, _) => Some r | None => None end.

(* ------------------------------------------------------------------ *)
(* Compiler                                                             *)

Fixpoint slen (ctx : list Z) (d : Z) (st : stmt) : nat :=
  match st with
  | SRet e => length (comp ctx d e) + 3
  | SLet e k => length (comp ctx d e) + 1 + slen (d :: ctx) (d + 1) k
  | SIf c t f => length (comp ctx d c) + 1 + slen ctx d t + slen ctx d f
  | SCall g a k => length (comp ctx d a) + 7 + slen (d :: ctx) (d + 1) k
  | STail g a => length (comp ctx d a) + 2
  end.

(* fs: the word index of each function's first instruction; p: the word index
   of the statement's first instruction. *)
Fixpoint cstmt (fs : list Z) (p : Z) (ctx : list Z) (d : Z) (st : stmt) : list instr :=
  match st with
  | SRet e => comp ctx d e ++ [AddSubImm false false 31 9 0; Movz 1 0 0; Ret 30]
  | SLet e k => comp ctx d e ++ [push0] ++
                cstmt fs (p + Z.of_nat (length (comp ctx d e)) + 1) (d :: ctx) (d + 1) k
  | SIf c t f =>
      let lc := Z.of_nat (length (comp ctx d c)) in
      comp ctx d c ++ [Cbz false 0 (Z.of_nat (slen ctx d t) + 1)] ++ cstmt fs (p + lc + 1) ctx d t ++
      cstmt fs (p + lc + 1 + Z.of_nat (slen ctx d t)) ctx d f
  | SCall g a k =>
      let la := Z.of_nat (length (comp ctx d a)) in
      comp ctx d a ++
      [Bl (nth g fs 0 - (p + la)); AddSubImm false false 9 31 (16 * d); LdrUoff 30 (2 * (d - 2));
       Cbz false 1 3; AddSubImm false false 31 9 0; Ret 30; push0] ++
      cstmt fs (p + la + 7) (d :: ctx) (d + 1) k
  | STail g a =>
      let la := Z.of_nat (length (comp ctx d a)) in
      comp ctx d a ++ [AddSubImm false false 31 9 0; Bimm (nth g fs 0 - (p + la + 1))]
  end.

(* mov x9, sp ; str x0, [sp, #-16]! ; str x30, [sp, #-16]! *)
Definition fprologue : list instr := [AddSubImm false false 9 31 0; push0; StrPre 30 (-16)].

Lemma cstmt_length : forall st fs p ctx d, length (cstmt fs p ctx d st) = slen ctx d st.
Proof.
  induction st; intros; cbn [cstmt slen]; rewrite ?length_app; cbn [length];
  rewrite ?IHst, ?IHst1, ?IHst2; lia.
Qed.

Definition flen (b : stmt) : nat := 3 + slen [0%Z] 2%Z b.
Fixpoint starts (base : Z) (bs : list stmt) : list Z :=
  match bs with [] => [] | b :: r => base :: starts (base + Z.of_nat (flen b)) r end.
Definition fstarts (fns : list stmt) : list Z := starts 0 fns.
Definition fcode (fs : list Z) (start : Z) (b : stmt) : list instr :=
  fprologue ++ cstmt fs (start + 3) [0] 2 b.
Fixpoint emit (fs : list Z) (base : Z) (bs : list stmt) : list instr :=
  match bs with [] => [] | b :: r => fcode fs base b ++ emit fs (base + Z.of_nat (flen b)) r end.
Definition compile_prog (fns : list stmt) : list instr := emit (fstarts fns) 0 fns.

(* ------------------------------------------------------------------ *)
(* Layout                                                               *)

Lemma fcode_length : forall fs start b, length (fcode fs start b) = flen b.
Proof. intros. unfold fcode, flen. rewrite length_app, cstmt_length. reflexivity. Qed.

Lemma emit_at : forall fs bs base g b, nth_error bs g = Some b ->
  exists pre post, emit fs base bs = pre ++ fcode fs (nth g (starts base bs) 0) b ++ post /\
                   4 * Z.of_nat (length pre) = 4 * (nth g (starts base bs) 0 - base).
Proof.
  intros fs bs. induction bs as [|b0 bs IH]; intros base g b H; [destruct g; discriminate|].
  destruct g as [|g]; cbn [nth_error] in H.
  - inversion H; subst. exists [], (emit fs (base + Z.of_nat (flen b)) bs). split; [reflexivity|cbn [length nth starts Z.of_nat]; lia].
  - destruct (IH (base + Z.of_nat (flen b0)) g b H) as [pre [post [E L]]].
    exists (fcode fs base b0 ++ pre), post. cbn [emit starts nth]. split.
    + rewrite E, <- app_assoc. reflexivity.
    + rewrite length_app, fcode_length. lia.
Qed.

Lemma function_at : forall fns g b, nth_error fns g = Some b ->
  code_at (compile_prog fns) (4 * nth g (fstarts fns) 0) (fcode (fstarts fns) (nth g (fstarts fns) 0) b).
Proof.
  intros fns g b H. destruct (emit_at (fstarts fns) fns 0 g b H) as [pre [post [E L]]].
  exists pre, post. split; [exact E|]. unfold fstarts in *. lia.
Qed.

(* ------------------------------------------------------------------ *)
(* Effects of the instructions added for calls                          *)

Lemma exec_str_r : forall s rt, wf s -> (rt =? 31) = false -> sp s mod 16 = 0 -> lo <= sp s - 16 ->
  exec (StrPre rt (-16)) s =
  Some (Next (MState (pc s + 4) (gpr s) (sp s - 16) (nzcv s) (upd (mem s) (sp s - 16) (gpr s rt)))).
Proof.
  intros s rt W R Ha Hl. pose proof (wf_sp s W). unfold exec. rewrite sp_aligned_true by assumption.
  cbv zeta. rewrite (signed_fits (sp s + -16)) by lia. replace (sp s + -16) with (sp s - 16) by ring.
  unfold rd_zr. rewrite R. reflexivity.
Qed.

Lemma exec_ldr_r : forall s rt k, (rt =? 31) = false -> sp s mod 16 = 0 -> lo <= sp s + k * 8 <= hi ->
  exec (LdrUoff rt k) s =
  Some (Next (MState (pc s + 4) (upd (gpr s) rt (mem s (sp s + k * 8))) (sp s) (nzcv s) (mem s))).
Proof.
  intros s rt k R Ha Hr. unfold exec. rewrite sp_aligned_true by assumption.
  rewrite (signed_fits (sp s + k * 8)) by lia. unfold wr_zr. rewrite R. reflexivity.
Qed.

Lemma exec_x9 : forall s imm, wf s -> lo <= sp s + imm <= hi ->
  exec (AddSubImm false false 9 31 imm) s =
  Some (Next (MState (pc s + 4) (upd (gpr s) 9 (sp s + imm)) (sp s) (nzcv s) (mem s))).
Proof.
  intros s imm W R. unfold exec. cbv zeta. change (rd_sp s 31) with (sp s).
  rewrite addsub_fst. unfold addsub_math. rewrite signed_fits by lia. reflexivity.
Qed.

Lemma exec_bl : forall s k, lo <= pc s + 4 <= hi ->
  exec (Bl k) s = Some (Next (MState (pc s + k * 4) (upd (gpr s) 30 (pc s + 4)) (sp s) (nzcv s) (mem s))).
Proof. intros s k R. unfold exec. rewrite signed_fits by lia. reflexivity. Qed.

Lemma exec_c_ret : forall s, exec_c (Ret 30) s = Some (Next (set_pc s (gpr s 30))).
Proof. reflexivity. Qed.

Lemma exec_c_other : forall i s, (forall rn, i <> Ret rn) -> exec_c i s = exec i s.
Proof. intros [] s H; try reflexivity. exfalso. eapply H. reflexivity. Qed.

(* One step of a non-RET instruction i, given Hc : code_at code p (i :: rest). *)
Ltac cstep L Hc :=
  eapply reach_c_step_wf;
  [ assumption
  | erewrite (step_c_at _ _ _ _ _ Hc);
    [ rewrite exec_c_other by discriminate;
      apply L; repeat (first [reflexivity | assumption | (cpc; lia) | (cpc; Z.div_mod_to_equations; lia)])
    | cpc; lia ]
  | intros ].

(* ------------------------------------------------------------------ *)
(* Correctness                                                          *)

(* Registers a call preserves: all but the scratch x0-x3, x9 and the link
   register (whose value on return is stated separately). *)
Definition keepsx (s s' : mstate) : Prop :=
  forall k, k <> 0 -> k <> 1 -> k <> 2 -> k <> 3 -> k <> 9 -> k <> 30 -> gpr s' k = gpr s k.

Lemma sexec_need_ge : forall call st d env r n, sexec call d env st = Some (r, n) -> d <= n.
Proof.
  intros call st. induction st; intros d env r n H; cbn [sexec] in H;
  match goal with x : expr |- _ => pose proof (depth_nonneg x) end;
  repeat match goal with
         | H : context [match ?x with _ => _ end] |- _ => destruct x eqn:?; try discriminate
         end;
  inversion H; subst;
  repeat match goal with Hs : sexec _ _ _ _ = Some _ |- _ =>
    first [apply IHst in Hs | apply IHst1 in Hs | apply IHst2 in Hs] end;
  lia.
Qed.

Section Program.
Variable fns : list stmt.
Local Abbreviation code := (compile_prog fns).
Local Abbreviation FS := (fstarts fns).
Hypothesis Hsize : 4 * Z.of_nat (length (compile_prog fns)) <= hi.

(* What a function call establishes, for every function g of the table and
   every answer of the call oracle. *)
Definition fn_spec (call : nat -> value -> option (result * Z)) : Prop :=
  forall g v r n s ra, call g v = Some (r, n) -> pc s = 4 * nth g FS 0 -> wf s -> gpr s 0 = repr v ->
    sp s mod 16 = 0 -> gpr s 30 = ra -> lo <= sp s - 16 * n ->
    reach_c code s (fun s' => pc s' = ra /\ sp s' = sp s /\ gpr s' 30 = ra /\ keepsx s s' /\
                              mem_above s s' /\ observed r s').

(* Inside a function whose entry SP is B: d slots in use, slot 1 holds the
   link register, which is also in x30. *)
Definition sframe (B d : Z) (ctx : list Z) (env : list value) (ra : Z) (s : mstate) : Prop :=
  frame B d ctx env s /\ gpr s 30 = ra /\ mem s (B - 32) = ra /\ 2 <= d.

Definition spost (B ra : Z) (s : mstate) (r : result) (s' : mstate) : Prop :=
  pc s' = ra /\ sp s' = B /\ gpr s' 30 = ra /\ keepsx s s' /\
  (forall a, B <= a -> mem s' a = mem s a) /\ observed r s'.

Lemma spost_trans : forall B ra s s2 r s',
  spost B ra s2 r s' -> keepsx s s2 -> (forall a, B <= a -> mem s2 a = mem s a) -> spost B ra s r s'.
Proof.
  intros B ra s s2 r s' [P [S [X [K [M O]]]]] K2 M2.
  repeat split; auto.
  - intros k ? ? ? ? ? ?. rewrite K, K2; auto.
  - intros a Ha. rewrite M, M2; auto.
Qed.

Lemma reach_c_mono : forall s (P Q : mstate -> Prop), reach_c code s P -> (forall x, P x -> Q x) -> reach_c code s Q.
Proof. intros s P Q [n [s' [H HP]]] K. exists n, s'. auto. Qed.

Lemma reach_c_wf : forall s (P : mstate -> Prop), wf s -> reach_c code s P -> reach_c code s (fun s' => wf s' /\ P s').
Proof. intros s P W [n [s' [H HP]]]. exists n, s'. split; [exact H|split; [eapply steps_c_wf; eauto|exact HP]]. Qed.

Lemma pc_inside : forall p s i rest, code_at code p (i :: rest) -> pc s = p -> lo <= pc s + 4 <= hi.
Proof.
  intros p s i rest H Hp. pose proof (fetch_inside _ _ _ (code_at_fetch _ _ _ _ H)).
  pose proof Hsize. unfold Core.lo, Core.hi in *. lia.
Qed.

(* A trap reported by a fragment: its RET returns to the link register. *)
Lemma finish_trap : forall q len B ra s s1 t,
  post code q len B s (RTrap t) s1 -> gpr s 30 = ra -> sp s <= B ->
  reach_c code s1 (spost B ra s (RTrap t)).
Proof.
  intros q len B ra s s1 t [K [M [F [X S]]]] R Hs.
  eapply reach_c_step. { unfold step_c. rewrite F. apply exec_c_ret. }
  apply reach_c_now. unfold spost, set_pc. cpc.
  rewrite K by lia. repeat split; auto.
  - intros k ? ? ? ? ? ?. apply K. lia.
  - intros a Ha. apply M. lia.
Qed.

(* mov sp, x9 ; mov x1, #0 ; ret *)
Lemma finish_ok : forall q len B ra s s1 v,
  post code q len B s (ROk v) s1 -> wf s1 -> gpr s 9 = B -> gpr s 30 = ra -> sp s <= B ->
  code_at code (q + 4 * Z.of_nat len) [AddSubImm false false 31 9 0; Movz 1 0 0; Ret 30] ->
  reach_c code s1 (spost B ra s (ROk v)).
Proof.
  intros q len B ra s s1 v [K [M [P [X S]]]] W X9 R Hs H.
  pose proof (code_at_cons _ _ _ _ H) as H1. pose proof (code_at_cons _ _ _ _ H1) as H2.
  cstep exec_movsp9 H. cstep exec_movz H1.
  eapply reach_c_step. { erewrite step_c_at; [apply exec_c_ret|exact H2|cpc; lia]. }
  apply reach_c_now. unfold spost, set_pc, observed. cpc.
  refine (conj _ (conj _ (conj _ (conj _ (conj _ (conj _ _)))))).
  - rewrite upd_other by lia. rewrite K by lia. exact R.
  - rewrite K by lia. exact X9.
  - rewrite upd_other by lia. rewrite K by lia. exact R.
  - intros k ? ? ? ? ? ?. cpc. rewrite upd_other by lia. apply K. lia.
  - intros a Ha. apply M. lia.
  - rewrite upd_same. apply movz_small. lia.
  - rewrite upd_other by lia. exact X.
Qed.

Ltac fr := match goal with F : frame _ _ _ _ _ |- _ => pose proof F as [?W [?Sp [?X9 [?En [?Fa [?A16 [?Bh ?D1]]]]]]] end.

Lemma stmt_ok : forall call, fn_spec call -> forall st B d ctx env ra p s r n,
  sexec call d env st = Some (r, n) -> code_at code (4 * p) (cstmt FS p ctx d st) -> pc s = 4 * p ->
  sframe B d ctx env ra s -> lo <= B - 16 * n ->
  reach_c code s (spost B ra s r).
Proof.
  intros call Spec st. induction st; intros B d ctx env ra p s r n Ev H Hp [Fr [R30 [MR D2]]] L;
  pose proof Fr as [W [Sp [X9 [En [Fa [A16 [Bh D1]]]]]]]; cbn [sexec cstmt] in Ev, H.
  - (* SRet *)
    destruct (eval env e) as [r0|] eqn:E; [|discriminate]. inversion Ev; subst r n.
    pose proof (code_at_app_l _ _ _ _ H) as Hc. pose proof (code_at_app_r _ _ _ _ H) as Hr.
    eapply reach_c_seq.
    { eapply reach_lift; [exact W|]. exact (comp_correct e env ctx d B code _ s r0 E Hc Hp Fr ltac:(lia)). }
    intros s1 [W1 P1]. destruct r0.
    + eapply finish_ok; eauto; lia.
    + eapply finish_trap; eauto; lia.
  - (* SLet *)
    pose proof (depth_nonneg e).
    pose proof (code_at_app_l _ _ _ _ H) as Hc. pose proof (code_at_app_r _ _ _ _ H) as Hpush. cbn [app] in Hpush.
    pose proof (code_at_cons _ _ _ _ Hpush) as Hk.
    destruct (eval env e) as [[v|t]|] eqn:E; try discriminate.
    + destruct (sexec call (d + 1) (v :: env) st) as [[r1 m]|] eqn:Ek; [|discriminate].
      inversion Ev; subst r n. pose proof (sexec_need_ge _ _ _ _ _ _ Ek).
      eapply reach_c_seq.
      { eapply reach_lift; [exact W|]. exact (comp_correct e env ctx d B code _ s (ROk v) E Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 [K1 [M1 [P1 [X1 S1]]]]].
      assert (Fr1 : frame B d ctx env s1) by (eapply frame_keep; eauto).
      eapply reach_c_step. { apply sim_step. eapply push_step; [exact Hpush|exact P1|exact Fr1|lia]. }
      eapply reach_c_seq.
      { eapply (IHst B (d + 1) (d :: ctx) (v :: env) ra (p + Z.of_nat (length (comp ctx d e)) + 1)); eauto.
        - replace (4 * (p + Z.of_nat (length (comp ctx d e)) + 1)) with (4 * p + 4 * Z.of_nat (length (comp ctx d e)) + 4) by lia.
          exact Hk.
        - cbn [pushed pc]. lia.
        - assert (Lp : lo <= B - 16 * (d + 1)) by lia.
          split; [exact (frame_pushed_let _ _ _ _ _ _ Fr1 Lp X1)|split; [|split; [|lia]]].
          + cbn [pushed gpr]. rewrite K1 by lia. exact R30.
          + cbn [pushed mem sp]. rewrite upd_other by lia. rewrite M1 by lia. exact MR.
        - lia. }
      intros s' Q. apply reach_c_now. eapply spost_trans; [exact Q| |].
      * intros k ? ? ? ? ? ?. cbn [pushed gpr]. apply K1. lia.
      * intros a Ha. cbn [pushed mem]. rewrite upd_other by lia. apply M1. lia.
    + inversion Ev; subst r n.
      eapply reach_c_seq.
      { eapply reach_lift; [exact W|]. exact (comp_correct e env ctx d B code _ s (RTrap t) E Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 P1]. eapply finish_trap; eauto; lia.
  - (* SIf *)
    pose proof (depth_nonneg c).
    pose proof (code_at_app_l _ _ _ _ H) as Hc. pose proof (code_at_app_r _ _ _ _ H) as Hcbz. cbn [app] in Hcbz.
    pose proof (code_at_cons _ _ _ _ Hcbz) as Hr.
    pose proof (code_at_app_l _ _ _ _ Hr) as Ht. pose proof (code_at_app_r _ _ _ _ Hr) as Hf.
    rewrite cstmt_length in Hf.
    destruct (eval env c) as [[[x|b]|t]|] eqn:E; try discriminate.
    + destruct (sexec call d env (if b then st1 else st2)) as [[r1 m]|] eqn:Eb; [|discriminate].
      inversion Ev; subst r n.
      eapply reach_c_seq.
      { eapply reach_lift; [exact W|]. exact (comp_correct c env ctx d B code _ s (ROk (VBool b)) E Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 [K1 [M1 [P1 [X1 S1]]]]].
      cstep exec_cbz Hcbz. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *. rewrite X1. cbn [repr].
      assert (Fr2 : forall q, frame B d ctx env (MState q (gpr s1) (sp s1) (nzcv s1) (mem s1))).
      { intros q. eapply frame_keep; [exact Fr| | | |cbn; exact S1].
        - exact W1.
        - intros k Hk. apply K1. exact Hk.
        - intros a Ha. apply M1. exact Ha. }
      assert (SF : forall q, sframe B d ctx env ra (MState q (gpr s1) (sp s1) (nzcv s1) (mem s1))).
      { intros q. split; [exact (Fr2 q)|split; [|split; [|exact D2]]]; cbn.
        - rewrite K1 by lia. exact R30.
        - rewrite M1 by lia. exact MR. }
      assert (Tr : forall q s', spost B ra (MState q (gpr s1) (sp s1) (nzcv s1) (mem s1)) r1 s' -> spost B ra s r1 s').
      { intros q s' Q. eapply spost_trans; [exact Q| |].
        - intros k ? ? ? ? ? ?. cbn [gpr]. apply K1. lia.
        - intros a Ha. cbn [mem]. apply M1. lia. }
      destruct b; cbn [Z.eqb xorb]; (eapply reach_c_mono; [|apply Tr]).
      * eapply (IHst1 B d ctx env ra (p + Z.of_nat (length (comp ctx d c)) + 1)); eauto.
        -- replace (4 * (p + Z.of_nat (length (comp ctx d c)) + 1)) with (4 * p + 4 * Z.of_nat (length (comp ctx d c)) + 4) by lia.
          exact Ht.
        -- cbn [pc]. lia.
        -- lia.
      * eapply (IHst2 B d ctx env ra (p + Z.of_nat (length (comp ctx d c)) + 1 + Z.of_nat (slen ctx d st1))); eauto.
        -- replace (4 * (p + Z.of_nat (length (comp ctx d c)) + 1 + Z.of_nat (slen ctx d st1)))
            with (4 * p + 4 * Z.of_nat (length (comp ctx d c)) + 4 + 4 * Z.of_nat (slen ctx d st1)) by lia.
          exact Hf.
        -- cbn [pc]. lia.
        -- lia.
    + inversion Ev; subst r n.
      eapply reach_c_seq.
      { eapply reach_lift; [exact W|]. exact (comp_correct c env ctx d B code _ s (RTrap t) E Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 P1]. eapply finish_trap; eauto; lia.
  - (* SCall *)
    pose proof (depth_nonneg a).
    pose proof (code_at_app_l _ _ _ _ H) as Hc. pose proof (code_at_app_r _ _ _ _ H) as C0. cbn [app] in C0.
    pose proof (code_at_cons _ _ _ _ C0) as C1. pose proof (code_at_cons _ _ _ _ C1) as C2.
    pose proof (code_at_cons _ _ _ _ C2) as C3. pose proof (code_at_cons _ _ _ _ C3) as C4.
    pose proof (code_at_cons _ _ _ _ C4) as C5. pose proof (code_at_cons _ _ _ _ C5) as C6.
    pose proof (code_at_cons _ _ _ _ C6) as Hk.
    destruct (eval env a) as [[v|t]|] eqn:E; try discriminate.
    2: { inversion Ev; subst r n.
         eapply reach_c_seq.
         { eapply reach_lift; [exact W|]. exact (comp_correct a env ctx d B code _ s (RTrap t) E Hc Hp Fr ltac:(lia)). }
         intros s1 [W1 P1]. eapply finish_trap; eauto; lia. }
    destruct (call g v) as [[r' nc]|] eqn:Eg; try discriminate.
    assert (Lc : lo <= B - 16 * (d + nc) /\ lo <= B - 16 * (d + depth a)).
    { destruct r' as [w|t]; [destruct (sexec call (d + 1) (w :: env) st) as [[r1 m]|]; [|discriminate]|];
      inversion Ev; subst; lia. }
    eapply reach_c_seq.
    { eapply reach_lift; [exact W|]. exact (comp_correct a env ctx d B code _ s (ROk v) E Hc Hp Fr ltac:(lia)). }
    intros s1 [W1 [K1 [M1 [P1 [X1 S1]]]]].
    pose proof (pc_inside _ s1 _ _ C0 P1) as Rpc.
    (* bl g *)
    cstep exec_bl C0. cpc.
    eapply reach_c_seq.
    { apply reach_c_wf; [assumption|].
      eapply (Spec g v r' nc _ (pc s1 + 4) Eg); cpc.
      - rewrite P1. lia.
      - assumption.
      - rewrite upd_other by lia. exact X1.
      - rewrite S1, Sp. Z.div_mod_to_equations. lia.
      - apply upd_same.
      - rewrite S1, Sp. lia. }
    intros s3 [W3 [P3 [S3 [R3 [K3 [M3 O3]]]]]]. cpc.
    (* add x9, sp, #16d ; ldr x30, [sp, #16(d-2)] *)
    cstep exec_x9 C1. cstep exec_ldr_r C2. cpc.
    replace (sp s3 + 16 * d) with B in * by lia.
    replace (sp s3 + 2 * (d - 2) * 8) with (B - 32) in * by lia.
    assert (Mra : mem s3 (B - 32) = ra) by (rewrite M3 by (cbn; lia); cbn; rewrite M1 by lia; exact MR).
    rewrite Mra in *.
    assert (Kx : forall k, k <> 0 -> k <> 1 -> k <> 2 -> k <> 3 -> k <> 9 -> k <> 30 -> gpr s3 k = gpr s k).
    { intros k ? ? ? ? ? ?. rewrite K3 by auto. cbn. rewrite upd_other by lia. apply K1. lia. }
    assert (Mx : forall a0, sp s <= a0 -> mem s3 a0 = mem s a0).
    { intros a0 Ha. rewrite M3 by (cbn; lia). cbn. apply M1. exact Ha. }
    destruct r' as [w|t].
    + (* the callee returned: cbz x1 -> push the result, continue *)
      destruct O3 as [O1 O0].
      destruct (sexec call (d + 1) (w :: env) st) as [[r1 m]|] eqn:Ek; [|discriminate].
      inversion Ev; subst r n. pose proof (sexec_need_ge _ _ _ _ _ _ Ek).
      cstep exec_cbz C3. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *. cpc.
      rewrite !upd_other by lia. rewrite O1. cbn [Z.eqb xorb].
      set (s6 := MState (pc s3 + 4 + 4 + 3 * 4) (upd (upd (gpr s3) 9 B) 30 ra) (sp s3) (nzcv s3) (mem s3)) in *.
      assert (Fr6 : frame B d ctx env s6).
      { eapply frame_keep; [exact Fr|assumption| | |unfold s6; cbn; lia].
        - intros k Hkk. unfold s6. cbn [gpr]. unfold upd.
          destruct (Z.eqb_spec k 30) as [->|]; [symmetry; exact R30|].
          destruct (Z.eqb_spec k 9) as [->|]; [symmetry; exact X9|]. apply Kx; lia.
        - intros a0 Ha. unfold s6. cbn [mem]. apply Mx. exact Ha. }
      eapply reach_c_step.
      { apply sim_step. eapply push_step; [exact C6|unfold s6; cbn [pc]; lia|exact Fr6|lia]. }
      eapply reach_c_mono.
      { eapply (IHst B (d + 1) (d :: ctx) (w :: env) ra (p + Z.of_nat (length (comp ctx d a)) + 7)); eauto.
        - replace (4 * (p + Z.of_nat (length (comp ctx d a)) + 7))
            with (4 * p + 4 * Z.of_nat (length (comp ctx d a)) + 4 + 4 + 4 + 4 + 4 + 4 + 4) by lia.
          exact Hk.
        - unfold s6. cbn [pushed pc]. lia.
        - split; [apply frame_pushed_let; [exact Fr6|lia|unfold s6; cbn [gpr]; rewrite !upd_other by lia; exact O0]|].
          split; [unfold s6; cbn [pushed gpr]; apply upd_same|]. split; [|lia].
          unfold s6. cbn [pushed mem sp]. rewrite upd_other by lia. exact Mra.
        - lia. }
      intros s' Q. eapply spost_trans; [exact Q| |].
      * intros k ? ? ? ? ? ?. unfold s6. cbn [pushed gpr]. rewrite !upd_other by lia. apply Kx; auto.
      * intros a0 Ha. unfold s6. cbn [pushed mem sp]. rewrite upd_other by lia. apply Mx. lia.
    + (* the callee trapped: x1 is nonzero, return with it *)
      cbn [observed] in O3. inversion Ev; subst r n.
      cstep exec_cbz C3. cpc. unfold rd_zr in *. cbn [Z.eqb Pos.eqb] in *. cpc.
      rewrite !upd_other by lia. rewrite O3.
      replace (xorb (trap_code t =? 0) false) with false by (destruct t; reflexivity).
      cstep exec_movsp9 C4.
      eapply reach_c_step. { erewrite step_c_at; [apply exec_c_ret|exact C5|cpc; lia]. }
      apply reach_c_now. unfold spost, set_pc, observed. cpc.
      rewrite (upd_other _ 30 _ 9) by lia. rewrite upd_same.
      refine (conj _ (conj eq_refl (conj _ (conj _ (conj _ _))))).
      * rewrite ?upd_same; reflexivity.
      * rewrite ?upd_same; reflexivity.
      * intros k ? ? ? ? ? ?. cpc. rewrite !upd_other by lia. apply Kx; auto.
      * intros a0 Ha. cpc. apply Mx. lia.
      * rewrite !upd_other by lia. exact O3.
  - (* STail *)
    pose proof (depth_nonneg a).
    pose proof (code_at_app_l _ _ _ _ H) as Hc. pose proof (code_at_app_r _ _ _ _ H) as Hm. cbn [app] in Hm.
    pose proof (code_at_cons _ _ _ _ Hm) as Hb.
    destruct (eval env a) as [[v|t]|] eqn:E; try discriminate.
    + destruct (call g v) as [[r1 m]|] eqn:Eg; [|discriminate].
      inversion Ev; subst r n.
      eapply reach_c_seq.
      { eapply reach_lift; [exact W|]. exact (comp_correct a env ctx d B code _ s (ROk v) E Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 [K1 [M1 [P1 [X1 S1]]]]].
      cstep exec_movsp9 Hm. cstep exec_b Hb. cpc.
      eapply reach_c_seq.
      { eapply (Spec g v r1 m _ ra Eg); cpc.
        - lia.
        - assumption.
        - exact X1.
        - rewrite K1 by lia. rewrite X9. exact A16.
        - rewrite K1 by lia. exact R30.
        - rewrite K1 by lia. rewrite X9. lia. }
      intros s' [P' [S' [R' [K' [M' O']]]]]. apply reach_c_now. cpc.
      repeat split; auto.
      * rewrite S'. rewrite K1 by lia. exact X9.
      * intros k ? ? ? ? ? ?. rewrite K' by auto. cbn [gpr]. apply K1. lia.
      * intros a0 Ha. rewrite M' by (cbn [sp]; rewrite K1 by lia; lia). cbn [mem]. apply M1. lia.
    + inversion Ev; subst r n.
      eapply reach_c_seq.
      { eapply reach_lift; [exact W|]. exact (comp_correct a env ctx d B code _ s (RTrap t) E Hc Hp Fr ltac:(lia)). }
      intros s1 [W1 P1]. eapply finish_trap; eauto; lia.
Qed.

End Program.

Section Functions.
Variable fns : list stmt.
Local Abbreviation code := (compile_prog fns).
Local Abbreviation FS := (fstarts fns).
Hypothesis Hsize : 4 * Z.of_nat (length (compile_prog fns)) <= hi.

(* A function's frame: mov x9, sp ; push x0 ; push x30 ; body. *)
Lemma fn_step : forall k, fn_spec fns (fcall k fns) -> fn_spec fns (fcall (S k) fns).
Proof.
  intros k IH g v r n s ra Ev Hpc W X0 A R30 L.
  cbn [fcall] in Ev. destruct (nth_error fns g) as [b|] eqn:Eb; [|discriminate].
  pose proof (sexec_need_ge _ _ _ _ _ _ Ev) as N2.
  pose proof (function_at fns g b Eb) as Hf. unfold fcode, fprologue in Hf. cbn [app] in Hf.
  pose proof (code_at_cons _ _ _ _ Hf) as Hf1. pose proof (code_at_cons _ _ _ _ Hf1) as Hf2.
  pose proof (code_at_cons _ _ _ _ Hf2) as Hb.
  pose proof (wf_sp s W) as Ws.
  cstep exec_mov9sp Hf. cstep exec_push Hf1. cstep exec_str_r Hf2. cpc.
  eapply reach_c_mono.
  { refine (stmt_ok fns Hsize (fcall k fns) IH b (sp s) 2 [0] [v] ra (nth g FS 0 + 3) _ r n Ev _ _ _ _).
    - replace (4 * (nth g FS 0 + 3)) with (4 * nth g FS 0 + 4 + 4 + 4) by lia. exact Hb.
    - cbn [pc]. lia.
    - split; [|split; [|split; [|lia]]].
      + split; [assumption|]. split; [cbn [sp]; lia|]. split; [cbn [gpr]; rewrite upd_same; reflexivity|].
        split; [|split; [repeat constructor; lia|split; [exact A|split; lia]]].
        constructor; [|constructor]. cbn [mem gpr sp].
        replace (sp s - 16 * (0 + 1)) with (sp s - 16) by lia.
        rewrite upd_other by lia. rewrite upd_same. rewrite upd_other by lia. exact X0.
      + cbn [gpr]. rewrite upd_other by lia. exact R30.
      + cbn [mem sp gpr]. replace (sp s - 16 - 16) with (sp s - 32) by lia. rewrite upd_same.
        rewrite upd_other by lia. exact R30.
    - lia. }
  intros s' [P [S [X [K [M O]]]]]. cpc.
  repeat split; auto.
  - intros k0 ? ? ? ? ? ?. rewrite K by auto. cbn [gpr]. apply upd_other. auto.
  - intros a Ha. rewrite M by exact Ha. cbn [mem]. rewrite !upd_other by lia. reflexivity.
Qed.

Lemma fn_all : forall k, fn_spec fns (fcall k fns).
Proof.
  induction k as [|k IH].
  - intros g v r n s ra Ev. discriminate.
  - apply fn_step. exact IH.
Qed.

(* The whole program, entered at function main with link address exit. *)
Theorem call_correct : forall fuel main x s r n exit,
  fcall fuel fns main (VInt x) = Some (r, n) ->
  wf s -> pc s = 4 * nth main FS 0 -> gpr s 0 = x -> sp s mod 16 = 0 -> gpr s 30 = exit ->
  (exit < 0 \/ 4 * Z.of_nat (length code) <= exit) -> lo <= sp s - 16 * n ->
  exists k f, (forall fuel', (k <= fuel')%nat -> run_c fuel' code exit s = Some f) /\
    pc f = exit /\ sp f = sp s /\ gpr f 30 = exit /\ keepsx s f /\ mem_above s f /\ observed r f.
Proof.
  intros fuel main x s r n exit Ev W Hpc X A R Ex L.
  destruct (fn_all fuel main (VInt x) r n s exit Ev Hpc W X A R L) as [m [f [St [P [Sf [X30 [K [M O]]]]]]]].
  exists (S m), f. split; [|exact (conj P (conj Sf (conj X30 (conj K (conj M O)))))].
  intros fuel' Hf. apply (run_c_steps _ exit m s f St P Ex). lia.
Qed.

End Functions.

(* ------------------------------------------------------------------ *)
(* Tail calls run in constant stack                                     *)

Fixpoint tail_only (st : stmt) : bool :=
  match st with
  | SCall _ _ _ => false
  | SLet _ k => tail_only k
  | SIf _ t f => tail_only t && tail_only f
  | _ => true
  end.

(* Slots one activation needs below its entry SP, not counting callees. *)
Fixpoint frame_need (d : Z) (st : stmt) : Z :=
  match st with
  | SRet e => d + depth e
  | SLet e k => Z.max (d + depth e) (frame_need (d + 1) k)
  | SIf c t f => Z.max (d + depth c) (Z.max (frame_need d t) (frame_need d f))
  | SCall _ a k => Z.max (d + depth a) (frame_need (d + 1) k)
  | STail _ a => d + depth a
  end.

Definition table_need (fns : list stmt) : Z := fold_right (fun b acc => Z.max (frame_need 2 b) acc) 0 fns.

Lemma table_need_nth : forall fns g b, nth_error fns g = Some b -> frame_need 2 b <= table_need fns.
Proof.
  induction fns as [|b0 fns IH]; intros [|g] b H; cbn in H; try discriminate; cbn [table_need fold_right].
  - inversion H; subst. lia.
  - apply IH in H. unfold table_need in H. lia.
Qed.

Lemma tail_need : forall call T, (forall g v r n, call g v = Some (r, n) -> n <= T) ->
  forall st d env r n, tail_only st = true -> sexec call d env st = Some (r, n) -> n <= Z.max (frame_need d st) T.
Proof.
  intros call T HT st. induction st; intros d env r n Ht Ev; cbn [tail_only] in Ht; cbn [sexec frame_need] in *;
  try discriminate.
  - destruct (eval env e); inversion Ev; lia.
  - destruct (eval env e) as [[v|t]|]; try discriminate.
    + destruct (sexec call (d + 1) (v :: env) st) as [[r1 m]|] eqn:E; inversion Ev; subst.
      apply IHst in E; auto. lia.
    + inversion Ev. lia.
  - apply andb_true_iff in Ht as [Ht1 Ht2].
    destruct (eval env c) as [[[x|[|]]|t]|]; try discriminate.
    + destruct (sexec call d env st1) as [[r1 m]|] eqn:E; inversion Ev; subst. apply IHst1 in E; auto. lia.
    + destruct (sexec call d env st2) as [[r1 m]|] eqn:E; inversion Ev; subst. apply IHst2 in E; auto. lia.
    + inversion Ev. lia.
  - destruct (eval env a) as [[v|t]|]; try discriminate.
    + destruct (call g v) as [[r1 m]|] eqn:E; inversion Ev; subst. apply HT in E. lia.
    + inversion Ev. lia.
Qed.

(* Every call of a table without non-tail calls needs at most table_need
   slots, whatever the fuel, i.e. whatever the number of iterations. *)
Theorem tail_calls_constant_stack : forall fns, forallb tail_only fns = true ->
  forall fuel g v r n, fcall fuel fns g v = Some (r, n) -> n <= table_need fns.
Proof.
  intros fns Ht fuel. induction fuel as [|k IH]; intros g v r n Ev; [discriminate|].
  cbn [fcall] in Ev. destruct (nth_error fns g) as [b|] eqn:Eb; [|discriminate].
  pose proof (table_need_nth _ _ _ Eb).
  assert (Tb : tail_only b = true).
  { apply nth_error_In in Eb. rewrite forallb_forall in Ht. auto. }
  pose proof (tail_need (fcall k fns) (table_need fns) IH b 2 [v] r n Tb Ev). lia.
Qed.

(* Hence a tail-recursive program of any iteration count runs within the
   constant stack bound 16 * table_need fns bytes. *)
Corollary tail_program_correct : forall fns, 4 * Z.of_nat (length (compile_prog fns)) <= hi ->
  forallb tail_only fns = true ->
  forall fuel main x s r n exit,
  fcall fuel fns main (VInt x) = Some (r, n) ->
  wf s -> pc s = 4 * nth main (fstarts fns) 0 -> gpr s 0 = x -> sp s mod 16 = 0 -> gpr s 30 = exit ->
  (exit < 0 \/ 4 * Z.of_nat (length (compile_prog fns)) <= exit) -> lo <= sp s - 16 * table_need fns ->
  exists k f, (forall fuel', (k <= fuel')%nat -> run_c fuel' (compile_prog fns) exit s = Some f) /\
    pc f = exit /\ sp f = sp s /\ gpr f 30 = exit /\ keepsx s f /\ mem_above s f /\ observed r f.
Proof.
  intros fns Hs Ht fuel main x s r n exit Ev W Hpc X A R Ex L.
  pose proof (tail_calls_constant_stack fns Ht fuel main (VInt x) r n Ev).
  eapply call_correct; eauto. lia.
Qed.

Print Assumptions call_correct.
Print Assumptions tail_calls_constant_stack.
Print Assumptions tail_program_correct.
