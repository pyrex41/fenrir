// Development check for profile fenrir-aarch64-checked-expr/1. NOT a
// qualification receipt. In a fresh directory it:
//  1. compiles the Rocq development (Core, Expr, Machine, Flags, Encode,
//     Compile) and keeps the Print Assumptions output;
//  2. for every hand and generated program: compiles the artifact, proves the
//     exact-image theorem for its bytes, assembles the same instructions from
//     mnemonics with GNU as and requires identical bytes, and runs the bytes
//     under qemu-aarch64 on every boundary input against the JavaScript
//     candidate (runtime/tc0/pure-call-machine.mjs);
//  3. alters single instructions of chosen images and requires that each
//     altered image fails its exact-image proof AND diverges under QEMU;
//  4. replays every compiled module with rocqchk.
// Usage: node tools/aarch64/check-expr.mjs [OUTPUT_DIR]
import {readFileSync, writeFileSync, mkdirSync, copyFileSync} from 'node:fs';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
import {encode} from '../tc0/canonical.mjs';
import {VALUES} from '../tc0/check-i64.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {compileExprArtifact, exprProofInstance, assembly, encodeInstr, imageOf, sha256, EXPR_PROFILE, RESULT_ABI} from './expr.mjs';
import {cases} from './expr-fixtures.mjs';
import {run, versions} from './toolchain.mjs';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.argv[2] || resolve(root, 'build/aarch64', `expr-${Date.now()}-${process.pid}`));
mkdirSync(out, {recursive: true});
const flags = ['-Q', out, 'FenrirARM'];
const MODULES = ['Core', 'Expr', 'Machine', 'Flags', 'Encode', 'Compile'];
const audit = [];
function prove(file, ok = true) {
  const r = run('coqc', [...flags, file], {cwd: out, ok, timeout: 600000});
  if (ok) audit.push({file, output: r.stdout.toString()});
  return r;
}
for (const m of MODULES) { copyFileSync(resolve(root, 'verification/aarch64', `${m}.v`), resolve(out, `${m}.v`)); prove(`${m}.v`); }
const core = audit.find(a => a.file === 'Compile.v').output;
assert.equal((core.match(/Closed under the global context/g) || []).length, 2, 'compile_correct and compile_correct_typed must be closed');

const inputs = [...VALUES, 5n, -7n, 1000n];
function native(binary, dir, resultType) {
  writeFileSync(resolve(dir, 'code.bin'), binary);
  const asm = `.global _start
.text
_start:
 adr x19, inputs
 mov x20, #${inputs.length}
 adr x21, outputs
loop:
 ldr x0, [x19], #8
 mov x22, sp
 bl target
 mov x23, sp
 cmp x22, x23
 b.ne failed
 stp x0, x1, [x21], #16
 subs x20, x20, #1
 b.ne loop
 mov x0, #1
 adr x1, outputs
 mov x2, #${inputs.length * 16}
 mov x8, #64
 svc #0
 cmp x0, #${inputs.length * 16}
 b.ne failed
 mov x0, #0
 b exit
failed:
 mov x0, #1
exit:
 mov x8, #93
 svc #0
.balign 4
target:
.incbin "code.bin"
.data
.balign 8
inputs:
${inputs.map(x => ` .quad ${x}`).join('\n')}
.bss
.balign 16
outputs: .skip ${inputs.length * 16}
`;
  writeFileSync(resolve(dir, 'runner.s'), asm);
  run('as', ['-o', 'runner.o', 'runner.s'], {cwd: dir});
  run('ld', ['-o', 'runner', 'runner.o'], {cwd: dir});
  const r = run('qemu', ['./runner'], {cwd: dir, ok: false, timeout: 60000});
  if (r.status !== 0 || r.stdout.length !== inputs.length * 16) return null;
  return inputs.map((_, i) => {
    const v = r.stdout.readBigInt64LE(i * 16), tag = r.stdout.readBigUInt64LE(i * 16 + 8);
    if (tag === 0n) return resultType === 'Bool' ? (v === 0n || v === 1n ? ['Ok', ['bool', v === 1n]] : ['InvalidBool', String(v)]) : ['Ok', ['int', String(v)]];
    if (tag === 1n) return ['Trap', 'Overflow'];
    if (tag === 2n) return ['Trap', 'DivZero'];
    return ['InvalidStatus', String(tag)];
  });
}
const expectedOf = artifact => inputs.map(x => {
  const r = new PureCallMachine(artifact, ['int', String(x)]).run(100000);
  assert.equal(r.execution, 'Completed'); return r.outcome;
});

