// TC1-C1 peer for the Shen harness (harness/tc1-tasks.shen); UNQUALIFIED development
// transport. For each hand fixture and each of its schedules: validate the program, turn
// the schedule policy into an explicit list of choices with the correct JavaScript task
// machine, run the machine under that list, and run each injected defect under the same
// list. Writes one JSON line per (fixture, schedule):
//   {name, schedule, production, program, choices, expectations, candidate, mutants}
// A run is {execution, steps, outcome?, wait_graph?}. A defective run that throws is
// recorded as {execution: "Crashed"}, never a kill. Nothing is compared here.
import {writeFileSync} from 'node:fs';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {runSchedule} from '../../runtime/tc1/task-machine.mjs';
import {scheduleFor,isProduction} from './task-schedule.mjs';
import {TASK_MUTANTS} from './task-defects.mjs';
import {cases} from '../../fixtures/tc1/task-hand-cases.mjs';
const FUEL=1000;
const [output]=process.argv.slice(2);
if(!output?.endsWith('.jsonl')||process.argv.length!==3)throw new Error('Usage: run-task-cases.mjs OUTPUT.jsonl');
if(cases.length>64||new Set(cases.map(c=>c.name)).size!==cases.length||cases.some(c=>!/^[a-z][a-z0-9-]*$/.test(c.name)))throw new Error('Unique safe case IDs required');
// A schedule's expectations: those for all schedules plus its own. Lists of order
// constraints are joined, per-task and per-channel maps are merged, the rest is replaced.
const LISTS=new Set(['order','absent','absent_before']);
function merge(all,own) {
  const out={...all};
  for(const [k,v] of Object.entries(own))
    out[k]=LISTS.has(k)?[...(all[k]??[]),...v]:v&&typeof v==='object'&&!Array.isArray(v)?{...(all[k]??{}),...v}:v;
  return out;
}
const lines=[];
for(const c of cases) {
  const checked=validatePureCallArtifact(encode(c.program),['int','0']);
  for(const spec of c.schedules) {
    const {choices}=scheduleFor(checked.artifact,checked.input,spec,FUEL);
    const run=options=>{
      try{return runSchedule(checked.artifact,checked.input,choices,options,FUEL);}
      catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
    };
    const expectations=merge(c.all,c.per_schedule[spec.name]??{});
    lines.push(JSON.stringify({name:c.name,schedule:spec.name,production:isProduction(spec),program:checked.artifact,choices,expectations,candidate:run({}),
      mutants:Object.fromEntries(Object.entries(TASK_MUTANTS).map(([key,option])=>[key,run({[option]:true})]))}));
  }
}
writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
console.log(JSON.stringify({cases:String(cases.length),runs:String(lines.length),output}));
