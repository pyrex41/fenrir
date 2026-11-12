#!/usr/bin/env node
// G0 exact-arithmetic ledger for the pure-call machine; development tier, NOT qualification.
//
// Core section 17 asks for a demonstration that a Shen port carries exact I64 values,
// intermediates and unsigned IDs, against independently established integer results,
// before it is relied on. This runs, through the full pure-call machine:
//
//   * every binary operation add/sub/mul/div/lt/le/gt/ge over the boundary product
//     V x V and neg over V, where V covers the I64 extremes, values around 2^53, the
//     square-root-of-2^63 boundary for multiplication, and small signed values;
//   * ID cases whose function, node and binding IDs exceed 2^53 and 2^64, including a
//     closure whose two captures must be ordered numerically, not by float value.
//
// Expected outcomes come from exact integers (BigInt), never from a port or the
// candidate. Each Shen port named on the command line (host shen-scheme and/or a
// Yggdrasil-shaken artifact) is checked separately; the candidate's trace must equal
// each port's trace. One ledger row per port.
import {readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {ROOT, MODEL_FILES, digest, synchronous, outputPath, parseList, normalize, modelValue, initialState, Oracle} from './tc0/shen-probe.mjs';
import {commandLine, sameJson, splitLines} from './check-tc0-pure-call.mjs';

const MIN=-(1n<<63n),MAX=(1n<<63n)-1n;
const V=[MIN,MIN+1n,-(1n<<53n)-1n,-(1n<<53n),-3037000500n,-3n,-2n,-1n,0n,1n,2n,3n,
  3037000499n,3037000500n,1n<<53n,(1n<<53n)+1n,1n<<62n,MAX-1n,MAX];
const BINARY=['add','sub','mul','div','lt','le','gt','ge'];
const COMPARE={lt:(a,b)=>a<b,le:(a,b)=>a<=b,gt:(a,b)=>a>b,ge:(a,b)=>a>=b};
const abs=n=>n<0n?-n:n;

// Independent exact result as a pure-call outcome.
function expected(op,a,b=null) {
  if(Object.hasOwn(COMPARE,op))return ['Ok',['bool',COMPARE[op](a,b)]];
  if(op==='div'&&b===0n)return ['Trap','DivZero'];
  let n;
  if(op==='div') {
    // Quotient of magnitudes with the sign applied afterwards: truncation toward zero.
    const q=abs(a)/abs(b);
    n=(a<0n)===(b<0n)?q:-q;
  } else if(op==='add')n=a+b;
  else if(op==='sub')n=a-b;
  else if(op==='mul')n=a*b;
  else if(op==='neg')n=-a;
  else throw new Error('Unknown operation '+op);
  return MIN<=n&&n<=MAX?['Ok',['int',String(n)]]:['Trap','Overflow'];
}

function program(name,result,body,ids=['0','1']) {
  const nodes=[];
  const collect=e=>{
    if(Array.isArray(e)&&e.length>1&&typeof e[0]==='string'&&['int','prim','let','var','lambda','apply'].includes(e[0])) {
      nodes.push(e[1]);
      for(const x of e.slice(2))collect(x);
    }
  };
  collect(body);
  return {contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/2',slice:'TC0-A',module:name,
    datatypes:[],effects:[],functions:[{id:ids[0],name:'main',parameter_id:ids[1],argument_type:'I64',
      result_type:result,effects:[],body}],entry:'main',input_schema:{type:'I64'},
    source_map:[ids[0],...nodes].map(i=>({id:i,file:'ledger',line:'0',column:'0'}))};
}

export function cases() {
  const rows=[];
  for(const op of BINARY)for(const a of V)for(const b of V)
    rows.push({name:`${op}-${rows.length}`,program:program('ledger',Object.hasOwn(COMPARE,op)?'Bool':'I64',
      ['prim','2',op,['int','3',String(a)],['int','4',String(b)]]),expected_outcome:expected(op,a,b),args:[String(a),String(b)]});
  for(const a of V)
    rows.push({name:`neg-${rows.length}`,program:program('ledger','I64',['prim','2','neg',['int','3',String(a)]]),
      expected_outcome:expected('neg',a),args:[String(a)]});
  // IDs beyond 2^53 and 2^64. Captures x=...992 and y=...993 must be ordered numerically.
  const big=k=>String((1n<<53n)+BigInt(k));
  const huge=k=>String((1n<<64n)+BigInt(k));
  const x=big(0),y=big(1),f=huge(5),q=huge(7);
  const body=['let',huge(1),y,['int',huge(2),'20'],['let',huge(3),x,['int',huge(4),'22'],
    ['let',big(9),f,['lambda',big(8),q,'I64','I64',[],[],['prim',big(7),'add',['var',big(6),x],['var',big(5),y]]],
      ['apply',big(4),['var',big(3),f],['int',big(2),'0']]]]];
  rows.push({name:'ids-beyond-2-53-and-2-64',program:program('ledger-ids','I64',body,[String(10n**30n),String(10n**30n+1n)]),
    expected_outcome:['Ok',['int','42']],args:[],expected_capture_order:[x,y]});
  return rows;
}

function main() {
  const args=commandLine('check-tc0-exact-arithmetic.mjs [--shen-executable SHEN] [--oracle-artifact DIR] --output OUTPUT',
    {values:['--shen-executable','--oracle-artifact','--output']},a=>a.output!==undefined);
  const ports=[];
  if(args['shen-executable'])ports.push(['host-shen',new Oracle({shen:args['shen-executable']})]);
  if(args['oracle-artifact'])ports.push(['yggdrasil-shaken',new Oracle({artifact:args['oracle-artifact']})]);
  if(!ports.length)throw new Error('Name at least one Shen port');
  const dest=outputPath(args.output,{fresh:true});
  const node=realpathSync(process.execPath);
  const at=p=>resolve(ROOT,p);
  const paths=[import.meta.filename,at('tools/check-tc0-pure-call.mjs'),at('tools/check-tc0-expression.mjs'),at('tools/tc0/shen-probe.mjs'),at('tools/tc0/run-pure-call-batch.mjs'),
    at('tools/tc0/pure-call-artifact.mjs'),at('tools/tc0/canonical.mjs'),...MODEL_FILES,at('runtime/tc0/pure-call-machine.mjs'),
    ...ports.flatMap(([,o])=>o.identityPaths()),node];
  const snapshot=()=>Object.fromEntries(paths.map(p=>[p,digest(p)]));
  const before=snapshot();
  const rows=cases();
  const batchIn=dest.replace(/\.json$/,'.programs.json'),batchOut=dest.replace(/\.json$/,'.candidate.jsonl');
  writeFileSync(batchIn,JSON.stringify(rows.map(r=>r.program)));
  synchronous([node,at('tools/tc0/run-pure-call-batch.mjs'),batchIn,batchOut],{timeout:300});
  const candidate=splitLines(readFileSync(batchOut,'utf8')).map(l=>JSON.parse(l));
  const ledger=[];
  for(const [label,oracle] of ports) {
    const started=performance.now();
    const {outs}=oracle.run(rows.map(r=>initialState(r.program)),{timeout:1});
    const failures=[];
    // As the former zip(rows, outs, candidate): stop at the shortest.
    for(let index=0;index<Math.min(rows.length,outs.length,candidate.length);index++) {
      const r=rows[index],cand=candidate[index];
      const lines=splitLines(outs[index]);
      if(!lines.length||lines.at(-1).trim()!=='terminal') {
        failures.push({name:r.name,reason:'model incomplete'});
        continue;
      }
      const steps=lines.filter(x=>x.startsWith('[sample ')).map((l,i)=>normalize(parseList(l),i));
      const outcome=steps.at(-1).events[0].outcome;
      const descriptors=lines.filter(l=>l.startsWith('[closure ')).map(l=>modelValue(parseList(l)));
      let ok=sameJson(outcome,r.expected_outcome)&&sameJson(cand.outcome,outcome)&&sameJson(cand.steps,steps);
      if(Object.hasOwn(r,'expected_capture_order'))
        ok=ok&&sameJson(descriptors[0].captures.map(([k])=>k),r.expected_capture_order);
      if(!ok)
        failures.push({name:r.name,args:r.args,expected:r.expected_outcome,model:outcome,
          candidate:cand.outcome,traces_equal:sameJson(cand.steps,steps)});
    }
    ledger.push({port:label,oracle:oracle.describe(),cases:String(rows.length),exact:String(rows.length-failures.length),
      failures:failures.slice(0,20),failure_count:String(failures.length),seconds:Math.round((performance.now()-started)/10)/100});
  }
  if(!sameJson(before,snapshot()))throw new Error('Source/toolchain drift');
  const outcomes={};
  for(const r of rows) {
    const k=r.expected_outcome[0]==='Ok'?'Ok':'Trap '+r.expected_outcome[1];
    outcomes[k]=(outcomes[k]??0)+1;
  }
  const report={schema:'tc0-exact-arithmetic-ledger/1',qualification:'UNKNOWN',sources:before,
    scope:'Boundary product V x V for add/sub/mul/div/lt/le/gt/ge, neg over V, and IDs beyond 2^53/2^64, through the full pure-call machine',
    values:V.map(String),expected_outcomes:outcomes,ledger,
    limitations:['Finite boundary vectors, not all I64 pairs','Agreement between ports supports portability, not semantic truth']};
  writeFileSync(dest,JSON.stringify(report,null,1)+'\n',{flag:'wx'});
  console.log(JSON.stringify({qualification:'UNKNOWN',cases:rows.length,expected_outcomes:outcomes,
    ledger:ledger.map(l=>({port:l.port,exact:l.exact,failure_count:l.failure_count,seconds:l.seconds}))}));
  process.exitCode=ledger.some(l=>l.failures.length)?1:0;
}

if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
