// Scripted transport peers are UNIT tests, NOT independent Shen evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {generatePureCalls} from '../../tools/tc0/pure-call-generate.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
test('same-mutant failure replay transport rejects identity and observation drift without publication',()=>{
 const parent=resolve('build/tc0');mkdirSync(parent,{recursive:true});const dir=mkdtempSync(resolve(parent,'pure-call-failure-unit-'));
 try{
  mkdirSync(resolve(dir,'bin'));const shen=resolve(dir,'bin/shen-scheme'),boot=resolve(dir,'shen.boot');writeFileSync(shen,'mock unit only');writeFileSync(boot,'mock boot');
  const paths=['tools/check-tc0-pure-call-reduction.py','tools/check-tc0-pure-call.py','tools/check-tc0-expression.py','tools/tc0/pure-call-generate.mjs','tools/tc0/pure-call-reduce.mjs','tools/tc0/pure-call-campaign-bridge.mjs','tools/tc0/run-pure-call.mjs','tools/tc0/pure-call-artifact.mjs','tools/tc0/canonical.mjs','models/tc0/pure-call-machine.shen','models/tc0/arithmetic.shen','runtime/tc0/pure-call-machine.mjs','spec/tc0/pure-call-demo.json'].map(p=>resolve(p));
  const sources=Object.fromEntries([...paths,process.execPath,shen,boot].map(p=>[p,digest(p)]));
  const program=generatePureCalls(1).cases[0].program,input=['int','0'],candidate=new PureCallMachine(program,input).run(200),mutant=new PureCallMachine(program,input,{reverseOperands:true}).run(200);
  const row={name:'mock-unit-only',program,input,candidate,equivalent_control:candidate,mutant,model_steps:candidate.steps,hand_outcome:candidate.outcome,discrepancy:'reversed-emissions-same-outcome'};
  const report={schema:'pure-call-reduction-development/1',qualification:'UNKNOWN',cleanup:'confirmed',sources,sources_after:sources,observations:[row],original:row,minimized:row};
  const file=resolve(dir,'input.json');let serial=0;
  const run=(r,out=resolve(dir,'output-'+serial+++'.json'))=>{writeFileSync(file,JSON.stringify(r));const result=spawnSync(process.execPath,['tools/tc0/check-pure-call-failure-replay.mjs',file,out],{timeout:10000,encoding:'utf8'});assert.ifError(result.error);return {result,out};};
  const {result,out}=run(report);assert.equal(result.status,0,result.stderr);const saved=readFileSync(out),bundle=JSON.parse(saved);assert.equal(bundle.qualification,'UNKNOWN');assert.equal(bundle.cases.length,2);for(const c of bundle.cases){assert.equal(c.result.replay,'Exact');assert.equal(c.result.conformance,'Diverged');assert.equal(c.bundle.footer.kind,'Divergence');}
  const duplicate=run(report,out);assert.notEqual(duplicate.result.status,0);assert.deepEqual(readFileSync(out),saved);
  for(const mutate of [
   x=>delete x.sources[resolve('models/tc0/pure-call-machine.shen')],
   x=>delete x.sources[process.execPath],x=>delete x.sources[shen],x=>delete x.sources[boot],
   x=>x.sources[resolve('models/tc0/pure-call-machine.shen')]='0'.repeat(64),
   x=>x.qualification='PASS',x=>x.cleanup='unresolved',x=>x.observations=[],
   x=>x.original.model_steps[0].depth='999',x=>x.original.mutant=x.original.candidate,
   x=>x.original.equivalent_control.outcome=['Ok',['int','999']],
   x=>x.original.discrepancy='invented'
  ]){const bad=structuredClone(report);mutate(bad);const r=run(bad);assert.notEqual(r.result.status,0);assert.equal(existsSync(r.out),false);}
 }finally{rmSync(dir,{recursive:true,force:true});}
});
