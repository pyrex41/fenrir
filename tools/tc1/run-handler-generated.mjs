// Batch peer of harness/tc1-generated.shen for the generated TC1 handler family G
// (handler-generate.mjs); UNQUALIFIED development transport. Generates the first COUNT
// programs, validates each, and runs the JavaScript handler machine and each of its six
// injected defects on it. Nothing is compared here and no model transitions are
// involved: the Shen harness does the comparing.
//
// Usage: run-handler-generated.mjs COUNT OUTDIR      (OUTDIR exists and is empty)
// Writes OUTDIR/family.json, the family header with `chunks` and `fuel`, and
// OUTDIR/chunk-<i>.jsonl, one JSON line per program in index order:
//   {name, nodes, program, candidate, mutants: {NAME: run}}
// A run is {execution, outcome, steps, descriptors}. A defective run that throws is
// recorded as {execution: "Crashed", error}, never as a kill.
import {writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {generateHandlers} from './handler-generate.mjs';
import {MUTANTS} from './handler-defects.mjs';
const GENERATED_FUEL=1000;
const CHUNK=256;
const [count,directory]=process.argv.slice(2);
if(!/^[1-9][0-9]*$/.test(count??'')||!directory||process.argv.length!==4)throw new Error('Usage: run-handler-generated.mjs COUNT OUTDIR');
const family=generateHandlers(Number(count));
let chunks=0;
for(let first=0;first<family.cases.length;first+=CHUNK,chunks++) {
  const lines=family.cases.slice(first,first+CHUNK).map(c=>{
    const checked=validatePureCallArtifact(encode(c.program),['int','0']);
    const run=options=>{
      try{const r=new HandlerMachine(checked.artifact,checked.input,options).run(GENERATED_FUEL);return {execution:r.execution,outcome:r.outcome,steps:r.steps,descriptors:r.descriptors};}
      catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
    };
    return JSON.stringify({name:c.name,nodes:c.nodes,program:checked.artifact,candidate:run({}),
      mutants:Object.fromEntries(Object.entries(MUTANTS).map(([key,option])=>[key,run({[option]:true})]))});
  });
  writeFileSync(resolve(directory,`chunk-${chunks}.jsonl`),lines.join('\n')+'\n',{flag:'wx'});
}
writeFileSync(resolve(directory,'family.json'),JSON.stringify({...family,cases:undefined,chunks:String(chunks),fuel:String(GENERATED_FUEL)})+'\n',{flag:'wx'});
console.log(JSON.stringify({count:family.count,chunks:String(chunks),output:directory}));
