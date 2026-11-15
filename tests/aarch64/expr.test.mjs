import {test} from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {compileExprArtifact, exprProofInstance, encodeInstr, UnsupportedExprProfile} from '../../tools/aarch64/expr.mjs';
import {artifact, cases} from '../../tools/aarch64/expr-fixtures.mjs';

const words = r => r.code.map(encodeInstr);

test('prologue, operand stack, trap block and epilogue encodings', () => {
  const r = compileExprArtifact(encode(artifact(['sub', ['add', 'x', 1n], 1n])));
  const w = words(r);
  assert.deepEqual(w.slice(0, 3), [0x910003e9, 0xf81f0fe0, 0xf94003e0]); // mov x9, sp; str x0,[sp,#-16]!; ldr x0,[sp]
  assert(w.includes(0xf84107e1));                                            // ldr x1, [sp], #16
  assert(w.includes(0xab000020) && w.includes(0xeb000020));                  // adds/subs x0, x1, x0
  assert(w.includes(0x54000087));                                            // b.vc .+16
  assert.deepEqual(w.slice(-3), [0x910043ff, 0xd2800001, 0xd65f03c0]);      // add sp,sp,#16; mov x1,#0; ret
  assert.deepEqual(w.slice(11, 14), [0x9100013f, 0xd2800021, 0xd65f03c0]);   // mov sp, x9; mov x1, #1; ret
  assert.match(exprProofInstance(r), /Theorem exact_image_correct/);
});

test('branch offsets of if span the arms exactly', () => {
  const r = compileExprArtifact(encode(artifact(['if', ['lt', 'x', 0n], ['neg', 'x'], 'x'])));
  const k = r.code.findIndex(i => i.op === 'Cbz'), b = r.code.findIndex(i => i.op === 'Bimm');
  assert.equal(k + r.code[k].imm, b + 1);              // cbz lands on the else arm
  assert.equal(b + r.code[b].imm, r.code.length - 3);  // b lands on the epilogue
});

test('well-typed syntax outside the profile is rejected', () => {
  const lambda = artifact('x');
  lambda.functions[0].body = ['apply', '2', ['lambda', '3', '4', 'I64', 'I64', [], [], ['var', '5', '4']], ['var', '6', '1']];
  lambda.source_map = ['0', '2', '3', '5', '6'].map(id => ({id, file: 'arm-expr', line: '0', column: '0'}));
  assert.throws(() => compileExprArtifact(encode(lambda)), UnsupportedExprProfile);
  const call = artifact('x');
  call.functions[0].body = ['call', '2', 'main', ['var', '3', '1']];
  call.source_map = ['0', '2', '3'].map(id => ({id, file: 'arm-expr', line: '0', column: '0'}));
  assert.throws(() => compileExprArtifact(encode(call)), UnsupportedExprProfile);
  const emit = artifact('x');
  emit.functions[0].body = ['let', '2', '3', ['emit', '4', 'l', ['var', '5', '1']], ['var', '6', '1']];
  emit.functions[0].effects = ['Emit'];
  emit.source_map = ['0', '2', '4', '5', '6'].map(id => ({id, file: 'arm-expr', line: '0', column: '0'}));
  assert.throws(() => compileExprArtifact(encode(emit)), UnsupportedExprProfile);
});

test('malformed artifacts still go through the closed TC0 validator', () => {
  const a = artifact(['add', 'x', 1n]); a.functions[0].body[1] = '0';
  assert.throws(() => compileExprArtifact(encode(a)), /Duplicate ID/);
});

test('the candidate traps on intermediate overflow; every fixture compiles', () => {
  const a = artifact(['sub', ['add', 'x', 1n], 1n]);
  assert.deepEqual(new PureCallMachine(a, ['int', '9223372036854775807']).run(500).outcome, ['Trap', 'Overflow']);
  const m = artifact(['div', 'x', -1n]);
  assert.deepEqual(new PureCallMachine(m, ['int', '-9223372036854775808']).run(500).outcome, ['Trap', 'Overflow']);
  for (const c of cases()) assert(compileExprArtifact(encode(c.artifact)).code.length > 5, c.name);
});
