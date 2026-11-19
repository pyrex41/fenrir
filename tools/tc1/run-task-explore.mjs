// Peer of harness/tc1-task-explore.shen for the exhaustive-small TC1-C1 scope; UNQUALIFIED
// development transport. Two modes; nothing is compared here and no model is involved.
//
//   run-task-explore.mjs enumerate OUTDIR
//     enumerates grammar G (task-enumerate.mjs), validates every program, and writes
//     OUTDIR/family.json (the enumeration header with `chunks`) and OUTDIR/programs-<i>.jsonl,
//     one JSON line {name, program, template} per program.
//   run-task-explore.mjs witnesses OUTDIR
//     reads OUTDIR/witnesses.jsonl, lines {name, schedule, choices} written by the Shen
//     harness (one per observation class it found), runs the JavaScript task machine under
//     each schedule (and the nine injected defects under the first witness of each
//     program), and writes OUTDIR/witness-runs-<i>.jsonl, lines {name, schedule,
//     candidate, mutants}, and OUTDIR/witness-runs.json. A defective run that throws is
//     {execution: "Crashed"}, never a kill.
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {runSchedule} from '../../runtime/tc1/task-machine.mjs';
import {enumerateTasks} from './task-enumerate.mjs';
import {TASK_MUTANTS} from './task-defects.mjs';
const CHUNK=400,WITNESS_CHUNK=300,FUEL=1000;
const [mode,directory]=process.argv.slice(2);
if(!['enumerate','witnesses'].includes(mode)||!directory||process.argv.length!==4)throw new Error('Usage: run-task-explore.mjs enumerate|witnesses OUTDIR');
const family=enumerateTasks();
if(mode==='enumerate') {
  let chunks=0;
  for(let first=0;first<family.cases.length;first+=CHUNK,chunks++)
    writeFileSync(resolve(directory,`programs-${chunks}.jsonl`),family.cases.slice(first,first+CHUNK).map(c=>JSON.stringify(c)).join('\n')+'\n',{flag:'wx'});
  writeFileSync(resolve(directory,'family.json'),JSON.stringify({...family,cases:undefined,chunks:String(chunks)})+'\n',{flag:'wx'});
  console.log(JSON.stringify({count:family.count,chunks:String(chunks)}));
} else {
  // Defects run on the first witness of each program (schedule obs-0) only, to bound the
  // output; the correct machine runs on every witness. Output is chunked so the harness
  // holds one chunk of traces at a time: OUTDIR/witness-runs-<i>.jsonl and
  // OUTDIR/witness-runs.json with the number of chunks.
  const programs=new Map(family.cases.map(c=>[c.name,c.program]));
  const witnesses=readFileSync(resolve(directory,'witnesses.jsonl'),'utf8').split('\n').filter(Boolean).map(line=>JSON.parse(line));
  let chunks=0;
  for(let first=0;first<witnesses.length;first+=WITNESS_CHUNK,chunks++) {
    const lines=witnesses.slice(first,first+WITNESS_CHUNK).map(w=>{
      const checked=validatePureCallArtifact(encode(programs.get(w.name)),['int','0']);
      const run=options=>{
        try{return runSchedule(checked.artifact,checked.input,w.choices,options,FUEL);}
        catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
      };
      const mutants=w.schedule==='obs-0'?Object.fromEntries(Object.entries(TASK_MUTANTS).map(([k,o])=>[k,run({[o]:true})])):{};
      return JSON.stringify({name:w.name,schedule:w.schedule,candidate:run({}),mutants});
    });
    writeFileSync(resolve(directory,`witness-runs-${chunks}.jsonl`),lines.join('\n')+'\n',{flag:'wx'});
  }
  writeFileSync(resolve(directory,'witness-runs.json'),JSON.stringify({witnesses:String(witnesses.length),chunks:String(chunks)})+'\n',{flag:'wx'});
  console.log(JSON.stringify({witnesses:String(witnesses.length),chunks:String(chunks)}));
}
