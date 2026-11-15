// Strict tape record/replay of the TC1-C1 JavaScript task machine against the model's
// reference trace; UNQUALIFIED development replay, the C1 counterpart of
// tools/tc1/handler-replay.mjs. THE TAPE BINDS THE SCHEDULE: its header carries the hash
// of the explicit choice list, and every recorded step names the task chosen; replay
// re-executes a fresh machine under exactly those choices and requires every step and
// the footer to equal the tape. A step that differs from the reference ends the tape
// with a Divergence footer at that epoch.
//
//   node tools/tc1/task-replay.mjs INPUT.jsonl OUTPUT.jsonl
// INPUT: a line {identity}, then one {name, program, choices, reference, mutant,
// tamper?} per case: reference the model's step records (supplied by the Shen harness),
// mutant null or a defect key (task-defects.mjs). tamper, for the negative tests, edits
// the recorded tape before the replay: "choice" (a recorded choice names another task),
// "step" (a recorded step's depth), "schedule" (replay under a schedule that differs from
// the one the header binds), "program" (replay against another program's identity),
// "catalog" (the header names another catalog). Output: per case {name, mutant, record
// (footer kind), divergence_epoch, replay ("Exact" or the refusal), conformance}.
// Reports only; the harness holds the expectations.
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {TaskMachine} from '../../runtime/tc1/task-machine.mjs';
import {TASK_MUTANTS} from './task-defects.mjs';

export const TAPE_SCHEMA='tc1-task-tape/1',TAPE_PROFILE='tc1-task-step/1',MAX_STEPS=1000;
export class TaskReplayRefused extends Error {}
const hash=x=>createHash('sha256').update(typeof x==='string'||Buffer.isBuffer(x)?x:encode(x)).digest('hex');
const copy=x=>JSON.parse(JSON.stringify(x));
const equal=(a,b)=>encode(a).equals(encode(b));
const root=resolve(import.meta.dirname,'../..');
const source=f=>hash(readFileSync(resolve(root,f)));
export const IMPLEMENTATION_HASH=hash(['runtime/tc1/task-machine.mjs','runtime/tc1/handler-machine.mjs'].map(source).join(''));
export const CATALOG_HASH=source('spec/tc1/task-catalog.json');

export function header(artifact,choices,reference,identity,options) {
  return {schema:TAPE_SCHEMA,profile:TAPE_PROFILE,program_hash:hash(artifact),input_hash:hash(['int','0']),
    schedule_hash:hash(choices),reference_hash:hash(reference),implementation_hash:IMPLEMENTATION_HASH,catalog_hash:CATALOG_HASH,
    identity_hash:hash(identity),options:Object.keys(options).sort(),bounds:{steps:String(MAX_STEPS)}};
}
function execute(artifact,choices,reference,options,saved) {
  const m=new TaskMachine(artifact,['int','0'],options),steps=[];let footer=null;
  for(const id of choices) {
    if(m.footer()||steps.length>=MAX_STEPS)break;
    if(!m.runnable().includes(id)){footer={kind:'ScheduleDiverged',epoch:String(steps.length)};break;}
    const actual=copy(m.step(id));steps.push(actual);
    if(saved&&(!saved.steps[steps.length-1]||!equal(actual,saved.steps[steps.length-1])))throw new TaskReplayRefused('Diverged:step '+(steps.length-1));
    const expected=reference[steps.length-1];
    if(!expected||!equal(actual,expected)){footer={kind:'Divergence',epoch:actual.epoch};break;}
  }
  if(!footer){const f=m.footer();footer=f?{kind:f.execution==='Completed'?'Completed':'Deadlock'}:{kind:'ScheduleIncomplete'};}
  footer.trace_hash=hash(steps);
  if(saved&&(steps.length!==saved.steps.length||!equal(footer,saved.footer)))throw new TaskReplayRefused('Diverged:footer');
  return {steps,footer};
}
export function record(artifact,choices,reference,identity,options) {
  const h=header(artifact,choices,reference,identity,options),{steps,footer}=execute(artifact,choices,reference,options);
  return {header:h,choices:steps.map(s=>s.task),steps,footer};
}
// Replay a tape for (artifact, choices, reference): the header must name exactly these,
// the choices recorded must be the schedule's prefix that ran, and a fresh run must
// reproduce every step and the footer.
export function replay(tape,artifact,choices,reference,identity,options) {
  const h=header(artifact,choices,reference,identity,options);
  for(const k of Object.keys(h))if(!equal(h[k],tape.header[k]))throw new TaskReplayRefused('Incompatible:'+k);
  if(Object.keys(tape.header).length!==Object.keys(h).length)throw new TaskReplayRefused('Incompatible:header');
  if(!equal(tape.choices,choices.slice(0,tape.choices.length))||!equal(tape.choices,tape.steps.map(s=>s.task)))throw new TaskReplayRefused('Diverged:choices');
  execute(artifact,choices,reference,options,tape);
  return {replay:'Exact',conformance:tape.footer.kind==='Divergence'?'Diverged':['Completed','Deadlock'].includes(tape.footer.kind)?'Admitted':'Unknown'};
}

function main() {
  const [input,output]=process.argv.slice(2);
  if(!input||!output?.endsWith('.jsonl')||process.argv.length!==4)throw new Error('Usage: task-replay.mjs INPUT.jsonl OUTPUT.jsonl');
  const [head,...rows]=readFileSync(input,'utf8').trimEnd().split('\n').map(line=>JSON.parse(line));
  if(!head.identity||rows.length<1||rows.length>512)throw new Error('Expected an identity line and 1..512 cases');
  const lines=rows.map(row=>{
    if(row.mutant!==null&&!Object.hasOwn(TASK_MUTANTS,row.mutant))throw new Error('Unknown mutant');
    try {
      const {artifact}=validatePureCallArtifact(encode(row.program),['int','0']);
      const options=row.mutant?{[TASK_MUTANTS[row.mutant]]:true}:{};
      const tape=record(artifact,row.choices,row.reference,head.identity,options);
      let artifact2=artifact,choices2=row.choices;
      if(row.tamper==='choice'&&tape.choices.length>1){const i=tape.choices.length-1;tape.choices[i]=tape.choices[i]==='0'?'1':'0';}
      if(row.tamper==='step'&&tape.steps.length)tape.steps[0].depth=String(Number(tape.steps[0].depth)+1);
      if(row.tamper==='schedule')choices2=[...row.choices.slice(0,-1),row.choices.at(-1)==='0'?'1':'0'];
      if(row.tamper==='program')artifact2={...artifact,module:artifact.module+'-other'};
      if(row.tamper==='catalog')tape.header.catalog_hash='0'.repeat(64);
      let result;
      try{result=replay(tape,artifact2,choices2,row.reference,head.identity,options);}
      catch(e){if(!(e instanceof TaskReplayRefused))throw e;result={replay:e.message,conformance:null};}
      return JSON.stringify({name:row.name,mutant:row.mutant,tamper:row.tamper??null,record:tape.footer.kind,
        divergence_epoch:tape.footer.kind==='Divergence'?tape.footer.epoch:null,steps:String(tape.steps.length),...result});
    } catch(e){return JSON.stringify({name:row.name,mutant:row.mutant,replay:'Error',error:String(e.message)});}
  });
  writeFileSync(output,lines.join('\n')+'\n',{flag:'wx'});
  console.log(JSON.stringify({cases:String(lines.length)}));
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
