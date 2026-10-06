import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {lower,dataHeader} from '../../tools/solo5/native-arithmetic/lower.mjs';
import {encode} from '../../tools/tc0/canonical.mjs';
const artifact=JSON.parse(readFileSync(new URL('../../fixtures/tc0/left-trap-program.json',import.meta.url)));
const clone=()=>structuredClone(artifact);
test('lowering preserves nodes, child order, IDs and artifact/source-map identity',()=>{
  const a=lower(encode(artifact),['unit']);
  assert.equal(a.rows.length,8);assert.equal(a.root,0);
  const fn=artifact.functions[0],root=a.rows[0];
  assert.equal(root.id,fn.body[1]);
  assert.deepEqual(root.children.map(i=>a.rows[i].id),fn.body.slice(3).map(e=>e[1]));
  const b=clone();b.source_map[0].line='999';
  assert.notEqual(lower(encode(b),['unit']).artifact_sha256,a.artifact_sha256);
  const header=dataHeader(a);
  assert.match(header,/Validated artifact DATA ONLY/);
  assert.doesNotMatch(header,/DivZero|Overflow|ScopeExit|TaskTermination/);
});
test('adapter rejects oversized IDs without widening existing validator semantics',()=>{
  const a=clone();a.functions[0].parameter_id='18446744073709551616';
  assert.throws(()=>lower(encode(a),['unit']),/ID range/);
});
test('unsafe/unmodeled labels rejected before C generation',()=>{
  for(const label of ['quote"injection','two words','a'.repeat(65),'é']) {
    const a=clone();a.functions[0].body[4][3][2]=label;
    assert.throws(()=>lower(encode(a),['unit']),/label/);
  }
});
test('unsupported tag and malformed arity stay rejected',()=>{
  const a=clone();a.functions[0].body[0]='invented';
  assert.throws(()=>lower(encode(a),['unit']));
  const b=clone();b.functions[0].body.pop();
  assert.throws(()=>lower(encode(b),['unit']));
});
test('minimum I64 literal is emitted without overflowing a C decimal constant',()=>{
  const a=clone();a.functions[0].body[3][3][2]='-9223372036854775808';
  const header=dataHeader(lower(encode(a),['unit']));
  assert.match(header,/\(-INT64_C\(9223372036854775807\)-1\)/);
});
