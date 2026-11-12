(* Fenrir direction amendment, first application example (model level).

   A tenant-scoped request atomically writes business state (a report),
   records a durable job, records its retry result, and only then may be
   answered with an acceptance.

   STATUS: "model property proved". Everything here is about this abstract
   transition system. Nothing relates it yet to Fenrir source programs, the
   Shen machines, a compiler, or a real database. The storage contract is an
   ASSUMPTION built into the model: a transaction is a pure function on one
   tenant's durable store and is installed atomically; a crash loses only
   volatile state. See README.md in this directory for the claim ledger. *)

From Coq Require Import List Bool Arith Lia.
Import ListNotations.

(* ---------- Durable data ---------- *)

Record receipt := Receipt {
  rc_tenant : nat; rc_key : nat; rc_digest : nat; rc_report : nat; rc_job : nat }.

Inductive status := Pending | Done | Failed.

(* One tenant's durable store. [dedup] maps a request key to the payload
   digest it was first used with and the receipt to replay on retry. *)
Record tstore := Store {
  reports : list (nat * nat);              (* report id, payload digest *)
  jobs    : list (nat * nat * status);     (* job id, report id, status  *)
  dedup   : list (nat * (nat * receipt));  (* key -> digest, receipt     *)
  next    : nat }.

Definition empty := Store [] [] [] 0.

