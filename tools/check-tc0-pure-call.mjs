#!/usr/bin/env node
// Independent integrated pure-call development observations, NOT qualification.
// Port of the former tools/check-tc0-pure-call.py observe/main; its transport and
// normalization half is tools/tc0/shen-probe.mjs.
import {mkdirSync, readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {dirname, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {ROOT, REFERENCE_STEPS, MODEL_FILES, digest, synchronous, outputPath, parseList, normalize, modelValue,
  initialState, Oracle, parseArgs} from './tc0/shen-probe.mjs';

// Line splitting as the former Python str.splitlines(): no trailing empty line.
export function splitLines(text) {
  const lines=text.split(new RegExp('\\r\\n|[\\n\\r\\v\\f\\x1c\\x1d\\x1e\\x85\\u{2028}\\u{2029}]','u'));
  if(lines.at(-1)==='')lines.pop();
  return lines;
}
// Command-line errors exit 2, as the former argparse front ends did.
export function commandLine(usage,spec,check=()=>true) {
  let args=null;
  try{args=parseArgs(process.argv.slice(2),spec);}catch{}
  if(!args||!check(args)){console.error('usage: '+usage);process.exit(2);}
  return args;
}
export const sameJson=isDeepStrictEqual;

// When true, every candidate run goes through tools/tc0/sandbox.mjs: no network, no
// environment, reads only the candidate tree and the program, no writes or processes.
let SANDBOX=false;
export function setSandbox(on){SANDBOX=on===true;}
export const sandboxed=()=>SANDBOX;

export function candidateArgv(node,filename,{sandbox=SANDBOX}={}) {
  const script=resolve(ROOT,'tools/tc0/run-pure-call.mjs');
  if(!sandbox)return [String(node),script,String(filename)];
  return [String(node),resolve(ROOT,'tools/tc0/sandbox.mjs'),'--read',resolve(ROOT,'tools/tc0'),resolve(ROOT,'runtime/tc0'),String(filename),'--',script,String(filename)];
}

// model, when given, is {stdout, stderr} of an oracle batch already run for this case.
// run replaces the process runner so a caller that bounds subprocesses also bounds these.
export function observe(testCase,oracle,node,scratch,{model=null,sandbox=SANDBOX,run=synchronous}={}) {
  const a=testCase.program;
  const filename=resolve(scratch,testCase.name+'.json');
  writeFileSync(filename,JSON.stringify(a));
  // Host validation occurs before translation or model execution.
  const {stdout,stderr}=run(candidateArgv(node,filename,{sandbox}));
  const candidate=JSON.parse(stdout);
  if(model===null) {
    const {outs,stderr:errs}=oracle.run([initialState(a)]);
    model={stdout:outs[0],stderr:errs};
  }
  const lines=splitLines(model.stdout);
  if(!lines.length||lines.at(-1).trim()!=='terminal')
    throw new Error(`Independent model incomplete within ${REFERENCE_STEPS} steps: ${testCase.name}`);
  const steps=lines.filter(x=>x.startsWith('[sample ')).map((line,i)=>normalize(parseList(line),i));
  const descriptors=lines.filter(x=>x.startsWith('[closure ')).map(line=>modelValue(parseList(line)));
  // Hand fixtures supply an independent expectation; structural reduction trials
  // may instead use the freshly observed model terminal outcome (never candidate).
  const has=k=>Object.hasOwn(testCase,k);
  const terminal=steps.at(-1).events[0].outcome;
  const expected=has('expected_outcome')?testCase.expected_outcome:terminal;
  if(candidate.execution!=='Completed'||!sameJson(candidate.steps,steps)||!sameJson(candidate.outcome,expected)||!sameJson(terminal,expected))
    throw new Error('Independent model/candidate/hand disagreement: '+testCase.name);
  if(!candidate.descriptors.every(d=>descriptors.some(x=>sameJson(x,d))))
    throw new Error('Descriptor not independently observed');
  if(has('expected_staging')&&!sameJson(steps.map(s=>[s.after,s.depth]),testCase.expected_staging))
    throw new Error('Hand staging mismatch');
  if(has('expected_return_frames')&&BigInt(steps.filter(s=>s.site.rule==='ReturnReturn').length)!==BigInt(testCase.expected_return_frames))
    throw new Error('Return destination count mismatch');
  if(has('maximum_depth')&&steps.some(s=>BigInt(s.depth)>BigInt(testCase.maximum_depth)))
    throw new Error('Semantic continuation depth exceeds hand bound');
  if(has('expected_descriptor_count')&&BigInt(candidate.descriptors.length)!==BigInt(testCase.expected_descriptor_count))
    throw new Error('Descriptor count mismatch');
  if(has('expected_emissions')&&!sameJson(steps.flatMap(s=>s.events.filter(e=>e.kind==='Emit').map(e=>e.label)),testCase.expected_emissions))
    throw new Error('Hand emission order mismatch');
  return {name:testCase.name,program:a,input:['int','0'],
    hand_expectations:Object.fromEntries(Object.entries(testCase).filter(([k])=>k!=='name'&&k!=='program')),
    hand_outcome:expected,candidate,model_steps:steps,model_descriptors:descriptors,
    shen_stdout:model.stdout,shen_stderr:model.stderr,candidate_stderr:stderr};
}

function main() {
  const args=commandLine('check-tc0-pure-call.mjs (--shen-executable SHEN | --oracle-artifact DIR) --output OUTPUT [--sandbox]',
    {values:['--shen-executable','--oracle-artifact','--output'],booleans:['--sandbox']},
    a=>a.output!==undefined&&(a['shen-executable']===undefined)!==(a['oracle-artifact']===undefined));
  setSandbox(args.sandbox===true);
  const dest=outputPath(args.output);
  const oracle=new Oracle({shen:args['shen-executable']??null,artifact:args['oracle-artifact']??null});
  const node=realpathSync(process.execPath);
  const at=p=>resolve(ROOT,p);
  const fixture=at('fixtures/tc0/pure-call-forward.json');
  const hand=at('fixtures/tc0/pure-call-hand-cases.mjs');
  const dataHand=at('fixtures/tc0/pure-data-hand-cases.mjs');
  const paths=[import.meta.filename,at('tools/check-tc0-expression.mjs'),at('tools/tc0/shen-probe.mjs'),fixture,hand,dataHand,
    at('tools/tc0/run-pure-call.mjs'),at('tools/tc0/pure-call-artifact.mjs'),
    at('tools/tc0/canonical.mjs'),at('runtime/tc0/pure-call-machine.mjs'),
    ...MODEL_FILES,at('spec/tc0/pure-call-demo.json'),
    at('tests/tc0/pure-call-machine.test.mjs'),at('tests/tc0/pure-call-artifact.test.mjs'),at('tests/tc0/pure-data.test.mjs'),
    ...oracle.identityPaths(),node];
  const snapshot=()=>Object.fromEntries(paths.map(p=>[p,digest(p)]));
  const before=snapshot();
  const load=(module,cap)=>{
    const {stdout}=synchronous([node,'--input-type=module','-e',
      `import {cases} from ${JSON.stringify(pathToFileURL(module).href)}; console.log(JSON.stringify(cases));`]);
    const rows=JSON.parse(stdout);
    if(rows.length>cap)throw new Error('Hand case cap');
    return rows;
  };
  const handCases=load(hand,8);
  const dataCases=load(dataHand,16);
  const forward={name:'hand-forward',program:JSON.parse(readFileSync(fixture,'utf8')),expected_outcome:['Ok',['int','1']],
    expected_staging:[['Eval','1'],['Value','1'],['Ready','0'],['Eval','0'],['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]};
  const cases=[forward,...handCases,...dataCases];
  if(new Set(cases.map(c=>c.name)).size!==cases.length||cases.some(c=>typeof c.name!=='string'||!/^[a-z][a-z0-9-]*$/.test(c.name)))
    throw new Error('Unique safe case IDs required');
  const scratch=at('build/tc0/pure-call-inputs');
  mkdirSync(scratch,{recursive:true});
  const {outs,stderr:errs}=oracle.run(cases.map(c=>initialState(c.program)));
  const results=cases.map((c,i)=>observe(c,oracle,node,scratch,{model:{stdout:outs[i],stderr:errs}}));
  if(!sameJson(before,snapshot()))throw new Error('Source/toolchain drift');
  const report={qualification:'UNKNOWN',scope:'tc0-a-pure-call-demo/1 and /2 hand cases; trusted-local development',
    sources:before,oracle:oracle.describe(),candidate_sandboxed:SANDBOX,bounds:{reference_steps:String(REFERENCE_STEPS),cases:String(cases.length),wall_seconds_per_process:'30'},
    cases:results,limitations:['No complete catalog or integrated strict replay yet','Hand cases are not generated discovery/exhaustive scope','Not full TC0-A or qualified evaluator/isolation']};
  mkdirSync(dirname(dest),{recursive:true});
  writeFileSync(dest,JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify({qualification:'UNKNOWN',independent_case_agreement:results.length,report:dest}));
}

if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
