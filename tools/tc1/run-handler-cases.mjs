// TC1 slice H1 peer for the Shen harness; UNQUALIFIED development transport.
// Validates each hand fixture, runs the JavaScript handler machine and each of its
// injected defects, and writes one JSON line per case:
//   {name, program, expectations, candidate, mutants: {NAME: run}}
// A defective run that throws is recorded as Crashed, never as a kill. Nothing is
// compared here and no model transitions are involved.
import {writeFileSync} from 'node:fs';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {cases} from '../../fixtures/tc1/handler-hand-cases.mjs';
const [output]=process.argv.slice(2);
if(!output?.endsWith('.jsonl')||process.argv.length!==3)throw new Error('Usage: run-handler-cases.mjs OUTPUT.jsonl');
export const MUTANTS={forgotten_resume:'forgottenResume',double_resume:'doubleResume',outermost_handler:'outermostHandler',dynamic_clause_environment:'dynamicClauseEnvironment'};
if(cases.length>32||new Set(cases.map(c=>c.name)).size!==cases.length||cases.some(c=>!/^[a-z][a-z0-9-]*$/.test(c.name)))throw new Error('Unique safe case IDs required, at most 32');
const lines=cases.map(({name,program,...expectations})=>{
  const checked=validatePureCallArtifact(encode(program),['int','0']);
  const run=options=>{
    try{const r=new HandlerMachine(checked.artifact,checked.input,options).run(200);return {execution:r.execution,outcome:r.outcome,steps:r.steps,descriptors:r.descriptors};}
    catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
  };
  return JSON.stringify({name,program:checked.artifact,expectations,candidate:run({}),
    mutants:Object.fromEntries(Object.entries(MUTANTS).map(([key,option])=>[key,run({[option]:true})]))});
});
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:String(lines.length),output}));
