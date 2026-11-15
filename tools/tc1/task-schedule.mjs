// Schedule policies for TC1-C1 (spec/tc1/CONCURRENCY.md section 9); UNQUALIFIED
// development tooling. A policy is turned into an explicit schedule, the list of task
// IDs chosen at each step, by running the JavaScript task machine under it. The
// harness then replays that list on the Shen model, which checks every choice against
// its own Runnable set, and (for a production policy) that every switch follows a
// scheduling point by the model's own step records.
import {TaskMachine} from '../../runtime/tc1/task-machine.mjs';

// xorshift32, seeded: the same seed gives the same schedule on every host.
function rng(seed){let x=(Number(seed)>>>0)||0x9e3779b9;return n=>{x^=x<<13;x>>>=0;x^=x>>>17;x^=x<<5;x>>>=0;return x%n;};}
const matches=(pattern,event)=>Object.entries(pattern).every(([k,v])=>JSON.stringify(event[k])===JSON.stringify(v));

// Is this schedule spec a production one (switches only after scheduling points)?
export const isProduction=spec=>spec.policy==='fifo'||spec.policy.startsWith('prandom:');

// Choices for `spec` on a program: runs the correct machine to a terminal root, a
// deadlock or `fuel` steps. Returns {choices, steps}.
export function scheduleFor(artifact,input,spec,fuel=1000) {
  const m=new TaskMachine(artifact,input),choices=[],steps=[];
  const [kind,arg]=spec.policy.split(':'),pick=arg===undefined?null:rng(arg);
  let queue=['0'],current=null,switchable=true,script=spec.script?[...spec.script]:[];
  while(!m.footer()&&steps.length<fuel) {
    const runnable=m.runnable();let id;
    if(kind==='script'&&script.length){id=script[0].task;}
    else {
      const k=kind==='script'?spec.then:spec.policy,[policy]=k.split(':');
      if(policy==='lowest')id=runnable[0];
      else if(policy==='highest')id=runnable.at(-1);
      else if(policy==='random')id=runnable[pick(runnable.length)];
      else if(policy==='prandom')id=switchable||!runnable.includes(current)?runnable[pick(runnable.length)]:current;
      else if(policy==='fifo')id=switchable||!runnable.includes(current)?queue.shift():current;
      else throw new Error('Unknown policy '+k);
    }
    if(!runnable.includes(id))throw new Error(`Policy ${spec.name} chose ${id}, which is not Runnable`);
    const record=m.step(id);choices.push(id);steps.push(record);
    if(kind==='script'&&script.length&&record.events.some(e=>matches(script[0].until,e)))script.shift();
    // FIFO bookkeeping (section 9): tasks made Runnable in the step join the back in the
    // order they became so; after a scheduling point the current task joins behind them.
    queue.push(...m.becameRunnable.filter(x=>!queue.includes(x)));
    switchable=record.point||!record.runnable.includes(id);current=id;
    if(switchable&&record.runnable.includes(id)&&!queue.includes(id))queue.push(id);
    queue=queue.filter(x=>record.runnable.includes(x));
  }
  return {choices,steps};
}
