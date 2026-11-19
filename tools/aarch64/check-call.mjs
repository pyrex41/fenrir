// Development check for profile fenrir-aarch64-checked-call/1. NOT a
// qualification receipt. In a fresh directory it compiles the Rocq
// development including CallCompile.v; for every program proves the
// exact-image theorem(s) for its bytes, cross-checks the bytes with GNU as,
// and runs them under qemu-aarch64 against the JavaScript candidate, on the
// boundary inputs (hand programs) or on deep inputs (deep recursion, long
// tail loop); single-instruction mutants must fail their byte-identity proof
// and diverge under QEMU; rocqchk replays every module.
// Usage: node tools/aarch64/check-call.mjs [OUTPUT_DIR]
import {readFileSync, writeFileSync, mkdirSync, copyFileSync} from 'node:fs';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
import {encode} from '../tc0/canonical.mjs';
import {VALUES} from '../tc0/check-i64.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {assembly, encodeInstr, imageOf, sha256} from './expr.mjs';
import {compileCallArtifact, callProofInstance, CALL_PROFILE, CALL_ABI} from './call.mjs';
import {callCases, deepCases} from './call-fixtures.mjs';
import {run, versions} from './toolchain.mjs';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.argv[2] || resolve(root, 'build/aarch64', `call-${Date.now()}-${process.pid}`));
mkdirSync(out, {recursive: true});
const flags = ['-Q', out, 'FenrirARM'];
const MODULES = ['Core', 'Expr', 'Machine', 'Flags', 'Encode', 'Compile', 'CallCompile'];
const audit = [];
function prove(file, ok = true) {
  const r = run('coqc', [...flags, file], {cwd: out, ok, timeout: 900000});
  if (ok) audit.push({file, output: r.stdout.toString()});
  return r;
}
for (const m of MODULES) { copyFileSync(resolve(root, 'verification/aarch64', `${m}.v`), resolve(out, `${m}.v`)); prove(`${m}.v`); }
const universal = audit.find(a => a.file === 'CallCompile.v').output;
assert.equal((universal.match(/Closed under the global context/g) || []).length, 3, 'call_correct, tail_calls_constant_stack, tail_program_correct must be closed');

const boundary = [...VALUES, 5n, -7n, 1000n];
function native(binary, dir, inputs, offset, resultType, {mutant = false} = {}) {
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
 bl target+${offset}
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
  mov x0, #42
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
  const r = run('qemu', ['./runner'], {
    cwd: dir, ok: false, timeout: 120000,
    allowSignals: mutant ? ['SIGSEGV', 'SIGBUS', 'SIGILL'] : [],
  });
  if (r.signal || r.status === 42) return null; // guest fault or launcher check
  assert.equal(r.status, 0, `unexpected QEMU exit: ${r.stderr}`);
  assert.equal(r.stdout.length, inputs.length * 16, 'incomplete AArch64 launcher output');
  return inputs.map((_, i) => {
    const v = r.stdout.readBigInt64LE(i * 16), tag = r.stdout.readBigUInt64LE(i * 16 + 8);
    if (tag === 0n) return resultType === 'Bool' ? (v === 0n || v === 1n ? ['Ok', ['bool', v === 1n]] : ['InvalidBool', String(v)]) : ['Ok', ['int', String(v)]];
    if (tag === 1n) return ['Trap', 'Overflow'];
    if (tag === 2n) return ['Trap', 'DivZero'];
    return ['InvalidStatus', String(tag)];
  });
}
const expectedOf = (artifact, inputs) => inputs.map(x => {
  const r = new PureCallMachine(artifact, ['int', String(x)]).run(100000000);
  assert.equal(r.execution, 'Completed'); return r.outcome;
});

const receipts = [], outcomes = {}, compiled = new Map();
let nativeCases = 0, gnuChecked = 0, tailTheorems = 0;
const all = [...callCases().map(c => ({...c, inputs: boundary})), ...deepCases()];
for (const [k, c] of all.entries()) {
  const dir = resolve(out, `case${k}`); mkdirSync(dir);
  const result = compileCallArtifact(encode(c.artifact)); compiled.set(c.name, result);
  writeFileSync(resolve(dir, 'artifact.json'), encode(c.artifact));
  const module = `CallCase${k}`;
  writeFileSync(resolve(out, `${module}.v`), callProofInstance(result));
  const pr = prove(`${module}.v`).stdout.toString();
  const closed = (pr.match(/Closed under the global context/g) || []).length;
  assert.equal(closed, result.manifest.tail_only ? 2 : 1, `${c.name}: exact-image theorem(s) not closed`);
  if (result.manifest.tail_only) tailTheorems++;
  writeFileSync(resolve(dir, 'reference.s'), result.code.map(assembly).join('\n') + '\n');
  run('as', ['-o', 'reference.o', 'reference.s'], {cwd: dir});
  run('objcopy', ['-O', 'binary', '-j', '.text', 'reference.o', 'reference.bin'], {cwd: dir});
  assert.deepEqual(readFileSync(resolve(dir, 'reference.bin')), result.binary, `${c.name}: GNU as disagrees with the encoder`);
  gnuChecked++;
  const observed = native(result.binary, dir, c.inputs, result.manifest.entry_offset, result.manifest.result_type);
  const expected = expectedOf(result.artifact, c.inputs);
  assert.deepEqual(observed, expected, `${c.name}: QEMU disagrees with the candidate`);
  for (const o of expected) { const key = o[0] === 'Ok' ? `Ok:${o[1][0]}` : `Trap:${o[1]}`; outcomes[key] = (outcomes[key] || 0) + 1; }
  nativeCases += c.inputs.length;
  receipts.push({name: c.name, module, inputs: c.inputs.length, ...result.manifest});
  console.log(`${module} ${c.name}: exact-image proof${result.manifest.tail_only ? 's (incl. constant stack)' : ''}, GNU as bytes, ${c.inputs.length} QEMU comparisons`);
}

