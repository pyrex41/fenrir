// Profile fenrir-aarch64-checked-call/1: projection of multi-function
// pure-call artifacts to CallCompile.v statements, a compiler and layout
// mirroring CallCompile.v (cstmt, fprologue, fstarts, compile_prog), and the
// per-image proof instance. Every image is re-derived inside Rocq
// (image_identity, vm_compute), so a divergence from the proved compiler
// fails the proof. The projection is NOT verified (ARM-02).
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode as canonical} from '../tc0/canonical.mjs';
import {projectExpr, rocqExpr, comp, depth, encodable, imageOf, sha256, I, push0, UnsupportedExprProfile} from './expr.mjs';

export const CALL_PROFILE = 'fenrir-aarch64-checked-call/1';
export const CALL_ABI = 'fenrir-aarch64-call-abi/1';
const reject = m => { throw new UnsupportedExprProfile(m); };
const hasCall = e => Array.isArray(e) && (e[0] === 'call' || e.some(hasCall));

// ---------- projection: artifact -> CallCompile.v statements (unverified) ----------
export function projectProgram(bytes) {
  const {artifact: a} = validatePureCallArtifact(bytes, ['int', '0'], {maxNodes: 2000});
  if (a.datatypes.length || a.effects.length) reject('No declarations');
  const index = new Map(a.functions.map((f, i) => [f.name, i]));
  for (const f of a.functions) {
    if (!['I64', 'Bool'].includes(f.argument_type) || !['I64', 'Bool'].includes(f.result_type) || f.effects.length)
      reject('First-order pure I64/Bool functions only');
  }
  const entry = a.functions[index.get(a.entry)];
  if (entry.argument_type !== 'I64') reject('The entry takes an I64');
  const callee = name => { if (!index.has(name)) reject('Unknown function'); return index.get(name); };
  const expr = (e, scope) => { if (hasCall(e)) reject('A call is only allowed as a let initializer or in tail position'); return projectExpr(e, scope); };
  function stmt(e, scope) {
    if (!hasCall(e)) return {k: 'ret', e: projectExpr(e, scope)};
    const [tag] = e;
    if (tag === 'call') return {k: 'tail', g: callee(e[2]), a: expr(e[3], scope)};
    if (tag === 'let') {
      const init = e[3];
      if (Array.isArray(init) && init[0] === 'call')
        return {k: 'call', g: callee(init[2]), a: expr(init[3], scope), body: stmt(e[4], [e[2], ...scope])};
      return {k: 'let', e: expr(init, scope), body: stmt(e[4], [e[2], ...scope])};
    }
    if (tag === 'if') return {k: 'if', c: expr(e[2], scope), t: stmt(e[3], scope), f: stmt(e[4], scope)};
    reject('A call is only allowed as a let initializer or in tail position');
  }
  const fns = a.functions.map(f => stmt(f.body, [f.parameter_id]));
  return {artifact: a, fns, main: index.get(a.entry), resultType: entry.result_type};
}

// ---------- compiler: CallCompile.v ----------
export function cstmt(fs, p, ctx, d, st) {
  if (st.k === 'ret') return [...comp(ctx, d, st.e), I.addSubImm(false, false, 31, 9, 0), I.movz(1, 0, 0), I.ret(30)];
  if (st.k === 'let') { const c = comp(ctx, d, st.e); return [...c, push0, ...cstmt(fs, p + c.length + 1, [d, ...ctx], d + 1, st.body)]; }
  if (st.k === 'if') {
    const c = comp(ctx, d, st.c), lt = slen(ctx, d, st.t);
    return [...c, I.cbz(false, 0, lt + 1), ...cstmt(fs, p + c.length + 1, ctx, d, st.t), ...cstmt(fs, p + c.length + 1 + lt, ctx, d, st.f)];
  }
  const c = comp(ctx, d, st.a), la = c.length;
  if (st.k === 'call') return [...c, I.bl(fs[st.g] - (p + la)), I.addSubImm(false, false, 9, 31, 16 * d), I.ldrUoff(30, 2 * (d - 2)),
    I.cbz(false, 1, 3), I.addSubImm(false, false, 31, 9, 0), I.ret(30), push0, ...cstmt(fs, p + la + 7, [d, ...ctx], d + 1, st.body)];
  return [...c, I.addSubImm(false, false, 31, 9, 0), I.b(fs[st.g] - (p + la + 1))];
}
export const slen = (ctx, d, st) => cstmt([], 0, ctx, d, st).length;
const fprologue = [I.addSubImm(false, false, 9, 31, 0), push0, I.strPre(30, -16)];
export const flen = b => 3 + slen([0], 2, b);
export function fstarts(fns) { const out = []; let base = 0; for (const b of fns) { out.push(base); base += flen(b); } return out; }
export function compileProg(fns) { const fs = fstarts(fns); return fns.flatMap((b, i) => [...fprologue, ...cstmt(fs, fs[i] + 3, [0], 2, b)]); }
export const tailOnly = st => st.k === 'call' ? false : st.k === 'let' ? tailOnly(st.body) : st.k === 'if' ? tailOnly(st.t) && tailOnly(st.f) : true;
export function frameNeed(d, st) {
  if (st.k === 'ret') return d + depth(st.e);
  if (st.k === 'let') return Math.max(d + depth(st.e), frameNeed(d + 1, st.body));
  if (st.k === 'if') return Math.max(d + depth(st.c), frameNeed(d, st.t), frameNeed(d, st.f));
  if (st.k === 'call') return Math.max(d + depth(st.a), frameNeed(d + 1, st.body));
  return d + depth(st.a);
}

