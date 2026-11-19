// Closed evidence boundary for the sequential worker fixture. The Shen checker
// judges histories; this driver checks the full expected denominator and verdicts.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {overlap,finalDrain,milestoneControls} from './a4-milestones.mjs';

const [mode,out]=process.argv.slice(2);
const source=join(out,'history.json');
const ackPath=join(out,'cut-over-lost-ack.json');
const h=JSON.parse(readFileSync(source,'utf8'));
const ack=JSON.parse(readFileSync(ackPath,'utf8'));
const mutations=[
  ['wrong-pin','rejected',4,x=>x.events[4][2][1]='0'.repeat(256)],
  ['recorder-gap','indeterminate',h.events.length,x=>x.events.push(['gap','observer unavailable'])],
  ['missing-post-install','indeterminate',5,x=>x.events.splice(6,1)],
  ['receipt-rewritten','rejected',11,x=>x.events[11][4][1].push(2)],
  ['wrong-unavailability','rejected',11,x=>x.events[11][4]=['unavailable']],
  ['pending-lost','rejected',6,x=>x.events[6][1][0][1]=[]],
  ['unverified-fault','rejected',h.events.length,x=>x.events.push(['fault','claimed-only'])],
  ['cross-tenant-pair','rejected',17,x=>x.events[17][1][1][4][1][0]=0],
  ['outbox-lost-at-cutover','rejected',10,x=>x.events[10][0]='respond-refused'],
  ['lost-ack-called-rollback','rejected',6,x=>x.events[5][2]=['aborted'],ack],
];
const rows=[[source,'accepted',null],[ackPath,'accepted',null],
  ...mutations.map(([n,v,i])=>[join(out,`${n}.json`),v,i])];
if(mode==='fixtures'){
  for(const [name,, ,alter,input=h] of mutations){
    const x=structuredClone(input);
    alter(x);
    x.scenario=name;
    writeFileSync(join(out,`${name}.json`),JSON.stringify(x),{flag:'wx'});
  }
  writeFileSync(join(out,'history-list.txt'),rows.map(([p])=>p).join('\n')+'\n',{flag:'wx'});
}else if(mode==='verify'){
  const bytes=readFileSync(join(out,'verifier','verdicts.jsonl'),'utf8');
  assert.equal(readFileSync(join(out,'verdicts.stdout'),'utf8'),bytes);
  const actual=bytes.trim().split('\n').map(line=>JSON.parse(line));
  assert.equal(actual.length,rows.length);
  rows.forEach(([file,verdict,index],i)=>{
    const a=actual[i];
    assert.equal(a.history,file);
    assert.equal(a.schema,'fenrir.service.history/2');
    assert.equal(a.verdict,verdict);
    assert.equal(a.first_inadmissible?.index??null,index);
  });
  const worker=JSON.parse(readFileSync(join(out,'worker.json'),'utf8'));
  assert.equal(worker.status,'worker-fixture-pass');
  assert.equal(worker.qualification,'UNKNOWN');
  assert.equal(worker.handler_pin,h.handler_pin);
  assert.equal(worker.migration_pin,h.migration_pin);
  assert.equal(worker.v1_worker_retired,true);
  assert.equal(worker.front_outbox_preserved,true);
  assert.equal(worker.v2_worker_kill_observed,true);
  overlap(h,worker.overlap,17,worker.overlap.bank);
  finalDrain(h,worker.drain);
  finalDrain(ack,worker.ack_drain);
  assert.equal(worker.supervisor_restart_v2_only,true);
  assert.equal(worker.retired_v1_absent_on_restart,true);
  assert.equal(worker.cut_over_lost_ack_observed,true);
  const report={schema:'fenrir.host.a4-worker-check/1',status:'development-pass',qualification:'UNKNOWN',
    evidence:'supervised upgrade, concurrent pair, witnessed cut-over acknowledgement loss and worker kill; no node crash campaign',
    worker,verdicts:actual,evidence_controls:milestoneControls(h,worker.overlap,17,worker.overlap.bank,worker.drain)};
  writeFileSync(join(out,'report.json'),JSON.stringify(report)+'\n',{flag:'wx'});
  console.log(JSON.stringify(report));
}else{
  throw new Error(`unexpected mode ${mode}`);
}
