// The JavaScript TC1-D1 machine (runtime/tc1/durable-machine.mjs): host interface,
// sequence numbers, boundary typing, defects off by default.
import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {DurableMachine} from '../../runtime/tc1/durable-machine.mjs';
import {cases} from '../../fixtures/tc1/durable-hand-cases.mjs';

const byName=n=>cases.find(c=>c.name===n);
const machine=(c,options)=>{const v=validatePureCallArtifact(encode(c.program),c.input);return new DurableMachine(v.artifact,v.input,options);};

test('every fixture validates and runs to its expected execution with its replies', () => {
  for(const c of cases)assert.equal(machine(c).run(200,c.replies).execution,c.expected_execution,c.name);
});
test('a host function sees each request with consecutive sequence numbers', () => {
  const seen=[];const r=machine(byName('two-requests-in-order')).run(200,q=>{seen.push(q);return ['int',String(10*(seen.length))];});
  assert.deepEqual(seen.map(q=>[q.seq,q.effect,q.operation,q.value]),[['0','Store','put',['int','1']],['1','Store','put',['int','11']]]);
  assert.deepEqual(r.outcome,['Ok',['int','1020']]);
});
test('the machine cannot step while the host holds the continuation, nor take a reply otherwise', () => {
  const m=machine(byName('single-request'));
  while(m.control.kind!=='HostWait')m.step();
  assert.throws(()=>m.step(),/Awaiting the host/);
  assert.equal(m.reply(['bool',true]).violation[0],'root');
  assert.equal(m.control.kind,'HostWait','an ill-typed reply takes no step');
  m.reply(['int','1']);
  assert.throws(()=>m.reply(['int','1']),/No request is pending/);
});
test('replies are typed recursively against datatypes, tuples and the I64 range', () => {
  const m=machine(byName('datatype-reply'));
  assert.equal(m.illTyped(['data','Answer','Found',['int','1']],['Data','Answer'],[]),null);
  assert.deepEqual(m.illTyped(['data','Answer','Found',['bool',true]],['Data','Answer'],[]),[0]);
  assert.ok(m.illTyped(['int','9223372036854775808'],'I64',[]));
  assert.equal(m.illTyped(['int','-9223372036854775808'],'I64',[]),null);
  assert.ok(m.illTyped(['int','-0'],'I64',[]));
  assert.deepEqual(m.illTyped(['tuple',['int','1'],['unit']],['Tuple','I64','I64'],[]),[1]);
});
test('defects are off by default', () => {
  assert.deepEqual(machine(byName('single-request')).defects,{});
});
