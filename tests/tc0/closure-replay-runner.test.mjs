import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {ClosureMachine} from '../../runtime/tc0/closure-machine.mjs';
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
test('runner serializes path identities canonically and rejects drift/overwriting input',()=>{
 const root=resolve('.'),parent=resolve('build/tc0');mkdirSync(parent,{recursive:true});const dir=mkdtempSync(resolve(parent,'replay-unit-'));
 try {
  const program=JSON.parse(readFileSync('fixtures/tc0/closure-capture-program.json'));
  // Mock oracle transport fixture only, NOT independent model evidence.
  const report={qualification:'UNKNOWN',scope:'Mock runner unit fixture, no oracle credit',sources:Object.fromEntries(
   ['tools/check-tc0-closure.py','models/tc0/closure-machine.shen','runtime/tc0/closure-machine.mjs','spec/tc0/pure-closure-demo.json'].map(p=>[resolve(root,p),digest(p)])),
   cases:[{name:'mock-unit-only',program,model_steps:new ClosureMachine(program,['int','0']).run(200).steps}]};
  const input=resolve(dir,'input.json'),output=resolve(dir,'output.json');writeFileSync(input,JSON.stringify(report));
  const run=(out=output)=>spawnSync(process.execPath,['tools/tc0/check-closure-replay.mjs',input,out],{timeout:10000,encoding:'utf8'});
  let r=run();assert.ifError(r.error);assert.equal(r.status,0,r.stderr);
  const result=JSON.parse(readFileSync(output));assert.equal(result.qualification,'UNKNOWN');assert.equal(result.cases[0].result.replay,'Exact');
  assert.ok(Array.isArray(result.sources));
  r=run(input);assert.notEqual(r.status,0);assert.deepEqual(JSON.parse(readFileSync(input)),report);
  report.sources[resolve(root,'models/tc0/closure-machine.shen')]='0'.repeat(64);writeFileSync(input,JSON.stringify(report));
  r=run();assert.notEqual(r.status,0);assert.match(r.stderr,/drift/);
 } finally {rmSync(dir,{recursive:true,force:true});}
});
