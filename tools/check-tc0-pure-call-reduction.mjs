#!/usr/bin/env node
// Bounded pure-call generated discovery/reduction; trusted-local, NOT qualification.
import {spawnSync} from 'node:child_process';
import {mkdirSync, realpathSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {ROOT, REFERENCE_STEPS, MODEL_FILES, digest, outputPath, Oracle} from './tc0/shen-probe.mjs';
import {commandLine, observe as observePureCall, sameJson} from './check-tc0-pure-call.mjs';

const emissions=run=>run.steps.flatMap(s=>s.events.filter(e=>e.kind==='Emit').map(e=>e.label));

// Candidate-only mutants (run-pure-call.mjs flags) and the one discrepancy class each
// is expected to produce. A mutant trace matching the reference is a survivor.
const MUTANTS={'reverse-operands':['--reverse-operands','reversed-emissions-same-outcome'],
  'arm-by-position':['--arm-by-position','wrong-match-arm']};
const FAMILIES={'pure-call':'tools/tc0/pure-call-generate.mjs','pure-data':'tools/tc0/pure-data-generate.mjs'};
const OUTPUT_CAP=8388608;

export function classify(reference,mutant,kind='reverse-operands') {
  if(mutant.execution!=='Completed')throw new Error('Mutant incomplete; no semantic kill');
  const model=reference.model_steps;
  if(sameJson(model,mutant.steps))return null;
  if(kind==='reverse-operands') {
    if(sameJson(emissions(reference.candidate),['left','right'])
        &&sameJson(emissions(mutant),['right','left'])
        &&sameJson(mutant.outcome,reference.hand_outcome))
      return 'reversed-emissions-same-outcome';
    return null;
  }
  // wrong-match-arm: the traces agree through a MatchReturn step, then dispatch
  // different nodes, i.e. the mutant entered a different arm body.
  const steps=mutant.steps;
  let k=null;
  for(let i=0;i<Math.min(model.length,steps.length)&&k===null;i++)if(!sameJson(model[i],steps[i]))k=i;
  if(k!==null&&k>0
      &&model[k-1].site.rule==='MatchReturn'
      &&model[k].site.rule==='Dispatch'&&steps[k].site.rule==='Dispatch'
      &&!sameJson(model[k].site.node,steps[k].site.node))
    return 'wrong-match-arm';
  return null;
}

// The host-Shen oracle with its process routed through the campaign's bounded runner.
class BoundedOracle extends Oracle {
  constructor(options,run){super(options);this.bounded=run;}
  run(initials,{timeout=30}={}) {
    const stdin=initials.map(i=>`${REFERENCE_STEPS} ${i}\n`).join('')+'end\n';
    const {stdout,stderr}=this.bounded([this.shen,'script',resolve(ROOT,'models/tc0/pure-call-oracle.shen')],
      {timeout:timeout*Math.max(1,initials.length),stdin,cwd:resolve(ROOT,'models/tc0')});
    const chunks=stdout.split('[case-end]\n');
    if(chunks.length!==initials.length+1)throw new Error(`Oracle returned ${chunks.length-1} cases for ${initials.length}`);
    return {outs:chunks.slice(0,-1),stderr};
  }
}

function main() {
  const integer=v=>v===undefined||/^[+-]?[0-9]+$/.test(v);
  const args=commandLine('check-tc0-pure-call-reduction.mjs --shen-executable SHEN --output OUTPUT [--max-cases N] [--max-attempts N] [--family {pure-call,pure-data}] [--mutant {arm-by-position,reverse-operands}] [--wall-seconds N]',
    {values:['--shen-executable','--output','--max-cases','--max-attempts','--family','--mutant','--wall-seconds']},
    a=>a['shen-executable']!==undefined&&a.output!==undefined&&integer(a['max-cases'])&&integer(a['max-attempts'])&&integer(a['wall-seconds'])
      &&Object.hasOwn(FAMILIES,a.family??'pure-call')&&Object.hasOwn(MUTANTS,a.mutant??'reverse-operands'));
  const maxCases=Number(args['max-cases']??'32'),maxAttempts=Number(args['max-attempts']??'100'),wall=Number(args['wall-seconds']??'120');
  const familyName=args.family??'pure-call',mutantName=args.mutant??'reverse-operands';
  if(!(maxCases>=1&&maxCases<=32)||!(maxAttempts>=1&&maxAttempts<=100)||!(wall>=1&&wall<=600))
    throw new Error('Caps: cases1..32, attempts1..100, wall seconds1..600');
  const [flag,expectedDiscrepancy]=MUTANTS[mutantName];
  const dest=outputPath(args.output,{fresh:true});
  const executable=realpathSync(resolve(args['shen-executable']));
  const node=realpathSync(process.execPath);
  const at=p=>resolve(ROOT,p);
  const paths=[import.meta.filename,at('tools/check-tc0-pure-call.mjs'),at('tools/check-tc0-expression.mjs'),at('tools/tc0/shen-probe.mjs'),
    ...['pure-call-generate.mjs','pure-data-generate.mjs','pure-call-reduce.mjs',
      'pure-call-campaign-bridge.mjs','run-pure-call.mjs','pure-call-artifact.mjs','canonical.mjs'].map(p=>at('tools/tc0/'+p)),
    ...MODEL_FILES,
    at('runtime/tc0/pure-call-machine.mjs'),at('spec/tc0/pure-call-demo.json'),
    executable,node,resolve(executable,'../../lib/shen-scheme/shen.boot')];
  const snapshot=()=>Object.fromEntries(paths.map(p=>[p,digest(p)]));
  const before=snapshot();
  const start=performance.now();
  const elapsed=()=>(performance.now()-start)/1000;
  // Every subprocess is bounded by its own timeout, the remaining campaign wall time
  // and the transport output cap.
  const boundedSynchronous=(argv,{timeout=30,stdin=null,cwd=ROOT}={})=>{
    const remaining=wall-elapsed();
    if(remaining<=0)throw new Error('Campaign watchdog');
    const r=spawnSync(String(argv[0]),argv.slice(1).map(String),{cwd,timeout:Math.max(1,Math.ceil(Math.min(timeout,remaining)*1000)),killSignal:'SIGKILL',
      maxBuffer:OUTPUT_CAP,input:stdin===null?undefined:stdin,stdio:[stdin===null?'ignore':'pipe','pipe','pipe']});
    if(r.error?.code==='ENOBUFS'||(r.stdout?.length??0)+(r.stderr?.length??0)>OUTPUT_CAP)throw new Error('Transport output cap');
    if(r.error?.code==='ETIMEDOUT')throw new Error('Process/campaign watchdog, not semantic timeout');
    if(r.error)throw new Error(`Process failed: ${r.error.message}`);
    if(r.signal)throw new Error(`Process killed by ${r.signal}`);
    if(r.status!==0)throw new Error(`Process exit ${r.status}: ${r.stderr.toString().slice(-2000)}`);
    return {stdout:r.stdout.toString(),stderr:r.stderr.toString()};
  };
  // Also bounds observe's candidate/model subprocesses; semantic logic stays independent.
  const oracle=new BoundedOracle({shen:executable},boundedSynchronous);
  // A fresh campaign directory avoids replacing prior source-bound inputs.
  mkdirSync(dirname(dest),{recursive:true});
  const scratch=dest.replace(/\.json$/,'.inputs');
  mkdirSync(scratch);
  const run=argv=>{
    if(elapsed()>wall)throw new Error('Campaign wall watchdog, not semantic outcome');
    const {stdout,stderr}=boundedSynchronous(argv,{timeout:30});
    if(Buffer.byteLength(stdout)+Buffer.byteLength(stderr)>OUTPUT_CAP)throw new Error('Transport output cap; no completion credit');
    return [JSON.parse(stdout),stderr];
  };
  const bridge=(action,arg)=>run([node,at('tools/tc0/pure-call-campaign-bridge.mjs'),action,String(arg)])[0];
  const observations=[];
  const observe=testCase=>{
    if(elapsed()>wall)throw new Error('Campaign watchdog');
    const measured=observePureCall(testCase,oracle,node,scratch,{run:boundedSynchronous});
    if(Buffer.byteLength(measured.shen_stdout)+Buffer.byteLength(measured.shen_stderr)>OUTPUT_CAP)throw new Error('Model output cap');
    const path=resolve(scratch,testCase.name+'.json');
    // Separate default invocation is an explicitly equivalent no-op control,
    // not a non-equivalent mutation and not independent semantic authority.
    const [control,controlErr]=run([node,at('tools/tc0/run-pure-call.mjs'),path]);
    if(!sameJson(control,measured.candidate))throw new Error('Equivalent control disagrees with fresh baseline');
    const [mutant,mutantErr]=run([node,at('tools/tc0/run-pure-call.mjs'),path,flag]);
    const metric=bridge('reduce',path).metric;
    if(metric.nodes>200)throw new Error('AST node bound exceeded');
    Object.assign(measured,{metric,equivalent_control:control,equivalent_control_stderr:controlErr,
      mutant,mutant_stderr:mutantErr,discrepancy:classify(measured,mutant,mutantName)});
    // Generated cases may carry an independently derived mutant outcome.
    const predicted=testCase[mutantName.replaceAll('-','_')+'_outcome']??null;
    if(predicted!==null&&measured.discrepancy&&!sameJson(mutant.outcome,predicted))
      throw new Error('Mutant outcome differs from the generator-derived prediction');
    observations.push(measured);
    return measured;
  };
  const family=run([node,at('tools/tc0/pure-call-campaign-bridge.mjs'),'generate',String(maxCases),familyName])[0];
  let original=null,discoveryIndex=null;
  for(const [i,generated] of family.cases.entries()) {
    const measured=observe(Object.fromEntries(Object.entries(generated).filter(([k])=>k!=='parameters')));
    if(measured.discrepancy!==null&&measured.discrepancy!==expectedDiscrepancy)throw new Error('Unexpected discrepancy class');
    if(measured.discrepancy){original=measured;discoveryIndex=i;break;}
  }
  if(original===null)throw new Error('No expected discrepancy discovered in generated prefix');
  let current=original,capHit=false;
  const history=[];
  for(;;) {
    const proposals=bridge('reduce',resolve(scratch,current.name+'.json')).proposals;
    let changed=false;
    for(const proposal of proposals) {
      if(history.length>=maxAttempts){capHit=true;break;}
      const trial=observe({name:'reduction-'+history.length,program:proposal.program});
      // Acceptance keeps the discrepancy class on fresh model/candidate
      // observations; the model outcome itself may change under reduction.
      const accepted=trial.discrepancy===original.discrepancy;
      if(trial.metric.nodes>=current.metric.nodes)throw new Error('Reduction did not decrease node metric');
      history.push({observation_index:String(observations.length-1),rule:proposal.rule,
        path:proposal.path,metric:trial.metric,accepted});
      if(accepted){current=trial;changed=true;break;}
    }
    if(capHit||!changed)break;
  }
  if(current.metric.nodes>=original.metric.nodes)throw new Error('No smaller valid failure obtained');
  const after=snapshot();
  if(!sameJson(before,after))throw new Error('Source/toolchain drift');
  const report={schema:'pure-call-reduction-development/2',qualification:'UNKNOWN',
    scope:`Trusted-local finite ${familyName} family, not full TC0-A`,family:familyName,
    mutant:mutantName,expected_discrepancy:expectedDiscrepancy,
    acceptance:'same discrepancy class on fresh Shen/candidate observations; outcome may change',sources:before,
    sources_after:after,command:process.argv.slice(1),bounds:{cases:String(maxCases),
      ast_nodes:'200',reference_steps:'200',attempts:String(maxAttempts),
      wall_seconds:String(wall),per_process_seconds:'30',output_bytes_per_process:'8388608'},
    generation:Object.fromEntries(Object.entries(family).filter(([k])=>k!=='cases')),
    discovered_index:String(discoveryIndex),stopped_at_first_failure:true,
    original,minimized:current,observations,history,
    reduction_cap_hit:capHit,cleanup:'confirmed',
    limitations:['Smallest-found typed proposals, not global minimality or exhaustive exploration',
      'No enforced evaluator isolation or independent agent repair',
      'No exact replay claim until separately source-verified tapes are regenerated']};
  // Recheck immediately before publishing the retained bytes.
  if(!sameJson(before,snapshot()))throw new Error('Late source drift');
  writeFileSync(dest,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
  console.log(JSON.stringify({qualification:'UNKNOWN',family:familyName,mutant:mutantName,discovered_index:String(discoveryIndex),
    attempts:history.length,original_metric:original.metric,
    minimized_metric:current.metric,reduction_cap_hit:capHit,report:dest}));
}

if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
