// Hand-case peer for the Shen harness; UNQUALIFIED development transport.
// Validates each hand fixture and runs the JavaScript implementation, writing one
// JSON line per case: {name, program, expectations, candidate}. The hand-derived
// expectations are passed through untouched; nothing is compared here and no
// oracle transitions are involved. harness/hand-cases.shen does the checking.
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {encode} from './canonical.mjs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases as callCases} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataCases} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
const [output,family]=process.argv.slice(2);
if(!output?.endsWith('.jsonl')||process.argv.length>4||(family!==undefined&&!['pure-call','pure-data'].includes(family)))throw new Error('Usage: run-pure-call-hand.mjs OUTPUT.jsonl [pure-call|pure-data]');
const fixtures=resolve(import.meta.dirname,'../../fixtures/tc0');
const forward={...JSON.parse(readFileSync(resolve(fixtures,'pure-call-forward-expectations.json'),'utf8')),
  program:JSON.parse(readFileSync(resolve(fixtures,'pure-call-forward.json'),'utf8'))};
if(callCases.length>8||dataCases.length>16)throw new Error('Hand case cap');
// With a family argument the cases are that generated family instead, carrying only the
// expectations its generator derived (outcome and emission order).
let cases=[forward,...callCases,...dataCases];
if(family){
  const generate=family==='pure-data'?(await import('./pure-data-generate.mjs')).generatePureData:(await import('./pure-call-generate.mjs')).generatePureCalls;
  cases=generate(family==='pure-data'?24:32).cases.map(c=>({name:c.name,program:c.program,expected_outcome:c.expected_outcome,...(c.expected_emissions?{expected_emissions:c.expected_emissions}:{})}));
}
if(new Set(cases.map(c=>c.name)).size!==cases.length||cases.some(c=>!/^[a-z][a-z0-9-]*$/.test(c.name)))throw new Error('Unique safe case IDs required');
const lines=cases.map(({name,program,...expectations})=>{
  const checked=validatePureCallArtifact(encode(program),['int','0']);
  const r=new PureCallMachine(checked.artifact,checked.input).run(200);
  return JSON.stringify({name,program:checked.artifact,expectations,
    candidate:{execution:r.execution,outcome:r.outcome,steps:r.steps,descriptors:r.descriptors}});
});
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:String(lines.length),output}));