const receipts = [], outcomes = {};
let nativeCases = 0, gnuChecked = 0;
const compiled = new Map();
for (const [k, c] of cases().entries()) {
  const dir = resolve(out, `case${k}`); mkdirSync(dir);
  const result = compileExprArtifact(encode(c.artifact)); compiled.set(c.name, result);
  writeFileSync(resolve(dir, 'artifact.json'), encode(c.artifact));
  const module = `ExprCase${k}`;
  writeFileSync(resolve(out, `${module}.v`), exprProofInstance(result));
  const pr = prove(`${module}.v`);
  assert.match(pr.stdout.toString(), /Closed under the global context/, `${c.name}: exact-image theorem not closed`);
  writeFileSync(resolve(dir, 'reference.s'), result.code.map(assembly).join('\n') + '\n');
  run('as', ['-o', 'reference.o', 'reference.s'], {cwd: dir});
  run('objcopy', ['-O', 'binary', '-j', '.text', 'reference.o', 'reference.bin'], {cwd: dir});
  assert.deepEqual(readFileSync(resolve(dir, 'reference.bin')), result.binary, `${c.name}: GNU as disagrees with the encoder`);
  gnuChecked++;
  const observed = native(result.binary, dir, result.manifest.result_type);
  const expected = expectedOf(result.artifact);
  assert.deepEqual(observed, expected, `${c.name}: QEMU disagrees with the candidate`);
  for (const o of expected) { const key = o[0] === 'Ok' ? `Ok:${o[1][0]}` : `Trap:${o[1]}`; outcomes[key] = (outcomes[key] || 0) + 1; }
  nativeCases += inputs.length;
  receipts.push({name: c.name, module, ...result.manifest});
  console.log(`${module} ${c.name}: exact-image proof, GNU as bytes, ${inputs.length} QEMU comparisons`);
}

