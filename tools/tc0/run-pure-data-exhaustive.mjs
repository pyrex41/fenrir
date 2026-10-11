// Batch candidate peer for the exhaustive-small scope; UNQUALIFIED development transport.
// Validates each enumerated artifact, then runs the candidate and each candidate-only
// mutant. Writes one JSON line per case to OUTPUT; no oracle transitions here.
import {writeFileSync} from 'node:fs';
import {encode} from './canonical.mjs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
import {enumeratePureData} from './pure-data-enumerate.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const [bound,output]=process.argv.slice(2);
if(!/^[1-6]$/.test(bound??'')||!output?.endsWith('.jsonl'))throw new Error('Usage: run-pure-data-exhaustive.mjs MAX_NODES OUTPUT.jsonl');
const family=enumeratePureData(Number(bound));
const lines=[JSON.stringify({...family,cases:undefined})];
for(const c of family.cases){
 const checked=validatePureCallArtifact(encode(c.program),['int','0']);
 // A mutant may crash (e.g. binding a missing field); that is recorded, never a semantic kill.
 const run=options=>{try{const r=new PureCallMachine(checked.artifact,checked.input,options).run(200);return {execution:r.execution,outcome:r.outcome,steps:r.steps};}catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}};
 lines.push(JSON.stringify({name:c.name,nodes:c.nodes,result:c.result,program:c.program,candidate:run({}),reverse_operands:run({reverseOperands:true}),arm_by_position:run({armByPosition:true})}));
}
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({count:family.count,output}));
