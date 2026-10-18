import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validateClosureProgram} from '../../tools/tc0/closure-artifact.mjs';
import {ClosureMachine} from '../../runtime/tc0/closure-machine.mjs';
const fixture=JSON.parse(readFileSync(new URL('../../fixtures/tc0/closure-alias-case.json',import.meta.url)));
test('captured closure preserves empty support and immutable aliases across repeated applications',()=>{
 const checked=validateClosureProgram(encode(fixture.program),['int','0']);
 const m=new ClosureMachine(checked.program,checked.input),steps=[];
 while(!m.terminal&&steps.length<200) {
  steps.push(m.step());
  // Every published observation of either descriptor retains its hand-derived captures.
  for(const d of m.descriptors) assert.deepEqual(d,fixture.expected_descriptors.find(e=>e.code_id===d.code_id));
 }
 assert.deepEqual(m.terminal,fixture.expected_outcome);assert.deepEqual(m.descriptors,fixture.expected_descriptors);
 assert.ok(steps.filter(s=>s.site.node==='25'&&s.site.rule==='Ready').length===2);
 assert.equal(m.descriptors[1].captures[0][1],m.descriptors[0]); // Immutable shared alias, not a mutable copy contract.
});
