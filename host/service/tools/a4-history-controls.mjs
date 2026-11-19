// Closed evidence boundary for the sequential worker fixture. The Shen checker
// judges histories; this driver checks the full expected denominator and verdicts.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';

const [mode,out]=process.argv.slice(2);
const source=join(out,'history.json');
const h=JSON.parse(readFileSync(source,'utf8'));
const copy=()=>structuredClone(h);
const mutations=[
  ['wrong-pin','rejected',4,x=>x.events[4][2][1]='0'.repeat(256)],
  ['recorder-gap','indeterminate',16,x=>x.events.push(['gap','observer unavailable'])],
  ['missing-post-install','indeterminate',5,x=>x.events.splice(6,1)],
  ['receipt-rewritten','rejected',10,x=>x.events[10][4][1].push(2)],
  ['wrong-unavailability','rejected',10,x=>x.events[10][4]=['unavailable']],
  ['pending-lost','rejected',6,x=>x.events[6][1][0][1]=[]],
  ['unverified-fault','rejected',16,x=>x.events.push(['fault','claimed-only'])],
];
const rows=[[source,'accepted',null],...mutations.map(([n,v,i])=>[join(out,`${n}.json`),v,i])];
if(mode==='fixtures'){
  for(const [name,, ,alter] of mutations){
    const x=copy();
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
  const report={schema:'fenrir.host.a4-worker-check/1',status:'development-pass',qualification:'UNKNOWN',
    evidence:'one observed sequential upgrade; no crash campaign',worker,verdicts:actual};
  writeFileSync(join(out,'report.json'),JSON.stringify(report)+'\n',{flag:'wx'});
  console.log(JSON.stringify(report));
}else{
  throw new Error(`unexpected mode ${mode}`);
}
