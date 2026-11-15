// Batch peer of harness/tc1-exhaustive.shen for the exhaustive-small TC1 handler scope;
// UNQUALIFIED development transport. Enumerates grammar H (handler-enumerate.mjs) to the
// bound, validates each program, and runs the JavaScript handler machine and each of its
// six injected defects on it. Nothing is compared here and no model transitions are
// involved: the Shen harness does the comparing.
//
// Usage: run-handler-exhaustive.mjs MAX_NODES OUTDIR      (OUTDIR exists and is empty)
// Writes OUTDIR/family.json, the enumeration header with `chunks`, the number of chunk
// files, and OUTDIR/chunk-<i>.jsonl for i in 0..chunks-1, one JSON line per program:
//   {name, nodes, program, candidate, mutants: {NAME: run}}
// in enumeration order. A run is {execution, outcome, steps}. A defective run that
// throws is recorded as {execution: "Crashed", error}, never as a kill. The traces are
// chunked so the harness never holds more than one chunk of them.
import {writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {enumerateHandlers} from './handler-enumerate.mjs';
import {MUTANTS} from './handler-defects.mjs';
const CHUNK=500,FUEL=200;
const [bound,directory]=process.argv.slice(2);
if(!/^[1-7]$/.test(bound??'')||!directory||process.argv.length!==4)throw new Error('Usage: run-handler-exhaustive.mjs MAX_NODES OUTDIR');
const family=enumerateHandlers(Number(bound));
let chunks=0;
for(let first=0;first<family.cases.length;first+=CHUNK,chunks++) {
  const lines=family.cases.slice(first,first+CHUNK).map(c=>{
    const checked=validatePureCallArtifact(encode(c.program),['int','0']);
    const run=options=>{
      try{const r=new HandlerMachine(checked.artifact,checked.input,options).run(FUEL);return {execution:r.execution,outcome:r.outcome,steps:r.steps};}
      catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
    };
    return JSON.stringify({name:c.name,nodes:c.nodes,program:checked.artifact,candidate:run({}),
      mutants:Object.fromEntries(Object.entries(MUTANTS).map(([key,option])=>[key,run({[option]:true})]))});
  });
  writeFileSync(resolve(directory,`chunk-${chunks}.jsonl`),lines.join('\n')+'\n',{flag:'wx'});
}
writeFileSync(resolve(directory,'family.json'),JSON.stringify({...family,cases:undefined,chunks:String(chunks)})+'\n',{flag:'wx'});
console.log(JSON.stringify({count:family.count,chunks:String(chunks),output:directory}));
