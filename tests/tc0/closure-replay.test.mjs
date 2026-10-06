import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {ClosureMachine} from '../../runtime/tc0/closure-machine.mjs';
import {validateClosureProgram} from '../../tools/tc0/closure-artifact.mjs';
import {closureHeader} from '../../tools/tc0/closure-replay-header.mjs';
import {hash,stateHash,recordClosure,replayClosure,ClosureReplayDiverged,ClosureReplayIncompatible} from '../../tools/tc0/closure-replay.mjs';
const checked=validateClosureProgram(readFileSync(new URL('../../fixtures/tc0/closure-capture-program.json',import.meta.url)),['int','0']);
const machine=()=>new ClosureMachine(checked.program,checked.input);
// Unit-test reference only; independent Shen report supplies integration references.
const reference=machine().run(200).steps;
const copy=x=>JSON.parse(JSON.stringify(x));
const header=(m,steps='200')=>closureHeader(m,checked.program,checked.input,reference,{scope:'candidate-reference replay unit tests'}, {steps});
test('singleton tape, last-step completion and closure state replay exactly',()=>{
 const m=machine(),h=header(m,'21'),b=recordClosure(m,reference,h);assert.equal(b.choices.length,21);
 assert.equal(b.footer.kind,'Completed');assert.equal(replayClosure(machine(),reference,h,b).conformance,'Admitted');
 assert.equal(replayClosure(machine(),reference,h,b).qualification,'UNKNOWN');
});
test('replay rejects missing/extra/changed epoch/domain/site/occurrence, trace and footer',()=>{
 const m=machine(),h=header(m),b=recordClosure(m,reference,h);
 for(const mutate of [x=>x.choices.pop(),x=>x.choices.push(copy(x.choices[0])),x=>{x.choices[0].scheduler_epoch='1';},
 x=>{x.choices[0].domain_hash='0'.repeat(64);},x=>{x.choices[0].site.node='999';},x=>{x.choices[0].site.occurrence='1';},
 x=>{x.steps[0].after='Terminal';},x=>{x.footer.state_hash='0'.repeat(64);},x=>{x.footer.outcome=['Ok',['int','13']];}]) {
  const changed=copy(b);mutate(changed);assert.throws(()=>replayClosure(machine(),reference,h,changed),ClosureReplayDiverged);
 }
 const changed=copy(h);changed.candidate_hash='0'.repeat(64);assert.throws(()=>replayClosure(machine(),reference,changed,b),ClosureReplayIncompatible);
});
test('incomplete closure capture boundary is Exact but Unknown',()=>{
 for(const steps of ['0','5','20']) {const m=machine(),h=header(m,steps),b=recordClosure(m,reference,h);const result=replayClosure(machine(),reference,h,b);
  assert.equal(result.replay,'Exact');assert.equal(result.conformance,'Unknown');assert.equal(result.execution,'BudgetExhausted');}
});
test('all exposed closure state, code and saved environments bind the boundary',()=>{
 const a=machine(),b=machine();assert.equal(stateHash(a),stateHash(b));
 b.codes.get('7').parameter='999';assert.notEqual(stateHash(a),stateHash(b));
 const c=machine();for(let i=0;i<5;i++)c.step();const prior=stateHash(c);c.descriptors[0].capture_support.push('99');assert.notEqual(stateHash(c),prior);
});
test('scripted capture-corruption failure replays Exact without conformance promotion',()=>{
 const corrupt=()=>{const m=machine(),original=m.step.bind(m);let once=false;
  m.step=()=>{const s=original();if(!once&&m.descriptors.length){m.descriptors[0].captures[0][1][1]='8';once=true;}return s;};return m;};
 const m=corrupt(),h=header(m);h.candidate_hash=hash({source:h.candidate_hash,script:'Unit test capture-corruption peer only'});
 const b=recordClosure(m,reference,h);assert.equal(b.footer.kind,'Divergence');
 const result=replayClosure(corrupt(),reference,h,b);assert.equal(result.replay,'Exact');assert.equal(result.conformance,'Diverged');
});
