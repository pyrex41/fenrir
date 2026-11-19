import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtempSync,rmSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const checker=fileURLToPath(new URL('../../tools/service/check-upgrade-sample.mjs',import.meta.url));
const scope=['2','1','2','2','2','1','1','1','4','1500000'];
const cleanGraph={complete:true,truncated:false,disabled_alphabet_steps:0,violations:[]};

test('A4 only boots a sample from the matching, complete refinement run',t=>{
  const out=mkdtempSync(join(tmpdir(),'fenrir-a4-sample-'));
  t.after(()=>rmSync(out,{recursive:true,force:true}));
  const bytes=JSON.stringify({family:'service-a4',fuel:'5000',programs:[{name:'run-0-migrate-v1-v2'}]});
  const sample=join(out,'service-upgrade-sample.json');
  const reportPath=join(out,'report.json');
  const report={
    schema:'fenrir.harness.service-upgrade-fenrir/1',status:'development-pass',qualification:'UNKNOWN',
    params:{tenants:2,keys:1,digests:2},
    budgets:{submits:2,deliveries:2,responses:1,crashes:1,dispatches:1,upgrade_steps:4},state_cap:1500000,
    a4_model:cleanGraph,refinement:{refines:true,same_graph_as_a4_model:true,exploration:cleanGraph,distinct_completed_runs:'1'},
    javascript_sample:{ran:true,sandboxed:true,runs:'1',agreeing_step_for_step:'1'},
    sample_sha256:createHash('sha256').update(bytes).digest('hex'),
  };
  const run=(body,args=scope)=>spawnSync(process.execPath,[checker,out,...args],{input:JSON.stringify(body),encoding:'utf8'});
  const expect=(body,status,args)=>{
    const r=run(body,args);
    assert.ifError(r.error);
    assert.equal(r.status,status,r.stderr);
  };
  writeFileSync(sample,bytes);
  writeFileSync(reportPath,JSON.stringify(report));
  expect(report,0);
  expect(report,1,['1',...scope.slice(1)]);
  expect({...report,unrecorded:true},1);
  for(const change of [
    {a4_model:{...cleanGraph,truncated:true}},
    {refinement:{...report.refinement,same_graph_as_a4_model:false}},
    {javascript_sample:{...report.javascript_sample,sandboxed:false}},
  ]){
    const mutated={...report,...change};
    writeFileSync(reportPath,JSON.stringify(mutated));
    expect(mutated,1);
  }
  writeFileSync(reportPath,JSON.stringify(report));
  const guest={
    schema:'fenrir.harness.solo5-durable/1',status:'development-pass',qualification:'UNKNOWN',
    protocol:'fenrir.solo5.pure-call-control/2',families:{'service-a4':'1'},fuel:'5000',
    programs:'1',programs_agreeing_with_model:'1',executions:{Completed:'1'},failures:[],
    replay:{tapes:'1',tapes_exact_on_every_boot:'1',cold_boots_per_tape:'1'},
  };
  expect(guest,0,['guest']);
  expect({...guest,replay:{...guest.replay,tapes_exact_on_every_boot:'0'}},1,['guest']);
  writeFileSync(sample,bytes+'\n');
  expect(report,1);
  expect(guest,1,['guest']);
});
