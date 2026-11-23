// Profile fenrir-aarch64-checked-expr/1: artifact projection, compiler,
// encoder and proof-instance generator. The compiler and encoder mirror
// verification/aarch64/Compile.v (comp, compile_fn) and Encode.v (encode,
// image_of) definition for definition; every emitted image is re-derived
// inside Rocq by the generated instance (image_identity, by vm_compute), so a
// divergence between this file and the proved compiler fails the proof.
// The projection from artifact JSON to the Rocq AST is NOT verified (ARM-02).
import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode as canonical} from '../tc0/canonical.mjs';

export const EXPR_PROFILE = 'fenrir-aarch64-checked-expr/1';
export const RESULT_ABI = 'fenrir-aarch64-result-abi/1';
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export class UnsupportedExprProfile extends Error {}
const reject = m => { throw new UnsupportedExprProfile(m); };
const LO = -(1n << 63n), HI = (1n << 63n) - 1n, M64 = 1n << 64n;

// ---------- projection: artifact -> Expr.v AST (unverified) ----------
const BINOPS = {add: 'OAdd', sub: 'OSub', mul: 'OMul', div: 'ODiv'};
const CMPOPS = {lt: 'CLt', le: 'CLe', gt: 'CGt', ge: 'CGe', eq: 'CEq'};

// A call-free expression; scope: binding IDs, innermost first; a variable is
// its index (de Bruijn).
export function projectExpr(e, scope) {
  const project = projectExpr;
  const [tag] = e;
  if (tag === 'int') return {k: 'int', n: BigInt(e[2])};
  if (tag === 'bool') return {k: 'bool', b: e[2]};
  if (tag === 'var') { const i = scope.indexOf(e[2]); if (i < 0) reject('Unbound variable'); return {k: 'var', i}; }
  if (tag === 'let') return {k: 'let', init: project(e[3], scope), body: project(e[4], [e[2], ...scope])};
  if (tag === 'if') return {k: 'if', c: project(e[2], scope), t: project(e[3], scope), f: project(e[4], scope)};
  if (tag === 'prim') {
    const op = e[2], args = e.slice(3).map(x => project(x, scope));
    if (op === 'neg') return {k: 'neg', origin: e[1], a: args[0]};
    if (op === 'not') return {k: 'not', a: args[0]};
    if (op in BINOPS) return {k: 'bin', origin: e[1], op, a: args[0], b: args[1]};
    if (op in CMPOPS) return {k: 'cmp', op, a: args[0], b: args[1]};
    reject(`Unsupported primitive ${op}`);
  }
  reject(`Unsupported expression ${tag}`);
}

export function projectArtifact(bytes) {
  const {artifact: a} = validatePureCallArtifact(bytes, ['int', '0']);
  if (a.functions.length !== 1 || a.datatypes.length || a.effects.length) reject('One function, no declarations');
  const f = a.functions[0];
  if (f.name !== a.entry || f.argument_type !== 'I64' || !['I64', 'Bool'].includes(f.result_type) || f.effects.length)
    reject('Pure I64 -> I64/Bool entry required');
  return {artifact: a, source: projectExpr(f.body, [f.parameter_id]), resultType: f.result_type};
}

