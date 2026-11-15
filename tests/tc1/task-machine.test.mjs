// Unit tests of the JavaScript TC1-C1 task machine (runtime/tc1/task-machine.mjs), its
// schedule policies and the exhaustive-small enumerator. Contract: spec/tc1/CONCURRENCY.md.
import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {TaskMachine,ScheduleError,runSchedule,outcomeValue} from '../../runtime/tc1/task-machine.mjs';
import {scheduleFor,isProduction} from '../../tools/tc1/task-schedule.mjs';
import {TASK_MUTANTS} from '../../tools/tc1/task-defects.mjs';
import {enumerateTasks,templates} from '../../tools/tc1/task-enumerate.mjs';
import {cases} from '../../fixtures/tc1/task-hand-cases.mjs';

const checked=c=>validatePureCallArtifact(encode(c.program),['int','0']);
const named=name=>checked(cases.find(c=>c.name===name));

// Section 4 invariants, after every step: a queue never exceeds its capacity; senders wait
// only on a full queue and receivers only on an empty one; a waiter is Blocked.
function invariants(m,where) {
  for(const ch of m.channels.values()) {
    assert.ok(BigInt(ch.queue.length)<=ch.capacity,where+': queue within capacity');
    if(ch.senders.length)assert.equal(BigInt(ch.queue.length),ch.capacity,where+': senders wait on a full queue');
    if(ch.receivers.length)assert.equal(ch.queue.length,0,where+': receivers wait on an empty queue');
    for(const w of [...ch.senders,...ch.receivers])assert.equal(m.tasks.get(w.task).status,'Blocked',where+': a registered waiter is Blocked');
  }
  for(const a of m.awaits)assert.equal(m.tasks.get(a.waiter).status,'Blocked',where+': an awaiting task is Blocked');
}
function runChecked(k,choices,where) {
  const m=new TaskMachine(k.artifact,k.input);
  for(const id of choices){m.step(id);invariants(m,where);}
  return m;
}

test('every fixture runs to its all-schedules execution and outcome under lowest and FIFO', () => {
  for(const c of cases)for(const policy of ['lowest','fifo']) {
    const k=checked(c),{choices}=scheduleFor(k.artifact,k.input,{name:policy,policy});
    const r=runSchedule(k.artifact,k.input,choices);
    if(c.all.execution)assert.equal(r.execution,c.all.execution,`${c.name} ${policy}`);
    if(c.all.outcome)assert.deepEqual(r.outcome,c.all.outcome,`${c.name} ${policy}`);
  }
});
test('channel and await invariants hold after every step, for every fixture and schedule', () => {
  for(const c of cases)for(const spec of c.schedules) {
    const k=checked(c);runChecked(k,scheduleFor(k.artifact,k.input,spec).choices,`${c.name} ${spec.name}`);
  }
});
test('stepping a task that is not Runnable is a schedule error, never a fallback', () => {
  const k=named('two-tasks-one-channel'),m=new TaskMachine(k.artifact,k.input);
  assert.throws(()=>m.step('1'),ScheduleError,'no task 1 yet');
  const r=runSchedule(k.artifact,k.input,['0','7']);
  assert.equal(r.execution,'ScheduleDiverged');assert.equal(r.at,'1');assert.equal(r.steps.length,1);
  assert.equal(runSchedule(k.artifact,k.input,['0']).execution,'ScheduleIncomplete');
});
test('the root starts alone, over the frame of its implicit scope 0', () => {
  const k=named('two-tasks-one-channel'),m=new TaskMachine(k.artifact,k.input);
  assert.deepEqual(m.runnable(),['0']);
  const first=m.step('0');
  assert.equal(first.depth,'2','the implicit scope frame and the let frame');
  assert.equal(first.point,false);
});
test('FIFO and production-random schedules switch only after a scheduling point', () => {
  for(const c of cases)for(const spec of c.schedules.filter(isProduction)) {
    const k=checked(c),{steps}=scheduleFor(k.artifact,k.input,spec);
    for(let i=1;i<steps.length;i++)if(steps[i].task!==steps[i-1].task)
      assert.ok(steps[i-1].point||!steps[i-1].runnable.includes(steps[i-1].task),`${c.name} ${spec.name} epoch ${i}`);
  }
});
test('a reference schedule may switch after a pure step; random:1 does so on the fixtures', () => {
  let found=false;
  for(const c of cases){const k=checked(c),{steps}=scheduleFor(k.artifact,k.input,{name:'random:1',policy:'random:1'});
    for(let i=1;i<steps.length;i++)if(steps[i].task!==steps[i-1].task&&!steps[i-1].point&&steps[i-1].runnable.includes(steps[i-1].task))found=true;}
  assert.ok(found);
});
test('defects are off unless asked for, and each changes some fixture run', () => {
  const changed=new Set();
  for(const c of cases)for(const spec of c.schedules) {
    const k=checked(c),{choices}=scheduleFor(k.artifact,k.input,spec),base=JSON.stringify(runSchedule(k.artifact,k.input,choices));
    assert.equal(JSON.stringify(runSchedule(k.artifact,k.input,choices,{})),base);
    for(const [key,option] of Object.entries(TASK_MUTANTS)) {
      let r;try{r=JSON.stringify(runSchedule(k.artifact,k.input,choices,{[option]:true}));}catch{continue;}
      if(r!==base)changed.add(key);
    }
  }
  assert.deepEqual([...changed].sort(),Object.keys(TASK_MUTANTS).sort());
});
test('an awaited outcome is the task outcome as an Outcome value', () => {
  assert.deepEqual(outcomeValue(['Ok',['int','3']]),['data','Outcome','Ok',['int','3']]);
  assert.deepEqual(outcomeValue(['Cancelled']),['data','Outcome','Cancelled']);
  assert.deepEqual(outcomeValue(['Trap','DivZero']),['data','Outcome','Failed',['data','TrapCode','DivZero']]);
});
test('the exhaustive-small grammar G has the sizes its header derives, all valid and distinct', () => {
  const f=enumerateTasks();
  assert.equal(f.count,'3600');assert.deepEqual(f.counts_by_family,{'one-channel':'3024','two-channel':'576'});
  assert.equal(new Set(templates().map(t=>JSON.stringify(t))).size,3600);
  assert.equal(new Set(f.cases.map(c=>c.name)).size,3600);
});
test('enumerated programs keep the channel invariants under seeded reference schedules', () => {
  const f=enumerateTasks();
  for(const c of f.cases.filter((_,i)=>i%37===0))for(const seed of [1,2]) {
    const k=checked(c);runChecked(k,scheduleFor(k.artifact,k.input,{name:'r',policy:'random:'+seed}).choices,c.name);
  }
});
