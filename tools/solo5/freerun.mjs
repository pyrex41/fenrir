#!/usr/bin/env node
// Development check: run TC0-A arithmetic artifacts inside a stock Solo5 spt
// guest and compare every reference step with the independent JS expression
// machine. No Docker, no KVM, no patched tender. NOT a TC0 or Solo5
// qualification: the host observes the run and does not control its steps,
// and the tender, toolchain and host kernel are trusted as built.
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync, copyFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {isDeepStrictEqual} from 'node:util';
import {lower, dataHeader} from './native-arithmetic/lower.mjs';
import {generate} from '../tc0/generate.mjs';
import {encode} from '../tc0/canonical.mjs';
import {validateArtifact} from '../tc0/artifact.mjs';
import {ExpressionMachine} from '../../runtime/tc0/expression-machine.mjs';

export const SOLO5_COMMIT='38e0c348be231a2a3c59510a5caabf562792679f';
const root=resolve(import.meta.dirname,'../..');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const FUEL=200;

function run(exe,args,{cwd,timeout=60000}={}) {
  const r=spawnSync(exe,args,{cwd,timeout,maxBuffer:8*1024*1024,env:{PATH:process.env.PATH}});
  if(r.error||r.signal)throw new Error(`${exe}: ${r.error?.message||r.signal}`);
  return r;
}
function must(exe,args,options) {
  const r=run(exe,args,options);
  if(r.status!==0)throw new Error(`${exe} ${args.join(' ')} exited ${r.status}: ${r.stderr}${r.stdout}`);
  return r.stdout.toString();
}

// Strict frame reader. Tender banner lines are diagnostics; every FG line must be well formed.
export function frames(output) {
  const lines=output.split('\n'),result=[];
  for(let i=0;i<lines.length;i++) {
    if(!lines[i].startsWith('FG'))continue;
    const match=/^FGRUN\/1 (0|[1-9][0-9]*)$/.exec(lines[i]);
    if(!match||i+1>=lines.length)throw new Error('Invalid frame header');
    const payload=lines[++i];
    if(Buffer.byteLength(payload)!==Number(match[1]))throw new Error('Frame length mismatch');
    result.push(JSON.parse(payload));
  }
  return result;
}

export function toolchain(solo5) {
  if(must('git',['-C',solo5,'rev-parse','HEAD']).trim()!==SOLO5_COMMIT)throw new Error('Solo5 checkout is not the pinned commit');
  if(must('git',['-C',solo5,'status','--porcelain','--untracked-files=no']).trim())throw new Error('Solo5 checkout has modified tracked files');
  const bin=resolve(solo5,'toolchain/bin');
  const cc=readdirSync(bin).find(name=>name.endsWith('-solo5-none-static-cc'));
  if(!cc)throw new Error('Solo5 toolchain is not built');
  const prefix=cc.slice(0,-3);
  const tools={cc:resolve(bin,cc),ld:resolve(bin,prefix+'-ld'),elftool:resolve(solo5,'elftool/solo5-elftool'),tender:resolve(solo5,'tenders/spt/solo5-spt')};
  for(const path of Object.values(tools))if(!existsSync(path))throw new Error('Missing '+path);
  return {...tools,triple:prefix,tender_sha256:sha(readFileSync(tools.tender))};
}

export function build(tools,artifactBytes,dir) {
  mkdirSync(dir,{recursive:true});
  const data=lower(artifactBytes,['unit']);
  writeFileSync(resolve(dir,'data.h'),dataHeader(data));
  writeFileSync(resolve(dir,'manifest.json'),'{"type":"solo5.manifest","version":1,"devices":[]}\n');
  const source=resolve(root,'backends/solo5/native-arithmetic');
  for(const file of ['freerun.c','machine.c','machine.h','format.c','format.h'])copyFileSync(resolve(source,file),resolve(dir,file));
  for(const unit of ['freerun','machine','format'])
    must(tools.cc,['-std=c99','-Wall','-Wextra','-Werror',`-DNA_FUEL=${FUEL}`,'-I.','-c',unit+'.c','-o',unit+'.o'],{cwd:dir});
  must(tools.elftool,['gen-manifest','manifest.json','manifest.c'],{cwd:dir});
  must(tools.cc,['-c','manifest.c','-o','manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi=spt','manifest.o','freerun.o','machine.o','format.o','-o','guest.spt'],{cwd:dir});
  return {guest:resolve(dir,'guest.spt'),artifact_sha256:data.artifact_sha256,input_sha256:data.input_sha256};
}

