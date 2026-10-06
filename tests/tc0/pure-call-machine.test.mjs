import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
const base=()=>JSON.parse(readFileSync(new URL('../../fixtures/tc0/pure-call-forward.json',import.meta.url)));
const run=a=>{const v=validatePureCallArtifact(encode(a),['int','0']);return new PureCallMachine(v.artifact,v.input).run();};
test('hand-derived tail forward call:13 distinct staged steps, no Return frame',()=>{const r=run(base());assert.deepEqual(r.outcome,['Ok',['int','1']]);assert.deepEqual(r.steps.map(s=>[s.after,s.depth]),[['Eval','1'],['Value','1'],['Ready','0'],['Eval','0'],['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]);});
test('non-tail named call retains caller destination, consumes Return separately',()=>{const a=base();a.functions[0].body=['prim','9','add',a.functions[0].body,['int','10','2']];for(const id of ['9','10'])a.source_map.push({id,file:'hand',line:'0',column:'0'});const r=run(a);assert.deepEqual(r.outcome,['Ok',['int','3']]);assert.equal(r.steps.filter(s=>s.site.rule==='ReturnReturn').length,1);assert.ok(r.steps.some(s=>s.depth==='3'));});
test('completion at final allowed step, shorter budget remains incomplete',()=>{const a=base(),m=new PureCallMachine(a,['int','0']);assert.equal(m.run(12).execution,'BudgetExhausted');assert.equal(m.run(1).execution,'Completed');assert.throws(()=>m.step());});
for(const c of cases)test('integrated hand '+c.name,()=>{
 const r=run(c.program);assert.equal(r.execution,'Completed');assert.deepEqual(r.outcome,c.expected_outcome);
 if(c.expected_return_frames!==undefined)assert.equal(r.steps.filter(s=>s.site.rule==='ReturnReturn').length,Number(c.expected_return_frames));
 if(c.maximum_depth!==undefined)assert.ok(Math.max(...r.steps.map(s=>Number(s.depth)))<=Number(c.maximum_depth));
 if(c.expected_descriptor_count!==undefined)assert.equal(r.descriptors.length,Number(c.expected_descriptor_count));
 if(c.expected_emissions!==undefined)assert.deepEqual(r.events.filter(e=>e.kind==='Emit').map(e=>e.label),c.expected_emissions);
 for(const d of r.descriptors){assert.deepEqual(Object.keys(d).sort(),['capture_support','captures','code_id']);assert.deepEqual(d.capture_support,[]);}
});
test('returned descriptor alias is captured once and keeps immutable lexical value7',()=>{const r=run(cases.find(c=>c.name==='returned-closure-alias').program);assert.deepEqual(r.descriptors[0].captures.map(([,v])=>v),[['int','7']]);});
test('captured higher-order descriptor retains full empty-support nested descriptor',()=>{const r=run(cases.find(c=>c.name==='higher-order-captured-closure').program);assert.deepEqual(r.descriptors[1].captures[0][1],r.descriptors[0]);assert.deepEqual(r.descriptors[1].captures[0][1].capture_support,[]);});
