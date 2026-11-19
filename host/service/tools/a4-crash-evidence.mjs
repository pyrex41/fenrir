// Campaign verdicts are not a grep or an interpretation of an exit code.
// Each planned file, real fault witness and adjudication is required.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {overlap,finalDrain,milestoneControls} from './a4-milestones.mjs';

const [mode,out,exit]=process.argv.slice(2);
const plan=[['node-v1','v1'],['node-prepared','prepared'],['node-migrated','migrated'],
  ['node-v2','v2'],['worker-v2-before-reply','worker']];
const file=n=>join(out,'runs',n,'history.json');
const read=p=>JSON.parse(readFileSync(p,'utf8'));
const rows=read(join(out,'crash-rows.json'));
const worker='worker-v2-before-reply';
const obsAfter=(x,i)=>x.events[i+1]?.[0]==='observe';
const controls=[
  ['missing-recovery-observation','indeterminate','node-prepared',(x,i)=>{x.events.splice(i+1,1);return i;}],
  ['missing-node-witness','indeterminate','node-migrated',(x,i)=>{x.events[i][4]=0;return i;}],
  ['outbox-survived-node','rejected','node-v2',(x,i)=>{x.events[i+2][0]='respond';return i+2;}],
  ['receipt-published-by-dead-worker','rejected',worker,(x,i)=>{x.events[i+2][0]='respond';return i+2;}],
  ['inconsistent-overlapping-retry','rejected',worker,(x,i)=>{x.events[i+4][1][1][4][1][4]++;return i+4;}],
  ['nested-recorder-gap','indeterminate',worker,(x,i)=>{x.events[i+4][1][1]=['gap','retry recorder lost'];return i+4;}],
];
const eligible=rows.length===plan.length&&rows.every((r,i)=>r.name===plan[i][0]&&r.status==='observed');
const expected=plan.map(([n])=>[file(n),null,null]);
if(mode==='fixtures'){
  if(eligible)for(const [name,verdict,base,mutate] of controls){
    const x=read(file(base));
    x.scenario=name;
    const index=mutate(x,rows.find(r=>r.name===base).proof.index);
    const target=join(out,`${name}.json`);
    writeFileSync(target,JSON.stringify(x),{flag:'wx'});
    expected.push([target,verdict,index]);
  }
  writeFileSync(join(out,'crash-controls.json'),JSON.stringify(expected),{flag:'wx'});
  writeFileSync(join(out,'crash-list.txt'),expected.map(([p])=>p).join('\n')+'\n',{flag:'wx'});
}else if(mode==='verify'){
  let verdicts=[];
  const errors=[];
  let evidenceControls=[];
  try{
    assert.equal(exit,'0','Shen verifier did not complete successfully');
    const output=readFileSync(join(out,'crash-verdicts.stdout'),'utf8');
    assert.equal(output,readFileSync(join(out,'crash-verifier','verdicts.jsonl'),'utf8'));
    verdicts=output.trim().split('\n').map(JSON.parse);
    const all=read(join(out,'crash-controls.json'));
    assert.deepEqual(all.slice(0,plan.length),expected);
    assert.equal(verdicts.length,all.length);
    const pilot=read(join(out,'report.json'));
    assert.equal(pilot.status,'development-pass');
    assert.equal(rows.length,plan.length);
    for(let i=0;i<plan.length;i++){
      const [n,phase]=plan[i], r=rows[i], v=verdicts[i];
      assert.equal(r.history,file(n)); assert.equal(v.history,file(n));
      assert.equal(r.name,n); assert.equal(r.phase,phase); assert.equal(v.scenario,n);
      assert.equal(v.schema,'fenrir.service.history/2');
      if(r.status==='unknown'){
        assert.equal(v.verdict,'indeterminate');
        errors.push(`${n}: recorder gap`);
        continue;
      }
      assert.equal(r.status,'observed');
      assert.equal(v.verdict,'accepted');
      const h=read(file(n)), p=r.proof;
      assert.equal(h.handler_pin,pilot.worker.handler_pin);
      assert.equal(h.migration_pin,pilot.worker.migration_pin);
      finalDrain(h,r.drain);
      assert.equal(obsAfter(h,p.index),true);
      const event=h.events[p.index];
      if(phase==='worker'){
        assert.match(p.worker,/^<\d+\.\d+\.\d+>$/); assert.match(p.replacement,/^<\d+\.\d+\.\d+>$/);
        assert.notEqual(p.worker,p.replacement); assert.equal(p.point,'w3_commit_before_reply');
        assert.equal(p.reason,'killed');
        assert.deepEqual(event,['submit-committed-unpublished',0,1,0,p.worker,p.replacement]);
        assert.deepEqual(h.events[p.index+3],['respond',['accepted',[0,0,1,0,0]]]);
        assert.equal(h.events[p.index+4][0],'concurrent');
        overlap(h,p.overlap,p.index+4,[p.replacement,p.peer]);
        evidenceControls=milestoneControls(h,p.overlap,p.index+4,[p.replacement,p.peer],r.drain);
      }else{
        assert(Number.isSafeInteger(p.before)&&p.before>0&&Number.isSafeInteger(p.after_pid)&&p.after_pid>0);
        assert.notEqual(p.before,p.after_pid);
        assert.equal(p.exit_status,137);
        assert.equal(p.phase,phase);
        assert.equal(p.witness,join(out,'runs',n,'node-sigkill'));
        assert.equal(readFileSync(p.witness,'utf8'),`a4_at_boundary kill_node ${p.before}`);
        assert.deepEqual(event,['crash','node',p.before,p.after_pid,137]);
        assert.equal(h.events[p.index-1][2][0],phase);
        assert.deepEqual(h.events[p.index+1],h.events[p.index-1]);
      }
    }
    assert(eligible,'one or more planned rows did not observe their fault');
    assert.equal(all.length,plan.length+controls.length);
    controls.forEach(([name,verdict,base,mutate],i)=>{
      const [path,wanted,index]=all[plan.length+i], v=verdicts[plan.length+i];
      assert.equal(path,join(out,`${name}.json`));
      assert.equal(wanted,verdict);
      assert.equal(index,mutate(read(file(base)),rows.find(r=>r.name===base).proof.index));
      assert.equal(v.history,path); assert.equal(v.scenario,name);
      assert.equal(v.schema,'fenrir.service.history/2'); assert.equal(v.verdict,verdict);
      assert.equal(v.first_inadmissible?.index,index);
    });
  }catch(e){errors.push(e.message);}
  const report={schema:'fenrir.host.a4-crash-campaign/1',status:errors.length?'UNKNOWN':'development-pass',
    qualification:'UNKNOWN',plan:plan.map(([n])=>n),rows,verdicts,errors,evidence_controls:evidenceControls,
    evidence:'durable phase boundary node SIGKILLs and a witnessed pre-reply worker kill; bounded concurrent retries'};
  writeFileSync(join(out,'crash-report.json'),JSON.stringify(report)+'\n',{flag:'wx'});
  console.log(JSON.stringify(report));
  if(errors.length)process.exitCode=1;
}else{
  throw new Error(`unexpected mode ${mode}`);
}