// ---------- instructions, as in Machine.v ----------
const I = {
  addSubImm: (sub, sf, rd, rn, imm) => ({op: 'AddSubImm', sub, sf, rd, rn, imm}),
  addSubReg: (sub, sf, rd, rn, rm, sh, amt) => ({op: 'AddSubReg', sub, sf, rd, rn, rm, sh, amt}),
  madd: (rd, rn, rm, ra) => ({op: 'Madd', rd, rn, rm, ra}),
  smulh: (rd, rn, rm) => ({op: 'Smulh', rd, rn, rm}),
  sdiv: (rd, rn, rm) => ({op: 'Sdiv', rd, rn, rm}),
  csinc: (rd, rn, rm, c) => ({op: 'Csinc', rd, rn, rm, c}),
  movz: (rd, imm, hw) => ({op: 'Movz', rd, imm, hw}),
  movk: (rd, imm, hw) => ({op: 'Movk', rd, imm, hw}),
  strPre: (rt, imm) => ({op: 'StrPre', rt, imm}),
  ldrPost: (rt, imm) => ({op: 'LdrPost', rt, imm}),
  ldrUoff: (rt, imm) => ({op: 'LdrUoff', rt, imm}),
  bcond: (c, imm) => ({op: 'Bcond', c, imm}),
  b: imm => ({op: 'Bimm', imm}),
  bl: imm => ({op: 'Bl', imm}),
  cbz: (nz, rt, imm) => ({op: 'Cbz', nz, rt, imm}),
  ret: rn => ({op: 'Ret', rn}),
};
const EQ = 0, NE = 1, VC = 7, GE = 10, LT = 11, GT = 12, LE = 13;
const CSET_INV = {lt: GE, le: GT, gt: LE, ge: LT, eq: NE};

// ---------- compiler: Compile.v comp / compile_fn ----------
const push0 = I.strPre(0, -16), pop1 = I.ldrPost(1, 16);
const trapSeq = (c, origin) => [I.addSubImm(false, false, 31, 9, 0), I.movz(1, c, 0), {...I.ret(30), origin}];
const half = (n, k) => Number(((((n % M64) + M64) % M64) >> BigInt(16 * k)) & 0xffffn);
const loadImm = n => [I.movz(0, half(n, 0), 0), I.movk(0, half(n, 1), 1), I.movk(0, half(n, 2), 2), I.movk(0, half(n, 3), 3)];
function binopCode(op, origin) {
  if (op === 'add') return [I.addSubReg(false, true, 0, 1, 0, 'LSL', 0), I.bcond(VC, 4), ...trapSeq(1, origin)];
  if (op === 'sub') return [I.addSubReg(true, true, 0, 1, 0, 'LSL', 0), I.bcond(VC, 4), ...trapSeq(1, origin)];
  if (op === 'mul') return [I.smulh(3, 1, 0), I.madd(0, 1, 0, 31), I.addSubReg(true, true, 31, 3, 0, 'ASR', 63), I.bcond(EQ, 4), ...trapSeq(1, origin)];
  return [I.cbz(true, 0, 4), ...trapSeq(2, origin), I.addSubImm(false, true, 31, 0, 1), I.bcond(NE, 6),
    I.addSubReg(true, true, 31, 31, 1, 'LSL', 0), I.bcond(VC, 4), ...trapSeq(1, origin), I.sdiv(0, 1, 0)];
}
export {I, trapSeq, push0, pop1};
export function comp(ctx, d, e) {
  switch (e.k) {
    case 'int': return loadImm(e.n);
    case 'bool': return [I.movz(0, e.b ? 1 : 0, 0)];
    case 'var': { if (e.i >= ctx.length) return []; return [I.ldrUoff(0, 2 * (d - 1 - ctx[e.i]))]; }
    case 'neg': return [...comp(ctx, d, e.a), I.addSubReg(true, true, 0, 31, 0, 'LSL', 0), I.bcond(VC, 4), ...trapSeq(1, e.origin)];
    case 'bin': return [...comp(ctx, d, e.a), push0, ...comp(ctx, d + 1, e.b), pop1, ...binopCode(e.op, e.origin)];
    case 'cmp': return [...comp(ctx, d, e.a), push0, ...comp(ctx, d + 1, e.b), pop1,
      I.addSubReg(true, true, 31, 1, 0, 'LSL', 0), I.csinc(0, 31, 31, CSET_INV[e.op])];
    case 'not': return [...comp(ctx, d, e.a), I.addSubImm(true, true, 31, 0, 0), I.csinc(0, 31, 31, NE)];
    case 'if': {
      const t = comp(ctx, d, e.t), f = comp(ctx, d, e.f);
      return [...comp(ctx, d, e.c), I.cbz(false, 0, t.length + 2), ...t, I.b(f.length + 1), ...f];
    }
    case 'let': return [...comp(ctx, d, e.init), push0, ...comp([d, ...ctx], d + 1, e.body), I.addSubImm(false, false, 31, 31, 16)];
  }
  throw new Error('Unknown node');
}
export const compileFn = e => [I.addSubImm(false, false, 9, 31, 0), push0, ...comp([0], 1, e),
  I.addSubImm(false, false, 31, 31, 16), I.movz(1, 0, 0), I.ret(30)];
