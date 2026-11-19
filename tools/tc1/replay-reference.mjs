// Strict-replay peer for the Shen harness, TC1 handlers; UNQUALIFIED development
// transport. The TC1 counterpart of tools/tc0/replay-reference.mjs.
// INPUT is JSON lines: first {identity}, then one {name, program, reference, mutant}
// per case, where reference is the model's step list supplied by the harness and
// mutant is null or the report key of an injected handler defect to enable
// (tools/tc1/handler-defects.mjs). For each case this validates the program, records a
// tape of the implementation against the reference, and replays the tape on a fresh
// machine. It reports what the replay found and decides nothing: the harness holds the
// expectation.
import {readFileSync,writeFileSync} from 'node:fs';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {MUTANTS} from './handler-defects.mjs';
import {handlerHeader} from './handler-replay-header.mjs';
import {recordHandlers,replayHandlers} from './handler-replay.mjs';
const [input,output]=process.argv.slice(2);
if(!input||!output?.endsWith('.jsonl')||process.argv.length!==4)throw new Error('Usage: replay-reference.mjs INPUT.jsonl OUTPUT.jsonl');
const [head,...rows]=readFileSync(input,'utf8').trimEnd().split('\n').map(line=>JSON.parse(line));
if(!head.identity||rows.length<1||rows.length>64)throw new Error('Expected an identity line and 1..64 cases');
const names=new Set();
const lines=rows.map(row=>{
  if(typeof row.name!=='string'||names.has(row.name))throw new Error('Unique case names');names.add(row.name);
  if(row.mutant!==null&&!Object.hasOwn(MUTANTS,row.mutant))throw new Error('Unknown mutant');
  // A case that cannot be recorded or replayed is reported as an error, never as a result.
  try{
  const checked=validatePureCallArtifact(encode(row.program),['int','0']);
  const machine=()=>new HandlerMachine(checked.artifact,checked.input,row.mutant?{[MUTANTS[row.mutant]]:true}:{});
  const m=machine(),header=handlerHeader(m,checked.artifact,checked.input,row.reference,head.identity,{run_id:'harness-'+row.name});
  const bundle=recordHandlers(m,checked.artifact,checked.input,row.reference,header);
  const replay=machine(),expected=handlerHeader(replay,checked.artifact,checked.input,row.reference,head.identity,{run_id:'harness-'+row.name});
  const result=replayHandlers(replay,checked.artifact,checked.input,row.reference,expected,bundle);
  return JSON.stringify({name:row.name,mutant:row.mutant,replay:result.replay,conformance:result.conformance,execution:result.execution,
    footer:bundle.footer.kind,divergence_epoch:bundle.footer.kind==='Divergence'?bundle.footer.epoch:null,trace_hash:bundle.footer.trace_hash,
    catalog_hash:header.catalog_hash,steps:String(bundle.steps.length)});
  }catch(e){return JSON.stringify({name:row.name,mutant:row.mutant,replay:'Error',error:String(e.message)});}
});
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:String(lines.length),output}));
