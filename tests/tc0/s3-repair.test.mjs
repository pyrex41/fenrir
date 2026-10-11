// S3 packet tooling. Scripted reference traces are UNIT tests, NOT Shen evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync,mkdirSync,mkdtempSync,rmSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import {makeDefective} from '../../tools/tc0/s3-defect.mjs';
import {generatePureData} from '../../tools/tc0/pure-data-generate.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const source=readFileSync(new URL('../../runtime/tc0/pure-call-machine.mjs',import.meta.url),'utf8');
const sha=b=>createHash('sha256').update(b).digest('hex');

test('defective original is exactly the arm-by-position mutant with no trace of the option',async()=>{
 const defective=makeDefective(source);assert.doesNotMatch(defective,/armByPosition|arm_by_position|[Mm]utant/);
 const parent=resolve('build/tc0');mkdirSync(parent,{recursive:true});const dir=mkdtempSync(resolve(parent,'s3-defect-'));
 try{
  const file=resolve(dir,'defective.mjs');writeFileSync(file,defective);
  const {PureCallMachine:Defective}=await import(pathToFileURL(file).href);
  for(const c of generatePureData().cases)assert.deepEqual(new Defective(c.program,['int','0']).run(200),new PureCallMachine(c.program,['int','0'],{armByPosition:true}).run(200),c.name);
 }finally{rmSync(dir,{recursive:true,force:true});}
 assert.throws(()=>makeDefective(source.replace('armByPosition=false','armByPosition=true')),/changed shape/);
});

test('s3-replay: defective original stops at the recorded divergence; repairs must be Admitted',async()=>{
 const parent=resolve('build/tc0');mkdirSync(parent,{recursive:true});const dir=mkdtempSync(resolve(parent,'s3-replay-'));
 try{
  const defective=resolve(dir,'defective.mjs');writeFileSync(defective,makeDefective(source));
  const c=generatePureData().cases[12],reference=new PureCallMachine(c.program,['int','0']).run(200),mutant=new PureCallMachine(c.program,['int','0'],{armByPosition:true}).run(200);
  const k=reference.steps.findIndex((s,i)=>JSON.stringify(s)!==JSON.stringify(mutant.steps[i]));
  const bundle={schema:'tc0-s3-failure-bundle/1',defective_candidate_sha256:sha(readFileSync(defective)),candidate_path:'runtime/tc0/pure-call-machine.mjs',
   failures:[{label:'unit',program:c.program,input:['int','0'],model_steps:reference.steps,model_outcome:reference.outcome,first_divergence_epoch:String(k)}]};
  const file=resolve(dir,'bundle.json');writeFileSync(file,JSON.stringify(bundle));let serial=0;
  const go=(candidate,mode)=>spawnSync(process.execPath,['tools/tc0/s3-replay.mjs',file,candidate,mode,resolve(dir,`out-${serial++}.json`)],{encoding:'utf8',timeout:10000});
  const reference_candidate=resolve('runtime/tc0/pure-call-machine.mjs');
  let r=go(defective,'original');assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout).cases[0].epoch,String(k));
  r=go(reference_candidate,'repaired');assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout).cases[0].conformance,'Admitted');
  assert.notEqual(go(reference_candidate,'original').status,0);assert.notEqual(go(defective,'repaired').status,0);
  bundle.failures[0].first_divergence_epoch=String(k+1);writeFileSync(file,JSON.stringify(bundle));assert.notEqual(go(defective,'original').status,0);
 }finally{rmSync(dir,{recursive:true,force:true});}
});
