(* A64 encodings of the instructions in Machine.v, a handwritten decoder for
   them, and decode (encode i) = Some i for every in-range instruction.
   Field layouts are from the Arm ARM encoding diagrams (64-bit variants, sf=1);
   the GNU assembler cross-check in tools/aarch64/check.mjs tests them, and
   ARM-03 would replace them. *)
From Stdlib Require Import ZArith List Bool Lia.
From FenrirARM Require Core Machine.
Import ListNotations Machine.
Open Scope Z_scope.

Definition shift_code (sh : shift) : Z := match sh with LSL => 0 | ASR => 2 end.

Definition encode (i : instr) : Z :=
  match i with
  | AddSubImm sub sf rd rn imm =>
      (if sub then if sf then 0xF1000000 else 0xD1000000
       else if sf then 0xB1000000 else 0x91000000)
      + imm * 1024 + rn * 32 + rd
  | AddSubReg sub sf rd rn rm sh amt =>
      (if sub then if sf then 0xEB000000 else 0xCB000000
       else if sf then 0xAB000000 else 0x8B000000)
      + shift_code sh * 4194304 + rm * 65536 + amt * 1024 + rn * 32 + rd
  | Madd rd rn rm ra => 0x9B000000 + rm * 65536 + ra * 1024 + rn * 32 + rd
  | Smulh rd rn rm => 0x9B407C00 + rm * 65536 + rn * 32 + rd
  | Sdiv rd rn rm => 0x9AC00C00 + rm * 65536 + rn * 32 + rd
  | Csinc rd rn rm c => 0x9A800400 + rm * 65536 + c * 4096 + rn * 32 + rd
  | Movz rd imm hw => 0xD2800000 + hw * 2097152 + imm * 32 + rd
  | Movk rd imm hw => 0xF2800000 + hw * 2097152 + imm * 32 + rd
  | StrPre rt imm9 => 0xF8000FE0 + (imm9 mod 512) * 4096 + rt
  | LdrPost rt imm9 => 0xF84007E0 + (imm9 mod 512) * 4096 + rt
  | LdrUoff rt imm12 => 0xF94003E0 + imm12 * 1024 + rt
  | Bcond c imm19 => 0x54000000 + (imm19 mod 524288) * 32 + c
  | Bimm imm26 => 0x14000000 + imm26 mod 67108864
  | Cbz nz rt imm19 => (if nz then 0xB5000000 else 0xB4000000) + (imm19 mod 524288) * 32 + rt
  | Ret rn => 0xD65F0000 + rn * 32
  end.

(* Operand ranges of an encodable instruction. *)
Definition r5 (r : Z) : bool := (0 <=? r) && (r <=? 31).
Definition urange (v n : Z) : bool := (0 <=? v) && (v <? 2 ^ n).
Definition srange (v n : Z) : bool := (- 2 ^ (n - 1) <=? v) && (v <? 2 ^ (n - 1)).
Definition encodable (i : instr) : bool :=
  match i with
  | AddSubImm _ _ rd rn imm => r5 rd && r5 rn && urange imm 12
  | AddSubReg _ _ rd rn rm _ amt => r5 rd && r5 rn && r5 rm && urange amt 6
  | Madd rd rn rm ra => r5 rd && r5 rn && r5 rm && r5 ra
  | Smulh rd rn rm | Sdiv rd rn rm => r5 rd && r5 rn && r5 rm
  | Csinc rd rn rm c => r5 rd && r5 rn && r5 rm && urange c 4
  | Movz rd imm hw | Movk rd imm hw => r5 rd && urange imm 16 && urange hw 2
  | StrPre rt imm9 | LdrPost rt imm9 => r5 rt && srange imm9 9
  | LdrUoff rt imm12 => r5 rt && urange imm12 12
  | Bcond c imm19 => urange c 4 && srange imm19 19
  | Bimm imm26 => srange imm26 26
  | Cbz _ rt imm19 => r5 rt && srange imm19 19
  | Ret rn => r5 rn
  end.

Definition field (w p n : Z) : Z := (w / 2 ^ p) mod 2 ^ n.
Definition sext (n v : Z) : Z := if v <? 2 ^ (n - 1) then v else v - 2 ^ n.

