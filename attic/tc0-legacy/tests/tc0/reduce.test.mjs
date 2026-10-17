import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {proposals,reduce,metric} from '../../tools/tc0/reduce.mjs';
import {validateArtifact} from '../../tools/tc0/artifact.mjs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {ExpressionMachine} from '../../runtime/tc0/expression-machine.mjs';
const original=JSON.parse(readFileSync(new URL('../../fixtures/tc0/left-trap-program.json',import.meta.url)));
const input=['unit'];
// Unit-test probe only: integration must use independent Shen observations.
function discrepancy(a) {
  const fn=a.functions[0];
  const control=new ExpressionMachine(fn.body,fn.parameter_id,input).run(200);
  const mutant=new ExpressionMachine(fn.body,fn.parameter_id,input,{reverseOperands:true}).run(200);
  const emits=r=>r.events.filter(e=>e.kind==='Emit');
  return control.outcome?.[0]==='Trap' && emits(control).length===0 && emits(mutant).length>0
    ? 'left-trap-right-emission' : null;
}
test('every proposal validates, decreases metric and leaves input untouched',()=>{
  const saved=encode(original), baseline=metric(original,input), rows=[...proposals(original,input)];
  assert.ok(rows.length>0);
  for(const row of rows) {validateArtifact(encode(row.artifact),input);
    assert.ok(row.metric[0]<baseline[0] || row.metric[0]===baseline[0] && row.metric[1]<baseline[1]);}
  assert.deepEqual(encode(original),saved);
  assert.deepEqual(rows,[...proposals(original,input)]);
});
test('reduction preserves classified defect and rechecks every attempt',()=>{
  let calls=0;const result=reduce(original,input,a=>{calls++;return discrepancy(a);});
  assert.equal(discrepancy(result.minimized),'left-trap-right-emission');
  assert.equal(calls,Number(result.attempts)+1);assert.equal(result.qualification,'UNKNOWN');
  assert.equal(result.cap_hit,false);assert.deepEqual([...proposals(result.minimized,input)].filter(r=>discrepancy(r.artifact)),[]);
  assert.deepEqual(result.original,original);
});
test('cap is retained; no failing original or malformed callback is accepted',()=>{
  const result=reduce(original,input,discrepancy,{maxAttempts:1});
  assert.equal(result.attempts,'1');assert.equal(result.cap_hit,true);
  assert.throws(()=>reduce(original,input,()=>null),/does not reproduce/);
  assert.throws(()=>reduce(original,input,()=>true),/discrepancy ID/);
  assert.throws(()=>reduce(original,input,discrepancy,{maxAttempts:0}),/cap/);
});
test('invalid binding eliminations are rejected before execution',()=>{
  // Existing fixture contains lets; every surviving proposal is independently checked.
  for(const row of proposals(original,input)) assert.doesNotThrow(()=>validateArtifact(encode(row.artifact),input));
  assert.throws(()=>reduce({...original,source_map:[]},input,discrepancy));
});
