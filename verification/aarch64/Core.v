From Coq Require Import ZArith List Bool Lia.
Import ListNotations.
Open Scope Z_scope.

(* A deliberately small, handwritten AArch64 instruction profile.
   ARM/Sail correspondence is an OPEN obligation, not an axiom here. *)
Definition lo : Z := -9223372036854775808.
Definition hi : Z := 9223372036854775807.
Definition modulus : Z := 18446744073709551616.
Definition fits (x : Z) : bool := (lo <=? x) && (x <=? hi).
Definition signed (x : Z) : Z := ((x - lo) mod modulus) + lo.
Inductive outcome := Ok (x : Z) | Overflow.
Definition checked x := if fits x then Ok x else Overflow.
Inductive operation := Add (k : Z) | Sub (k : Z) | Neg.
Definition mathematical op x :=
  match op with Add k => x + k | Sub k => x - k | Neg => -x end.
Definition admissible op :=
  match op with Add k | Sub k => 0 <= k <= 4095 | Neg => True end.
Fixpoint evaluate ops x :=
  match ops with
  | [] => Ok x
  | op :: rest => match checked (mathematical op x) with
                  | Ok y => evaluate rest y | Overflow => Overflow end
  end.

(* Source projection of the admitted unary TC0-A profile. IDs are irrelevant
   to values here; JSON decoding/projection is separately listed as trusted. *)
Inductive expr := Input | Apply (op : operation) (e : expr).
Fixpoint eval_expr e x :=
  match e with Input => Ok x | Apply op e =>
    match eval_expr e x with Ok y => checked (mathematical op y)
                           | Overflow => Overflow end end.
Fixpoint lower e := match e with Input => [] | Apply op e => lower e ++ [op] end.
Lemma evaluate_app : forall a b x,
 evaluate (a ++ b) x = match evaluate a x with Ok y => evaluate b y | Overflow => Overflow end.
Proof. induction a; intros; simpl; auto. destruct (checked (mathematical a x)); auto. Qed.
Theorem source_lowering : forall e x, evaluate (lower e) x = eval_expr e x.
Proof. induction e; intros; simpl; auto. rewrite evaluate_app, IHe.
 destruct (eval_expr e x); simpl; auto. destruct (checked (mathematical op x0)); reflexivity. Qed.

Inductive instruction := Arithmetic (op : operation) | Bvc | Status (n : Z) | Ret.
Definition word op := match op with
 | Add k => 2969567232 + 1024*k
 | Sub k => 4043309056 + 1024*k
 | Neg => 3942646752 end.
Definition decode w : option instruction :=
 if w =? 3942646752 then Some (Arithmetic Neg) else
 if w =? 1409286247 then Some Bvc else
 if w =? 3531604001 then Some (Status 1) else
 if w =? 3531603969 then Some (Status 0) else
 if w =? 3596551104 then Some Ret else
 if (2969567232 <=? w) && (w <=? 2973760512) && ((w-2969567232) mod 1024 =? 0)
 then Some (Arithmetic (Add ((w-2969567232)/1024))) else
 if (4043309056 <=? w) && (w <=? 4047502336) && ((w-4043309056) mod 1024 =? 0)
 then Some (Arithmetic (Sub ((w-4043309056)/1024))) else None.
Definition block op := [word op; 1409286247; 3531604001; 3596551104].
Fixpoint compile ops := match ops with
 | [] => [3531603969; 3596551104]
 | op :: rest => block op ++ compile rest end.
Lemma signed_fits : forall x, fits x = true -> signed x = x.
Proof. intros x H. unfold fits in H. apply andb_true_iff in H.
 destruct H as [H1 H2]. apply Z.leb_le in H1. apply Z.leb_le in H2.
 unfold signed. rewrite Z.mod_small; unfold lo, hi, modulus in *; lia. Qed.
Lemma fits_spec : forall x, fits x = true <-> lo <= x <= hi.
Proof. intros. unfold fits. rewrite andb_true_iff, !Z.leb_le. tauto. Qed.
Lemma signed_upper : forall x, hi < x <= modulus - 1 -> signed x = x - modulus.
Proof. intros x H. unfold signed.
 replace (x-lo) with ((x-lo-modulus) + 1*modulus) by ring.
 rewrite Z.mod_add by (unfold modulus; lia).
 rewrite Z.mod_small; unfold lo, hi, modulus in *; lia. Qed.
Lemma signed_lower : forall x, -modulus <= x < lo -> signed x = x + modulus.
Proof. intros x H. unfold signed.
 replace (x-lo) with ((x-lo+modulus) + (-1)*modulus) by ring.
 rewrite Z.mod_add by (unfold modulus; lia).
 rewrite Z.mod_small; unfold lo, hi, modulus in *; lia. Qed.
(* Sign-bit formula for the concrete instructions, independent of fits. *)
Definition vflag op x :=
 let r := signed (mathematical op x) in
 match op with
 | Add _ => (0 <=? x) && (r <? 0)
 | Sub _ => (x <? 0) && (0 <=? r)
 | Neg => (x <? 0) && (r <? 0)
 end.
Lemma flag_correct : forall op x, admissible op -> fits x = true ->
 vflag op x = negb (fits (mathematical op x)).
