// Strict-replay peer for the Shen harness; UNQUALIFIED development transport.
// INPUT is JSON lines: first {identity}, then one {name, program, reference, mutant}
// per case, where reference is the model's step list supplied by the harness and
// mutant is null or the name of an implementation defect to enable. For each case
// this records a tape of the implementation against the reference and replays it
// on a fresh machine, using the existing tape code unchanged. It reports what the
// replay found and decides nothing: the harness holds the expectation.
import {readFileSync,writeFileSync} from 'node:fs';
import {encode} from './canonical.mjs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {pureCallHeader} from './pure-call-replay-header.mjs';
import {recordPureCall,replayPureCall} from './pure-call-replay.mjs';
const [input,output]=process.argv.slice(2);
if(!input||!output?.endsWith('.jsonl')||process.argv.length!==4)throw new Error('Usage: replay-reference.mjs INPUT.jsonl OUTPUT.jsonl');
const MUTANTS={'reverse-operands':'reverseOperands','arm-by-position':'armByPosition','wrap-overflow':'wrapOverflow'};
const [head,...rows]=readFileSync(input,'utf8').trimEnd().split('\n').map(line=>JSON.parse(line));
if(!head.identity||rows.length<1||rows.length>64)throw new Error('Expected an identity line and 1..64 cases');
const names=new Set();
const lines=rows.map(row=>{
  if(typeof row.name!=='string'||names.has(row.name))throw new Error('Unique case names');names.add(row.name);
  if(row.mutant!==null&&!Object.hasOwn(MUTANTS,row.mutant))throw new Error('Unknown mutant');
  const checked=validatePureCallArtifact(encode(row.program),['int','0']);
  const machine=()=>new PureCallMachine(checked.artifact,checked.input,row.mutant?{[MUTANTS[row.mutant]]:true}:{});
  const m=machine(),header=pureCallHeader(m,checked.artifact,checked.input,row.reference,head.identity,{run_id:'harness-'+row.name});
  const bundle=recordPureCall(m,row.reference,header),result=replayPureCall(machine(),row.reference,header,bundle);
  return JSON.stringify({name:row.name,mutant:row.mutant,replay:result.replay,conformance:result.conformance,execution:result.execution,
    footer:bundle.footer.kind,divergence_epoch:bundle.footer.kind==='Divergence'?bundle.footer.epoch:null,trace_hash:bundle.footer.trace_hash,steps:String(bundle.steps.length)});
});
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:String(lines.length),output}));
