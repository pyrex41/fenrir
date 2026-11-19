// Seeded generated family for TC1-C1 beyond grammar G (spec/tc1/CONCURRENCY.md);
// UNQUALIFIED development generator. A program is main : I64 -> I64:
//
//   let c0 = channel(I64, K0) in [let c1 = channel(I64, K1) in]   K in {1, 2}
//   [scope(] let t1 = spawn(() => B1) in let t2 = spawn(() => B2) in [let t3 = spawn(() => B3) in]
//            R; 0 [)]                                             the spawns optionally in an explicit scope
//
// A child body Bi is 1 to 3 actions, then the value 0; an action is one of
//   send(c, v), match receive(c) {Item(x) => x, End => 0}, emit("e", v), yield, div(1, 0)
//   (a trap), close(c), cancel(tj) and match await(tj) {Ok(x) => x, Cancelled => 0,
//   Failed(f) => 0} for an earlier sibling j < i, a nested scope that spawns a grandchild
//   with one action and does one action itself, and a handler inside the task:
//   handle Tick {tick(n) => n + 1} in (emit("h", perform Tick.tick(v)); ...), a channel
//   made and dropped (channel(I64, 1)), and a scope abandoned by discontinue:
//   handle Stop {stop(x, k) => discontinue(k); 0} in scope(spawn(() => 0); perform Stop.stop(v); 0).
// R is 0 to 2 root actions from send, receive, cancel, await, close, emit.
// Values are 100 * task + 10 * position + 1, so every value names its origin.
// Effect sets are computed exactly, from the rules of CONCURRENCY.md section 2 (spawn
// adds the function's effects and Task; scope, await, cancel, yield add Task; the
// channel forms add Channel; emit adds Emit; handle Tick removes Tick); the validator
// then judges every program, and a rejection is a generator defect that stops the run.
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

export const TASK_GENERATED_SCHEMA='tc1-task-generated/1';
function rng(seed){let x=(Number(seed)>>>0)||0x9e3779b9;return n=>{x^=x<<13;x>>>=0;x^=x>>>17;x^=x<<5;x>>>=0;return x%n;};}
const order=names=>[...new Set(names)].sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b)));

