// One fresh observation of the JavaScript handler machine for the TC1 reduction
// campaign (harness/tc1-reduction.shen); UNQUALIFIED development transport.
// Usage: handler-observe.mjs PROGRAM.json DEFECT OUTPUT.json
// Validates the program (a rejection is an error: nothing is observed), then runs the
// implementation twice without defects (the second run is the equivalent control) and
// once with DEFECT, a report key of tools/tc1/handler-defects.mjs, enabled. Writes
//   {nodes, candidate, control, mutant}
// where each run is {execution, outcome, steps, descriptors}; a defective run that throws
// is {execution: "Crashed", error}, never a kill. Nothing is compared here.
import {readFileSync,writeFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {MUTANTS} from './handler-defects.mjs';
const FUEL=1000;
const [path,defect,output]=process.argv.slice(2);
if(!path||!Object.hasOwn(MUTANTS,defect??'')||!output?.endsWith('.json')||process.argv.length!==5)throw new Error('Usage: handler-observe.mjs PROGRAM.json DEFECT OUTPUT.json');
const checked=validatePureCallArtifact(readFileSync(path),['int','0']);
const run=options=>{
  try{const r=new HandlerMachine(checked.artifact,checked.input,options).run(FUEL);return {execution:r.execution,outcome:r.outcome,steps:r.steps,descriptors:r.descriptors};}
  catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
};
writeFileSync(output,JSON.stringify({nodes:checked.node_count,candidate:run({}),control:run({}),mutant:run({[MUTANTS[defect]]:true})})+'\n',{flag:'wx'});