Fixpoint lookup (k : nat) (l : list (nat * (nat * receipt))) :=
  match l with
  | [] => None
  | (k', v) :: r => if k' =? k then Some v else lookup k r
  end.

Inductive result := Accepted (rc : receipt) | Conflict.

(* The whole request transaction. The receipt is created here and nowhere
   else: holding one is evidence of this commit. *)
Definition submit (t k d : nat) (s : tstore) : tstore * result :=
  match lookup k (dedup s) with
  | Some (d', rc) => if d' =? d then (s, Accepted rc) else (s, Conflict)
  | None =>
      let n := next s in
      let rc := Receipt t k d n n in
      (Store ((n, d) :: reports s) ((n, n, Pending) :: jobs s)
             ((k, (d, rc)) :: dedup s) (S n), Accepted rc)
  end.

(* Worker completion, with durable deduplication: only a Pending job moves. *)
Definition finish (j : nat) (ok : bool) (e : nat * nat * status) :=
  match e with
  | (j', r, Pending) => if j' =? j then (j', r, if ok then Done else Failed) else e
  | _ => e
  end.

Definition complete (j : nat) (ok : bool) (s : tstore) :=
  Store (reports s) (map (finish j ok) (jobs s)) (dedup s) (next s).

(* ---------- Per-tenant invariant: the three records travel together ---------- *)

Record good (t : nat) (s : tstore) : Prop := {
  g_dedup : forall k d rc, lookup k (dedup s) = Some (d, rc) ->
      rc = Receipt t k d (rc_report rc) (rc_job rc) /\
      In (rc_report rc, d) (reports s) /\
      exists st, In (rc_job rc, rc_report rc, st) (jobs s);
  g_report : forall n d, In (n, d) (reports s) ->
      n < next s /\ (exists st, In (n, n, st) (jobs s)) /\
      exists k rc, lookup k (dedup s) = Some (d, rc) /\ rc_report rc = n;
  g_job : forall j r st, In (j, r, st) (jobs s) ->
      j < next s /\ exists d, In (r, d) (reports s);
  g_nodup : NoDup (map fst (reports s)) }.

Lemma good_empty : forall t, good t empty.
Proof. intro t. split; simpl; intros; try contradiction; try discriminate. constructor. Qed.

Lemma good_submit : forall t k d s, good t s -> good t (fst (submit t k d s)).
Proof.
  intros t k d s G. unfold submit.
  destruct (lookup k (dedup s)) as [[d' rc]|] eqn:L.
  - destruct (d' =? d); exact G.
  - destruct G as [Gd Gr Gj Gn]. split; simpl.
    + intros k0 d0 rc0 H. destruct (k =? k0) eqn:E.
      * apply Nat.eqb_eq in E. subst k0. injection H as <- <-. simpl.
        split; [reflexivity|]. split; [left; reflexivity|].
        exists Pending. left. reflexivity.
      * destruct (Gd _ _ _ H) as (A & B & st & C).
        split; [exact A|]. split; [right; exact B|]. exists st. right. exact C.
    + intros n d0 [H|H].
      * injection H as <- <-. split; [lia|].
        split; [exists Pending; left; reflexivity|].
        exists k, (Receipt t k d (next s) (next s)). rewrite Nat.eqb_refl. auto.
      * destruct (Gr _ _ H) as (A & (st & B) & k0 & rc0 & C & D).
        split; [lia|]. split; [exists st; right; exact B|].
        exists k0, rc0. split; [|exact D].
        destruct (k =? k0) eqn:E; [|exact C].
        apply Nat.eqb_eq in E. subst k0. congruence.
    + intros j r st [H|H].
      * injection H as <- <- <-. split; [lia|]. exists d. left. reflexivity.
      * destruct (Gj _ _ _ H) as (A & d0 & B). split; [lia|]. exists d0. right. exact B.
    + constructor; [|exact Gn]. intro H. apply in_map_iff in H.
      destruct H as ([n d0] & E & H). simpl in E. subst n.
      destruct (Gr _ _ H) as (A & _). lia.
Qed.

Lemma finish_in : forall j ok l j0 r st, In (j0, r, st) l ->
  exists st', In (j0, r, st') (map (finish j ok) l).
Proof.
  intros j ok l j0 r st H. apply (in_map (finish j ok)) in H.
  unfold finish in H at 1. destruct st; eauto. destruct (j0 =? j); eauto.
Qed.

Lemma finish_inv : forall j ok l j0 r st', In (j0, r, st') (map (finish j ok) l) ->
  exists st, In (j0, r, st) l.
Proof.
  intros j ok l j0 r st' H. apply in_map_iff in H.
  destruct H as ([[j1 r1] s1] & E & H). unfold finish in E.
  destruct s1; [destruct (j1 =? j)|..]; injection E as <- <- <-; eauto.
Qed.

Lemma good_complete : forall t j ok s, good t s -> good t (complete j ok s).
Proof.
  intros t j ok s [Gd Gr Gj Gn]. split; simpl; auto.
  - intros k d rc H. destruct (Gd _ _ _ H) as (A & B & st & C).
    split; [exact A|]. split; [exact B|]. eapply finish_in; eauto.
  - intros n d H. destruct (Gr _ _ H) as (A & (st & B) & C).
    split; [exact A|]. split; [eapply finish_in; eauto|exact C].
  - intros j0 r st H. destruct (finish_inv _ _ _ _ _ _ H) as (st0 & H0). eauto.
Qed.

(* ---------- Retry semantics of the transaction itself ---------- *)

Lemma lookup_submit_stable : forall t k d s k0 v,
  lookup k0 (dedup s) = Some v -> lookup k0 (dedup (fst (submit t k d s))) = Some v.
Proof.
  intros t k d s k0 v H. unfold submit.
  destruct (lookup k (dedup s)) as [[d' rc]|] eqn:L.
  - destruct (d' =? d); exact H.
  - simpl. destruct (k =? k0) eqn:E; [|exact H].
    apply Nat.eqb_eq in E. subst k0. congruence.
Qed.

Lemma submit_recorded : forall t k d s s' rc, good t s ->
  submit t k d s = (s', Accepted rc) ->
  rc_tenant rc = t /\ rc_key rc = k /\ rc_digest rc = d /\
  lookup k (dedup s') = Some (d, rc).
Proof.
  intros t k d s s' rc G. unfold submit.
  destruct (lookup k (dedup s)) as [[d' rc']|] eqn:L.
  - destruct (d' =? d) eqn:E; [|discriminate]. intro H. injection H as <- <-.
    apply Nat.eqb_eq in E. subst d'.
    destruct (g_dedup _ _ G _ _ _ L) as (A & _). rewrite A. simpl. rewrite <- A. auto.
  - intro H. injection H as <- <-. simpl. rewrite Nat.eqb_refl. auto.
Qed.

(* Same key, same payload: the recorded answer, and no second mutation. *)
Theorem replay_same : forall t k d s rc,
  lookup k (dedup s) = Some (d, rc) -> submit t k d s = (s, Accepted rc).
Proof. intros. unfold submit. rewrite H, Nat.eqb_refl. reflexivity. Qed.

(* Same key, different payload: explicit refusal, and no mutation. *)
Theorem replay_conflict : forall t k d d' s rc,
  lookup k (dedup s) = Some (d, rc) -> d' <> d -> submit t k d' s = (s, Conflict).
Proof.
  intros. unfold submit. rewrite H.
  destruct (d =? d') eqn:E; [apply Nat.eqb_eq in E; congruence|reflexivity].
Qed.

(* ---------- The system: durable stores, volatile outbox, observed trace ---------- *)

Inductive event := EAccepted (rc : receipt) | EConflict (t k : nat).

Definition reply (t k : nat) (r : result) :=
  match r with Accepted rc => EAccepted rc | Conflict => EConflict t k end.

Record sys := Sys {
  durable : nat -> tstore;   (* survives crashes *)
  outbox  : list event;      (* volatile: computed but unsent responses *)
  trace   : list event }.    (* what clients have actually been told *)

Definition upd (f : nat -> tstore) (t : nat) (s : tstore) :=
  fun t' => if t' =? t then s else f t'.

Inductive label :=
| LSubmit (t k d : nat)            (* request or client retry, with tenant capability t *)
| LComplete (t j : nat) (ok : bool) (* worker delivery, possibly duplicated *)
| LRespond (e : event)             (* a computed response reaches the client *)
| LCrash.                          (* lose all volatile state *)

Definition tenant_of (l : label) : option nat :=
  match l with LSubmit t _ _ | LComplete t _ _ => Some t | _ => None end.

Inductive step : label -> sys -> sys -> Prop :=
| SSubmit : forall t k d x,
    step (LSubmit t k d) x
      (Sys (upd (durable x) t (fst (submit t k d (durable x t))))
           (reply t k (snd (submit t k d (durable x t))) :: outbox x) (trace x))
| SComplete : forall t j ok x,
    step (LComplete t j ok) x
      (Sys (upd (durable x) t (complete j ok (durable x t))) (outbox x) (trace x))
| SRespond : forall e x, In e (outbox x) ->
    step (LRespond e) x (Sys (durable x) (outbox x) (e :: trace x))
| SCrash : forall x,
    step LCrash x (Sys (durable x) [] (trace x)).

Inductive reachable : sys -> Prop :=
| RInit : reachable (Sys (fun _ => empty) [] [])
| RStep : forall l x y, reachable x -> step l x y -> reachable y.

(* 1. AUTHORITY (write isolation): a step taken under tenant t's capability
   leaves every other tenant's durable store exactly as it was. This is a
   frame property; it is NOT a confidentiality (noninterference) theorem. *)
Theorem tenant_frame : forall l x y t', step l x y ->
  tenant_of l <> Some t' -> durable y t' = durable x t'.
Proof.
  intros l x y t' H N. destruct H; simpl in *; auto; unfold upd;
  destruct (t' =? t) eqn:E; auto; apply Nat.eqb_eq in E; congruence.
Qed.

Definition recorded (st : nat -> tstore) (rc : receipt) :=
  lookup (rc_key rc) (dedup (st (rc_tenant rc))) = Some (rc_digest rc, rc).

Definition inv (x : sys) :=
  (forall t, good t (durable x t)) /\
  (forall rc, In (EAccepted rc) (outbox x) \/ In (EAccepted rc) (trace x) ->
              recorded (durable x) rc).

Lemma recorded_step : forall l x y rc, step l x y ->
  recorded (durable x) rc -> recorded (durable y) rc.
Proof.
  intros l x y rc H R. unfold recorded in *. destruct H; simpl; auto; unfold upd;
  destruct (rc_tenant rc =? t) eqn:E; auto; apply Nat.eqb_eq in E; rewrite E in R.
  - apply lookup_submit_stable. exact R.
  - exact R.
Qed.

Lemma inv_step : forall l x y, inv x -> step l x y -> inv y.
Proof.
  intros l x y [G R] H. split.
  - intro t0. destruct H; simpl; auto; unfold upd;
    destruct (t0 =? t) eqn:E; auto; apply Nat.eqb_eq in E; subst t0.
    + apply good_submit, G.
    + apply good_complete, G.
  - intros rc Hin. assert (S := recorded_step _ _ _ rc H).
    destruct H; simpl in *.
    + destruct Hin as [[Hin|Hin]|Hin]; auto.
      destruct (submit t k d (durable x t)) as [s' r] eqn:Sub. simpl in *.
      destruct r; [|discriminate]. injection Hin as ->.
      destruct (submit_recorded _ _ _ _ _ _ (G t) Sub) as (A & B & C & D).
      unfold recorded, upd. rewrite A, B, C, Nat.eqb_refl. exact D.
    + auto.
    + destruct Hin as [Hin|[Hin|Hin]]; auto. subst e. auto.
    + destruct Hin as [[]|Hin]; auto.
Qed.

Theorem reachable_inv : forall x, reachable x -> inv x.
Proof.
  induction 1.
  - split; simpl; [intro; apply good_empty|intros rc [[]|[]]].
  - eapply inv_step; eauto.
Qed.

(* 2. ATOMICITY: in every reachable state, across every interleaving of
   requests, retries, duplicate worker deliveries and crashes, each tenant's
   report, job and retry record exist together or not at all. *)
Theorem atomic_records : forall x t, reachable x -> good t (durable x t).
Proof. intros x t H. apply (reachable_inv x H). Qed.

(* 3. RESPONSE DISCIPLINE / acceptance durability: if a client has been told
   Accepted, the receipt names this tenant's request, and the report, its job
   obligation and the retry record are in durable state now -- however many
   crashes happened in between. *)
Theorem acceptance_durable : forall x rc, reachable x -> In (EAccepted rc) (trace x) ->
  let s := durable x (rc_tenant rc) in
  recorded (durable x) rc /\
  In (rc_report rc, rc_digest rc) (reports s) /\
  exists st, In (rc_job rc, rc_report rc, st) (jobs s).
Proof.
  intros x rc H Hin. destruct (reachable_inv x H) as [G R].
  assert (Rec := R rc (or_intror Hin)). split; [exact Rec|].
  destruct (g_dedup _ _ (G (rc_tenant rc)) _ _ _ Rec) as (_ & B & C). auto.
Qed.

(* 4. RETRY SAFETY: after an acknowledged acceptance, retrying the same
   request at any later time returns the same receipt and changes nothing;
   reusing its key with another payload is refused and changes nothing. *)
Theorem retry_safe : forall x rc, reachable x -> In (EAccepted rc) (trace x) ->
  let s := durable x (rc_tenant rc) in
  submit (rc_tenant rc) (rc_key rc) (rc_digest rc) s = (s, Accepted rc) /\
  forall d', d' <> rc_digest rc ->
    submit (rc_tenant rc) (rc_key rc) d' s = (s, Conflict).
Proof.
  intros x rc H Hin. destruct (acceptance_durable x rc H Hin) as (Rec & _).
  split; [apply replay_same; exact Rec|].
  intros d' N. eapply replay_conflict; eauto.
Qed.

(* Distinct accepted requests of one tenant never share a report. *)
Theorem reports_unique : forall x t, reachable x -> NoDup (map fst (reports (durable x t))).
Proof. intros x t H. apply (g_nodup _ _ (atomic_records x t H)). Qed.

(* 5. RECOVERY: a crash changes neither durable state nor what clients were
   told; a duplicated worker delivery is absorbed; a terminal job stays
   terminal. *)
Theorem crash_preserves : forall x y, step LCrash x y ->
  durable y = durable x /\ trace y = trace x.
Proof. intros x y H. inversion H. auto. Qed.

Lemma finish_idem : forall j ok ok' e, finish j ok' (finish j ok e) = finish j ok e.
Proof.
  intros j ok ok' [[j' r] st]. destruct st; simpl; auto.
  destruct (j' =? j) eqn:E; simpl; [destruct ok; reflexivity|rewrite E; reflexivity].
Qed.

Theorem duplicate_delivery_absorbed : forall j ok ok' s,
  complete j ok' (complete j ok s) = complete j ok s.
Proof.
  intros. unfold complete. simpl. f_equal. rewrite map_map.
  apply map_ext. intro. apply finish_idem.
Qed.

Theorem terminal_stable : forall l x y t j r st, step l x y -> st <> Pending ->
  In (j, r, st) (jobs (durable x t)) -> In (j, r, st) (jobs (durable y t)).
Proof.
  intros l x y t j r st H N Hin. destruct H; simpl; auto; unfold upd;
  destruct (t =? t0) eqn:E; auto; apply Nat.eqb_eq in E; subst t0.
  - unfold submit. destruct (lookup k (dedup (durable x t))) as [[d' rc]|].
    + destruct (d' =? d); exact Hin.
    + simpl. auto.
  - simpl. apply (in_map (finish j0 ok)) in Hin. destruct st; auto. congruence.
Qed.

(* 6. PROGRESS, conditional: this is not a liveness theorem. It says that IF
   the scheduler eventually delivers job j to a worker, j is terminal
   afterwards; with [terminal_stable] it then stays so. Whether delivery
   happens is an explicit scheduling/availability assumption. *)
Theorem delivery_terminates : forall j ok s r, ~ In (j, r, Pending) (jobs (complete j ok s)).
Proof.
  intros j ok s r H. simpl in H. apply in_map_iff in H.
  destruct H as ([[j1 r1] s1] & E & _). unfold finish in E.
  destruct s1; try discriminate. destruct (j1 =? j) eqn:Q.
  - destruct ok; discriminate.
  - injection E as -> _. rewrite Nat.eqb_refl in Q. discriminate.
Qed.

(* ---------- Negative control: the job lives only in a volatile mailbox ---------- *)

(* The same service with the job sent as a volatile message instead of being
   staged in the transaction. The acceptance-durability statement is FALSE
   for it, with a four-step witness. A checker that also "proved" this design
   would be proving nothing. *)
Module VolatileMailbox.

  Record bsys := BSys {
    b_reports : list nat;   (* durable *)
    b_mailbox : list nat;   (* volatile job messages *)
    b_trace   : list nat }. (* accepted report ids *)

  Inductive bstep : bsys -> bsys -> Prop :=
  | BCommit : forall n x, bstep x (BSys (n :: b_reports x) (b_mailbox x) (b_trace x))
  | BSend : forall n x, In n (b_reports x) ->
      bstep x (BSys (b_reports x) (n :: b_mailbox x) (b_trace x))
  | BCrash : forall x, bstep x (BSys (b_reports x) [] (b_trace x))
  | BAccept : forall n x, In n (b_reports x) ->
      bstep x (BSys (b_reports x) (b_mailbox x) (n :: b_trace x)).

  Inductive breachable : bsys -> Prop :=
  | BInit : breachable (BSys [] [] [])
  | BStep : forall x y, breachable x -> bstep x y -> breachable y.

  (* commit report; send message; worker process terminates; return Accepted *)
  Theorem accepted_job_lost : exists x,
    breachable x /\ In 0 (b_trace x) /\ In 0 (b_reports x) /\ ~ In 0 (b_mailbox x).
  Proof.
    exists (BSys [0] [] [0]). split; [|simpl; tauto].
    eapply BStep; [eapply BStep; [eapply BStep; [eapply BStep; [apply BInit|]|]|]|].
    - apply (BCommit 0).
    - apply (BSend 0). simpl. auto.
    - apply BCrash.
    - apply (BAccept 0). simpl. auto.
  Qed.

End VolatileMailbox.

Print Assumptions acceptance_durable.
Print Assumptions retry_safe.
Print Assumptions tenant_frame.