export function execute(tools,built,mode) {
  const r=run(tools.tender,['--mem=16',built.guest,mode],{timeout:20000});
  if(r.status!==0)throw new Error(`Guest exited ${r.status}: ${r.stdout}${r.stderr}`);
  const all=frames(r.stdout.toString());
  const hello=all[0],terminal=all.at(-1);
  if(hello?.kind!=='Hello'||hello.artifact_sha256!==built.artifact_sha256||hello.input_sha256!==built.input_sha256)throw new Error('Guest identity mismatch');
  if(terminal?.kind!=='Terminal'||all.length<2)throw new Error('Missing terminal frame');
  return {execution:terminal.execution,steps:all.slice(1,-1)};
}

export function reference(artifactBytes,mode) {
  const graph=validateArtifact(artifactBytes,['unit']);
  const fn=graph.artifact.functions[0];
  const result=new ExpressionMachine(fn.body,fn.parameter_id,graph.input,{reverseOperands:mode==='mutant'}).run(FUEL);
  return {execution:result.execution,steps:result.steps,outcome:result.outcome};
}

function firstDivergence(a,b) {
  const n=Math.max(a.length,b.length);
  for(let i=0;i<n;i++)if(!isDeepStrictEqual(a[i],b[i]))return {epoch:String(i),guest:a[i]??null,candidate:b[i]??null};
  return null;
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const solo5=resolve(option('--solo5',resolve(root,'build/vendor/solo5')));
  const maxCases=Number(option('--max-cases','80'));
  if(!Number.isSafeInteger(maxCases)||maxCases<1||maxCases>400)throw new Error('--max-cases must be 1..400');
  const tools=toolchain(solo5);
  const out=resolve(root,'build/solo5/freerun',`${Date.now()}-${process.pid}`);
  const programs=[{name:'left-trap-fixture',bytes:readFileSync(resolve(root,'fixtures/tc0/left-trap-program.json'))}];
  for(const item of generate({maxCases}))programs.push({name:`generated-${programs.length-1}`,bytes:Buffer.from(encode(item.artifact))});
  const outcomes={},failures=[];let steps=0,mutantKilled=0,mutantSurvived=0;
  programs.forEach((program,index)=>{
    const built=build(tools,program.bytes,resolve(out,String(index)));
    const guest=execute(tools,built,'normal'),candidate=reference(program.bytes,'normal');
    const divergence=guest.execution!==candidate.execution?{epoch:'execution',guest:guest.execution,candidate:candidate.execution}:firstDivergence(guest.steps,candidate.steps);
    if(divergence)failures.push({program:program.name,mode:'normal',...divergence});
    steps+=guest.steps.length;
    const key=candidate.outcome.join(':');outcomes[key]=(outcomes[key]||0)+1;
    // Negative control: the guest's reverse-operand defect must be visible to this same comparison
    // whenever the JS candidate with the same injected defect differs from the normal candidate.
    const guestMutant=execute(tools,built,'mutant'),candidateMutant=reference(program.bytes,'mutant');
    if(firstDivergence(guestMutant.steps,candidateMutant.steps))failures.push({program:program.name,mode:'mutant',...firstDivergence(guestMutant.steps,candidateMutant.steps)});
    if(firstDivergence(guestMutant.steps,candidate.steps))mutantKilled++;else mutantSurvived++;
  });
  const report={schema:'fenrir.solo5.freerun-development/1',status:failures.length||!mutantKilled?'development-fail':'development-pass',
    qualification:'UNKNOWN',
    scope:'TC0-A arithmetic demo schema /1; stock spt tender; observed free run compared with the JS expression machine only; no Shen oracle run',
    solo5_commit:SOLO5_COMMIT,triple:tools.triple,tender_sha256:tools.tender_sha256,fuel:String(FUEL),
    programs:String(programs.length),reference_steps_compared:String(steps),outcomes,
    reverse_operand_mutant:{killed:String(mutantKilled),survived_equivalent:String(mutantSurvived)},failures};
  writeFileSync(resolve(out,'report.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
  if(report.status!=='development-pass')process.exitCode=1;
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