export function depth(e) {
  switch (e.k) {
    case 'int': case 'bool': case 'var': return 0;
    case 'neg': case 'not': return depth(e.a);
    case 'bin': case 'cmp': return Math.max(depth(e.a), 1 + depth(e.b));
    case 'if': return Math.max(depth(e.c), depth(e.t), depth(e.f));
    case 'let': return Math.max(depth(e.init), 1 + depth(e.body));
  }
}

// ---------- encoder: Encode.v encode ----------
const mod = (v, m) => ((v % m) + m) % m;
const SHIFT = {LSL: 0, ASR: 2};
export function encodeInstr(i) {
  const r = i;
  switch (i.op) {
    case 'AddSubImm': return (i.sub ? (i.sf ? 0xF1000000 : 0xD1000000) : (i.sf ? 0xB1000000 : 0x91000000)) + i.imm * 1024 + i.rn * 32 + i.rd;
    case 'AddSubReg': return (i.sub ? (i.sf ? 0xEB000000 : 0xCB000000) : (i.sf ? 0xAB000000 : 0x8B000000)) + SHIFT[i.sh] * 4194304 + i.rm * 65536 + i.amt * 1024 + i.rn * 32 + i.rd;
    case 'Madd': return 0x9B000000 + i.rm * 65536 + i.ra * 1024 + i.rn * 32 + i.rd;
    case 'Smulh': return 0x9B407C00 + i.rm * 65536 + i.rn * 32 + i.rd;
    case 'Sdiv': return 0x9AC00C00 + i.rm * 65536 + i.rn * 32 + i.rd;
    case 'Csinc': return 0x9A800400 + i.rm * 65536 + i.c * 4096 + i.rn * 32 + i.rd;
    case 'Movz': return 0xD2800000 + i.hw * 2097152 + i.imm * 32 + i.rd;
    case 'Movk': return 0xF2800000 + i.hw * 2097152 + i.imm * 32 + i.rd;
    case 'StrPre': return 0xF8000FE0 + mod(i.imm, 512) * 4096 + i.rt;
    case 'LdrPost': return 0xF84007E0 + mod(i.imm, 512) * 4096 + i.rt;
    case 'LdrUoff': return 0xF94003E0 + i.imm * 1024 + i.rt;
    case 'Bcond': return 0x54000000 + mod(i.imm, 524288) * 32 + i.c;
    case 'Bimm': return 0x14000000 + mod(i.imm, 67108864);
    case 'Bl': return 0x94000000 + mod(i.imm, 67108864);
    case 'Cbz': return (i.nz ? 0xB5000000 : 0xB4000000) + mod(i.imm, 524288) * 32 + i.rt;
    case 'Ret': return 0xD65F0000 + i.rn * 32;
  }
  throw new Error(`Unknown instruction ${r.op}`);
}
// Encode.v encodable: rejects images whose fields do not fit.
export function encodable(i) {
  const r5 = r => r >= 0 && r <= 31, u = (v, n) => v >= 0 && v < 2 ** n, s = (v, n) => v >= -(2 ** (n - 1)) && v < 2 ** (n - 1);
  switch (i.op) {
    case 'AddSubImm': return r5(i.rd) && r5(i.rn) && u(i.imm, 12);
    case 'AddSubReg': return r5(i.rd) && r5(i.rn) && r5(i.rm) && u(i.amt, 6);
    case 'Madd': return [i.rd, i.rn, i.rm, i.ra].every(r5);
    case 'Smulh': case 'Sdiv': return [i.rd, i.rn, i.rm].every(r5);
    case 'Csinc': return [i.rd, i.rn, i.rm].every(r5) && u(i.c, 4);
    case 'Movz': case 'Movk': return r5(i.rd) && u(i.imm, 16) && u(i.hw, 2);
    case 'StrPre': case 'LdrPost': return r5(i.rt) && s(i.imm, 9);
    case 'LdrUoff': return r5(i.rt) && u(i.imm, 12);
    case 'Bcond': return u(i.c, 4) && s(i.imm, 19);
    case 'Bimm': case 'Bl': return s(i.imm, 26);
    case 'Cbz': return r5(i.rt) && s(i.imm, 19);
    case 'Ret': return r5(i.rn);
  }
}

