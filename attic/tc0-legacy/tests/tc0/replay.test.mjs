import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { validateArtifact } from '../../tools/tc0/artifact.mjs';
import { encode } from '../../tools/tc0/canonical.mjs';
import { ExpressionMachine } from '../../runtime/tc0/expression-machine.mjs';
import { record, replay, checkpointHash, candidateStateHash, ReplayDiverged, ReplayIncompatible } from '../../tools/tc0/replay.mjs';
const raw=readFileSync(new URL('../../fixtures/tc0/left-trap-program.json',import.meta.url));
const graph=validateArtifact(raw,['unit']), fn=graph.artifact.functions[0];
const reference=JSON.parse(readFileSync(new URL('../../fixtures/tc0/left-trap-trace.json',import.meta.url))).steps;
const clone=v=>JSON.parse(JSON.stringify(v));
const digest=b=>createHash('sha256').update(b).digest('hex');
const source=path=>digest(readFileSync(new URL('../../'+path,import.meta.url)));
function machine(mutant=false) {return new ExpressionMachine(fn.body,fn.parameter_id,graph.input,{reverseOperands:mutant});}
function header(peer,fuel=11) {
  return {schema:'arithmetic-demo-tape/1',contract:'0.2',slice:'TC0-A',profile:'arithmetic-demo-frames/1',run_id:'left-trap-development',
    artifact_hash:digest(encode(graph.artifact)),input_hash:digest(encode(graph.input)),oracle_hash:checkpointHash(reference),
    oracle_source_hash:checkpointHash([source('models/tc0/arithmetic.shen'),source('models/tc0/expression-machine.shen'),source('fixtures/tc0/left-trap-trace.json')]),
    catalog_hash:source('spec/tc0/arithmetic-demo-frames.json'),monitor_hash:source('tools/tc0/replay.mjs'),
    adapter_hash:checkpointHash([source('tools/tc0/artifact.mjs'),source('tools/tc0/canonical.mjs')]),
    candidate_hash:source('runtime/tc0/expression-machine.mjs'),compiler_runtime_hash:digest(readFileSync(process.execPath)),
    environment_hash:checkpointHash({node:process.version,platform:process.platform,arch:process.arch,mode:'trusted-local-development'}),
    initial_state_hash:candidateStateHash(peer),candidate_options:{reverse_operands:peer.reverseOperands},bounds:{reference_steps:String(fuel)}};
}
function make(mutant=false,fuel=11) {const peer=machine(mutant), identity=header(peer,fuel);return {identity,bundle:record(peer,reference,identity)};}

test('retains singleton choices and replays the last-step completing trace',()=>{
  const {identity,bundle}=make(); assert.equal(bundle.choices.length,11);assert.equal(bundle.footer.kind,'Completed');
  assert.deepEqual(bundle.footer.outcome,['Trap','DivZero']);
  assert.equal(replay(machine(),reference,identity,bundle).replay,'Exact');
  assert.equal(replay(machine(),reference,identity,bundle).conformance,'Admitted');
});
test('exact original failure replay retains Diverged conformance, never PASS',()=>{
  const {identity,bundle}=make(true);assert.equal(bundle.footer.kind,'Divergence');assert.equal(bundle.footer.epoch,'1');
  assert.equal(bundle.choices.length,2);const result=replay(machine(true),reference,identity,bundle);
  assert.equal(result.replay,'Exact');assert.equal(result.conformance,'Diverged');assert.equal(result.execution,'StoppedAtDivergence');
  assert.equal(result.qualification,'UNKNOWN');
  mkdirSync(new URL('../../build/tc0/replay/',import.meta.url),{recursive:true});
  writeFileSync(new URL('../../build/tc0/replay/original-mutant.json',import.meta.url),encode(bundle));
  writeFileSync(new URL('../../build/tc0/replay/original-mutant-replay.json',import.meta.url),encode(result));
});
test('missing, extra, reordered and changed choices never fall back',()=>{
  const {identity,bundle}=make();
  const mutations=[b=>b.choices.pop(),b=>b.choices.push(clone(b.choices[0])),
    b=>{[b.choices[0],b.choices[1]]=[b.choices[1],b.choices[0]];},
    b=>{b.choices[0].domain_hash='0'.repeat(64);},b=>{b.choices[0].site.node='999';},
    b=>{b.choices[0].site.occurrence='1';},b=>{b.choices[0].scheduler_epoch='1';},b=>{b.choices[0].selected.task='1';},
    b=>{b.choices[0].kind='AdvanceTime';},b=>{b.choices[0].run_id='different';},
    b=>{b.choices[0].index='01';},b=>{b.choices[0].extra=null;}];
  for(const mutate of mutations) {const changed=clone(bundle);mutate(changed);assert.throws(()=>replay(machine(),reference,identity,changed),ReplayDiverged);}
});
test('trace and final boundary are checked independently of choices',()=>{
  const {identity,bundle}=make();
  for(const mutate of [b=>b.steps.pop(),b=>b.steps.push(clone(b.steps[0])),b=>{b.steps[0].after='Terminal';},
    b=>{b.footer.candidate_state_hash='0'.repeat(64);},b=>{b.footer.kind='BudgetExhausted';},
    b=>{b.footer.outcome=['Ok',['int','1']];},b=>{b.extra=true;}]) {
    const changed=clone(bundle);mutate(changed);assert.throws(()=>replay(machine(),reference,identity,changed),ReplayDiverged);
  }
});
test('source/runtime/artifact/input/catalog/profile drift is incompatible',()=>{
  const {identity,bundle}=make();
  for(const key of ['oracle_source_hash','candidate_hash','compiler_runtime_hash','artifact_hash','input_hash','catalog_hash','environment_hash','monitor_hash','adapter_hash']) {
    const current=clone(identity);current[key]='0'.repeat(64);assert.throws(()=>replay(machine(),reference,current,bundle),ReplayIncompatible);
  }
  const current=clone(identity);current.profile='other';assert.throws(()=>replay(machine(),reference,current,bundle),ReplayIncompatible);
  const changed=clone(reference);changed[0].depth='9';assert.throws(()=>replay(machine(),changed,identity,bundle),ReplayIncompatible);
});
test('repaired-candidate scenario is not exact original-candidate replay',()=>{
  const {bundle}=make(true), repaired=machine(), identity=header(repaired);
  assert.throws(()=>replay(repaired,reference,identity,bundle),ReplayIncompatible);
});
test('budget footer replays Exact but cannot become admitted completion',()=>{
  for(const fuel of [0,10]) {
    const {identity,bundle}=make(false,fuel);assert.equal(bundle.footer.kind,'BudgetExhausted');
    const result=replay(machine(),reference,identity,bundle);assert.equal(result.replay,'Exact');
    assert.equal(result.conformance,'Unknown');assert.equal(result.execution,'BudgetExhausted');
  }
});
test('complete candidate state includes saved environments and semantic values',()=>{
  const a=machine(), b=machine();assert.equal(candidateStateHash(a),candidateStateHash(b));
  b.env.set('1',['int','7']);assert.notEqual(candidateStateHash(a),candidateStateHash(b));
});
