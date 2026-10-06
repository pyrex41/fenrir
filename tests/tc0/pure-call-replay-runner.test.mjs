// Mock source/report transport tests only; no independent oracle credit.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync,existsSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
test('integrated runner mock admission, required identities and stale inputs fail closed',()=>{
 const root=resolve('.'),parent=resolve('build/tc0');mkdirSync(parent,{recursive:true});const dir=mkdtempSync(resolve(parent,'pure-call-replay-unit-'));
 try {
  // Deliberately fake toolchain files exercise identity framing, NOT Shen execution.
  mkdirSync(resolve(dir,'bin'));const shen=resolve(dir,'bin/shen-scheme'),boot=resolve(dir,'shen.boot');writeFileSync(shen,'mock unit toolchain');writeFileSync(boot,'mock boot');
  const paths=['tools/check-tc0-pure-call.py','tools/check-tc0-expression.py','tools/tc0/run-pure-call.mjs','tools/tc0/pure-call-artifact.mjs','tools/tc0/canonical.mjs','models/tc0/pure-call-machine.shen','models/tc0/arithmetic.shen','runtime/tc0/pure-call-machine.mjs','spec/tc0/pure-call-demo.json','fixtures/tc0/pure-call-forward.json','fixtures/tc0/pure-call-hand-cases.mjs','tests/tc0/pure-call-machine.test.mjs','tests/tc0/pure-call-artifact.test.mjs'].map(p=>resolve(root,p));
  const program=JSON.parse(readFileSync('fixtures/tc0/pure-call-forward.json'));
  const report={qualification:'UNKNOWN',scope:'Mock unit transport only',sources:Object.fromEntries([...paths,process.execPath,shen,boot].map(p=>[p,digest(p)])),cases:[{name:'mock-unit-only',program,input:['int','0'],model_steps:new PureCallMachine(program,['int','0']).run().steps}]};
  const input=resolve(dir,'input.json'),output=resolve(dir,'output.json');
  const run=(r=report,out=output)=>{writeFileSync(input,JSON.stringify(r));return spawnSync(process.execPath,['tools/tc0/check-pure-call-replay.mjs',input,out],{timeout:10000,encoding:'utf8'});};
  let r=run();assert.ifError(r.error);assert.equal(r.status,0,r.stderr);const saved=readFileSync(output);
  const result=JSON.parse(saved);assert.equal(result.qualification,'UNKNOWN');assert.equal(result.cases[0].result.replay,'Exact');assert.ok(Array.isArray(result.sources));
  r=run(report,input);assert.notEqual(r.status,0);assert.deepEqual(JSON.parse(readFileSync(input)),report);
  for(const mutate of [
   x=>delete x.sources[resolve('models/tc0/pure-call-machine.shen')],
   x=>delete x.sources[process.execPath],x=>delete x.sources[shen],x=>delete x.sources[boot],
   x=>x.sources[resolve('models/tc0/pure-call-machine.shen')]='0'.repeat(64),
   x=>x.qualification='PASS',x=>x.cases=[],x=>x.cases.push(x.cases[0]),
   x=>x.cases[0].program.schema_version='pure-closure-demo/1',
   x=>x.cases[0].model_steps[0].depth='99'
  ]){const bad=structuredClone(report);mutate(bad);r=run(bad);assert.notEqual(r.status,0,r.stderr);assert.deepEqual(readFileSync(output),saved,'failed admission must not publish a replacement');}
  const absent=resolve(dir,'absent.json'),bad=structuredClone(report);bad.sources[shen]='0'.repeat(64);r=run(bad,absent);assert.notEqual(r.status,0);assert.equal(existsSync(absent),false);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
