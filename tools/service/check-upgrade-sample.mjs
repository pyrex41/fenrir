// Validate A4 evidence at the boundary between the refinement and Solo5 runners.
// A successful process exit is necessary but is not itself evidence.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {join} from 'node:path';

const [out,...args]=process.argv.slice(2);
try {
  const report=JSON.parse(readFileSync(0,'utf8'));
  const sampleBytes=readFileSync(join(out,'service-upgrade-sample.json'));
  const sample=JSON.parse(sampleBytes);
  const refinement=JSON.parse(readFileSync(join(out,'report.json'),'utf8'));
  assert.equal(refinement.sample_sha256,createHash('sha256').update(sampleBytes).digest('hex'));
  const size=sample.programs.length;
  const count=String(size);
  const names=sample.programs.map(p=>p.name);
  assert.equal(sample.family,'service-a4');
  assert.equal(sample.fuel,'5000');
  assert(size>0&&size<=4096);
  assert.equal(new Set(names).size,size);
  assert.equal(report.status,'development-pass');
  assert.equal(report.qualification,'UNKNOWN');
  if(args[0]==='guest'){
    assert.equal(report.schema,'fenrir.harness.solo5-durable/1');
    assert.equal(report.protocol,'fenrir.solo5.pure-call-control/2');
    assert.deepEqual(report.families,{'service-a4':count});
    assert.equal(report.fuel,sample.fuel);
    assert.equal(report.programs,count);
    assert.equal(report.programs_agreeing_with_model,count);
    assert.equal(report.executions.Completed,count);
    assert.deepEqual(report.failures,[]);
    assert.equal(report.replay.tapes,count);
    assert.equal(report.replay.tapes_exact_on_every_boot,count);
    assert.equal(report.replay.cold_boots_per_tape,'1');
  }else{
    assert.equal(report.schema,'fenrir.harness.service-upgrade-fenrir/1');
    assert.deepEqual(report,refinement);
    const scopeKeys=['tenants','keys','digests','submits','deliveries','responses','crashes','dispatches','upgrade_steps','state_cap'];
    const reported={...report.params,...report.budgets,state_cap:report.state_cap};
    assert.equal(args.length,scopeKeys.length);
    scopeKeys.forEach((key,i)=>assert.equal(reported[key],Number(args[i]),key));
    assert.equal(report.refinement.refines,true);
    assert.equal(report.refinement.same_graph_as_a4_model,true);
    for(const graph of [report.a4_model,report.refinement.exploration]){
      assert.equal(graph.complete,true);
      assert.equal(graph.truncated,false);
      assert.equal(graph.disabled_alphabet_steps,0);
      assert.deepEqual(graph.violations,[]);
    }
    assert.equal(report.refinement.distinct_completed_runs,count);
    assert.equal(report.javascript_sample.ran,true);
    assert.equal(report.javascript_sample.sandboxed,true);
    assert.equal(report.javascript_sample.runs,count);
    assert.equal(report.javascript_sample.agreeing_step_for_step,count);
  }
} catch (e) {
  console.error(`A4 evidence rejected: ${e.message}`);
  process.exitCode=1;
}
