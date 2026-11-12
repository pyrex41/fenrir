#!/usr/bin/env node
// Independent Shen/candidate closure development probe; NOT qualification.
// Port of the former tools/check-tc0-closure.py. Superseded closure-machine
// lineage: kept working, not extended.
import {existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {basename, dirname, extname, isAbsolute, relative, resolve} from 'node:path';
import {isDeepStrictEqual} from 'node:util';
import {ROOT, digest, synchronous, parseList} from './tc0/shen-probe.mjs';

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
const below=(parent,path)=>{const inside=relative(parent,path);return !inside.startsWith('..')&&!isAbsolute(inside);};
const pick=(table,key)=>{if(typeof key!=='string'||!Object.hasOwn(table,key))throw new Error('Unexpected model token '+JSON.stringify(key));return table[key];};
const includes=(list,item)=>list.some(x=>isDeepStrictEqual(x,item));

// This machine's own term translation (int/var/lambda/let/apply/add only).
// codes collects one "[id [parameter body]]" entry per lambda, innermost first.
function translate(e,codes) {
  const [tag,node,...a]=e;let operands;
  if(tag==='int'||tag==='var')operands=a[0];
  else if(tag==='lambda') {
    const body=translate(a[5],codes);
    codes.push(`[${node} [${a[0]} ${body}]]`);
    operands=`${a[0]} ${body}`;
  } else if(tag==='let')operands=`${a[0]} ${translate(a[1],codes)} ${translate(a[2],codes)}`;
  else if(tag==='apply'||tag==='add')operands=a.map(x=>translate(x,codes)).join(' ');
  else throw new Error('Unsupported closure translation');
  return `[${tag} ${node} ${operands}]`;
}

function value(v) {
  if(Array.isArray(v)&&v.length===2&&v[0]==='int')return v;
  if(Array.isArray(v)&&v.length===4&&v[0]==='closure'&&Array.isArray(v[3])&&v[3].length===0)
    return {code_id:v[1],captures:v[2].map(pair=>{
      if(!Array.isArray(pair)||pair.length!==2)throw new Error('Unexpected closure model value');
      return [pair[0],value(pair[1])];
    }),capture_support:[]};
  throw new Error('Unexpected closure model value');
}

const RULES={dispatch:'Dispatch',ready:'Ready','let-return':'LetReturn','collect-return':'CollectReturn',
  'return-return':'ReturnReturn',value:'Value',unwind:'Unwind',join:'Join',terminate:'Terminate'};
const KINDS={eval:'Eval',value:'Value',ready:'Ready',unwind:'Unwind',join:'Join',terminate:'Terminate',terminal:'Terminal'};
const EVENT_KINDS={'scope-exit':'ScopeExit','task-termination':'TaskTermination'};
function sample(s,epoch) {
  if(!Array.isArray(s)||s.length!==5||s[0]!=='sample')throw new Error('Invalid sample');
  const [,site,after,depth,events]=s;
  const event=e=>{
    if(e.length!==2||!Object.hasOwn(EVENT_KINDS,e[0]))throw new Error('Unexpected event');
    const o=e[1];
    const outcome=o[0]==='ok'?['Ok',value(o[1])]:['Trap',pick({overflow:'Overflow'},o[1])];
    return {kind:EVENT_KINDS[e[0]],outcome};
  };
  return {epoch:String(epoch),site:{[site[0]]:site[0]==='node'?site[1]:pick(KINDS,site[1]),rule:pick(RULES,site[2])},
    after:pick(KINDS,after),depth,events:events.map(event)};
}

// --additional-case may be repeated; each occurrence appends one fixture path.
function parseArguments(argv) {
  const out={'additional-case':[]};
  for(let i=0;i<argv.length;i++) {
    const flag=argv[i];
    if(!['--shen-executable','--output','--additional-case'].includes(flag)||i+1>=argv.length)
      throw new Error('Unknown or incomplete argument '+flag);
    if(flag==='--additional-case')out['additional-case'].push(argv[++i]);
    else out[flag.slice(2)]=argv[++i];
  }
  if(!out['shen-executable']||!out.output)
    throw new Error('Usage: check-tc0-closure.mjs --shen-executable SHEN --output build/....json [--additional-case FIXTURE]...');
  return out;
}

function main() {
  const args=parseArguments(process.argv.slice(2));
  const destination=resolved(args.output);
  if(!below(resolve(ROOT,'build'),destination)||extname(destination)!=='.json')throw new Error('Development output must be JSON below build');
  // Follow symlinks: the runtime files are located relative to the real executable.
  const executable=realpathSync(resolve(args['shen-executable']));
  const node=realpathSync(process.execPath);
  const at=p=>resolve(ROOT,p);
  const paths=[import.meta.filename,at('tools/check-tc0-expression.mjs'),at('tools/tc0/shen-probe.mjs'),at('tools/tc0/run-closure.mjs'),
    at('tools/tc0/closure-artifact.mjs'),at('tools/tc0/canonical.mjs'),at('runtime/tc0/closure-machine.mjs'),
    at('models/tc0/closure-machine.shen'),at('models/tc0/arithmetic.shen'),
    at('fixtures/tc0/closure-capture-program.json'),at('spec/tc0/pure-closure-demo.json'),
    at('tests/tc0/closure.test.mjs'),executable,node,resolve(executable,'../../lib/shen-scheme/shen.boot')];
  const additional=[];
  if(args['additional-case'].length>8)throw new Error('Additional case cap');
  const FIELDS=['case_id','program','expected_outcome','expected_descriptors'];
  for(const filename of args['additional-case']) {
    const path=realpathSync(resolve(filename));
    if(!below(at('fixtures/tc0'),path))throw new Error('Additional cases must be retained TC0 fixtures');
    const fixture=JSON.parse(readFileSync(path,'utf8'));
    const keys=fixture!==null&&typeof fixture==='object'&&!Array.isArray(fixture)?Object.keys(fixture):null;
    if(keys===null||keys.length!==FIELDS.length||!FIELDS.every(k=>keys.includes(k))||typeof fixture.case_id!=='string'
      ||!/^[\p{L}\p{N}]+$/u.test(fixture.case_id.replaceAll('-','')))
      throw new Error('Closed additional fixture fields/name');
    additional.push(fixture);
    paths.push(path);
  }
  const snapshot=()=>Object.fromEntries(paths.map(p=>[p,digest(p)]));
  const before=snapshot();
  const base=JSON.parse(readFileSync(at('fixtures/tc0/closure-capture-program.json'),'utf8'));
  const higher=structuredClone(base);
  higher.body[4][4]=['apply','21',['lambda','15','16',['Arrow','I64','I64'],'I64',[],[],
    ['apply','17',['var','18','16'],['int','19','5']]],['var','20','5']];
  const nonTail=structuredClone(base);
  nonTail.body[4][4]=['add','22',nonTail.body[4][4],['int','23','1']];
  const overflow=structuredClone(nonTail);
  overflow.body[3][2]='9223372036854775807';
  const nested=structuredClone(base);
  nested.body[4][3]=['lambda','7','8','I64',['Arrow','I64','I64'],[],[],
    ['lambda','15','16','I64','I64',[],[],['add','17',['add','9',['var','10','2'],['var','11','8']],['var','18','16']]]];
  nested.body[4][4]=['apply','12',['apply','19',['var','13','5'],['int','14','3']],['int','20','5']];
  const cases=[['capture',base,['Ok',['int','12']]],['higher-order',higher,['Ok',['int','12']]],
    ['non-tail',nonTail,['Ok',['int','13']]],['overflow-unwind',overflow,['Trap','Overflow']],
    ['nested-returned-closure',nested,['Ok',['int','15']]]];
  for(const c of additional)cases.push([c.case_id,c.program,c.expected_outcome]);
  if(new Set(cases.map(([name])=>name)).size!==cases.length)throw new Error('Duplicate case ID');
  const results=[];
  const scratch=at('build/tc0/closure-inputs');
  mkdirSync(scratch,{recursive:true});
  for(const [name,p,expected] of cases) {
    // Host peer validates the closed graph before any candidate/model execution.
    const program=resolve(scratch,name+'.json');
    writeFileSync(program,ascii(JSON.stringify(p)));
    const candidate=JSON.parse(synchronous([node,at('tools/tc0/run-closure.mjs'),program]).stdout);
    if(candidate.execution!=='Completed')throw new Error('Candidate budget exhausted, not completing evidence');
    const codes=[];
    const body=translate(p.body,codes);
    const initial=`[closure-state [eval ${body} true] [[${p.input_binding} [int 0]]] [] [${codes.join(' ')}]]`;
    const state='(value tc0.cl.probe)';
    const terminal=`(= (hd (hd (tl ${state}))) terminal)`;
    const argv=[executable,'eval','-l',at('models/tc0/arithmetic.shen'),'-l',at('models/tc0/closure-machine.shen'),
      '-e',`(set tc0.cl.probe ${initial})`];
    for(let i=0;i<200;i++)argv.push('-e',`(if ${terminal} [] (tc0.cl.sample ${state}))`,
      '-e',`(if ${terminal} [] (set tc0.cl.probe (hd (tl (tc0.cl.step ${state})))))`,
      '-e',`(if (= (hd (hd (tl ${state}))) value) (hd (tl (hd (tl ${state})))) [])`);
    argv.push('-e',`(hd (hd (tl ${state})))`);
    const {stdout:modelStdout,stderr:modelStderr}=synchronous(argv,{timeout:30});
    const lines=splitLines(modelStdout);
    if(lines.at(-1).trim()!=='terminal')throw new Error('Independent model did not complete within bound');
    const steps=lines.filter(line=>line.startsWith('[sample ')).map((line,i)=>sample(parseList(line),i));
    const descriptors=lines.filter(line=>line.startsWith('[closure ')).map(line=>value(parseList(line)));
    if(!isDeepStrictEqual(candidate.steps,steps)||!isDeepStrictEqual(candidate.outcome,expected)
      ||!isDeepStrictEqual(steps.at(-1).events[0].outcome,expected))
      throw new Error('Model/candidate/hand outcome or staging disagreement in '+name);
    // Compare freshly constructed descriptors, also observed repeatedly during propagation.
    if(!candidate.descriptors.every(d=>includes(descriptors,d)))throw new Error('Candidate descriptors not independently observed');
    for(const fixture of additional) {
      if(name===fixture.case_id) {
        if(!isDeepStrictEqual(candidate.descriptors,fixture.expected_descriptors)||!fixture.expected_descriptors.every(d=>includes(descriptors,d)))
          throw new Error('Hand-derived descriptor disagreement');
      }
    }
    if(name==='capture') {
      const hand=[['Eval','1'],['Value','1'],['Eval','0'],['Eval','1'],['Value','1'],['Eval','0'],
        ['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Eval','0'],
        ['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Value','0'],
        ['Join','0'],['Terminate','0'],['Terminal','0']];
      if(!isDeepStrictEqual(steps.map(s=>[s.after,s.depth]),hand))throw new Error('Hand-derived21-step capture staging disagreement');
    }
    results.push({name,program:p,program_sha256:digest(program),hand_outcome:expected,
      candidate,model_steps:steps,model_descriptors:descriptors,
      shen_stdout:modelStdout,shen_stderr:modelStderr});
  }
  if(!isDeepStrictEqual(before,snapshot()))throw new Error('Source/toolchain drift during probe');
  const report={qualification:'UNKNOWN',scope:'Standalone pure-closure-demo/1 trusted-local development',
    sources:before,cases:results,limitations:['Not full TC0-A artifact/catalog','No named/recursive calls',
      'No strict closure-profile replay/reduction yet','No independently reviewed evaluator/isolation']};
  mkdirSync(dirname(destination),{recursive:true});
  writeFileSync(destination,ascii(JSON.stringify(report,null,2))+'\n');
  console.log(JSON.stringify({qualification:'UNKNOWN',independent_case_agreement:results.length,report:destination}));
}

if (process.argv[1] && resolve(process.argv[1]) === import.meta.filename) main();