Definition decode (w : Z) : option instr :=
  if negb ((0 <=? w) && (w <? 4294967296)) then None else
  let top := field w 24 8 in
  let rd := field w 0 5 in
  let rn := field w 5 5 in
  let rm := field w 16 5 in
  if field w 26 6 =? 5 then Some (Bimm (sext 26 (field w 0 26))) else
  if (top =? 0x91) || (top =? 0xD1) || (top =? 0xB1) || (top =? 0xF1) then
    if field w 22 2 =? 0
    then Some (AddSubImm (field w 30 1 =? 1) (field w 29 1 =? 1) rd rn (field w 10 12))
    else None
  else if (top =? 0x8B) || (top =? 0xCB) || (top =? 0xAB) || (top =? 0xEB) then
    if field w 21 1 =? 0 then
      if field w 22 2 =? 0
      then Some (AddSubReg (field w 30 1 =? 1) (field w 29 1 =? 1) rd rn rm LSL (field w 10 6))
      else if field w 22 2 =? 2
      then Some (AddSubReg (field w 30 1 =? 1) (field w 29 1 =? 1) rd rn rm ASR (field w 10 6))
      else None
    else None
  else if top =? 0x9B then
    if (field w 21 3 =? 0) && (field w 15 1 =? 0) then Some (Madd rd rn rm (field w 10 5))
    else if (field w 21 3 =? 2) && (field w 10 6 =? 31) then Some (Smulh rd rn rm)
    else None
  else if top =? 0x9A then
    if (field w 21 3 =? 6) && (field w 10 6 =? 3) then Some (Sdiv rd rn rm)
    else if (field w 21 3 =? 4) && (field w 10 2 =? 1) then Some (Csinc rd rn rm (field w 12 4))
    else None
  else if (top =? 0xD2) || (top =? 0xF2) then
    if field w 23 1 =? 1 then
      if top =? 0xD2 then Some (Movz rd (field w 5 16) (field w 21 2))
      else Some (Movk rd (field w 5 16) (field w 21 2))
    else None
  else if top =? 0xF8 then
    if rn =? 31 then
      if (field w 21 3 =? 0) && (field w 10 2 =? 3) then Some (StrPre rd (sext 9 (field w 12 9)))
      else if (field w 21 3 =? 2) && (field w 10 2 =? 1) then Some (LdrPost rd (sext 9 (field w 12 9)))
      else None
    else None
  else if top =? 0xF9 then
    if (field w 22 2 =? 1) && (rn =? 31) then Some (LdrUoff rd (field w 10 12)) else None
  else if top =? 0x54 then
    if field w 4 1 =? 0 then Some (Bcond (field w 0 4) (sext 19 (field w 5 19))) else None
  else if (top =? 0xB4) || (top =? 0xB5) then
    Some (Cbz (top =? 0xB5) rd (sext 19 (field w 5 19)))
  else if (field w 10 22 =? 0x3597C0) && (rd =? 0) then Some (Ret rn)
  else None.

Lemma sext9 : forall v, -256 <= v < 256 -> sext 9 (v mod 512) = v.
Proof. intros. unfold sext. change (2 ^ (9 - 1)) with 256. change (2 ^ 9) with 512.
 destruct (Z.ltb_spec (v mod 512) 256); Z.div_mod_to_equations; lia. Qed.
Lemma sext19 : forall v, -262144 <= v < 262144 -> sext 19 (v mod 524288) = v.
Proof. intros. unfold sext. change (2 ^ (19 - 1)) with 262144. change (2 ^ 19) with 524288.
 destruct (Z.ltb_spec (v mod 524288) 262144); Z.div_mod_to_equations; lia. Qed.
Lemma sext26 : forall v, -33554432 <= v < 33554432 -> sext 26 (v mod 67108864) = v.
Proof. intros. unfold sext. change (2 ^ (26 - 1)) with 33554432. change (2 ^ 26) with 67108864.
 destruct (Z.ltb_spec (v mod 67108864) 33554432); Z.div_mod_to_equations; lia. Qed.

Ltac pow_consts_in H :=
  repeat match type of H with context [2 ^ ?k] =>
    let c := eval vm_compute in (2 ^ k) in change (2 ^ k) with c in H end.
Ltac pow_consts :=
  repeat match goal with |- context [2 ^ ?k] =>
    let c := eval vm_compute in (2 ^ k) in change (2 ^ k) with c end.
Ltac fsolve := unfold field; pow_consts; Z.div_mod_to_equations; lia.
Ltac base_of W := match W with ?A + _ => base_of A | _ => W end.
(* Replace one field of a symbolic encoding by the operand it holds or the
   constant opcode bits it covers.  The candidate is chosen syntactically, so
   lia is only asked to prove (never to refute) an equation. *)
Ltac solve_field W p n :=
  let m := eval vm_compute in (2 ^ p) in
  lazymatch p with
  | 0 =>
      lazymatch W with
      | _ + (_ * _) => let K := base_of W in let c := eval vm_compute in (field K p n) in
                       replace (field W p n) with c by fsolve
      | _ + ?X => replace (field W p n) with X by fsolve
      end
  | _ =>
      first
        [ match W with context [?X * m] => replace (field W p n) with X by fsolve end
        | let K := base_of W in let c := eval vm_compute in (field K p n) in
          replace (field W p n) with c by fsolve ]
  end.
(* Work on the guard of the outermost conditional only, so fields of
   branches that are never taken are never examined. *)
Ltac is_pos p := lazymatch p with xH => idtac | xO ?q => is_pos q | xI ?q => is_pos q end.
Ltac closed z := lazymatch z with Z0 => idtac | Zpos ?p => is_pos p | Zneg ?p => is_pos p end.
Ltac eqb_consts :=
  repeat match goal with |- context [Z.eqb ?a ?b] =>
    closed a; closed b;
    let x := eval vm_compute in (Z.eqb a b) in
    lazymatch x with
    | true => change (Z.eqb a b) with true
    | false => change (Z.eqb a b) with false
    end
  end.
