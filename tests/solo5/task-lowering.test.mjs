// TC1-C1 lowering for the v3 control guest (spec/solo5/pure-call-control-v3.md) and the
// v3 byte vectors' layout. No Solo5 needed; the guest itself is checked by
// harness/solo5-tasks.shen.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {lowerBatch,UnsupportedGuestProgram} from '../../tools/solo5/pure-call/lower.mjs';
import {cases} from '../../fixtures/tc1/task-hand-cases.mjs';
import {cases as handlerCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {cases as durableCases} from './durable-hand-cases.mjs';

const root=resolve(import.meta.dirname,'../..');
const INPUT=['int','0'];

test('task programs are refused for the free-running image and lowered for the v3 guest',()=>{
  const items=cases.map(c=>({program:c.program,input:INPUT}));
  assert.throws(()=>lowerBatch(items),UnsupportedGuestProgram);
  assert.throws(()=>lowerBatch(items),/v3 control guest/);
  const lowered=lowerBatch(items,{tasks:true});
  assert.equal(lowered.artifact_sha256.length,cases.length);
  assert.match(lowered.header,/static const unsigned pc_program_count=18;/);
});

test('the nine task forms lower to the tags appended to machine.h, a channel capacity to integer',()=>{
  const header=readFileSync(resolve(root,'backends/solo5/pure-call/machine.h'),'utf8');
  const tags=/enum pc_tag \{([^}]*)\}/.exec(header)[1].replace(/\/\*[^*]*\*\//g,'').split(',').map(s=>s.trim()).filter(Boolean);
  assert.deepEqual(tags.slice(20),['PC_SCOPE','PC_SPAWN','PC_AWAIT','PC_CANCEL','PC_YIELD','PC_CHANNEL','PC_SEND','PC_RECEIVE','PC_CLOSE']);
  const two=cases.find(c=>c.name==='two-tasks-one-channel');
  const {header:h}=lowerBatch([{program:two.program,input:INPUT}],{tasks:true});
  // channel(I64, 2): tag 25, no children, capacity in the integer column.
  assert.match(h,/\{25,UINT64_C\(\d+\),0,0,INT64_C\(2\),0,0,0,0,0,/);
});

test('v3 rejects legacy and durable artifacts without changing those adapters',()=>{
  const items=handlerCases.map(c=>({program:c.program,input:INPUT}));
  assert.ok(lowerBatch(items).header);
  assert.throws(()=>lowerBatch(items,{tasks:true}),/Expected a TC1-C1 task artifact/);
  assert.ok(lowerBatch(durableCases,{bindInputs:true,durable:true}).header);
  assert.throws(()=>lowerBatch(durableCases,{tasks:true}),/controlled v2 guest/);
  assert.throws(()=>lowerBatch(durableCases,{tasks:true,bindInputs:true,durable:true}),/separate adapters/);
});

test('v3 vectors: single frames, canonical sorted payloads, scheduler in Init',()=>{
  const lines=readFileSync(resolve(root,'spec/solo5/pure-call-control-v3.vectors'),'utf8').split('\n').filter(l=>l&&!l.startsWith('#'));
  assert.equal(lines.length,10);
  const sortedDeep=v=>Array.isArray(v)?v.every(sortedDeep):v&&typeof v==='object'?
    Object.keys(v).join()===Object.keys(v).sort().join()&&Object.values(v).every(sortedDeep):true;
  for(const line of lines) {
    const [name,role,,hex]=line.split(' ');
    const bytes=Buffer.from(hex,'hex'),head=bytes.subarray(0,26).toString('latin1');
    const m=/^FGC1 ([HG])([A-Z]) (\d{8}) (\d{8})\n$/.exec(head);
    assert.ok(m,name);
    const n=Number(m[4]);assert.equal(bytes.length,27+n,name);
    if(role==='reject')continue;
    const text=bytes.subarray(26,26+n).toString('latin1'),payload=JSON.parse(text);
    assert.equal(JSON.stringify(payload),text,`${name}: one spelling`);
    assert.ok(sortedDeep(payload),`${name}: keys sorted at every level`);
    if(payload.kind==='Init')assert.ok(['reference','fifo'].includes(payload.scheduler),name);
    if(payload.kind==='Steps'&&role==='steps')assert.equal(payload.execution==='Deadlock','wait_graph' in payload,`${name}: wait_graph exactly when Deadlock`);
  }
});
