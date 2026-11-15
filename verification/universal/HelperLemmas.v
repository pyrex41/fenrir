(* A SEPARATE result, not the certificate route of 04_DIRECTION_AMENDMENT.md §3.

   Two cond-free helpers of models/tc0/i64.shen, proved inside Búri's contract
   calculus BURI/KL-CONTRACT-1 (rocq/ContractLogic.v at Búri 47491e2), whose
   rules Búri proves sound (ContractLogic.soundness). No term is written here:
   both bodies are `extracted_*`, generated into FenrirCert.v by certify.shen
   from the KLambda that Shen/JIT 0.7 compiles the model to. Each proof first
   pins the extracted body to the shape it expects (`*_body_is`, by
   computation), so a change in the model or the compiler breaks the proof
   instead of silently changing its subject.

   1. digit_correct. (defun tc0.i64.digit (V117) (- (string->n V117) 48)).
      For every character code c with 48 <= c <= 57 ("0".."9"), every store in
      which `-` and `string->n` are bound to their primitives, every profile and
      every resource policy covering the profile's limits, evaluating the body
      with V117 bound to the one-character string c terminates (total
      correctness), raises nothing, changes nothing, emits no event, and
      returns the integer c - 48, which lies in 0..9. No premises.

   2. checked_correct. (defun tc0.i64.checked (V270) (if (tc0.i64.fits? V270)
      [ok (tc0.i64.show V270)] [trap overflow])). Under two NAMED PREMISES -
      call contracts for tc0.i64.fits? (returns the Boolean fitsb x, purely) and
      tc0.i64.show (returns showv x, purely) on a domain D, which this file
      does not prove and which Búri's soundness theorem takes as ctx_at
      premises - the body returns exactly [ok (showv V)] when fitsb V is true
      and [trap overflow] when it is false, with no exception and no effect.
      This is the outer shape of the range property; that fitsb decides the
      I64 range and that the argument is the exact sum are NOT proved.

   What both are about: Búri's formal KLambda semantics (KLSemantics.next).
   That Shen/JIT executes KLambda as that semantics says is Búri's open goal,
   not a result. Checked by Rocq (Coq 8.18.0, Búri's pin for this lane). *)
From Coq Require Import List ZArith NArith String Lia.
From Buri Require Import Observation KLSyntax KLValue KLSemantics KLMetatheory ContractLogic ContractPrims.
From Fenrir Require Import FenrirCert.
Import ListNotations.
Import Observation.Observation KLSyntax.KLSyntax KLValue.KLValue KLSemantics.KLSemantics.
Import ContractLogic.ContractLogic ContractPrims.ContractPrims.

Definition digit_param : text := match extracted_digit with (_, [x], _) => x | _ => [] end.
Definition digit_body : expr := match extracted_digit with (_, _, b) => b end.
Definition subn : text := of_string "-".
Definition s2nn : text := of_string "string->n".

(* The extracted body is the expected shape; this pins the lemma to the extraction. *)
Lemma digit_body_is : digit_body =
  ECall subn [ECall s2nn [EVar digit_param]; ENum (NInt 48)].
Proof. vm_compute. reflexivity. Qed.

Section Digit.
Variable P : profile.
Variable RP : resource -> Prop.

Definition G : list cspec := [prim_spec P RP subn PSub; prim_spec P RP s2nn PStringToN].
Definition nothing : epost := fun _ _ _ => False.
Definition prims_bound (s : store) :=
  lookup subn (gfuns s) = Some (FPrim PSub) /\ lookup s2nn (gfuns s) = Some (FPrim PStringToN).

Lemma digit_deriv : forall (c : N) rho s0, prims_bound s0 ->
  lookup digit_param rho = Some (VStr [c]) ->
  deriv P RP Total G (fun s => s = s0) rho digit_body
    (fun v s t => v = VNum (NInt (Z.of_N c - 48)) /\ s = s0 /\ t = []) nothing.
Proof.
  intros c rho s0 [Bsub Bs2n] Hrho. rewrite digit_body_is.
  eapply r_call with (Qs := fun vs s t => vs = [VNum (NInt (Z.of_N c)); VNum (NInt 48)] /\ s = s0 /\ t = []).
  - eapply da_cons with (R := fun v s t => v = VNum (NInt (Z.of_N c)) /\ s = s0 /\ t = []).
    + eapply r_call with (Qs := fun vs s t => vs = [VStr [c]] /\ s = s0 /\ t = []).
      * apply da_one. eapply r_conseq.
        -- apply (r_val P RP Total G rho (EVar digit_param) (VStr [c])
                    (fun v s t => [v] = [VStr [c]] /\ s = s0 /\ t = []) nothing).
           exact Hrho.
        -- intros s ->. auto.
        -- auto.
        -- auto.
      * intros vs s1 t1 (-> & -> & ->).
        apply (aj_ctx P RP Total G (prim_spec P RP s2nn PStringToN) [] [VStr [c]]).
        -- cbn; auto.
        -- intros s ->. cbn. split; [split; [exact Bs2n|split; reflexivity]|split].
           ++ intros v s' t (-> & E). injection E as <- <-. unfold shift. auto.
           ++ intros x s' t (_ & _ & E). discriminate E.
    + intros v s1 t1 (-> & -> & ->). apply da_one. eapply r_conseq.
      * apply (r_val P RP Total G rho (ENum (NInt 48)) (VNum (NInt 48))
                 (fun v s t => [VNum (NInt (Z.of_N c)); v] = [VNum (NInt (Z.of_N c)); VNum (NInt 48)] /\ s = s0 /\ t = [])
                 (shiftE [] nothing)).
        reflexivity.
      * intros s ->. auto.
      * intros v s t (E & -> & ->). cbn. auto.
      * auto.
  - intros vs s1 t1 (-> & -> & ->).
    apply (aj_ctx P RP Total G (prim_spec P RP subn PSub) [] [VNum (NInt (Z.of_N c)); VNum (NInt 48)]).
    + cbn; auto.
    + intros s ->. cbn. split; [split; [exact Bsub|split; reflexivity]|split].
      * intros v s' t (-> & E). injection E as <- <-. unfold shift. auto.
      * intros x s' t (_ & _ & E). discriminate E.
Qed.

Hypothesis PO : policy_ok P RP.

(* The meaning, through Búri's soundness theorem and its proved primitive contracts. *)
Theorem digit_correct : forall (c : N) rho s0, (48 <= c <= 57)%N -> prims_bound s0 ->
  lookup digit_param rho = Some (VStr [c]) ->
  triple P RP Total (fun s => s = s0) rho digit_body
    (fun v s t => exists d, v = VNum (NInt d) /\ (0 <= d <= 9)%Z /\ d = (Z.of_N c - 48)%Z /\ s = s0 /\ t = []) nothing.
Proof.
  intros c rho s0 Hc B Hrho n.
  assert (Ctx : ctx_at P RP Total n G).
  { intros k [<-|[<-|[]]]; apply prim_spec_valid. }
  pose proof (proj1 (soundness P RP PO Total G n Ctx) _ _ _ _ _ (digit_deriv c rho s0 B Hrho)) as T.
  eapply sem_conseq; [exact T| | |].
  - auto.
  - intros v s t (-> & -> & ->). exists (Z.of_N c - 48)%Z. repeat split; lia.
  - auto.
Qed.
End Digit.

(* ---------- 2. tc0.i64.checked, under named premises for fits? and show ---------- *)
Definition checked_param : text := match extracted_checked with (_, [x], _) => x | _ => [] end.
Definition checked_body : expr := match extracted_checked with (_, _, b) => b end.
Definition consn : text := of_string "cons".
Definition fitsn : text := of_string "tc0.i64.fits?".
Definition shown : text := of_string "tc0.i64.show".
Definition okn : text := of_string "ok".
Definition trapn : text := of_string "trap".
Definition overflown : text := of_string "overflow".

Lemma checked_body_is : checked_body =
  EIf (ECall fitsn [EVar checked_param])
      (ECall consn [ESym okn; ECall consn [ECall shown [EVar checked_param]; ENil]])
      (ECall consn [ESym trapn; ECall consn [ESym overflown; ENil]]).
Proof. vm_compute. reflexivity. Qed.

Section Checked.
Variable P : profile.
Variable RP : resource -> Prop.
(* The premises' content: fits? and show are pure functions fitsb and showv on a domain D. *)
Variables (fitsb : value -> bool) (showv : value -> value) (D : value -> Prop).

Definition exact (v : value) (s0 : store) : post := fun w s t => w = v /\ s = s0 /\ t = [].
Definition fits_spec : cspec := CSpec fitsn (fun vs _ => exists x, vs = [x] /\ D x)
  (fun vs s0 v s t => exists x, vs = [x] /\ v = VBool (fitsb x) /\ s = s0 /\ t = []) (fun _ _ _ _ _ => False).
Definition show_spec : cspec := CSpec shown (fun vs _ => exists x, vs = [x] /\ D x)
  (fun vs s0 v s t => exists x, vs = [x] /\ v = showv x /\ s = s0 /\ t = []) (fun _ _ _ _ _ => False).
Definition GC : list cspec := [prim_spec P RP consn PCons; fits_spec; show_spec].

Lemma d_atom : forall rho e v s0 E, atom rho e = Some v ->
  deriv P RP Total GC (fun s => s = s0) rho e (exact v s0) E.
Proof.
  intros rho e v s0 E A. eapply r_conseq; [apply (r_val P RP Total GC rho e v (exact v s0) E A)| | |].
  - intros s ->. unfold exact; auto.
  - auto.
  - auto.
Qed.

Lemma a_one : forall rho a v s0 tg E, deriv P RP Total GC (fun s => s = s0) rho a (exact v s0) E ->
  dargs P RP Total GC (fun s => s = s0) rho [a] tg (fun ws s t => ws = [v] /\ s = s0 /\ t = []) E.
Proof.
  intros rho a v s0 tg E H. apply da_one. eapply r_conseq; [exact H| | |]; auto.
  intros w s t (-> & -> & ->); auto.
Qed.

Lemma a_two : forall rho a b va vb s0 tg E,
  deriv P RP Total GC (fun s => s = s0) rho a (exact va s0) E ->
  deriv P RP Total GC (fun s => s = s0) rho b (exact vb s0) E ->
  dargs P RP Total GC (fun s => s = s0) rho [a; b] tg (fun ws s t => ws = [va; vb] /\ s = s0 /\ t = []) E.
Proof.
  intros rho a b va vb s0 tg E Ha Hb. eapply da_cons; [exact Ha|].
  intros v s1 t1 (-> & -> & ->). apply da_one. eapply r_conseq; [exact Hb| | |].
  - auto.
  - intros w s t (-> & -> & ->); cbn; auto.
  - intros x s t Hx; exact Hx.
Qed.

Lemma d_call : forall rho c args vs s0 r E, In c GC ->
  dargs P RP Total GC (fun s => s = s0) rho args (TCall (c_name c)) (fun ws s t => ws = vs /\ s = s0 /\ t = []) E ->
  c_pre c vs s0 ->
  (forall v s t, c_post c vs s0 v s t -> v = r /\ s = s0 /\ t = []) ->
  (forall x s t, c_exn c vs s0 x s t -> False) ->
  deriv P RP Total GC (fun s => s = s0) rho (ECall (c_name c) args) (exact r s0) E.
Proof.
  intros rho c args vs s0 r E I A Pre Post Exn. eapply r_call; [exact A|].
  intros ws s1 t1 (-> & -> & ->). apply (aj_ctx P RP Total GC c [] vs); [exact I|].
  intros s ->. cbn [app]. split; [exact Pre|split].
  - intros v s' t Hp. destruct (Post v s' t Hp) as (-> & -> & ->). unfold shift, exact. auto.
  - intros x s' t Hx. exfalso; eapply Exn; eauto.
Qed.

Lemma d_cons : forall rho a b va vb s0 E, lookup consn (gfuns s0) = Some (FPrim PCons) ->
  deriv P RP Total GC (fun s => s = s0) rho a (exact va s0) E ->
  deriv P RP Total GC (fun s => s = s0) rho b (exact vb s0) E ->
  deriv P RP Total GC (fun s => s = s0) rho (ECall consn [a; b]) (exact (VCons va vb) s0) E.
Proof.
  intros rho a b va vb s0 E B Ha Hb.
  apply (d_call rho (prim_spec P RP consn PCons) [a; b] [va; vb] s0 (VCons va vb) E).
  - left; reflexivity.
  - apply a_two; assumption.
  - cbn. repeat split; auto.
  - intros v s t (-> & H). cbn in H. injection H as <- <-. auto.
  - intros x s t (_ & _ & H). cbn in H. discriminate H.
Qed.

Definition checked_result (V : value) : value :=
  if fitsb V then VCons (VSym okn) (VCons (showv V) VNil) else VCons (VSym trapn) (VCons (VSym overflown) VNil).

Lemma checked_deriv : forall V rho s0, D V -> lookup consn (gfuns s0) = Some (FPrim PCons) ->
  lookup checked_param rho = Some V ->
  deriv P RP Total GC (fun s => s = s0) rho checked_body (exact (checked_result V) s0) (fun _ _ _ => False).
Proof.
  intros V rho s0 HD B Hrho. rewrite checked_body_is. unfold checked_result.
  eapply r_if with (R := exact (VBool (fitsb V)) s0).
  - apply (d_call rho fits_spec [EVar checked_param] [V] s0 (VBool (fitsb V))).
    + right; left; reflexivity.
    + apply a_one, d_atom; exact Hrho.
    + exists V; auto.
    + intros v s t (x & E & -> & -> & ->). injection E as ->. auto.
    + intros x s t [].
  - intros s1 t1 (Eb & -> & ->). injection Eb as Hf. rewrite <- Hf.
    eapply r_conseq; [| | |].
    + apply d_cons; [exact B|apply d_atom; reflexivity|].
      apply d_cons; [exact B| |apply d_atom; reflexivity].
      apply (d_call rho show_spec [EVar checked_param] [V] s0 (showv V)).
      * right; right; left; reflexivity.
      * apply a_one, d_atom; exact Hrho.
      * exists V; auto.
      * intros v s t (x & E & -> & -> & ->). injection E as ->. auto.
      * intros x s t [].
    + intros s ->; reflexivity.
    + intros v s t H; exact H.
    + intros x s t H; exact H.
  - intros s1 t1 (Eb & -> & ->). injection Eb as Hf. rewrite <- Hf.
    eapply r_conseq; [| | |].
    + apply d_cons; [exact B|apply d_atom; reflexivity|].
      apply d_cons; [exact B|apply d_atom; reflexivity|apply d_atom; reflexivity].
    + intros s ->; reflexivity.
    + intros v s t H; exact H.
    + intros x s t H; exact H.
  - intros v s1 t1 (-> & _ & _) N. exfalso; eapply N; reflexivity.
Qed.

Hypothesis PO : policy_ok P RP.
(* The two host contracts are premises, exactly as Búri's soundness theorem takes them. *)
Hypothesis Premises : forall n, ctx_at P RP Total n [fits_spec; show_spec].

Theorem checked_correct : forall V rho s0, D V -> lookup consn (gfuns s0) = Some (FPrim PCons) ->
  lookup checked_param rho = Some V ->
  triple P RP Total (fun s => s = s0) rho checked_body (exact (checked_result V) s0) (fun _ _ _ => False).
Proof.
  intros V rho s0 HD B Hrho n.
  assert (Ctx : ctx_at P RP Total n GC).
  { intros k [<-|I]; [apply prim_spec_valid|exact (Premises n k I)]. }
  exact (proj1 (soundness P RP PO Total GC n Ctx) _ _ _ _ _ (checked_deriv V rho s0 HD B Hrho)).
Qed.
End Checked.
