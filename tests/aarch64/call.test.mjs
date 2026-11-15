import {test} from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {encodeInstr, UnsupportedExprProfile} from '../../tools/aarch64/expr.mjs';
import {compileCallArtifact, callProofInstance, fstarts} from '../../tools/aarch64/call.mjs';
import {program, callCases, deepCases} from '../../tools/aarch64/call-fixtures.mjs';

test('frame prologue, call site and tail jump encodings', () => {
  const r = compileCallArtifact(encode(program([['main', 'I64', 'I64', ['let', 'r', ['call', 'f', 'x'], ['call', 'f', 'r']]],
    ['f', 'I64', 'I64', ['add', 'x', 1n]]])));
  const w = r.code.map(encodeInstr);
  assert.deepEqual(w.slice(0, 3), [0x910003e9, 0xf81f0fe0, 0xf81f0ffe]);  // mov x9, sp; str x0,[sp,#-16]!; str x30,[sp,#-16]!
  const bl = r.code.findIndex(i => i.op === 'Bl');
  assert.equal(bl + r.code[bl].imm, fstarts(r.fns)[1]);                        // bl lands on f's prologue
  assert.deepEqual(w.slice(bl + 1, bl + 4), [0x910083e9, 0xf94003fe, 0xb4000061]); // add x9,sp,#32; ldr x30,[sp]; cbz x1,.+12
  const b = r.code.findIndex(i => i.op === 'Bimm');
  assert.equal(r.code[b - 1].op, 'AddSubImm'); assert.equal(r.code[b - 1].rd, 31); assert.equal(r.code[b - 1].rn, 9); // release the frame first
  assert.match(callProofInstance(r), /Theorem exact_image_correct/);
});

test('a call outside let-initializer or tail position is rejected', () => {
  const a = program([['main', 'I64', 'I64', ['add', ['call', 'f', 'x'], 1n]], ['f', 'I64', 'I64', 'x']]);
  assert.throws(() => compileCallArtifact(encode(a)), UnsupportedExprProfile);
  const b = program([['main', 'I64', 'I64', ['call', 'f', ['call', 'f', 'x']]], ['f', 'I64', 'I64', 'x']]);
  assert.throws(() => compileCallArtifact(encode(b)), UnsupportedExprProfile);
});

test('every call fixture compiles; tail-only tables are recognised', () => {
  for (const c of [...callCases(), ...deepCases()]) assert(compileCallArtifact(encode(c.artifact)).code.length > 10, c.name);
  assert.equal(compileCallArtifact(encode(callCases().find(c => c.name === 'count-down-tail').artifact)).manifest.tail_only, true);
  assert.equal(compileCallArtifact(encode(callCases().find(c => c.name === 'sum-recursive').artifact)).manifest.tail_only, false);
});
