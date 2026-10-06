// Unit oracle peers are scripted candidate traces, NOT independent Shen evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {pureCallHeader} from '../../tools/tc0/pure-call-replay-header.mjs';
import {recordPureCall,replayPureCall,stateHash,PureCallReplayDiverged,PureCallReplayIncompatible} from '../../tools/tc0/pure-call-replay.mjs';
const base=JSON.parse(readFileSync(new URL('../../fixtures/tc0/pure-call-forward.json',import.meta.url)));
const clone=x=>JSON.parse(JSON.stringify(x));
function setup(a=base,{steps='200',reverseOperands=false}={}){
 const machine=()=>new PureCallMachine(a,['int','0'],{reverseOperands});
 const reference=new PureCallMachine(a,['int','0']).run().steps,m=machine();
 const header=pureCallHeader(m,a,['int','0'],reference,{unit_mock:true},{steps});
 return {machine,reference,header,bundle:recordPureCall(m,reference,header)};
}
test('integrated singleton choices and terminal footer replay Exact',()=>{const s=setup(),r=replayPureCall(s.machine(),s.reference,s.header,s.bundle);assert.equal(r.replay,'Exact');assert.equal(r.execution,'Completed');assert.equal(r.qualification,'UNKNOWN');assert.equal(s.bundle.choices.length,13);assert.ok(s.bundle.choices.every((c,i)=>c.index===String(i)&&c.scheduler_epoch===String(i)));});
test('bounded prefix Exact remains Unknown, final-step completion not budget exhaustion',()=>{const s=setup(base,{steps:'12'});assert.equal(replayPureCall(s.machine(),s.reference,s.header,s.bundle).conformance,'Unknown');assert.equal(s.bundle.footer.kind,'BudgetExhausted');const t=setup(base,{steps:'13'});assert.equal(t.bundle.footer.kind,'Completed');});
test('reversed-order mutant exact divergence is not conformance PASS',()=>{const a=cases.find(c=>c.name==='named-emit-order').program,s=setup(a,{reverseOperands:true});assert.equal(s.bundle.footer.kind,'Divergence');const r=replayPureCall(s.machine(),s.reference,s.header,s.bundle);assert.equal(r.replay,'Exact');assert.equal(r.conformance,'Diverged');assert.equal(r.execution,'StoppedAtDivergence');});
test('reject missing/extra/domain/site/epoch/selection/schema/trace/footer drift',()=>{
 for(const mutate of [b=>b.choices.pop(),b=>b.choices.push(b.choices[0]),b=>b.choices[0].domain_hash='0'.repeat(64),b=>b.choices[0].site.node='99',b=>b.choices[0].site.occurrence='1',b=>b.choices[0].scheduler_epoch='1',b=>b.choices[0].selected.task='1',b=>b.choices[0].schema='closure-demo-choice/1',b=>b.steps[0].depth='99',b=>b.steps.pop(),b=>b.footer.state_hash='0'.repeat(64),b=>b.footer.trace_hash='0'.repeat(64),b=>b.footer.outcome=['Ok',['int','99']],b=>b.extra=true]){
  const s=setup(),b=clone(s.bundle);mutate(b);assert.throws(()=>replayPureCall(s.machine(),s.reference,s.header,b),PureCallReplayDiverged);
 }
});
test('reject old identity and changed artifact/input/oracle/candidate/catalog/bounds headers',()=>{
 const s=setup();for(const field of ['oracle_hash','candidate_hash','catalog_hash','program_hash','input_hash','reference_hash','initial_state_hash']){const b=clone(s.bundle);b.header[field]='0'.repeat(64);assert.throws(()=>replayPureCall(s.machine(),s.reference,s.header,b),PureCallReplayIncompatible);}
 const h={...s.header,schema:'closure-demo-tape/1'};assert.throws(()=>recordPureCall(s.machine(),s.reference,h),PureCallReplayIncompatible);
 const m=s.machine();m.input=['int','1'];assert.throws(()=>recordPureCall(m,s.reference,s.header),PureCallReplayIncompatible);
});
test('state checkpoint binds tail/control/env/frames/codes/names/options/descriptors/events',()=>{
 const initial=new PureCallMachine(base,['int','0']),h=stateHash(initial);
 for(const mutate of [m=>m.control.tail=false,m=>m.env.set('1',['int','9']),m=>m.frames.push({kind:'Return',node:'2',env:new Map()}),m=>m.codes.delete('4'),m=>m.functions.delete('inc'),m=>m.reverseOperands=true,m=>m.descriptors.push({code_id:'4',captures:[],capture_support:[]}),m=>m.events.push({kind:'Emit',label:'fake'})]){const m=new PureCallMachine(base,['int','0']);mutate(m);assert.notEqual(stateHash(m),h);}
});
test('same step prefix but corrupt descriptor state cannot replay footer Exact',()=>{
 const a=cases.find(c=>c.name==='returned-closure-alias').program,s=setup(a),m=s.machine(),original=m.step.bind(m);
 m.step=()=>{const r=original();if(m.terminal)m.descriptors[0].captures[0][1]=['int','999'];return r;};
 assert.throws(()=>replayPureCall(m,s.reference,s.header,s.bundle),PureCallReplayDiverged);
});