export function generateTaskProgram(seed,name) {
  const pick=rng(seed),chance=(n,d)=>pick(d)<n;
  let next=0n;const fresh=()=>String(next++),locations=[];
  const node=(tag,...rest)=>{const id=fresh();locations.push(id);return [tag,id,...rest];};
  const fnId=fresh(),parameter=fresh();locations.push(fnId);
  const int=n=>node('int',String(n));
  const v=id=>node('var',id);
  const shape=[];
  let usesTick=false,usesStop=false;
  const channels=[{id:null,capacity:String(1+pick(2))}];
  if(chance(1,2))channels.push({id:null,capacity:String(1+pick(2))});
  const children=2+(chance(1,3)?1:0),inScope=chance(1,3);
  const handles=[];
  const ch=()=>channels[pick(channels.length)];
  // One action of task `task` at position `k`; `siblings` the handles it may cancel or await.
  function action(task,k,siblings,depth,allowed) {
    const value=100*task+10*k+1;
    const kinds=allowed.filter(a=>(a!=='cancel'&&a!=='await')||siblings.length);
    const a=kinds[pick(kinds.length)];shape.push(`${task}:${a}`);
    const c=ch();
    if(a==='send')return node('send',v(c.id),int(value));
    if(a==='receive'){const x=fresh();return node('match',node('receive',v(c.id)),['Item',[x],v(x)],['End',[],int(0)]);}
    if(a==='emit')return node('emit','e',int(value));
    if(a==='yield')return node('yield');
    if(a==='trap')return node('prim','div',int(1),int(0));
    if(a==='close')return node('close',v(c.id));
    const t=siblings[pick(siblings.length)];
    if(a==='cancel')return node('cancel',v(t));
    if(a==='await'){const x=fresh(),f=fresh();return node('match',node('await',v(t)),['Ok',[x],v(x)],['Cancelled',[],int(0)],['Failed',[f],int(0)]);}
    if(a==='scope'&&depth===0){
      const g=lambda(seq([action(10*task+1,0,[],1,['send','receive','emit','yield','trap'])]));
      const t2=fresh();
      return node('scope',node('let',t2,node('spawn',g),seq([action(task,k+5,[t2],1,['send','receive','emit','cancel','await'])])));
    }
    if(a==='newchan')return node('channel','I64','1');
    if(a==='abandon'&&depth===0){
      usesStop=true;const x=fresh(),k=fresh(),t3=fresh();
      const body=node('scope',node('let',t3,node('spawn',lambda(int(0))),node('let',fresh(),node('perform','Stop','stop',int(value)),int(0))));
      return node('handle','Stop',[['stop',x,k,node('let',fresh(),node('discontinue',k),int(0))]],body);
    }
    if(a==='handler'&&depth===0){
      usesTick=true;const n=fresh();
      return node('handle','Tick',[['tick',n,node('prim','add',v(n),int(1))]],node('emit','h',node('perform','Tick','tick',int(value))));
    }
    return node('yield');
  }
  function seq(actions){const go=i=>i===actions.length?int(0):node('let',fresh(),actions[i],go(i+1));return go(0);}
  function lambda(body){return node('lambda',fresh(),'Unit','I64',null,[],body);}
  const CHILD=['send','receive','emit','yield','trap','close','cancel','await','scope','handler','newchan','abandon'];
  const ROOT=['send','receive','cancel','await','close','emit'];
  const bind=(init,body)=>{const id=fresh();const n=node('let',id,init,null);n[4]=body(id);return n;};
  function spawns(i) {
    if(i>children) {
      const r=pick(3);const acts=[];for(let k=0;k<r;k++)acts.push(action(0,k,handles,0,ROOT));
      return seq(acts);
    }
    const before=[...handles];
    const count=1+pick(3),acts=[];for(let k=0;k<count;k++)acts.push(action(i,k,before,0,CHILD));
    const f=lambda(seq(acts));
    return bind(node('spawn',f),id=>{handles.push(id);return spawns(i+1);});
  }
  const body=bind(node('channel','I64',channels[0].capacity),c0=>{channels[0].id=c0;
    const rest=()=>inScope?node('scope',spawns(1)):spawns(1);
    return channels.length>1?bind(node('channel','I64',channels[1].capacity),c1=>{channels[1].id=c1;return rest();}):rest();});
  // Effect sets, exactly, bottom up.
  function effects(e) {
    const [tag]=e,out=new Set();const add=s=>{for(const k of s)out.add(k);};
    const sub=x=>Array.isArray(x)&&typeof x[0]==='string'&&typeof x[1]==='string'&&/^\d+$/.test(x[1]);
    if(tag==='lambda'){const inner=effects(e[7]);e[5]=order([...inner]);return new Set();}
    if(tag==='match'){add(effects(e[2]));for(const arm of e.slice(3))add(effects(arm[2]));}
    else if(tag==='handle'){for(const c of e[3])add(effects(c.at(-1)));const b=effects(e[4]);b.delete(e[2]);add(b);}
    else for(const x of e.slice(2))if(sub(x))add(effects(x));
    if(tag==='spawn'){add(e[2][5]);out.add('Task');}
    if(['scope','await','cancel','yield'].includes(tag))out.add('Task');
    if(['channel','send','receive','close'].includes(tag))out.add('Channel');
    if(tag==='emit')out.add('Emit');
    if(tag==='perform')out.add(e[2]);
    return out;
  }
  const mainEffects=order([...effects(body)]);
  return {contract_version:'tc1-draft-1',schema_version:'tc1-task-demo/1',slice:'TC1-C1',module:name,datatypes:[],
    effects:[...(usesStop?[{name:'Stop',operations:[{name:'stop',argument_type:'I64',result_type:'Unit'}]}]:[]),
             ...(usesTick?[{name:'Tick',operations:[{name:'tick',argument_type:'I64',result_type:'I64'}]}]:[])],
    functions:[{id:fnId,name:'main',parameter_id:parameter,argument_type:'I64',result_type:'I64',effects:mainEffects,body}],entry:'main',
    input_schema:{type:'I64'},source_map:locations.map(id=>({id,file:'tc1-task-generated',line:'0',column:'0'})),shape};
}

// The family: COUNT programs from SEED, each seed SEED + i. Every program must validate.
export function generateTaskFamily({seed=1,count=200}={}) {
  const cases=[];
  for(let i=0;i<count;i++) {
    const name=`tc1-task-generated-${i}`,raw=generateTaskProgram(seed+i,name),{shape,...program}=raw;
    try{validatePureCallArtifact(encode(program),['int','0']);}
    catch(e){throw new Error(`Generated program ${name} (seed ${seed+i}) is rejected by the validator (${e.message}): ${shape.join(' ')}`);}
    cases.push({name,seed:String(seed+i),shape,program});
  }
  return {schema:TASK_GENERATED_SCHEMA,generator:'tools/tc1/task-generate.mjs',seed:String(seed),count:String(count),cases};
}
