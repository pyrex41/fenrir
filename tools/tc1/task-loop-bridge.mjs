// Bounded JSON transport for the TC1-C1 loop-closure harness (harness/tc1-task-loop.shen);
// UNQUALIFIED development tooling. No model transitions; nothing is compared here. A
// defective run that throws is {execution: "Crashed"}, never a kill.
//
//   generated OUT.jsonl SEED COUNT
//       the generated family (task-generate.mjs), each program under the schedule
//       policies POLICIES below: one line {name, seed, shape, schedule, production,
//       program, choices, candidate, mutants} per (program, policy)
//   observe PROGRAM.json POLICY DEFECT OUT.json
//       {choices, candidate, control, mutant} for one program: the policy turned into
//       choices by the defect-free machine, which then runs twice under them (the second
//       run is the equivalent control), and once with DEFECT (a key of task-defects.mjs)
//   reduce PROGRAM.json POLICY DEFECT OUT.json
//       {metric, rejected, proposals} (task-reduce.mjs); every proposal also carries its
//       defect-free run and its DEFECT run under its own schedule
import {readFileSync,writeFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {runSchedule} from '../../runtime/tc1/task-machine.mjs';
import {scheduleFor,isProduction} from './task-schedule.mjs';
import {TASK_MUTANTS} from './task-defects.mjs';
import {generateTaskFamily} from './task-generate.mjs';
import {taskReductions} from './task-reduce.mjs';
const FUEL=1000,INPUT=['int','0'];
export const POLICIES=Object.freeze(['lowest','highest','fifo','random:1','prandom:1']);
const run=(artifact,choices,options)=>{
  try{return runSchedule(artifact,INPUT,choices,options,FUEL);}
  catch(e){if(!Object.keys(options).length)throw e;return {execution:'Crashed',error:String(e.message)};}
};
const [mode,...args]=process.argv.slice(2);
if(mode==='generated'&&args.length===3&&args[0].endsWith('.jsonl')&&/^\d+$/.test(args[1])&&/^\d+$/.test(args[2])) {
  const family=generateTaskFamily({seed:Number(args[1]),count:Number(args[2])}),lines=[];
  for(const c of family.cases)for(const policy of POLICIES) {
    const spec={name:policy,policy},{choices}=scheduleFor(c.program,INPUT,spec,FUEL);
    lines.push(JSON.stringify({name:c.name,seed:c.seed,shape:c.shape,schedule:policy,production:isProduction(spec),program:c.program,choices,
      candidate:run(c.program,choices,{}),mutants:Object.fromEntries(Object.entries(TASK_MUTANTS).map(([k,o])=>[k,run(c.program,choices,{[o]:true})]))}));
  }
  writeFileSync(args[0],lines.join('\n')+'\n',{flag:'wx'});
  console.log(JSON.stringify({programs:family.count,runs:String(lines.length)}));
} else if((mode==='observe'||mode==='reduce')&&args.length===4&&Object.hasOwn(TASK_MUTANTS,args[2])&&args[3].endsWith('.json')) {
  const [path,policy,defect,output]=args;
  const {artifact}=validatePureCallArtifact(readFileSync(path),INPUT);
  const option={[TASK_MUTANTS[defect]]:true};
  if(mode==='observe') {
    const {choices}=scheduleFor(artifact,INPUT,{name:policy,policy},FUEL);
    writeFileSync(output,JSON.stringify({choices,candidate:run(artifact,choices,{}),control:run(artifact,choices,{}),mutant:run(artifact,choices,option)})+'\n',{flag:'wx'});
  } else {
    const r=taskReductions(artifact,policy);
    for(const p of r.proposals){p.candidate=run(p.program,p.choices,{});p.mutant=run(p.program,p.choices,option);}
    writeFileSync(output,JSON.stringify(r)+'\n',{flag:'wx'});
  }
  console.log('{}');
} else throw new Error('Usage: task-loop-bridge.mjs generated OUT.jsonl SEED COUNT | observe|reduce PROGRAM.json POLICY DEFECT OUT.json');
