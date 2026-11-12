#!/usr/bin/env node
// Development arithmetic probe, NOT a TC0-A qualification evaluator.
// Port of the former tools/check-tc0-arithmetic.py. Superseded arithmetic-only
// lineage: kept working, not extended.
import {spawnSync} from 'node:child_process';
import {mkdirSync, readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {dirname, relative, resolve} from 'node:path';
import {isDeepStrictEqual} from 'node:util';
import {ROOT, digest, parseArgs} from './tc0/shen-probe.mjs';

const OPS={add:2,sub:2,mul:2,div:2,neg:1};
const MINIMUM=-(1n<<63n),MAXIMUM=(1n<<63n)-1n;
const DECIMAL=/^(0|-[1-9][0-9]*|[1-9][0-9]*)$/;

// Report text matches the former json.dumps(..., indent=2): non-ASCII is escaped.
const reportJson=value=>JSON.stringify(value,null,2).replace(/[\u007f-\uffff]/g,c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0'));
// The summary names the output as given, tidied the way pathlib prints a path.
function pathText(path) {
  const parts=path.split('/').filter(part=>part!==''&&part!=='.');
  return (path.startsWith('/')?'/':'')+parts.join('/')||'.';
}
// One process to completion with captured text output; a timeout throws.
function run(argv,timeout) {
  const r=spawnSync(argv[0],argv.slice(1),{timeout:timeout*1000,killSignal:'SIGKILL',maxBuffer:512*1024*1024,stdio:['inherit','pipe','pipe']});
  if(r.error)throw new Error(`Process failed: ${r.error.message}`);
  return {status:r.status,stdout:r.stdout.toString(),stderr:r.stderr.toString()};
}

// Exact integers (BigInt): operands and results can exceed 2^53.
function independentlyExpected(op,args) {
  const a=args[0];
  if(op==='div'&&args[1]===0n)return {status:'Trap',code:'DivZero'};
  let result;
  if(op==='add')result=a+args[1];
  else if(op==='sub')result=a-args[1];
  else if(op==='mul')result=a*args[1];
  else if(op==='neg')result=-a;
  else {
    const b=args[1],magnitude=x=>x<0n?-x:x;
    result=magnitude(a)/magnitude(b);
    if((a<0n)!==(b<0n))result=-result;
  }
  if(!(MINIMUM<=result&&result<=MAXIMUM))return {status:'Trap',code:'Overflow'};
  return {status:'Ok',value:String(result)};
}

function main() {
  const args=parseArgs(process.argv.slice(2),{values:['--shen-executable','--output']});
  if(!args['shen-executable']||!args.output)throw new Error('Usage: check-tc0-arithmetic.mjs --shen-executable SHEN --output REPORT.json');
  // Follow symlinks: the runtime files are located relative to the real executable.
  const executable=realpathSync(resolve(args['shen-executable']));
  const boot=resolve(executable,'../../lib/shen-scheme/shen.boot');
  const fixturePath=resolve(ROOT,'fixtures/tc0/arithmetic-boundaries.json');
  const model=resolve(ROOT,'models/tc0/arithmetic.shen');
  const candidate=resolve(ROOT,'runtime/tc0/arithmetic-candidate.mjs');
  const fixtures=JSON.parse(readFileSync(fixturePath,'utf8'));
  const expressions=[];
  for(const fixture of fixtures) {
    const op=fixture.op,values=fixture.args;
    if(typeof op!=='string'||!Object.hasOwn(OPS,op)||!Array.isArray(values)||values.length!==OPS[op])throw new Error('Invalid operation or arity');
    if(values.some(value=>typeof value!=='string'||!DECIMAL.test(value)))throw new Error('Invalid decimal input');
    const numbers=values.map(BigInt);
    if(numbers.some(value=>!(MINIMUM<=value&&value<=MAXIMUM)))throw new Error('Input outside I64');
    if(!isDeepStrictEqual(independentlyExpected(op,numbers),fixture.expected))
      throw new Error('Hand fixture disagrees with independent exact integer arithmetic');
    expressions.push('-e',`(tc0.arithmetic ${op} [${values.join(' ')}])`);
  }
  const invocation=run([executable,'eval','-l',model,...expressions],30);
  if(invocation.status!==0)throw new Error('Shen launch/load failed: '+invocation.stderr.slice(-2000));
  const rawResults=[...invocation.stdout.matchAll(/^\[(ok|trap) ([a-z0-9-]+)\]$/gm)].map(m=>[m[1],m[2]]);
  if(rawResults.length!==fixtures.length)throw new Error('Invalid Shen result count/framing: '+invocation.stdout.slice(-2000));
  const rows=[],mutantFailures=[];
  const node=process.execPath;
  const TRAPS={overflow:'Overflow','div-zero':'DivZero'};
  fixtures.forEach((fixture,i)=>{
    const [tag,value]=rawResults[i];
    let reference;
    if(tag==='ok')reference={status:'Ok',value};
    else {
      if(!Object.hasOwn(TRAPS,value))throw new Error('Unexpected model token '+JSON.stringify(value));
      reference={status:'Trap',code:TRAPS[value]};
    }
    const command=[node,candidate,fixture.op,...fixture.args];
    const normal=run(command,5),faulty=run([...command,'--mutant=rounded-add'],5);
    if(normal.status!==0||faulty.status!==0)throw new Error('Candidate crashed/invalid input; not a semantic mutant kill');
    const actual=JSON.parse(normal.stdout),mutated=JSON.parse(faulty.stdout);
    const matches=isDeepStrictEqual(reference,actual)&&isDeepStrictEqual(actual,fixture.expected);
    rows.push({id:fixture.id,expected:fixture.expected,reference,candidate:actual,matches});
    if(!isDeepStrictEqual(mutated,reference))
      mutantFailures.push({id:fixture.id,args:fixture.args,op:fixture.op,reference,mutated});
  });
  const report={
    scope:'Development I64 arithmetic component only; no TC0-A qualification',
    qualification:'UNKNOWN',
    sources:Object.fromEntries([model,candidate,fixturePath,import.meta.filename].map(path=>[relative(ROOT,path),digest(path)])),
    shen_executable:{path:executable,sha256:digest(executable)},
    shen_boot:{path:boot,sha256:digest(boot)},
    cases:rows,rounded_add_mutant_discrepancies:mutantFailures,
    gaps:['G0 isolation/baseline not qualified','No full AST/frame machine, closures or hand-derived step trace',
      'No reduction or exact semantic tape replay','No approved TC0-A evaluator'],
  };
  const output=args.output;
  mkdirSync(dirname(output),{recursive:true});
  writeFileSync(output,reportJson(report)+'\n');
  const allMatch=rows.every(row=>row.matches);
  console.log(JSON.stringify({component_cases:String(rows.length),all_match:allMatch,
    mutant_discrepancies:String(mutantFailures.length),qualification:'UNKNOWN',report:pathText(output)}));
  process.exitCode=allMatch&&mutantFailures.length>0?0:1;
}

if (process.argv[1] && resolve(process.argv[1]) === import.meta.filename) main();