Proof.
 intros op x Hop Hx. apply fits_spec in Hx.
 destruct (fits (mathematical op x)) eqn:Hfit.
 - unfold vflag. rewrite signed_fits by exact Hfit.
   apply fits_spec in Hfit.
   destruct op; cbn [mathematical admissible] in *;
   repeat match goal with
   | |- context [Z.leb ?a ?b] => destruct (Z.leb_spec a b)
   | |- context [Z.ltb ?a ?b] => destruct (Z.ltb_spec a b)
   end; cbn; try reflexivity; unfold lo, hi in *; lia.
 - assert (Hout : mathematical op x < lo \/ hi < mathematical op x).
   { destruct (Z_lt_ge_dec (mathematical op x) lo) as [Hlow|Hlow].
     - left; lia.
     - destruct (Z_le_gt_dec (mathematical op x) hi) as [Hhigh|Hhigh].
       + assert (fits (mathematical op x) = true) by (apply fits_spec; lia). congruence.
       + right; lia. }
   unfold vflag. destruct op; cbn [mathematical admissible] in *;
   destruct Hout as [Hout|Hout];
   try (unfold lo, hi in *; lia);
   first [rewrite signed_lower by (unfold lo, hi, modulus in *; lia)
         |rewrite signed_upper by (unfold lo, hi, modulus in *; lia)];
   repeat match goal with
   | |- context [Z.leb ?a ?b] => destruct (Z.leb_spec a b)
   | |- context [Z.ltb ?a ?b] => destruct (Z.ltb_spec a b)
   end; cbn; try reflexivity; unfold lo, hi, modulus in *; lia.
Qed.

Record state := State { value : Z; overflow : bool; status : Z }.
Definition arithmetic op s :=
 let n := mathematical op (value s) in State (signed n) (vflag op (value s)) (status s).
(* PC represented by remaining suffix; B.VC +12 skips two following words.
   Return is a function boundary, not a Linux process exit. *)
Fixpoint run (fuel : nat) (code : list Z) (s : state) : option outcome :=
 match fuel with O => None | S fuel =>
 match code with [] => None | w :: rest =>
 match decode w with
 | None => None
 | Some (Arithmetic op) => run fuel rest (arithmetic op s)
 | Some Bvc => run fuel (if overflow s then rest else skipn 2 rest) s
 | Some (Status n) => run fuel rest (State (value s) (overflow s) n)
 | Some Ret => if status s =? 0 then Some (Ok (value s))
               else if status s =? 1 then Some Overflow else None
 end end end.

Lemma decode_word : forall op, admissible op -> decode (word op) = Some (Arithmetic op).
Proof.
 intros op H. destruct op as [k|k|]; [| |reflexivity];
 cbn [admissible] in H; unfold word, decode;
 repeat match goal with |- context [Z.eqb ?a ?b] =>
   let E := fresh in assert (E : (a =? b) = false) by (apply Z.eqb_neq; lia); rewrite E
 end;
 repeat match goal with |- context [Z.leb ?a ?b] =>
   first [let E := fresh in assert (E : (a <=? b) = true) by (apply Z.leb_le; lia); rewrite E
         |let E := fresh in assert (E : (a <=? b) = false) by (apply Z.leb_gt; lia); rewrite E]
 end;
 replace (2969567232 + 1024 * k - 2969567232) with (k * 1024) by ring;
 replace (4043309056 + 1024 * k - 4043309056) with (k * 1024) by ring;
 rewrite ?Z.mod_mul, ?Z.div_mul by lia; reflexivity.
Qed.

Theorem compiler_correct : forall ops,
 Forall admissible ops -> forall x v tag extra, fits x = true ->
 run (4 * length ops + 2 + extra)%nat (compile ops) (State x v tag) = Some (evaluate ops x).
Proof.
 intros ops H. induction H as [|op ops Hop Hops IH]; intros x v tag extra Hx.
 - reflexivity.
 - cbn [length compile block].
   replace (4 * S (length ops) + 2 + extra)%nat
     with (S (S (S (S (4 * length ops + 2 + extra)))))%nat by lia.
   unfold block. cbn [app]. cbn [run]. rewrite decode_word by exact Hop.
   replace (decode 1409286247) with (Some Bvc) by reflexivity.
   replace (decode 3531604001) with (Some (Status 1)) by reflexivity.
   replace (decode 3596551104) with (Some Ret) by reflexivity.
   unfold arithmetic. cbn [value overflow status].
   rewrite flag_correct by assumption.
   destruct (fits (mathematical op x)) eqn:Hfit.
   + change (run (S (S (4 * length ops + 2 + extra))) (compile ops)
       (State (signed (mathematical op x)) false tag) = Some (evaluate (op :: ops) x)).
     replace (S (S (4 * length ops + 2 + extra)))%nat
       with (4 * length ops + 2 + (2 + extra))%nat by lia.
     rewrite IH. 2: { rewrite signed_fits by exact Hfit. exact Hfit. }
     rewrite signed_fits by exact Hfit.
     cbn [evaluate]. unfold checked. rewrite Hfit. reflexivity.
   + cbn [negb overflow run decode status].
     cbn [evaluate]. unfold checked. rewrite Hfit. reflexivity.
Qed.
Theorem expression_binary_correct : forall e,
 Forall admissible (lower e) -> forall x v tag, fits x = true ->
 run (4 * length (lower e) + 2)%nat (compile (lower e)) (State x v tag) = Some (eval_expr e x).
Proof. intros. rewrite <- (Nat.add_0_r (4 * length (lower e) + 2)%nat).
 rewrite compiler_correct by assumption. rewrite source_lowering. reflexivity. Qed.

Fixpoint words_of_bytes (bs : list Z) : option (list Z) :=
 match bs with
 | [] => Some []
 | a :: b :: c :: d :: rest =>
   if forallb (fun n => (0 <=? n) && (n <=? 255)) [a;b;c;d] then
   match words_of_bytes rest with Some ws => Some (a+256*b+65536*c+16777216*d :: ws) | None => None end
   else None
 | _ => None end.
Print Assumptions expression_binary_correct.