export function compileCallArtifact(bytes) {
  const {artifact, fns, main, resultType} = projectProgram(bytes);
  const code = compileProg(fns);
  if (!code.every(encodable)) reject('An operand does not fit its encoding field');
  const binary = imageOf(code), starts = fstarts(fns);
  const manifest = {profile: CALL_PROFILE, abi: CALL_ABI, artifact_sha256: sha256(canonical(artifact)), binary_sha256: sha256(binary),
    binary_bytes: binary.length, instructions: code.length, functions: fns.length, entry_offset: 4 * starts[main],
    result_type: resultType, tail_only: fns.every(tailOnly), table_need: Math.max(0, ...fns.map(b => frameNeed(2, b))),
    scope: 'Function table only; handwritten instruction model; no Sail/ARM correspondence proof',
    open_obligations: ['json-projection', 'authoritative-isa-refinement', 'loader-and-call-abi', 'native-runtime', 'process-lifecycle', 'stack-overflow']};
  return {artifact, fns, main, code, binary, manifest};
}

// ---------- Rocq rendering ----------
export function rocqStmt(st) {
  if (st.k === 'ret') return `(SRet ${rocqExpr(st.e)})`;
  if (st.k === 'let') return `(SLet ${rocqExpr(st.e)} ${rocqStmt(st.body)})`;
  if (st.k === 'if') return `(SIf ${rocqExpr(st.c)} ${rocqStmt(st.t)} ${rocqStmt(st.f)})`;
  if (st.k === 'call') return `(SCall ${st.g}%nat ${rocqExpr(st.a)} ${rocqStmt(st.body)})`;
  return `(STail ${st.g}%nat ${rocqExpr(st.a)})`;
}
export const rocqProgram = fns => `[${fns.map(rocqStmt).join('; ')}]`;

export function callProofInstance(result) {
  const {fns, main, binary, manifest} = result;
  const tail = manifest.tail_only ? `
Lemma prog_tail_only : forallb tail_only prog = true.
Proof. vm_compute. reflexivity. Qed.
(* Any iteration count: the stack bound does not depend on fuel. *)
Theorem exact_image_tail_correct : forall code fuel x s r n exit,
  decode_image image = Some code -> fcall fuel prog main (VInt x) = Some (r, n) ->
  wf s -> pc s = 4 * nth main (fstarts prog) 0 -> gpr s 0 = x -> sp s mod 16 = 0 -> gpr s 30 = exit ->
  (exit < 0 \\/ 4 * Z.of_nat (length code) <= exit) -> lo <= sp s - 16 * table_need prog ->
  exists k f, (forall fuel', (k <= fuel')%nat -> run_c fuel' code exit s = Some f) /\\
    pc f = exit /\\ sp f = sp s /\\ gpr f 30 = exit /\\ keepsx s f /\\ mem_above s f /\\ observed r f.
Proof.
  intros code fuel x s r n exit H. rewrite image_decodes_to_compiler in H. injection H as <-.
  apply (tail_program_correct prog size_ok prog_tail_only).
Qed.
Print Assumptions exact_image_tail_correct.
` : '';
  return `From Stdlib Require Import ZArith List Lia.
From FenrirARM Require Import Machine Encode Expr Compile CallCompile.
Import ListNotations.
Open Scope Z_scope.
(* Profile ${manifest.profile}, calling convention ${manifest.abi}.
   Canonical artifact SHA256: ${manifest.artifact_sha256}
   Exact code SHA256: ${manifest.binary_sha256}
   The JSON -> statement projection is not verified (ARM-02). *)
Definition prog : list stmt := ${rocqProgram(fns)}.
Definition main : nat := ${main}%nat.
Definition image : list Z := [${[...binary].join(';')}].
Lemma image_identity : image = image_of (compile_prog prog).
Proof. vm_compute. reflexivity. Qed.
Lemma image_encodable : forallb encodable (compile_prog prog) = true.
Proof. vm_compute. reflexivity. Qed.
Lemma image_decodes_to_compiler : decode_image image = Some (compile_prog prog).
Proof. rewrite image_identity. apply image_decodes. exact image_encodable. Qed.
Lemma size_ok : 4 * Z.of_nat (length (compile_prog prog)) <= hi.
Proof. apply Z.leb_le. vm_compute. reflexivity. Qed.
Theorem exact_image_correct : forall code fuel x s r n exit,
  decode_image image = Some code -> fcall fuel prog main (VInt x) = Some (r, n) ->
  wf s -> pc s = 4 * nth main (fstarts prog) 0 -> gpr s 0 = x -> sp s mod 16 = 0 -> gpr s 30 = exit ->
  (exit < 0 \\/ 4 * Z.of_nat (length code) <= exit) -> lo <= sp s - 16 * n ->
  exists k f, (forall fuel', (k <= fuel')%nat -> run_c fuel' code exit s = Some f) /\\
    pc f = exit /\\ sp f = sp s /\\ gpr f 30 = exit /\\ keepsx s f /\\ mem_above s f /\\ observed r f.
Proof.
  intros code fuel x s r n exit H. rewrite image_decodes_to_compiler in H. injection H as <-.
  apply (call_correct prog size_ok).
Qed.
Print Assumptions exact_image_correct.
${tail}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const r = compileCallArtifact(readFileSync(process.argv[2]));
  console.log(JSON.stringify(r.manifest, null, 2));
}
