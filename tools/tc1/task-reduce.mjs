// Typed, schedule-aware structural proposals for TC1-C1 task programs; UNQUALIFIED
// development reducer. Each proposal is a whole program, normalized, revalidated here by
// the validator (types, effect sets, serializability of what leaves a scope or a task)
// and given a schedule: the policy that exhibited the failure, re-derived on the
// proposal by the defect-free JavaScript machine (tools/tc1/task-schedule.mjs), so the
// schedule is valid for that program by construction; the Shen model then replays it and
// refuses any choice it does not have Runnable. A proposal the validator rejects is
// dropped, never offered. A proposal is a candidate only: the Shen harness accepts it
// only when fresh model and implementation runs under its schedule show the same
// discrepancy class (harness/tc1-task-loop.shen). Crashes never count.
//
// Program rules, at every expression of every function:
//   drop-let            let v = a in b          ->  b
//   let-to-init         let v = a in b          ->  a
//   if-to-branch        if(c, a, b)             ->  a, b
//   prim-to-operand     op(a, b)                ->  a, b
//   match-to-arm        match e {..., C(xs) => a, ...} -> a
//   handle-to-body      handle(E, cs, b)        ->  b
//   perform-to-argument perform(E, op, a)       ->  a
//   scope-to-body       scope(b)                ->  b
//   spawn-body-to-literal  spawn(() => b)       ->  spawn(() => 0)
//   expr-to-literal     an expression of two or more nodes -> 0 or (), whichever type checks
// and effect sets are recomputed by the validator's own rule: each lambda and function
// gets exactly the effects its body still performs (a proposal whose sets do not
// validate is dropped). Schedule rules, for the same program:
//   schedule-policy     the program under another policy (lowest, fifo, highest,
//                       random:1..3), accepted only when it switches tasks less often.
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from '../tc0/pure-call-artifact.mjs';
import {scheduleFor} from './task-schedule.mjs';
const clone=x=>JSON.parse(JSON.stringify(x));
const FUEL=1000,INPUT=['int','0'];
export const SCHEDULE_POLICIES=Object.freeze(['lowest','fifo','highest','random:1','random:2','random:3']);
const order=names=>[...new Set(names)].sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b)));

export function children(e) {
  const t=e[0],from=k=>e.slice(k).map((_,i)=>[i+k]);
  if(t==='let')return [[3],[4]];
  if(t==='if')return [[2],[3],[4]];
  if(t==='prim')return from(3);
  if(t==='apply')return [[2],[3]];
  if(t==='call'||t==='emit')return [[3]];
  if(t==='tuple')return from(2);
  if(t==='project')return [[2]];
  if(t==='construct')return from(4);
  if(t==='match')return [[2],...e.slice(3).map((_,i)=>[i+3,2])];
  if(t==='lambda')return [[7]];
  if(t==='handle')return [...e[3].map((c,i)=>[3,i,c.length-1]),[4]];
  if(t==='perform')return [[4]];
  if(t==='resume')return [[3]];
  if(['scope','spawn','await','cancel','receive','close'].includes(t))return [[2]];
  if(t==='send')return [[2],[3]];
  return [];
}
const at=(e,keys)=>keys.reduce((x,k)=>x[k],e);

// The number of times a schedule switches from one task to another.
export const switches=choices=>choices.reduce((n,c,i)=>n+(i>0&&c!==choices[i-1]?1:0),0);

// Effect sets recomputed from the bodies (CONCURRENCY.md section 2; EFFECTS.md section 1).
function effectsOf(e) {
  const out=new Set(),add=s=>{for(const k of s)out.add(k);},t=e[0];
  if(t==='lambda'){e[5]=order([...effectsOf(e[7])]);return out;}
  if(t==='handle'){for(const c of e[3])add(effectsOf(c.at(-1)));const b=effectsOf(e[4]);b.delete(e[2]);add(b);return out;}
  for(const k of children(e))add(effectsOf(at(e,k)));
  if(t==='spawn'&&e[2][0]==='lambda')add(e[2][5]);
  if(['spawn','scope','await','cancel','yield'].includes(t))out.add('Task');
  if(['channel','send','receive','close'].includes(t))out.add('Channel');
  if(t==='emit')out.add('Emit');
  if(t==='perform')out.add(e[2]);
  return out;
}

