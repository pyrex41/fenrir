// Synchronous JSON bridge for trusted-local development campaigns. No verdict authority.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {generate} from './generate.mjs';
import {proposals,metric} from './reduce.mjs';
import {validateArtifact} from './artifact.mjs';
import {encode,decode} from './canonical.mjs';
import {ExpressionMachine} from '../../runtime/tc0/expression-machine.mjs';
import {record,replay,checkpointHash,candidateStateHash} from './replay.mjs';
const request=decode(readFileSync(0));
const digest=b=>createHash('sha256').update(b).digest('hex');
const source=p=>digest(readFileSync(new URL('../../'+p,import.meta.url)));
let response;
if(request.action==='generate') response=[...generate({maxCases:Number(request.max_cases)})];
else {
 const graph=validateArtifact(encode(request.artifact),request.input),fn=graph.artifact.functions[0];
 const machine=mutant=>new ExpressionMachine(fn.body,fn.parameter_id,graph.input,{reverseOperands:mutant});
 if(request.action==='proposals') response=[...proposals(graph.artifact,graph.input)].map(row=>({...row,metric:row.metric.map(String)}));
 else if(request.action==='run') response={control:machine(false).run(200),mutant:machine(true).run(200),metric:metric(graph.artifact,graph.input).map(String)};
 else if(request.action==='replay') {
  const reference=request.reference,peer=machine(true);
  const header={schema:'arithmetic-demo-tape/1',contract:'0.2',slice:'TC0-A',profile:'arithmetic-demo-frames/1',run_id:request.run_id,
   artifact_hash:digest(encode(graph.artifact)),input_hash:digest(encode(graph.input)),oracle_hash:checkpointHash(reference),
   oracle_source_hash:checkpointHash([source('models/tc0/arithmetic.shen'),source('models/tc0/expression-machine.shen'),source('tools/check-tc0-expression.py'),source('tools/check-tc0-reduction.py'),request.shen_hash,request.shen_boot_hash]),
   catalog_hash:source('spec/tc0/arithmetic-demo-frames.json'),monitor_hash:source('tools/tc0/replay.mjs'),
   adapter_hash:checkpointHash([source('tools/tc0/artifact.mjs'),source('tools/tc0/canonical.mjs'),source('tools/tc0/reduction-bridge.mjs')]),
   candidate_hash:source('runtime/tc0/expression-machine.mjs'),compiler_runtime_hash:digest(readFileSync(process.execPath)),
   environment_hash:checkpointHash({node:process.version,platform:process.platform,arch:process.arch,mode:'trusted-local-development'}),
   initial_state_hash:candidateStateHash(peer),candidate_options:{reverse_operands:true},bounds:{reference_steps:'200'}};
  const bundle=record(peer,reference,header);response={bundle,replay:replay(machine(true),reference,header,bundle)};
 } else throw new Error('Unknown bridge action');
}
process.stdout.write(encode(response));
