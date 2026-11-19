// TC1-C1 loop-closure tooling (harness/tc1-task-loop.shen): the versioned task catalog
// and its pin, the generated family, the schedule-aware reducer, the retained failures
// and the tape tool. Development checks; the semantic comparisons are the harness's.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {generateTaskFamily} from '../../tools/tc1/task-generate.mjs';
import {taskReductions,switches} from '../../tools/tc1/task-reduce.mjs';
import {record,replay,TaskReplayRefused} from '../../tools/tc1/task-replay.mjs';
import {runSchedule} from '../../runtime/tc1/task-machine.mjs';
import {scheduleFor} from '../../tools/tc1/task-schedule.mjs';

const root=resolve(import.meta.dirname,'../..');
const INPUT=['int','0'];

test('the task catalog is versioned, its keys unique, and the harness pins its digest',()=>{
  const bytes=readFileSync(resolve(root,'spec/tc1/task-catalog.json'));
  const catalog=JSON.parse(bytes);
  assert.equal(catalog.version,'tc1-task-catalog/1');
  const keys=catalog.transitions.map(t=>t.key);
  assert.equal(new Set(keys).size,keys.length);
  assert.equal(keys.length,53);
  for(const t of catalog.transitions){
    assert.ok(Array.isArray(t.after)&&t.after.length,t.key);
    assert.equal(typeof t.scheduling_point,'boolean',t.key);
  }
  const pin=/\(define tl\.catalog-sha -> "([0-9a-f]{64})"\)/.exec(readFileSync(resolve(root,'harness/tc1-task-loop.shen'),'utf8'))[1];
  assert.equal(createHash('sha256').update(bytes).digest('hex'),pin);
});

test('the generated family is valid, deterministic and goes beyond grammar G',()=>{
  const a=generateTaskFamily({seed:1,count:40}),b=generateTaskFamily({seed:1,count:40});
  assert.equal(encode(a.cases.map(c=>c.program)).toString(),encode(b.cases.map(c=>c.program)).toString());
  const shapes=a.cases.flatMap(c=>c.shape.map(s=>s.split(':')[1]));
  for(const kind of ['scope','handler','abandon','trap','close','cancel','await'])assert.ok(shapes.includes(kind),kind);
  assert.ok(a.cases.some(c=>c.shape.some(s=>s.startsWith('3:'))),'some program has three children');
});

test('every reduction proposal validates, is smaller, and carries a schedule re-derived for it',()=>{
  const {program}=generateTaskFamily({seed:1,count:1}).cases[0];
  const {metric,proposals}=taskReductions(program,'fifo');
  assert.ok(proposals.length>10);
  for(const p of proposals.slice(0,40)){
    const {artifact,node_count}=validatePureCallArtifact(encode(p.program),INPUT);
    assert.ok(Number(node_count)<Number(metric.nodes)||(Number(node_count)===Number(metric.nodes)&&switches(p.choices)<Number(metric.switches)),p.rule);
    assert.deepEqual(p.choices,scheduleFor(artifact,INPUT,{name:p.policy,policy:p.policy},1000).choices,p.rule);
  }
});

test('retained failures: each defect has an original and a smaller minimized case',()=>{
  const r=JSON.parse(readFileSync(resolve(root,'fixtures/tc1/task-retained-failures.json'),'utf8'));
  const defects=[...new Set(r.cases.map(c=>c.defect))];
  assert.ok(defects.length>=3);
  for(const d of defects){
    const o=r.cases.find(c=>c.defect===d&&c.role==='original'),m=r.cases.find(c=>c.defect===d&&c.role==='minimized');
    assert.ok(o&&m,d);
    assert.ok(Number(m.nodes)<Number(o.nodes),d);
    validatePureCallArtifact(encode(m.program),INPUT);
  }
});

test('a tape binds its schedule: the same tape refuses another schedule',()=>{
  const {program}=generateTaskFamily({seed:1,count:1}).cases[0];
  const {choices}=scheduleFor(program,INPUT,{name:'lowest',policy:'lowest'},1000);
  const reference=runSchedule(program,INPUT,choices,{},1000).steps.map(s=>JSON.parse(JSON.stringify(s)));
  const tape=record(program,choices,reference,{test:true},{});
  assert.ok(['Completed','Deadlock'].includes(tape.footer.kind));
  assert.equal(replay(tape,program,choices,reference,{test:true},{}).replay,'Exact');
  const other=[...choices];other[other.length-1]=other.at(-1)==='0'?'1':'0';
  assert.throws(()=>replay(tape,program,other,reference,{test:true},{}),TaskReplayRefused);
  assert.equal(replay(record(program,[...choices,'0'],reference,{test:true},{}),
    program,[...choices,'0'],reference,{test:true},{}).conformance,'Unknown');
  assert.equal(record(program,choices,[...reference,reference.at(-1)],{test:true},{}).footer.kind,'UnconsumedSuffix');
  assert.throws(()=>replay({...tape,footer:{...tape.footer,kind:'Divergence'}},program,choices,reference,{test:true},{}),/Diverged:footer/);
  const options={eagerCancel:false};
  const withOption=record(program,choices,reference,{test:true},options);
  assert.throws(()=>replay(withOption,program,choices,reference,{test:true},{eagerCancel:true}),/Incompatible:options/);
  assert.throws(()=>replay({...tape,extra:1},program,choices,reference,{test:true},{}),/Incompatible:structure/);
});