// Single-instruction alterations of call frames.
const MUTANTS = [
  ['saved-link-register', 'sum-recursive', 1, i => i.op === 'StrPre' && i.rt === 30, i => ({...i, rt: 29})],
  ['link-reload-slot', 'sum-recursive', 0, i => i.op === 'LdrUoff' && i.rt === 30, i => ({...i, imm: i.imm + 2})],
  ['trap-frame-restore', 'callee-overflow', 0, (i, j, code) => i.op === 'AddSubImm' && i.rd === 31 && i.rn === 9 && j > 0 && code[j - 1].op === 'Cbz' && code[j - 1].rt === 1, i => ({...i, rd: 9})],
  ['frame-base-restore', 'callee-divzero', 0, i => i.op === 'AddSubImm' && i.rd === 9 && i.rn === 31 && i.imm > 0, i => ({...i, imm: i.imm - 16})],
  ['call-target', 'sum-recursive', 0, i => i.op === 'Bl', i => ({...i, imm: i.imm + 1})],
  ['callee-status-test', 'chain', 0, i => i.op === 'Cbz' && i.rt === 1, i => ({...i, nz: true})],
  ['tail-frame-release', 'count-down-tail', 0, (i, j, code) => i.op === 'AddSubImm' && i.rd === 31 && i.rn === 9 && code[j + 1] && code[j + 1].op === 'Bimm', i => ({...i, rd: 9})],
  ['tail-target', 'even-odd-mutual-tail', 0, i => i.op === 'Bimm' && i.imm < 0, i => ({...i, imm: i.imm + 3})],
];
const rejected = [];
for (const [name, program, nth, find, change] of MUTANTS) {
  const good = compiled.get(program);
  const sites = good.code.map((i, j) => find(i, j, good.code) ? j : -1).filter(j => j >= 0);
  assert(sites.length > nth, `${name}: no site`);
  const k = sites[nth];
  const code = good.code.map((i, j) => j === k ? change(i) : i), binary = imageOf(code);
  const text = callProofInstance({...good, binary});
  writeFileSync(resolve(out, 'Mutant.v'), text);
  const r = prove('Mutant.v', false);
  assert.notEqual(r.status, 0, `${name}: altered bytes were proved`);
  const identityProof = text.split('\n').findIndex(l => l.startsWith('Lemma image_identity')) + 2;
  assert.match(r.stderr.toString(), new RegExp(`line ${identityProof}, [^]*Unable to unify`), `${name}: failed for another reason`);
  const dir = resolve(out, `mutant-${name}`); mkdirSync(dir);
  const observed = native(binary, dir, boundary, good.manifest.entry_offset, good.manifest.result_type, {mutant: true});
  assert.notDeepEqual(observed, expectedOf(good.artifact, boundary), `${name}: survived QEMU`);
  rejected.push({name, program, instruction: k, word: encodeInstr(code[k]).toString(16), qemu: observed === null ? 'crashed or launcher check failed' : 'different results'});
  console.log(`mutant ${name}: proof rejected, QEMU diverged (${observed === null ? 'crash/launcher check' : 'results'})`);
}

const checked = run('coqchk', [...flags, ...MODULES.map(m => `FenrirARM.${m}`), ...receipts.map(r => `FenrirARM.${r.module}`)], {cwd: out});
writeFileSync(resolve(out, 'coqchk.log'), checked.stdout.toString() + checked.stderr.toString());
assert(audit.every(a => !/Axioms:/.test(a.output)), 'unexpected axioms');
writeFileSync(resolve(out, 'assumptions.log'), audit.map(a => `== ${a.file}\n${a.output}`).join('\n'));
const sources = ['verification/aarch64/Machine.v', 'verification/aarch64/Encode.v', 'verification/aarch64/Compile.v', 'verification/aarch64/CallCompile.v',
  'tools/aarch64/call.mjs', 'tools/aarch64/call-fixtures.mjs', 'tools/aarch64/check-call.mjs', 'tools/aarch64/expr.mjs', 'tools/aarch64/toolchain.mjs',
  'tools/tc0/pure-call-artifact.mjs', 'runtime/tc0/pure-call-machine.mjs'];
const report = {schema: 'fenrir.aarch64.call-check/1', profile: CALL_PROFILE, abi: CALL_ABI,
  status: 'development-pass', qualification: 'UNKNOWN', node: process.version, versions: versions(),
  source_inventory: Object.fromEntries(sources.map(p => [p, sha256(readFileSync(resolve(root, p)))])),
  programs: receipts.length, proof_instances: receipts.length, tail_constant_stack_instances: tailTheorems, gnu_as_checked: gnuChecked,
  native_comparisons: nativeCases, outcomes, rejected_mutants: rejected,
  universal_theorems: ['CallCompile.call_correct', 'CallCompile.tail_calls_constant_stack', 'CallCompile.tail_program_correct'],
  claims: {universal_handwritten_model_proof: true, exact_byte_identity: true, coqchk_replay: true, stack_overflow_covered: false,
    authoritative_ARM_refinement: false, json_projection_verified: false, whole_process: false},
  receipts};
writeFileSync(resolve(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(`PASS: ${receipts.length} programs, ${nativeCases} QEMU comparisons, ${rejected.length} rejected mutants.\n${out}/report.json`);
