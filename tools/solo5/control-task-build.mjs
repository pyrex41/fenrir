#!/usr/bin/env node
// Build step for the host-controlled TC1-C1 check (harness/solo5-tasks.shen): one guest
// image of protocol fenrir.solo5.pure-call-control/3 (control.c built with -DFGC_V3 and
// linked with tasks.c, which includes the unchanged handler machine) over a batch of
// validated tc1-task-demo/1 programs, each with the recorded schedules the harness will
// run it under. Writes, into one fresh directory under build/solo5/control-tasks/:
//   control.spt          the v3 guest
//   artifacts/<i>.json   each program's canonical artifact bytes
//   batch.json           identities and schedules (fenrir.solo5.control-task-batch/1)
// It makes no semantic decision and runs no comparison: a schedule policy is turned into
// an explicit list of choices exactly as tools/tc1/run-task-cases.mjs does for
// harness/tc1-tasks.shen, and the model then replays and checks every choice.
//
//   node tools/solo5/control-task-build.mjs [--stride 50] [--programs FILE.json]... [--solo5 DIR]
//
// Families: the 18 hand fixtures (fixtures/tc1/task-hand-cases.mjs) under every schedule
// tc1-tasks.shen runs them under; every STRIDE-th program of grammar G
// (tools/tc1/task-enumerate.mjs), declared in batch.json, whose witness schedules the
// harness takes from the exploration itself; and each FILE.json given,
// {"family": NAME, "programs": [{name, program, schedules?}...]} (default schedules:
// lowest, highest, fifo, random:1). Every program also carries its FIFO schedule, the one
// the guest's own FIFO policy must reproduce. The free-running guest is not built: it
// has no scheduler input and refuses task programs (v3 section 8).
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {must} from './freerun.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {controlHeader,controlToolchain} from './control-pure-call-build.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
import {scheduleFor,isProduction} from '../tc1/task-schedule.mjs';
import {enumerateTasks} from '../tc1/task-enumerate.mjs';
import {cases as handCases} from '../../fixtures/tc1/task-hand-cases.mjs';

const root=resolve(import.meta.dirname,'../..');
const FUEL=1000,INPUT=['int','0'];
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const DEFAULT=['lowest','highest','fifo','random:1'].map(policy=>({name:policy,policy}));

export function buildTaskGuest(tools,header,identities,dir) {
  mkdirSync(dir,{recursive:true});
  writeFileSync(resolve(dir,'data.h'),header);
  writeFileSync(resolve(dir,'control-data.h'),identities);
  writeFileSync(resolve(dir,'control-manifest.json'),
    '{"type":"solo5.manifest","version":1,"devices":[{"name":"ctlin","type":"NET_BASIC"},{"name":"ctlout","type":"NET_BASIC"}]}\n');
  const source=resolve(root,'backends/solo5/pure-call');
  for(const file of ['control.c','tasks.c','tasks.h','machine.c','machine.h'])copyFileSync(resolve(source,file),resolve(dir,file));
  for(const unit of ['control','tasks'])
    must(tools.cc,['-std=c11','-O1','-Wall','-Wextra','-Werror','-DFGC_V3','-I.','-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  must(tools.elftool,['gen-manifest','control-manifest.json','control-manifest.c'],{cwd:dir});
  must(tools.cc,['-c','control-manifest.c','-o','control-manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi=spt','control-manifest.o','control.o','tasks.o','-o','control.spt'],{cwd:dir});
  return resolve(dir,'control.spt');
}

// Explicit choice lists for a program under schedule specs, by the correct JS machine.
export function schedulesFor(artifact,specs) {
  return specs.map(spec=>({name:spec.name,production:isProduction(spec),choices:scheduleFor(artifact,INPUT,spec,FUEL).choices}));
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const all=name=>args.flatMap((a,i)=>a===name?[args[i+1]]:[]);
  const stride=Number(option('--stride','50'));
  if(!Number.isSafeInteger(stride)||stride<1||stride>10000)throw new Error('--stride must be 1..10000');
  const tools=controlToolchain(option('--solo5',undefined));
  const out=resolve(root,'build/solo5/control-tasks',`${Date.now()}-${process.pid}`);
  const family=enumerateTasks();
  const sample=family.cases.filter((_,i)=>i%stride===0);
  const programs=[
    ...handCases.map(c=>({family:'tc1-task-hand',name:c.name,program:c.program,specs:c.schedules})),
    ...sample.map(c=>({family:'tc1-task-small-sample',name:c.name,program:c.program,specs:[]}))];
  const families={'tc1-task-hand':String(handCases.length),'tc1-task-small-sample':String(sample.length)};
  for(const file of all('--programs')) {
    const given=JSON.parse(readFileSync(resolve(file),'utf8'));
    if(!/^[a-z0-9-]{1,64}$/.test(given.family)||families[given.family])throw new Error('Family name');
    families[given.family]=String(given.programs.length);
    for(const p of given.programs)programs.push({family:given.family,name:p.name,program:p.program,specs:p.schedules??DEFAULT});
  }
  if(programs.length>4096)throw new Error('At most 4096 programs');
  const checked=programs.map(p=>validatePureCallArtifact(encode(p.program),INPUT));
  const lowered=lowerBatch(programs.map(p=>({program:p.program,input:INPUT})),{tasks:true});
  const control=buildTaskGuest(tools,lowered.header,controlHeader(lowered,checked),out);
  mkdirSync(resolve(out,'artifacts'),{recursive:true});
  checked.forEach((c,i)=>{
    const bytes=encode(c.artifact);
    if(sha(bytes)!==lowered.artifact_sha256[i])throw new Error('Artifact identity drift');
    writeFileSync(resolve(out,'artifacts',`${i}.json`),bytes);
  });
  writeFileSync(resolve(out,'batch.json'),JSON.stringify({
    schema:'fenrir.solo5.control-task-batch/1',
    guest:control,control,tender:tools.tender,solo5_identity:tools.identity,
    guest_sha256:sha(readFileSync(control)),control_sha256:sha(readFileSync(control)),tender_sha256:tools.tender_sha256,
    batch_sha256:lowered.batch_sha256,fuel:String(FUEL),count:String(programs.length),
    sample:{grammar:'tools/tc1/task-enumerate.mjs grammar G',population:family.count,stride:String(stride),selected:String(sample.length)},
    families,
    programs:programs.map((p,i)=>({family:p.family,name:p.name,schema:checked[i].artifact.schema_version,artifact_sha256:lowered.artifact_sha256[i],
      schedules:schedulesFor(checked[i].artifact,p.specs),fifo:scheduleFor(checked[i].artifact,INPUT,{name:'fifo',policy:'fifo'},FUEL).choices}))})+'\n');
  console.log(out);
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
