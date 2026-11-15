#!/usr/bin/env node
// Development check: run TC0-A pure-call programs (schemas /1 and /2: calls,
// closures, tuples, datatypes, match, bytes, eq) inside a stock Solo5 spt
// guest and compare every reference step with the independent JS pure-call
// machine. The comparison with the Shen model is done in Shen by
// harness/solo5-pure-call.shen (use --build-only here first). NOT a TC0 or Solo5
// qualification: the host observes a free run and does not control steps.
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {toolchain, frames, run, must, firstDivergence, SOLO5_COMMIT} from './freerun.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases as callHand} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {generatePureCalls} from '../tc0/pure-call-generate.mjs';
import {generatePureData} from '../tc0/pure-data-generate.mjs';
import {enumeratePureData} from '../tc0/pure-data-enumerate.mjs';
import {VALUES} from '../tc0/check-i64.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {cases as handlerCases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {enumerateHandlers} from '../tc1/handler-enumerate.mjs';

const root=resolve(import.meta.dirname,'../..');
const FUEL=200,CHUNK=250,INPUT=['int','0'];
const MODES={normal:{},'reverse-operands':{reverseOperands:true},'wrap-overflow':{wrapOverflow:true}};
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');

export function buildGuest(tools,header,dir) {
  mkdirSync(dir,{recursive:true});
  writeFileSync(resolve(dir,'data.h'),header);
  writeFileSync(resolve(dir,'manifest.json'),'{"type":"solo5.manifest","version":1,"devices":[]}\n');
  const source=resolve(root,'backends/solo5/pure-call');
  for(const file of ['guest.c','machine.c','machine.h','format.c'])copyFileSync(resolve(source,file),resolve(dir,file));
  for(const unit of ['guest','machine','format'])
    must(tools.cc,['-std=c11','-O1','-Wall','-Wextra','-Werror',`-DPC_FUEL=${FUEL}`,'-I.','-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  must(tools.elftool,['gen-manifest','manifest.json','manifest.c'],{cwd:dir});
  must(tools.cc,['-c','manifest.c','-o','manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi=spt','manifest.o','guest.o','machine.o','format.o','-o','guest.spt'],{cwd:dir});
  return resolve(dir,'guest.spt');
}

// Returns traces for programs [first,end): [{execution, steps}].
export function executeRange(tools,guest,batch,mode,first,end) {
  const r=run(tools.tender,['--mem=32',guest,`${mode} ${first} ${end}`],{timeout:120000});
  if(r.status!==0)throw new Error(`Guest exited ${r.status} in ${mode} ${first}..${end}: ${r.stdout.toString().slice(-600)}${r.stderr}`);
  const all=frames(r.stdout.toString());
  if(all[0]?.kind!=='Hello'||all[0].batch_sha256!==batch||all.at(-1)?.kind!=='Terminal')throw new Error('Guest identity or termination mismatch');
  const traces=[];let current=null;
  for(const frame of all.slice(1,-1)) {
    if(frame.kind==='Program'){if(current||frame.index!==String(first+traces.length))throw new Error('Program framing');current=[];}
    else if(frame.kind==='End'){if(!current)throw new Error('Program framing');traces.push({execution:frame.execution,steps:current});current=null;}
    else {if(!current)throw new Error('Step outside a program');current.push(frame);}
  }
  if(current||traces.length!==end-first)throw new Error('Wrong guest trace count');
  return traces;
}

// Exact-arithmetic family: every binary I64 operation over the boundary set squared, and
// negation over the set, each as a whole program through the machine. No expected results
// are attached: the guest's C arithmetic and the model's digit arithmetic are the two
// independent sides, compared by the harness.
export function exactArithmeticCases() {
  const base=callHand[0].program,cases=[];
  const program=(name,result,body,ids)=>({...base,module:name,datatypes:[],effects:[],entry:'main',
    functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:result,effects:[],body}],
    source_map:['0',...ids].map(id=>({id,file:name,line:'0',column:'0'}))});
  VALUES.forEach((a,i)=>{
    cases.push({name:`neg-${i}`,program:program(`neg-${i}`,'I64',['prim','2','neg',['int','3',String(a)]],['2','3'])});
    VALUES.forEach((b,j)=>{
      for(const op of ['add','sub','mul','div','lt','le','gt','ge'])
        cases.push({name:`${op}-${i}-${j}`,program:program(`${op}-${i}-${j}`,['lt','le','gt','ge'].includes(op)?'Bool':'I64',
          ['prim','2',op,['int','3',String(a)],['int','4',String(b)]],['2','3','4'])});
    });
  });
  return cases;
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const solo5=resolve(option('--solo5',resolve(root,'build/vendor/solo5')));
  const bound=Number(option('--exhaustive-nodes','4'));
  if(!Number.isSafeInteger(bound)||bound<0||bound>5)throw new Error('--exhaustive-nodes must be 0..5');
  const tools=toolchain(solo5);
  const out=resolve(root,'build/solo5/freerun-pure-call',`${Date.now()}-${process.pid}`);
  const exact=args.includes('--exact-arithmetic');
  // --tc1: the TC1 handler fixtures (both slices), with the TC0-A hand cases alongside so
  // the guest's two injected defects still have programs that expose them.
  // --tc1-exhaustive-nodes N: every program of the TC1 handler grammar H
  // (tools/tc1/handler-enumerate.mjs) with at most N nodes, again with the TC0-A hand
  // cases: H has no overflow, so the wrap-overflow defect needs them.
  const handlerBound=args.includes('--tc1-exhaustive-nodes')?Number(option('--tc1-exhaustive-nodes')):0;
  if(args.includes('--tc1-exhaustive-nodes')&&!(Number.isSafeInteger(handlerBound)&&handlerBound>=1&&handlerBound<=7))throw new Error('--tc1-exhaustive-nodes must be 1..7');
  if([exact,args.includes('--tc1'),handlerBound>0].filter(Boolean).length>1)throw new Error('Choose one of --exact-arithmetic, --tc1 and --tc1-exhaustive-nodes');
  // Either TC1 family runs on the handler machine.
  const tc1=args.includes('--tc1')||handlerBound>0;
  const families=exact?{'exact-arithmetic':exactArithmeticCases()}
    :handlerBound?{[`tc1-exhaustive-${handlerBound}`]:enumerateHandlers(handlerBound).cases,hand:[...callHand,...dataHand]}
    :tc1?{'tc1-handlers':[...handlerCases,...resumptionCases],hand:[...callHand,...dataHand]}
    :{hand:[...callHand,...dataHand],'generated-pure-call':generatePureCalls(32).cases,'generated-pure-data':generatePureData(24).cases};
  if(bound&&!exact&&!tc1){
    const exhaustive=enumeratePureData(bound,{maxCases:8000});
    if(exhaustive.truncated)throw new Error('Exhaustive family truncated');
    families[`exhaustive-${bound}`]=exhaustive.cases;
  }
  const programs=Object.entries(families).flatMap(([family,cases])=>cases.map(c=>({family,name:c.name,program:c.program,input:INPUT})));
  const lowered=lowerBatch(programs);
  const guest=buildGuest(tools,lowered.header,out);
  const checked=programs.map(p=>validatePureCallArtifact(encode(p.program),p.input));
  // --build-only: write the validated programs and the guest image for the Shen harness
  // (harness/solo5-pure-call.shen) and stop. No comparison happens in this process.
  if(args.includes('--build-only')) {
    writeFileSync(resolve(out,'programs.json'),JSON.stringify(checked.map(c=>c.artifact)));
    writeFileSync(resolve(out,'batch.json'),JSON.stringify({guest,tender:tools.tender,batch_sha256:lowered.batch_sha256,programs:resolve(out,'programs.json'),count:String(programs.length),
      families:Object.fromEntries(Object.entries(families).map(([family,cases])=>[family,String(cases.length)]))})+'\n');
    console.log(out);return;
  }
  // The TC1 implementation has no operand-order or overflow defect switches, so under --tc1
  // only the normal run has a JavaScript reference; defective guest runs are still counted.
  const reference=mode=>tc1&&mode!=='normal'?null:checked.map(c=>{const r=new (tc1?HandlerMachine:PureCallMachine)(c.artifact,c.input,tc1?{}:MODES[mode]).run(FUEL);return {execution:r.execution,steps:r.steps,outcome:r.outcome};});
  const guestRun=mode=>{const traces=[];for(let first=0;first<programs.length;first+=CHUNK)traces.push(...executeRange(tools,guest,lowered.batch_sha256,mode,first,Math.min(first+CHUNK,programs.length)));return traces;};
  const failures=[],outcomes={},perFamily={},mutants={};let steps=0;
  const normalCandidate=reference('normal');
  for(const mode of Object.keys(MODES)) {
    const guestTraces=guestRun(mode),candidate=mode==='normal'?normalCandidate:reference(mode);
    let killed=0;
    programs.forEach((program,i)=>{
      const g=guestTraces[i],c=candidate?candidate[i]:null;
      const divergence=!c?null:g.execution!==c.execution?{epoch:'execution',guest:g.execution,candidate:c.execution}:firstDivergence(g.steps,c.steps);
      if(divergence&&failures.length<20)failures.push({family:program.family,program:program.name,mode,...divergence});
      else if(divergence)failures.push({family:program.family,program:program.name,mode,epoch:divergence.epoch});
      if(mode==='normal') {
        steps+=g.steps.length;perFamily[program.family]=(perFamily[program.family]||0)+1;
        const key=c.outcome?(c.outcome[0]==='Trap'?'Trap:'+c.outcome[1]:'Ok'):'BudgetExhausted';outcomes[key]=(outcomes[key]||0)+1;
      } else if(firstDivergence(g.steps,normalCandidate[i].steps))killed++;
    });
    if(mode!=='normal')mutants[mode]={killed:String(killed),survived_equivalent:String(programs.length-killed)};
  }
  const noKill=Object.values(mutants).some(m=>m.killed==='0');
  const report={schema:'fenrir.solo5.freerun-pure-call-development/1',status:failures.length||noKill?'development-fail':'development-pass',
    qualification:'UNKNOWN',
    scope:'TC0-A pure-call demo schemas /1 and /2; stock spt tender; observed free run compared with the JS pure-call machine; entry input ["int","0"]',
    guest_sha256:sha(readFileSync(guest)),batch_sha256:lowered.batch_sha256,fuel:String(FUEL),
    programs:String(programs.length),programs_by_family:perFamily,reference_steps_compared:String(steps),outcomes,mutants,
    failure_count:String(failures.length),failures:failures.slice(0,20)};
  writeFileSync(resolve(out,'report.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
  if(report.status!=='development-pass')process.exitCode=1;
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