// ---------- GNU assembler text, an independent path to the same bytes ----------
const COND = ['eq', 'ne', 'cs', 'cc', 'mi', 'pl', 'vs', 'vc', 'hi', 'ls', 'ge', 'lt', 'gt', 'le', 'al', 'nv'];
const x = r => r === 31 ? 'xzr' : `x${r}`;
const xs = r => r === 31 ? 'sp' : `x${r}`;
export function assembly(i) {
  switch (i.op) {
    case 'AddSubImm': return `${i.sub ? 'sub' : 'add'}${i.sf ? 's' : ''} ${i.sf ? x(i.rd) : xs(i.rd)}, ${xs(i.rn)}, #${i.imm}`;
    case 'AddSubReg': return `${i.sub ? 'sub' : 'add'}${i.sf ? 's' : ''} ${x(i.rd)}, ${x(i.rn)}, ${x(i.rm)}, ${i.sh.toLowerCase()} #${i.amt}`;
    case 'Madd': return `madd ${x(i.rd)}, ${x(i.rn)}, ${x(i.rm)}, ${x(i.ra)}`;
    case 'Smulh': return `smulh ${x(i.rd)}, ${x(i.rn)}, ${x(i.rm)}`;
    case 'Sdiv': return `sdiv ${x(i.rd)}, ${x(i.rn)}, ${x(i.rm)}`;
    case 'Csinc': return `csinc ${x(i.rd)}, ${x(i.rn)}, ${x(i.rm)}, ${COND[i.c]}`;
    case 'Movz': return `movz ${x(i.rd)}, #${i.imm}, lsl #${16 * i.hw}`;
    case 'Movk': return `movk ${x(i.rd)}, #${i.imm}, lsl #${16 * i.hw}`;
    case 'StrPre': return `str ${x(i.rt)}, [sp, #${i.imm}]!`;
    case 'LdrPost': return `ldr ${x(i.rt)}, [sp], #${i.imm}`;
    case 'LdrUoff': return `ldr ${x(i.rt)}, [sp, #${i.imm * 8}]`;
    case 'Bcond': return `b.${COND[i.c]} .+${i.imm * 4}`;
    case 'Bimm': return `b .+${i.imm * 4}`;
    case 'Bl': return `bl .+${i.imm * 4}`;
    case 'Cbz': return `${i.nz ? 'cbnz' : 'cbz'} ${x(i.rt)}, .+${i.imm * 4}`;
    case 'Ret': return `ret ${x(i.rn)}`;
  }
}

export function imageOf(code) {
  const binary = Buffer.alloc(code.length * 4);
  code.forEach((i, k) => binary.writeUInt32LE(encodeInstr(i), k * 4));
  return binary;
}

export function compileExprArtifact(bytes) {
  const {artifact, source, resultType} = projectArtifact(bytes);
  const code = compileFn(source);
  if (!code.every(encodable)) reject('An operand does not fit its encoding field');
  const binary = imageOf(code);
  const manifest = {profile: EXPR_PROFILE, result_abi: RESULT_ABI, artifact_sha256: sha256(canonical(artifact)),
    binary_sha256: sha256(binary), binary_bytes: binary.length, instructions: code.length, result_type: resultType,
    stack_slots: 1 + depth(source),
    scope: 'Function only; handwritten instruction model; no Sail/ARM correspondence proof',
    open_obligations: ['json-projection', 'authoritative-isa-refinement', 'loader-and-call-abi', 'native-runtime', 'process-lifecycle']};
  return {artifact, source, code, binary, manifest};
}

