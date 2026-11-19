// Strict tape replay of the TC1 handler machine (tools/tc1/handler-replay.mjs). The
// reference here is the implementation's own trace: a scripted peer for UNIT tests,
// NOT Shen evidence. harness/tc1-strict-replay.shen replays against the model.
import test from 'node:test';
import assert from 'node:assert/strict';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {cases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {handlerHeader} from '../../tools/tc1/handler-replay-header.mjs';
import {recordHandlers,replayHandlers,stateHash,HandlerReplayDiverged,HandlerReplayIncompatible} from '../../tools/tc1/handler-replay.mjs';
const clone=x=>JSON.parse(JSON.stringify(x));
const input=['int','0'];
const program=name=>[...cases,...resumptionCases].find(c=>c.name===name).program;
function setup(a=program('clause-continues-after-resume'),{steps='1000',options={}}={}){
  const machine=()=>new HandlerMachine(a,input,options);
  const reference=new HandlerMachine(a,input).run(1000).steps,m=machine();
  const header=handlerHeader(m,a,input,reference,{unit_mock:true},{steps});
  return {a,machine,reference,header,bundle:recordHandlers(m,a,input,reference,header)};
}

test('every hand fixture records and replays Exact and Admitted against its own trace', () => {
  for(const c of [...cases,...resumptionCases]) {
    const s=setup(c.program),r=replayHandlers(s.machine(),s.a,input,s.reference,s.header,s.bundle);
    assert.deepEqual([r.replay,r.conformance,r.execution,r.qualification],['Exact','Admitted','Completed','UNKNOWN'],c.name);
    assert.equal(s.bundle.choices.length,s.reference.length);
  }
});

test('a defect diverges exactly, at the first differing epoch, and is never Admitted', () => {
  const s=setup(program('handler-basic'),{options:{forgottenResume:true}});
  assert.equal(s.bundle.footer.kind,'Divergence');
  const own=new HandlerMachine(s.a,input,{forgottenResume:true}).run(1000).steps;
  const first=own.findIndex((x,i)=>JSON.stringify(x)!==JSON.stringify(s.reference[i]));
  assert.equal(s.bundle.footer.epoch,String(first));
  const r=replayHandlers(s.machine(),s.a,input,s.reference,s.header,s.bundle);
  assert.deepEqual([r.replay,r.conformance,r.execution],['Exact','Diverged','StoppedAtDivergence']);
});

test('a bounded prefix is Unknown, not Admitted', () => {
  const s=setup(undefined,{steps:'5'});
  assert.equal(s.bundle.footer.kind,'BudgetExhausted');
  assert.equal(replayHandlers(s.machine(),s.a,input,s.reference,s.header,s.bundle).conformance,'Unknown');
});

test('tape drift is rejected: choices, steps, footer, framing', () => {
  for(const mutate of [b=>b.choices.pop(),b=>b.choices.push(b.choices[0]),b=>b.choices[0].site.node='99',b=>b.choices[0].site.occurrence='1',
    b=>b.choices[0].scheduler_epoch='1',b=>b.choices[0].schema='pure-call-demo-choice/1',b=>b.steps[3].depth='99',b=>b.steps.pop(),
    b=>b.footer.state_hash='0'.repeat(64),b=>b.footer.trace_hash='0'.repeat(64),b=>b.footer.outcome=['Ok',['int','99']],b=>b.extra=true,
    b=>{b['choices,footer']=[b.choices,b.footer];delete b.choices;delete b.footer;}]) {
    const s=setup(),b=clone(s.bundle);mutate(b);
    assert.throws(()=>replayHandlers(s.machine(),s.a,input,s.reference,s.header,b),HandlerReplayDiverged);
  }
});

test('changed identities are incompatible: program, input, reference, catalog, candidate, schema, used machine', () => {
  const s=setup();
  for(const field of ['oracle_hash','candidate_hash','catalog_hash','program_hash','input_hash','reference_hash','initial_state_hash','adapter_hash','toolchain_hash','environment_hash']) {
    const b=clone(s.bundle);b.header[field]='0'.repeat(64);
    assert.throws(()=>replayHandlers(s.machine(),s.a,input,s.reference,s.header,b),HandlerReplayIncompatible,field);
  }
  assert.throws(()=>recordHandlers(s.machine(),s.a,input,s.reference,{...s.header,schema:'pure-call-demo-tape/1'}),HandlerReplayIncompatible);
  assert.throws(()=>recordHandlers(s.machine(),program('handler-basic'),input,s.reference,s.header),HandlerReplayIncompatible);
  assert.throws(()=>recordHandlers(s.machine(),s.a,['int','1'],s.reference,s.header),HandlerReplayIncompatible);
  const used=s.machine();used.step();
  assert.throws(()=>recordHandlers(used,s.a,input,s.reference,s.header),HandlerReplayIncompatible);
  // The header binds the defect switches: a tape of the fixed machine does not replay a defective one.
  assert.throws(()=>recordHandlers(new HandlerMachine(s.a,input,{doubleResume:true}),s.a,input,s.reference,s.header),HandlerReplayIncompatible);
});

test('even a matching header cannot use a non-handler artifact', () => {
  const s=setup();
  for(const schema_version of ['tc0-a-pure-call-demo/2','tc1-handler-demo/3','tc1-handler-demo/4','tc1-durable-demo/1','tc1-task-demo/1']) {
    const a={...s.a,schema_version},m=new HandlerMachine(a,input);
    const header=handlerHeader(m,a,input,s.reference,{unit_mock:true});
    assert.throws(()=>recordHandlers(m,a,input,s.reference,header),/Handler artifact schema required/);
  }
});

test('the state checkpoint binds control, environment, frames, codes, defects, descriptors and events', () => {
  const a=program('clause-continues-after-resume'),h=stateHash(new HandlerMachine(a,input));
  for(const mutate of [m=>{m.control.tail=false;},m=>{m.env.set('1',['int','9']);},m=>{m.frames.push({kind:'Return',node:'2',env:new Map()});},
    m=>{m.codes.clear();},m=>{m.options.shallowResume=true;},m=>{m.descriptors.push({code_id:'4',captures:[],capture_support:[]});},m=>{m.events.push({kind:'Emit',label:'fake'});}]) {
    const m=new HandlerMachine(a,input);mutate(m);assert.notEqual(stateHash(m),h);
  }
});

test('a peer that copies the reference but corrupts its suspended segment cannot replay the footer', () => {
  const s=setup(program('second-perform-inside-first-resume')),m=s.machine(),original=m.step.bind(m);
  m.step=()=>{const r=original();if(m.terminal)m.events.push({kind:'Emit',label:'late'});return r;};
  assert.throws(()=>replayHandlers(m,s.a,input,s.reference,s.header,s.bundle),HandlerReplayDiverged);
});