Ltac head_step :=
  lazymatch goal with |- ?L = _ =>
    lazymatch L with
    | (if ?c then _ else _) =>
        first
          [ progress (eqb_consts; cbv beta iota zeta delta [negb andb orb])
          | lazymatch c with context [field ?W ?p ?n] => solve_field W p n end ]
    | Some _ => lazymatch L with context [field ?W ?p ?n] => solve_field W p n end
    end
  end.

(* cbn is avoided: on the unfolded decoder it does not terminate in
   reasonable time.  Only the outermost guard is ever reduced. *)
Ltac decode_tac :=
  unfold decode;
  match goal with |- context [0 <=? ?W] =>
    replace (0 <=? W) with true by (symmetry; apply Z.leb_le; pow_consts; Z.div_mod_to_equations; lia);
    replace (W <? 4294967296) with true by (symmetry; apply Z.ltb_lt; pow_consts; Z.div_mod_to_equations; lia)
  end;
  cbv beta iota zeta delta [negb andb orb]; repeat head_step;
  cbv beta iota delta [Z.eqb Pos.eqb];
  rewrite ?sext9, ?sext19, ?sext26 by lia; reflexivity.

Lemma decode_encode : forall i, encodable i = true -> decode (encode i) = Some i.
Proof.
  intros i H. destruct i; unfold encodable, r5, urange, srange in H;
  repeat rewrite andb_true_iff in H; repeat rewrite Z.leb_le in H; repeat rewrite Z.ltb_lt in H;
  pow_consts_in H;
  repeat match goal with b : bool |- _ => destruct b end;
  try (destruct sh); cbn [encode shift_code]; decode_tac.
Qed.

Lemma encode_range : forall i, encodable i = true -> 0 <= encode i < 4294967296.
Proof.
  intros i H. destruct i; unfold encodable, r5, urange, srange in H;
  repeat rewrite andb_true_iff in H; repeat rewrite Z.leb_le in H; repeat rewrite Z.ltb_lt in H;
  pow_consts_in H;
  repeat match goal with b : bool |- _ => destruct b end;
  try (destruct sh); cbn [encode shift_code]; Z.div_mod_to_equations; lia.
Qed.

Fixpoint decode_all (ws : list Z) : option (list instr) :=
  match ws with
  | [] => Some []
  | w :: rest => match decode w, decode_all rest with
                 | Some i, Some l => Some (i :: l)
                 | _, _ => None
                 end
  end.

Lemma decode_all_encode : forall l, forallb encodable l = true -> decode_all (map encode l) = Some l.
Proof.
  induction l as [|i l IH]; intros H; cbn in H |- *; auto.
  apply andb_true_iff in H as [Hi His]. rewrite decode_encode, IH by assumption. reflexivity.
Qed.

(* Little-endian byte image, as emitted by tools/aarch64/compile.mjs. *)
Definition le_bytes (w : Z) : list Z :=
  [w mod 256; (w / 256) mod 256; (w / 65536) mod 256; (w / 16777216) mod 256].
Definition image_of (l : list instr) : list Z := flat_map (fun i => le_bytes (encode i)) l.

Lemma words_cons : forall a b c d rest, 0 <= a <= 255 -> 0 <= b <= 255 -> 0 <= c <= 255 -> 0 <= d <= 255 ->
  Core.words_of_bytes (a :: b :: c :: d :: rest) =
  match Core.words_of_bytes rest with Some ws => Some (a + 256 * b + 65536 * c + 16777216 * d :: ws) | None => None end.
Proof.
  intros. cbn [Core.words_of_bytes forallb].
  repeat match goal with |- context [?x <=? ?y] => replace (x <=? y) with true by (symmetry; apply Z.leb_le; lia) end.
  reflexivity.
Qed.

Lemma words_of_image : forall l, forallb encodable l = true ->
  Core.words_of_bytes (image_of l) = Some (map encode l).
Proof.
  induction l as [|i l IH]; intros H; [reflexivity|].
  cbn [forallb] in H. apply andb_true_iff in H as [Hi His]. pose proof (encode_range i Hi) as R.
  change (image_of (i :: l)) with (le_bytes (encode i) ++ image_of l).
  unfold le_bytes at 1. cbn [app].
  rewrite words_cons by (Z.div_mod_to_equations; lia).
  rewrite IH by exact His. cbn [map]. f_equal. f_equal.
  Z.div_mod_to_equations; lia.
Qed.

(* Exact bytes decode, through the handwritten decoder, to the program. *)
Definition decode_image (bytes : list Z) : option (list instr) :=
  match Core.words_of_bytes bytes with Some ws => decode_all ws | None => None end.
Theorem image_decodes : forall l, forallb encodable l = true -> decode_image (image_of l) = Some l.
Proof. intros. unfold decode_image. rewrite words_of_image by assumption. apply decode_all_encode. assumption. Qed.