// ---------- Rocq rendering ----------
const zlit = n => (n < 0n ? `(${n})` : `${n}`);
export function rocqExpr(e) {
  switch (e.k) {
    case 'int': return `(EInt ${zlit(e.n)})`;
    case 'bool': return `(EBool ${e.b})`;
    case 'var': return `(EVar ${e.i})`;
    case 'neg': return `(ENeg ${rocqExpr(e.a)})`;
    case 'not': return `(ENot ${rocqExpr(e.a)})`;
    case 'bin': return `(EBin ${BINOPS[e.op]} ${rocqExpr(e.a)} ${rocqExpr(e.b)})`;
    case 'cmp': return `(ECmp ${CMPOPS[e.op]} ${rocqExpr(e.a)} ${rocqExpr(e.b)})`;
    case 'if': return `(EIf ${rocqExpr(e.c)} ${rocqExpr(e.t)} ${rocqExpr(e.f)})`;
    case 'let': return `(ELet ${rocqExpr(e.init)} ${rocqExpr(e.body)})`;
  }
}

// One exact-image theorem: these bytes decode to the proved compiler's output
// for this source, so compile_correct applies to them.
export function exprProofInstance(result) {
  const {source, binary, manifest} = result;
  const ty = manifest.result_type === 'Bool' ? 'TBool' : 'TInt';
  return `From Stdlib Require Import ZArith List Lia.
From FenrirARM Require Import Machine Encode Expr Compile.
Import ListNotations.
Open Scope Z_scope.
(* Profile ${manifest.profile}, result ABI ${manifest.result_abi}.
   Canonical artifact SHA256: ${manifest.artifact_sha256}
   Exact code SHA256: ${manifest.binary_sha256}
   The JSON -> source projection is not verified (ARM-02). *)
Definition source : expr := ${rocqExpr(source)}.
Definition image : list Z := [${[...binary].join(';')}].
Lemma source_typed : typeof [TInt] source = Some ${ty}.
Proof. vm_compute. reflexivity. Qed.
Lemma image_identity : image = image_of (compile_fn source).
Proof. vm_compute. reflexivity. Qed.
Lemma image_encodable : forallb encodable (compile_fn source) = true.
Proof. vm_compute. reflexivity. Qed.
Lemma image_decodes_to_compiler : decode_image image = Some (compile_fn source).
Proof. rewrite image_identity. apply image_decodes. exact image_encodable. Qed.
Theorem exact_image_correct : forall code x s,
  decode_image image = Some code -> lo <= x <= hi -> wf s -> pc s = 0 -> gpr s 0 = x ->
  sp s mod 16 = 0 -> lo <= sp s - 16 * (1 + depth source) ->
  exists r f, eval_main source x = Some r /\\ result_ty r ${ty} /\\
    (forall fuel, (length code <= fuel)%nat -> run fuel code s = Some f) /\\
    returns s f /\\ observed r f.
Proof.
  intros code x s H. rewrite image_decodes_to_compiler in H. injection H as <-.
  apply compile_correct_typed. exact source_typed.
Qed.
Print Assumptions exact_image_correct.
`;
}

export function writeExprBuild(result, dir) {
  mkdirSync(dir, {recursive: true});
  writeFileSync(resolve(dir, 'code.bin'), result.binary);
  writeFileSync(resolve(dir, 'Instance.v'), exprProofInstance(result));
  writeFileSync(resolve(dir, 'manifest.json'), JSON.stringify(result.manifest, null, 2) + '\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.argv.length !== 4) throw new Error('Usage: node tools/aarch64/expr.mjs ARTIFACT OUTPUT_DIR');
  writeExprBuild(compileExprArtifact(readFileSync(process.argv[2])), process.argv[3]);
}
