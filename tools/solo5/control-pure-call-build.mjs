#!/usr/bin/env node
// Build step for the host-controlled pure-call check (harness/solo5-control.shen). Writes,
// into one fresh directory under build/solo5/control-pure-call/, two guest images over
// the same batch of validated programs:
//   guest.spt    the existing free-running guest (backends/solo5/pure-call/guest.c),
//                unchanged, used only to cross-check the controlled runs
//   control.spt  the host-controlled guest (control.c), protocol
//                fenrir.solo5.pure-call-control/1 over two stock net devices
// plus artifacts/<i>.json, each program's canonical artifact bytes (the bytes whose
// SHA-256 the guest embeds and the Init request must name), and batch.json.
// It makes no semantic decision and runs no comparison: generating, validating and
// lowering programs is still JavaScript, as for the free-run check.
//
//   node tools/solo5/control-pure-call-build.mjs [--stride 25] [--solo5 DIR]
//
// Scope: the TC0-A hand cases (/1 and /2: calls, closures, data), the TC1 handler
// fixtures (both slices), and every STRIDE-th program of the 5-node exhaustive grammar
// (indices 0, STRIDE, 2*STRIDE, ...), declared in batch.json.
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {defaultSolo5, toolchain, must, SOLO5_COMMIT} from './freerun.mjs';
import {buildGuest} from './freerun-pure-call.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
import {cases as callHand} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlerCases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {enumeratePureData} from '../tc0/pure-data-enumerate.mjs';

const root=resolve(import.meta.dirname,'../..');
const FUEL=200,INPUT=['int','0'],EXHAUSTIVE_NODES=5;
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

// Identity data for the controlled guest only: each program's artifact SHA-256 and schema.
export function controlHeader(lowered,checked) {
  const quote=(s,pattern)=>{if(typeof s!=='string'||!pattern.test(s))throw new Error('Unsupported identity spelling '+s);return JSON.stringify(s);};
  if(lowered.artifact_sha256.length!==checked.length)throw new Error('Program identity count mismatch');
  return '/* Program identities for the controlled guest. DATA ONLY. */\n'+
    `static const char *const pc_program_sha256[]={${lowered.artifact_sha256.map(s=>quote(s,/^[0-9a-f]{64}$/)).join(',')}};\n`+
    `static const char *const pc_program_schema[]={${checked.map(c=>quote(c.artifact.schema_version,/^[A-Za-z0-9._\/-]{1,63}$/)).join(',')}};\n`;
}

// Record what the PR10 toolchain actually checked, not a presumed Nix store origin.
export function controlToolchain(solo5=defaultSolo5()) {
  const tools=toolchain(resolve(solo5),'spt');
  return {...tools,identity:{source:tools.solo5_source,path:tools.solo5_path,
    commit:SOLO5_COMMIT,triple:tools.triple,tender_sha256:tools.tender_sha256}};
}

export function buildControlGuest(tools,header,identities,dir,{durable=false}={}) {
  mkdirSync(dir,{recursive:true});
  writeFileSync(resolve(dir,'data.h'),header);
  writeFileSync(resolve(dir,'control-data.h'),identities);
  writeFileSync(resolve(dir,'control-manifest.json'),
    '{"type":"solo5.manifest","version":1,"devices":[{"name":"ctlin","type":"NET_BASIC"},{"name":"ctlout","type":"NET_BASIC"}]}\n');
  const source=resolve(root,'backends/solo5/pure-call');
  for(const file of ['control.c','machine.c','machine.h','format.c'])copyFileSync(resolve(source,file),resolve(dir,file));
  for(const unit of ['control','machine','format'])
    must(tools.cc,['-std=c11','-O1','-Wall','-Wextra','-Werror',...(durable?['-DFGC_V2']:[]),'-I.','-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  must(tools.elftool,['gen-manifest','control-manifest.json','control-manifest.c'],{cwd:dir});
  must(tools.cc,['-c','control-manifest.c','-o','control-manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi=spt','control-manifest.o','control.o','machine.o','format.o','-o','control.spt'],{cwd:dir});
  return resolve(dir,'control.spt');
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const stride=Number(option('--stride','25'));
  if(!Number.isSafeInteger(stride)||stride<1||stride>10000)throw new Error('--stride must be 1..10000');
  const tools=controlToolchain(option('--solo5',undefined));
  const out=resolve(root,'build/solo5/control-pure-call',`${Date.now()}-${process.pid}`);
  const exhaustive=enumeratePureData(EXHAUSTIVE_NODES,{maxCases:8000});
  if(exhaustive.truncated)throw new Error('Exhaustive family truncated');
  const sample=exhaustive.cases.filter((_,i)=>i%stride===0);
  const families={hand:[...callHand,...dataHand],'tc1-handlers':[...handlerCases,...resumptionCases],[`exhaustive-${EXHAUSTIVE_NODES}-sample`]:sample};
  const programs=Object.entries(families).flatMap(([family,cases])=>cases.map(c=>({family,name:c.name,program:c.program,input:INPUT})));
  const lowered=lowerBatch(programs);
  const checked=programs.map(p=>validatePureCallArtifact(encode(p.program),p.input));
  const guest=buildGuest(tools,lowered.header,out);
  const control=buildControlGuest(tools,lowered.header,controlHeader(lowered,checked),out);
  mkdirSync(resolve(out,'artifacts'),{recursive:true});
  checked.forEach((c,i)=>{
    const bytes=encode(c.artifact);
    if(sha(bytes)!==lowered.artifact_sha256[i])throw new Error('Artifact identity drift');
    writeFileSync(resolve(out,'artifacts',`${i}.json`),bytes);
  });
  writeFileSync(resolve(out,'batch.json'),JSON.stringify({
    schema:'fenrir.solo5.control-pure-call-batch/1',
    guest,control,tender:tools.tender,solo5_identity:tools.identity,
    guest_sha256:sha(readFileSync(guest)),control_sha256:sha(readFileSync(control)),tender_sha256:tools.tender_sha256,
    batch_sha256:lowered.batch_sha256,fuel:String(FUEL),count:String(programs.length),
    sample:{grammar:`pure-data exhaustive, ${EXHAUSTIVE_NODES} nodes`,population:String(exhaustive.cases.length),stride:String(stride),selected:String(sample.length)},
    families:Object.fromEntries(Object.entries(families).map(([family,cases])=>[family,String(cases.length)])),
    programs:programs.map((p,i)=>({family:p.family,name:p.name,schema:checked[i].artifact.schema_version,artifact_sha256:lowered.artifact_sha256[i]}))})+'\n');
  console.log(out);
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