export function normalizeTaskProgram(p) {
  const ids=new Set(p.functions.map(f=>f.id)),effects=new Set();
  const walk=e=>{ids.add(e[1]);if(e[0]==='perform'||e[0]==='handle')effects.add(e[2]);for(const k of children(e))walk(at(e,k));};
  for(const f of p.functions){f.effects=order([...effectsOf(f.body)]);walk(f.body);}
  p.source_map=p.source_map.filter(r=>ids.has(r.id));
  const mapped=new Set(p.source_map.map(r=>r.id));
  for(const id of ids)if(!mapped.has(id))p.source_map.push({id,file:'tc1-task-reduced',line:'0',column:'0'});
  p.effects=p.effects.filter(d=>effects.has(d.name));
  return p;
}

export function taskMetric(p,policy) {
  const checked=validatePureCallArtifact(encode(p),INPUT);
  const {choices}=scheduleFor(checked.artifact,INPUT,{name:policy,policy},FUEL);
  return {nodes:Number(checked.node_count),switches:switches(choices),choices};
}

function freshId(p) {
  let max=-1n;
  JSON.stringify(p,(k,v)=>{if(typeof v==='string'&&/^\d+$/.test(v)&&BigInt(v)>max)max=BigInt(v);return v;});
  return String(max+1n);
}

// Proposals for (program, policy), smallest program first; each {rule, path, policy,
// metric:{nodes, switches}, choices, program}.
export function taskReductions(program,policy) {
  const original=taskMetric(program,policy),proposals=[],seen=new Set();
  let rejected=0;
  function propose(p,rule,path,pol=policy) {
    normalizeTaskProgram(p);
    let metric;
    try{metric=taskMetric(p,pol);}
    catch(e){if(e instanceof InvalidPureCallArtifact||e instanceof PureCallValidationLimit){rejected++;return;}throw e;}
    const smaller=metric.nodes<original.nodes||(metric.nodes===original.nodes&&metric.switches<original.switches);
    if(!smaller)return;
    const key=encode(p).toString()+'|'+pol;if(seen.has(key))return;seen.add(key);
    proposals.push({rule,path,policy:pol,metric:{nodes:String(metric.nodes),switches:String(metric.switches)},choices:metric.choices,program:p});
  }
  for(let f=0;f<program.functions.length;f++) {
    const get=(p,path)=>at(p.functions[f].body,path);
    const set=(p,path,value)=>{if(!path.length){p.functions[f].body=value;return;}get(p,path.slice(0,-1))[path.at(-1)]=value;};
    const replaced=(path,make)=>{const p=clone(program);set(p,path,make(p));return p;};
    const replace=(path,replacement,rule)=>propose(replaced(path,()=>clone(replacement)),rule,[String(f),...path.map(String)]);
    function walk(e,path) {
      const t=e[0],here=[String(f),...path.map(String)];
      if(t==='let'){replace(path,e[4],'drop-let');replace(path,e[3],'let-to-init');}
      if(t==='if'){replace(path,e[3],'if-to-branch');replace(path,e[4],'if-to-branch');}
      if(t==='prim')for(const operand of e.slice(3))replace(path,operand,'prim-to-operand');
      if(t==='match')for(const arm of e.slice(3))replace(path,arm[2],'match-to-arm');
      if(t==='handle')replace(path,e[4],'handle-to-body');
      if(t==='perform')replace(path,e[4],'perform-to-argument');
      if(t==='scope')replace(path,e[2],'scope-to-body');
      if(t==='spawn'&&e[2][0]==='lambda'&&e[2][7][0]!=='int')
        propose(replaced([...path,2,7],p=>['int',freshId(p),'0']),'spawn-body-to-literal',here);
      if(children(e).length&&t!=='lambda')for(const [tag,...rest] of [['int','0'],['unit']])propose(replaced(path,p=>[tag,freshId(p),...rest]),'expr-to-literal',here);
      for(const k of children(e))walk(at(e,k),[...path,...k]);
    }
    walk(program.functions[f].body,[]);
  }
  for(const other of SCHEDULE_POLICIES)if(other!==policy)propose(clone(program),'schedule-policy',[],other);
  return {metric:{nodes:String(original.nodes),switches:String(original.switches)},rejected:String(rejected),
    proposals:proposals.sort((a,b)=>Number(a.metric.nodes)-Number(b.metric.nodes)||Number(a.metric.switches)-Number(b.metric.switches))};
}
