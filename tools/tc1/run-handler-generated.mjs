// Batch peer of harness/tc1-random.shen, harness/tc1-reduce.shen and
// harness/tc1-replay.shen for TC1 handler programs GENERATED IN SHEN
// (harness/tc1-generate.shen); UNQUALIFIED development transport. Reads the programs,
// asks the validator about each, and runs the JavaScript handler machine on it.
// Nothing here generates a program, runs the model or decides a verdict: the Shen
// harness does the comparing.
//
// Usage: run-handler-generated.mjs IN.jsonl OUTDIR FUEL MODE     (OUTDIR exists and is empty)
// IN.jsonl has one JSON object {name, program} per line. MODE is one of
//   family           the implementation only
//   family:DEFECT    the implementation with DEFECT switched on, reported as the
//                    implementation: a negative control for the family check
//   mutants          the implementation and each of its six injected defects
//   shrink:DEFECT    the implementation and DEFECT, but rows only for the (at most
//                    five) smallest programs on which the two complete with different
//                    traces. This ranks candidates for the shrinker and nothing more:
//                    whether the failure holds is decided in Shen, against the model.
// Writes OUTDIR/family.json {count, invalid, differing, chunks, fuel, mode} and
// OUTDIR/chunk-<i>.jsonl, one JSON line per program in input order:
//   {name, valid: true, nodes, program, candidate, mutants: {NAME: run}}
//   {name, valid: false, error}                 the validator rejected the program
// A run is {execution, outcome, steps}. A run that throws is recorded as
// {execution: "Crashed", error}, never as a kill and never as agreement.
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {isDeepStrictEqual} from 'node:util';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {MUTANTS} from './handler-defects.mjs';
const CHUNK=500,KEEP=5;
const [input,directory,fuelText,mode]=process.argv.slice(2);
const [kind,defect]=(mode??'').split(':');
if(process.argv.length!==6||!/^[1-9][0-9]{0,3}$/.test(fuelText)||!['family','mutants','shrink'].includes(kind)
  ||(defect!==undefined&&!Object.hasOwn(MUTANTS,defect))||(kind==='shrink'&&!defect)||(kind==='mutants'&&defect))
  throw new Error('Usage: run-handler-generated.mjs IN.jsonl OUTDIR FUEL family[:DEFECT]|mutants|shrink:DEFECT');
const fuel=Number(fuelText);
const run=(checked,options)=>{
  try{const r=new HandlerMachine(checked.artifact,checked.input,options).run(fuel);return {execution:r.execution,outcome:r.outcome,steps:r.steps};}
  catch(e){return {execution:'Crashed',error:String(e.message)};}
};
let invalid=0,differing=0;
const rows=readFileSync(input,'utf8').split('\n').filter(Boolean).map(line=>{
  const {name,program}=JSON.parse(line);
  let checked;
  try{checked=validatePureCallArtifact(encode(program),['int','0']);}
  catch(e){invalid++;return {name,valid:false,error:String(e.message)};}
  const row={name,valid:true,nodes:checked.node_count,program:checked.artifact,
    candidate:run(checked,kind==='family'&&defect?{[MUTANTS[defect]]:true}:{}),mutants:{}};
  if(kind==='mutants')for(const [key,option] of Object.entries(MUTANTS))row.mutants[key]=run(checked,{[option]:true});
  if(kind==='shrink') {
    row.mutants[defect]=run(checked,{[MUTANTS[defect]]:true});
    row.differs=row.candidate.execution==='Completed'&&row.mutants[defect].execution==='Completed'
      &&!isDeepStrictEqual(row.candidate.steps,row.mutants[defect].steps);
    if(row.differs)differing++;
  }
  return row;
});
// Shrink mode keeps every rejection (a generator defect the harness must see) and the
// smallest differing programs, earliest first among equals.
const kept=kind!=='shrink'?rows:[...rows.filter(r=>!r.valid),
  ...rows.map((r,i)=>({r,i})).filter(x=>x.r.differs).sort((a,b)=>Number(a.r.nodes)-Number(b.r.nodes)||a.i-b.i).slice(0,KEEP).map(x=>x.r)];
let chunks=0;
for(let first=0;first<kept.length;first+=CHUNK,chunks++)
  writeFileSync(resolve(directory,`chunk-${chunks}.jsonl`),kept.slice(first,first+CHUNK).map(r=>JSON.stringify({...r,differs:undefined})).join('\n')+'\n',{flag:'wx'});
writeFileSync(resolve(directory,'family.json'),JSON.stringify({count:String(rows.length),invalid:String(invalid),differing:String(differing),
  chunks:String(chunks),fuel:String(fuel),mode})+'\n',{flag:'wx'});
console.log(JSON.stringify({count:String(rows.length),chunks:String(chunks),output:directory}));
