#!/usr/bin/env node
// Bounded generated Shen/candidate discovery and reduction; trusted LOCAL only.
// Port of the former tools/check-tc0-reduction.py. Superseded expression-level
// reduction lineage: kept working, not extended.
import {existsSync, mkdirSync, realpathSync, writeFileSync} from 'node:fs';
import {basename, dirname, extname, isAbsolute, relative, resolve} from 'node:path';
import {isDeepStrictEqual} from 'node:util';
import {ROOT, digest, synchronous, shenExpr, parseList, normalizeExpression, parseArgs} from './tc0/shen-probe.mjs';

// JSON text as the former json.dumps wrote it: non-ASCII is escaped.
const ascii=text=>text.replace(/[\u007f-\uffff]/g,c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0'));
// Line splitting as the former str.splitlines(): no trailing empty line.
function splitLines(text) {
  const lines=text.split(/\r\n|[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/);
  if(lines.at(-1)==='')lines.pop();
  return lines;
}
// Absolute path with symlinks followed for the part that exists.
function resolved(path) {
  let head=resolve(path);const tail=[];
  while(!existsSync(head)&&dirname(head)!==head){tail.unshift(basename(head));head=dirname(head);}
  return resolve(realpathSync(head),...tail);
}
function cap(text,fallback) {
  if(text===undefined)return fallback;
  if(!/^[+-]?[0-9]+$/.test(text.trim()))throw new Error('Development caps must be integers');
  return Number(text.trim());
}

function main() {
  const args=parseArgs(process.argv.slice(2),{values:['--shen-executable','--output','--max-cases','--max-attempts']});
  if(!args['shen-executable']||!args.output)
    throw new Error('Usage: check-tc0-reduction.mjs --shen-executable SHEN --output build/....json [--max-cases N] [--max-attempts N]');
  const maxCases=cap(args['max-cases'],16),maxAttempts=cap(args['max-attempts'],40);
  if(!(1<=maxCases&&maxCases<=100)||!(1<=maxAttempts&&maxAttempts<=100))throw new Error('Development caps must be 1..100');
  const destination=resolved(args.output);
  const inside=relative(resolve(ROOT,'build'),destination);
  if(inside.startsWith('..')||isAbsolute(inside)||extname(destination)!=='.json')throw new Error('Output must be JSON below build/');
  // Follow symlinks: the runtime files are located relative to the real executable.
  const executable=realpathSync(resolve(args['shen-executable']));
  const boot=resolve(executable,'../../lib/shen-scheme/shen.boot');
  const node=realpathSync(process.execPath);
  const at=p=>resolve(ROOT,p);
  const paths=[import.meta.filename,at('tools/check-tc0-expression.mjs'),at('tools/tc0/shen-probe.mjs'),
    ...['generate.mjs','reduce.mjs','reduction-bridge.mjs','artifact.mjs','canonical.mjs','replay.mjs'].map(p=>at('tools/tc0/'+p)),
    at('models/tc0/arithmetic.shen'),at('models/tc0/expression-machine.shen'),
    at('runtime/tc0/expression-machine.mjs'),at('spec/tc0/arithmetic-demo-frames.json'),executable,boot,node];
  const snapshot=()=>Object.fromEntries(paths.map(p=>[p,digest(p)]));
  const before=snapshot();
  const start=performance.now();
  const observations=[];
  const budget=()=>{
    if(performance.now()-start>120000)throw new Error('Development campaign watchdog; not semantic timeout');
  };
  function bridge(request) {
    budget();
    // The request goes to the bridge on standard input; no shell or background process.
    const {stdout}=synchronous([node,at('tools/tc0/reduction-bridge.mjs')],{timeout:30,stdin:ascii(JSON.stringify(request))});
    return JSON.parse(stdout);
  }
  function observe(artifact,inputValue) {
    budget();
    const pair=bridge({action:'run',artifact,input:inputValue});
    const fn=artifact.functions[0];
    if(!isDeepStrictEqual(inputValue,['unit'])||fn.argument_type!=='Unit')throw new Error('Undemonstrated input translation');
    const initial=`[state [eval ${shenExpr(fn.body)}] [[${fn.parameter_id} [unit]]] []]`;
    // Fixed independent model bound, NOT a step count taken from candidate.
    const state='(value tc0.campaign.state)';
    const terminal=`(= (hd (hd (tl ${state}))) terminal)`;
    const argv=[executable,'eval','-l',at('models/tc0/arithmetic.shen'),
      '-l',at('models/tc0/expression-machine.shen'),'-e',`(set tc0.campaign.state ${initial})`];
    for(let i=0;i<200;i++)argv.push('-e',`(if ${terminal} [] (tc0.demo.sample ${state}))`,
      '-e',`(if ${terminal} [] (set tc0.campaign.state (hd (tl (tc0.demo.step ${state})))))`);
    argv.push('-e',`(hd (hd (tl ${state})))`);
    const {stdout,stderr}=synchronous(argv,{timeout:30});
    const lines=splitLines(stdout);
    if(lines.at(-1).trim()!=='terminal')throw new Error('Independent model budget exhausted; no completion credit');
    const samples=lines.filter(line=>line.startsWith('[sample ')).map(parseList);
    const reference=samples.map((s,i)=>normalizeExpression(s,i));
    if(pair.control.execution!=='Completed'||!isDeepStrictEqual(pair.control.steps,reference))
      throw new Error('Unmodified candidate disagrees with independent model');
    const events=reference.flatMap(row=>row.events);
    const outcome=events.at(-1).outcome;
    if(!isDeepStrictEqual(pair.control.outcome,outcome))throw new Error('Candidate terminal outcome disagrees');
    const mutant=pair.mutant;
    if(mutant.execution!=='Completed')throw new Error('Mutant did not complete within development bound');
    const discrepancy=outcome[0]==='Trap'&&!events.some(e=>e.kind==='Emit')&&mutant.events.some(e=>e.kind==='Emit')
      ?'left-trap-right-emission':null;
    const result={artifact,input:inputValue,reference,control:pair.control,
      mutant,metric:pair.metric,discrepancy,
      shen_stdout:stdout,shen_stderr:stderr};
    observations.push(result);
    return result;
  }
  const rows=bridge({action:'generate',max_cases:String(maxCases)});
  let original=null,discoveredIndex;
  for(const row of rows) {
    const measured=observe(row.artifact,row.input);
    if(measured.discrepancy) {
      original=measured;
      discoveredIndex=row.index;
      break;
    }
  }
  if(original===null)throw new Error('No discrepancy discovered in bounded generated prefix');
  let current=original;
  const history=[];
  let capHit=false;
  while(true) {
    let changed=false;
    const proposals=bridge({action:'proposals',artifact:current.artifact,input:current.input});
    for(const proposal of proposals) {
      if(history.length===maxAttempts) {
        capHit=true;
        break;
      }
      const trial=observe(proposal.artifact,current.input);
      const accepted=trial.discrepancy===original.discrepancy;
      history.push({observation_index:String(observations.length-1),metric:trial.metric,accepted});
      if(accepted) {
        current=trial;
        changed=true;
        break;
      }
    }
    if(capHit||!changed)break;
  }
  const replays={};
  for(const [label,failure] of [['original',original],['minimized',current]]) {
    replays[label]=bridge({action:'replay',artifact:failure.artifact,input:failure.input,
      reference:failure.reference,run_id:'generated-'+label,shen_hash:before[executable],
      shen_boot_hash:before[boot]});
    if(replays[label].replay.replay!=='Exact'||replays[label].replay.conformance!=='Diverged')
      throw new Error('Original/minimized failure replay did not retain Exact/Diverged');
  }
  if(!isDeepStrictEqual(before,snapshot()))throw new Error('Source/toolchain drift during campaign');
  const report={qualification:'UNKNOWN',scope:'Trusted-local arithmetic-demo development, not full TC0-A',
    sources:before,discovered_index:discoveredIndex,generation:rows[0].enumeration,
    generation_stopped_at_first_failure:true,original,minimized:current,
    history,reduction_cap_hit:capHit,reduction_scope:'Smallest-found deterministic proposals, not globally minimal',
    observations,replays,
    limitations:['No qualified isolation or evaluator','No fresh agent repair evaluation','No calls/closures/full A',
      'Development oracle/catalog unqualified','Semantic replay observes exposed state, not hidden native computation']};
  mkdirSync(dirname(destination),{recursive:true});
  writeFileSync(destination,ascii(JSON.stringify(report,null,2))+'\n');
  console.log(JSON.stringify({qualification:'UNKNOWN',discovered_index:discoveredIndex,attempts:history.length,
    original_metric:original.metric,minimized_metric:current.metric,reduction_cap_hit:capHit,
    original_failure_replay:replays.original.replay,report:destination}));
}

if (process.argv[1] && resolve(process.argv[1]) === import.meta.filename) main();
