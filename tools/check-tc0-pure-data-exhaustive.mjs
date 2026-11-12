#!/usr/bin/env node
// Exhaustive-small schema /2 Shen-vs-candidate agreement and mutant kills; NOT qualification.
//
// Every program of the bounded grammar in tools/tc0/pure-data-enumerate.mjs is run on
// the Shen model (one batch process) and on the candidate (one batch process). All
// programs must complete within the reference-step bound with identical normalized
// traces and outcomes. Each candidate-only mutant is then classified per program as
// killed (completed, trace differs from the fresh model trace), survived (identical
// trace: an equivalent program for that mutant) or crashed (never credited as a kill).
import {createHash} from 'node:crypto';
import {readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {ROOT, REFERENCE_STEPS, MODEL_FILES, digest, synchronous, outputPath, parseList, normalize, initialState, Oracle} from './tc0/shen-probe.mjs';
import {commandLine, sameJson, splitLines} from './check-tc0-pure-call.mjs';

const MUTANTS=['reverse_operands','wrap_overflow','arm_by_position'];

// Sorted-key, separator-free, ASCII-only JSON: the bytes the former Python
// json.dumps(steps, sort_keys=True, separators=(',', ':')) hashed.
function sortedJson(v) {
  if(Array.isArray(v))return '['+v.map(sortedJson).join(',')+']';
  if(v&&typeof v==='object')return '{'+Object.keys(v).sort().map(k=>sortedJson(k)+':'+sortedJson(v[k])).join(',')+'}';
  return JSON.stringify(v).replace(/[\u0080-￿]/g,c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0'));
}
const traceHash=steps=>createHash('sha256').update(sortedJson(steps)).digest('hex');
const seconds=started=>Math.round((performance.now()-started)/10)/100;

function main() {
  const args=commandLine('check-tc0-pure-data-exhaustive.mjs (--shen-executable SHEN | --oracle-artifact DIR) [--max-nodes N] --output OUTPUT [--sandbox]',
    {values:['--shen-executable','--oracle-artifact','--max-nodes','--output'],booleans:['--sandbox']},
    a=>a.output!==undefined&&(a['shen-executable']===undefined)!==(a['oracle-artifact']===undefined)&&/^[+-]?[0-9]+$/.test(a['max-nodes']??'5'));
  const maxNodes=Number(args['max-nodes']??'5'),sandbox=args.sandbox===true;
  if(!(maxNodes>=1&&maxNodes<=5))throw new Error('Node bound 1..5');
  const dest=outputPath(args.output,{fresh:true});
  const oracle=new Oracle({shen:args['shen-executable']??null,artifact:args['oracle-artifact']??null});
  const node=realpathSync(process.execPath);
  const at=p=>resolve(ROOT,p);
  const paths=[import.meta.filename,at('tools/check-tc0-pure-call.mjs'),at('tools/check-tc0-expression.mjs'),at('tools/tc0/shen-probe.mjs'),
    ...['pure-data-enumerate.mjs','run-pure-data-exhaustive.mjs','pure-call-artifact.mjs','canonical.mjs'].map(p=>at('tools/tc0/'+p)),
    ...MODEL_FILES,at('runtime/tc0/pure-call-machine.mjs'),at('spec/tc0/pure-call-demo.json'),
    ...oracle.identityPaths(),node];
  const snapshot=()=>Object.fromEntries(paths.map(p=>[p,digest(p)]));
  const before=snapshot();
  const batch=dest.replace(/\.json$/,'.candidate.jsonl');
  let started=performance.now();
  let runner=[at('tools/tc0/run-pure-data-exhaustive.mjs'),String(maxNodes),batch];
  if(sandbox)runner=[at('tools/tc0/sandbox.mjs'),'--read',at('tools/tc0'),at('runtime/tc0'),'--write',batch,'--',...runner];
  synchronous([node,...runner],{timeout:300});
  const candidateSeconds=seconds(started);
  const [header,...rows]=splitLines(readFileSync(batch,'utf8')).map(line=>JSON.parse(line));
  if(rows.length!==Number(header.count)||header.truncated)throw new Error('Candidate batch does not cover the enumerated scope');
  started=performance.now();
  const {outs}=oracle.run(rows.map(r=>initialState(r.program)),{timeout:1});
  const modelSeconds=seconds(started);
  const disagreements=[],cases=[];
  const stats=Object.fromEntries(MUTANTS.map(m=>[m,{killed:0,survived:0,crashed:0,first_killed:null}]));
  rows.forEach((row,index)=>{
    const lines=splitLines(outs[index]);
    if(!lines.length||lines.at(-1).trim()!=='terminal') {
      disagreements.push({name:row.name,reason:'model incomplete within reference steps'});
      return;
    }
    const model=lines.filter(x=>x.startsWith('[sample ')).map((l,i)=>normalize(parseList(l),i));
    const outcome=model.at(-1).events[0].outcome;
    const got=row.candidate;
    if(got.execution!=='Completed'||!sameJson(got.steps,model)||!sameJson(got.outcome,outcome)) {
      disagreements.push({name:row.name,program:row.program,model_outcome:outcome,
        candidate_outcome:got.outcome??null,reason:'trace or outcome disagreement'});
      return;
    }
    const verdicts={};
    for(const m of MUTANTS) {
      const r=row[m];
      const verdict=r.execution==='Crashed'?'crashed':r.execution==='Completed'&&sameJson(r.steps,model)?'survived':r.execution==='Completed'?'killed':'crashed';
      stats[m][verdict]+=1;
      verdicts[m]=verdict;
      if(verdict==='killed'&&stats[m].first_killed===null)
        stats[m].first_killed={name:row.name,program:row.program,model_outcome:outcome,mutant_outcome:r.outcome};
    }
    cases.push({name:row.name,nodes:row.nodes,result:row.result,outcome,
      steps:String(model.length),trace_sha256:traceHash(model),...verdicts});
  });
  const after=snapshot();
  if(!sameJson(before,after))throw new Error('Source/toolchain drift');
  const outcomes={};
  for(const c of cases) {
    const key=c.outcome[0]==='Ok'?'Ok':'Trap '+c.outcome[1];
    outcomes[key]=(outcomes[key]??0)+1;
  }
  const report={schema:'pure-data-exhaustive-small-development/1',qualification:'UNKNOWN',
    scope:`Every program of grammar G (tools/tc0/pure-data-enumerate.mjs) with at most ${maxNodes} AST nodes; nothing wider`,
    sources:before,sources_after:after,oracle:oracle.describe(),command:process.argv.slice(1),
    enumeration:header,bounds:{max_nodes:String(maxNodes),reference_steps:String(REFERENCE_STEPS)},candidate_sandboxed:sandbox,
    seconds:{candidate_batch:candidateSeconds,model_batch:modelSeconds},
    agreeing:String(cases.length),disagreements,outcomes,
    max_steps:cases.length?String(Math.max(...cases.map(c=>Number(c.steps)))):'0',
    mutants:stats,candidate_batch_sha256:digest(batch),
    model_stdout_sha256:createHash('sha256').update(outs.join('')).digest('hex'),cases,
    limitations:['Bounded grammar and node count; not exhaustive TC0-A exploration',
      'Mutant survivors are equivalent on those programs, not evidence of mutant equivalence in general',
      'Crashed mutants are recorded, never credited as semantic kills']};
  writeFileSync(dest,JSON.stringify(report,null,1)+'\n',{flag:'wx'});
  console.log(JSON.stringify({qualification:'UNKNOWN',programs:header.count,agreeing:cases.length,
    disagreements:disagreements.length,outcomes,
    mutants:Object.fromEntries(MUTANTS.map(m=>[m,Object.fromEntries(Object.entries(stats[m]).filter(([k])=>k!=='first_killed'))])),
    seconds:report.seconds,report:dest}));
  if(disagreements.length)process.exitCode=1;
}

if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
