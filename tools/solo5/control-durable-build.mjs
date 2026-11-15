#!/usr/bin/env node
// Build step for the host-controlled TC1-D1 check (harness/solo5-durable.shen): one
// guest image of protocol fenrir.solo5.pure-call-control/2 (control.c built with
// -DFGC_V2) over a batch of validated durable programs, each with its entry input and
// the host replies the harness will give it. Writes, into one fresh directory under
// build/solo5/control-durable/:
//   control.spt          the v2 guest
//   artifacts/<i>.json   each program's canonical artifact bytes
//   batch.json           identities, inputs and replies (fenrir.solo5.control-durable-batch/1)
// It makes no semantic decision and runs no comparison.
//
//   node tools/solo5/control-durable-build.mjs [--programs FILE.json] [--solo5 DIR]
//
// Default programs: the TC1-D1 hand fixtures (fixtures/tc1/durable-hand-cases.mjs).
// FILE.json: {"family": NAME, "programs": [{name, program, input, replies}...]}, for
// example the service sample written by harness/service-fenrir.shen; an optional "fuel"
// member (1 to 100000, the guest's limit) replaces the default step budget of 200 for the
// whole batch (the A4 migration program runs longer than 200 steps). The free-running
// guest is not built: it has no host and refuses residual programs (v2 section 6).
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {toolchain, must} from './freerun.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {controlHeader} from './control-pure-call-build.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
import {cases as durableCases} from '../../fixtures/tc1/durable-hand-cases.mjs';

const root=resolve(import.meta.dirname,'../..');
const FUEL=200;
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

function build(tools,header,identities,dir) {
  mkdirSync(dir,{recursive:true});
  writeFileSync(resolve(dir,'data.h'),header);
  writeFileSync(resolve(dir,'control-data.h'),identities);
  writeFileSync(resolve(dir,'control-manifest.json'),
    '{"type":"solo5.manifest","version":1,"devices":[{"name":"ctlin","type":"NET_BASIC"},{"name":"ctlout","type":"NET_BASIC"}]}\n');
  const source=resolve(root,'backends/solo5/pure-call');
  for(const file of ['control.c','machine.c','machine.h','format.c'])copyFileSync(resolve(source,file),resolve(dir,file));
  for(const unit of ['control','machine','format'])
    must(tools.cc,['-std=c11','-O1','-Wall','-Wextra','-Werror','-DFGC_V2','-I.','-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  must(tools.elftool,['gen-manifest','control-manifest.json','control-manifest.c'],{cwd:dir});
  must(tools.cc,['-c','control-manifest.c','-o','control-manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi=spt','control-manifest.o','control.o','machine.o','format.o','-o','control.spt'],{cwd:dir});
  return resolve(dir,'control.spt');
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const file=option('--programs',null);
  const given=file?JSON.parse(readFileSync(resolve(file),'utf8')):null;
  const family=given?given.family:'tc1-durable';
  const fuel=given&&given.fuel!==undefined?Number(given.fuel):FUEL;
  if(!Number.isSafeInteger(fuel)||fuel<1||fuel>100000)throw new Error('fuel must be 1 to 100000');
  const programs=(given?given.programs:durableCases).map(c=>({family,name:c.name,program:c.program,input:c.input,replies:c.replies}));
  if(!programs.length||programs.length>4096)throw new Error('1 to 4096 programs');
  const tools=toolchain(option('--solo5',null));
  const out=resolve(root,'build/solo5/control-durable',`${Date.now()}-${process.pid}`);
  const lowered=lowerBatch(programs,{bindInputs:true});
  const checked=programs.map(p=>validatePureCallArtifact(encode(p.program),p.input));
  const control=build(tools,lowered.header,controlHeader(lowered,checked),out);
  mkdirSync(resolve(out,'artifacts'),{recursive:true});
  checked.forEach((c,i)=>{
    const bytes=encode(c.artifact);
    if(sha(bytes)!==lowered.artifact_sha256[i])throw new Error('Artifact identity drift');
    writeFileSync(resolve(out,'artifacts',`${i}.json`),bytes);
  });
  writeFileSync(resolve(out,'batch.json'),JSON.stringify({
    schema:'fenrir.solo5.control-durable-batch/1',
    guest:control,control,tender:tools.tender,solo5_identity:tools.identity,
    guest_sha256:sha(readFileSync(control)),control_sha256:sha(readFileSync(control)),tender_sha256:tools.tender_sha256,
    batch_sha256:lowered.batch_sha256,fuel:String(fuel),count:String(programs.length),
    families:{[family]:String(programs.length)},
    programs:programs.map((p,i)=>({family:p.family,name:p.name,schema:checked[i].artifact.schema_version,artifact_sha256:lowered.artifact_sha256[i],
      input_sha256:lowered.input_sha256[i],input:checked[i].input,replies:p.replies}))})+'\n');
  console.log(out);
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
