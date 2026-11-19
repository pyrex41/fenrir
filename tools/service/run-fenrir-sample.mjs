// Stage A2 peer for harness/service-fenrir.shen; UNQUALIFIED development transport.
// Runs the JavaScript TC1-D1 implementation on every run of a service sample (the
// handler, a request and the host's replies, as written by the harness) and writes one
// JSON line per run: {name, candidate: {execution, outcome, steps}}. Nothing is compared
// here and no model transitions are involved.
//
//   node tools/service/run-fenrir-sample.mjs SAMPLE.json OUTPUT.jsonl
import {readFileSync,writeFileSync} from 'node:fs';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {DurableMachine} from '../../runtime/tc1/durable-machine.mjs';
const [samplePath,output]=process.argv.slice(2);
if(!samplePath||!output?.endsWith('.jsonl')||process.argv.length!==4)throw new Error('Usage: run-fenrir-sample.mjs SAMPLE.json OUTPUT.jsonl');
const sample=JSON.parse(readFileSync(samplePath,'utf8'));
const lines=sample.programs.map(({name,program,input,replies})=>{
  const checked=validatePureCallArtifact(encode(program),input);
  const r=new DurableMachine(checked.artifact,checked.input).run(5000,replies);
  return JSON.stringify({name,candidate:{execution:r.execution,outcome:r.outcome,steps:r.steps}});
});
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({runs:String(lines.length),output}));