// Single-instruction alterations: each must break the exact-image proof and
// change some observed result.
const EQ = 0, NE = 1, VS = 6, VC = 7, AL = 14;
const MUTANTS = [
  ['trap-code', 'add-sub-intermediate', i => i.op === 'Movz' && i.rd === 1 && i.imm === 1, () => ({op: 'Movz', rd: 1, imm: 2, hw: 0})],
  ['overflow-branch', 'add-sub-intermediate', i => i.op === 'Bcond' && i.c === VC, i => ({...i, c: VS})],
  ['operand-order', 'sub-add-intermediate', i => i.op === 'AddSubReg' && i.sub && i.rd === 0 && i.rn === 1, i => ({...i, rn: 0, rm: 1})],
  ['stack-slot', 'let-chain', i => i.op === 'LdrUoff' && i.imm === 0, i => ({...i, imm: 2})],
  ['branch-polarity', 'abs', i => i.op === 'Cbz' && !i.nz, i => ({...i, nz: true})],
  ['divzero-guard', 'div-by-x', i => i.op === 'Cbz' && i.nz, i => ({op: 'Bimm', imm: i.imm})],
  ['mul-overflow-test', 'mul-square', i => i.op === 'Bcond' && i.c === EQ, i => ({...i, c: AL})],
  ['min-div-guard', 'div-by-minus-one', i => i.op === 'Bcond' && i.c === VC, i => ({...i, c: AL})],
  ['compare-condition', 'cmp-le', i => i.op === 'Csinc', i => ({...i, c: 13})],
  ['stack-release', 'let-shadow', i => i.op === 'AddSubImm' && !i.sf && i.rd === 31 && i.rn === 31, i => ({...i, imm: 32})],
];
const rejected = [];
for (const [name, program, find, change] of MUTANTS) {
  const good = compiled.get(program), k = good.code.findIndex(find);
  assert(k >= 0, `${name}: no site`);
  const code = good.code.map((i, j) => j === k ? change(i) : i), binary = imageOf(code);
  assert.notDeepEqual(binary, good.binary);
  const text = exprProofInstance({...good, binary});
  writeFileSync(resolve(out, 'Mutant.v'), text);
  const r = prove('Mutant.v', false);
  assert.notEqual(r.status, 0, `${name}: altered bytes were proved`);
  // The failure must be the byte-identity proof itself, not infrastructure.
  const identityProof = text.split('\n').findIndex(l => l.startsWith('Lemma image_identity')) + 2;
  assert.match(r.stderr.toString(), new RegExp(`line ${identityProof}, [^]*Unable to unify`), `${name}: failed for another reason`);
  const dir = resolve(out, `mutant-${name}`); mkdirSync(dir);
  const observed = native(binary, dir, good.manifest.result_type);
  assert.notDeepEqual(observed, expectedOf(good.artifact), `${name}: survived QEMU`);
  rejected.push({name, program, instruction: k, word: encodeInstr(code[k]).toString(16)});
  console.log(`mutant ${name}: proof rejected, QEMU diverged`);
}

const checked = run('coqchk', [...flags, ...MODULES.map(m => `FenrirARM.${m}`), ...receipts.map(r => `FenrirARM.${r.module}`)], {cwd: out});
writeFileSync(resolve(out, 'coqchk.log'), checked.stdout.toString() + checked.stderr.toString());
assert(audit.every(a => !/Axioms:/.test(a.output)), 'unexpected axioms');
writeFileSync(resolve(out, 'assumptions.log'), audit.map(a => `== ${a.file}\n${a.output}`).join('\n'));
const sources = ['verification/aarch64/Core.v', 'verification/aarch64/Expr.v', 'verification/aarch64/Machine.v',
  'verification/aarch64/Flags.v', 'verification/aarch64/Encode.v', 'verification/aarch64/Compile.v',
  'tools/aarch64/expr.mjs', 'tools/aarch64/expr-fixtures.mjs', 'tools/aarch64/check-expr.mjs', 'tools/aarch64/toolchain.mjs',
  'tools/tc0/canonical.mjs', 'tools/tc0/pure-call-artifact.mjs', 'runtime/tc0/pure-call-machine.mjs'];
const report = {schema: 'fenrir.aarch64.expr-check/1', profile: EXPR_PROFILE, result_abi: RESULT_ABI,
  status: 'development-pass', qualification: 'UNKNOWN', node: process.version, versions: versions(),
  source_inventory: Object.fromEntries(sources.map(p => [p, sha256(readFileSync(resolve(root, p)))])),
  programs: receipts.length, proof_instances: receipts.length, gnu_as_checked: gnuChecked,
  inputs: inputs.length, native_comparisons: nativeCases, outcomes, rejected_mutants: rejected,
  universal_theorems: ['Compile.compile_correct', 'Compile.compile_correct_typed', 'Expr.type_safety', 'Encode.decode_encode', 'Encode.image_decodes'],
  assumptions: 'Closed under the global context (assumptions.log)', coqchk: 'Modules were successfully checked (coqchk.log)',
  claims: {universal_handwritten_model_proof: true, exact_byte_identity: true, coqchk_replay: true,
    authoritative_ARM_refinement: false, json_projection_verified: false, full_TC0: false, whole_process: false},
  receipts};
writeFileSync(resolve(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(`PASS: ${receipts.length} programs, ${nativeCases} QEMU comparisons, ${rejected.length} rejected mutants.\n${out}/report.json`);
