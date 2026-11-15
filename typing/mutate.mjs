// Systematic single-point mutants of valid artifacts, UNQUALIFIED development family for
// the typing differential (typing/run.shen). Every operator below is applied at every
// point of every seed where it applies, one change per mutant. A mutant's verdict is
// not known in advance: most are ill-typed, some are not (an unused binder may take any
// type), and the differential requires only that the two validators agree on each.
//
// Operators, by what they change:
//   types      literal-swap (int<->bool, unit/bytes->int), prim-swap (add->lt, lt->add,
//              not->neg, neg->not), project-index (+1), var-unbound, signature-swap,
//              lambda-swap, operation-swap, field-swap (I64<->Bool in each annotation)
//   effects    effects-drop, effects-add-emit, effects-add-undeclared, effects-reorder
//              (function and lambda sets), entry-add-user-effect, handle-other-effect,
//              perform-unknown-operation, call-unknown-function
//   clauses    clause-drop, clause-add-resumption (op(x) => c to op(x,k) => c),
//              clause-drop-resumption (op(x,k) => c to op(x) => c), arm-drop, arm-duplicate
//   resumption resume-to-argument (zero uses), discontinue-to-unit (zero uses),
//              resume-twice, resume-as-variable, resume-unequal-paths (1 use against 2)
//   durable    class-swap (durable <-> ordinary)
//   tasks      capacity-edge (0 and 9), channel-element-arrow, channel-element-task,
//              handle-swap (await <-> receive, cancel <-> close), scope-unwrap
//              (scope(b) to b), yield-to-unit, spawn-call (spawn(f) to apply(f, unit))
// When a mutation removes or adds expression nodes the source map is rebuilt to cover
// exactly the program's locations, so the mutant breaks no structural rule by accident.
import {cases as callHand} from '../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlerCases,resumptionCases} from '../fixtures/tc1/handler-hand-cases.mjs';
import {generatePureCalls} from '../tools/tc0/pure-call-generate.mjs';
import {generatePureData} from '../tools/tc0/pure-data-generate.mjs';
import {enumeratePureData} from '../tools/tc0/pure-data-enumerate.mjs';
import {enumerateHandlers} from '../tools/tc1/handler-enumerate.mjs';
import {cases as durableHand} from '../fixtures/tc1/durable-hand-cases.mjs';
import {cases as taskHand} from '../fixtures/tc1/task-hand-cases.mjs';
import {enumerateTasks} from '../tools/tc1/task-enumerate.mjs';

const clone=x=>JSON.parse(JSON.stringify(x));
// Child expression positions of a node: [container, key] pairs.
function children(e) {
  const [tag]=e,at=(...ks)=>ks.map(k=>[e,k]),from=i=>e.slice(i).map((_,j)=>[e,i+j]);
  switch(tag) {
    case 'let':return at(3,4);case 'if':return at(2,3,4);case 'prim':return from(3);case 'tuple':return from(2);
    case 'project':return at(2);case 'construct':return from(4);case 'emit':return at(3);case 'lambda':return at(7);
    case 'apply':return at(2,3);case 'call':return at(3);case 'perform':return at(4);case 'resume':return at(3);
    case 'match':return [[e,2],...e.slice(3).map(arm=>[arm,2])];
    case 'handle':return [...e[3].map(c=>[c,c.length-1]),[e,4]];
    case 'scope':case 'spawn':case 'await':case 'cancel':case 'receive':case 'close':return at(2);
    case 'send':return at(2,3);
    default:return [];
  }
}
// Every expression of a program with the container and key that hold it.
function sites(p) {
  const out=[];const walk=(holder,key)=>{const e=holder[key];out.push({holder,key,e});for(const [h,k] of children(e))walk(h,k);};
  p.functions.forEach(f=>walk(f,'body'));return out;
}
const locations=p=>[...p.functions.map(f=>f.id),...sites(p).map(s=>s.e[1])];
export function resync(p) {
  const rows=new Map(p.source_map.map(r=>[r.id,r]));
  p.source_map=locations(p).map(id=>rows.get(id)??{id,file:'mutant',line:'0',column:'0'});return p;
}
// Fresh IDs above every ID in the program.
function freshIds(p) {
  let next=0n;JSON.stringify(p,(k,v)=>{if(typeof v==='string'&&/^(0|[1-9][0-9]*)$/.test(v)&&BigInt(v)>=next)next=BigInt(v)+1n;return v;});
  return ()=>String(next++);
}
// A copy of e with new node and binder IDs; references to binders outside e are kept.
function reid(e,fresh,names=new Map()) {
  const n=clone(e),bind=x=>{const y=fresh();names.set(x,y);return y;},ref=x=>names.get(x)??x;
  const walk=x=>{
    x[1]=fresh();const [tag]=x;
    if(tag==='var'||tag==='discontinue')x[2]=ref(x[2]);
    if(tag==='resume')x[2]=ref(x[2]);
    if(tag==='let'){walk(x[3]);x[2]=bind(x[2]);walk(x[4]);return;}
    if(tag==='lambda'){x[2]=bind(x[2]);walk(x[7]);return;}
    if(tag==='match'){walk(x[2]);for(const arm of x.slice(3)){arm[1]=arm[1].map(bind);walk(arm[2]);}return;}
    if(tag==='handle'){walk(x[4]);for(const c of x[3]){c[1]=bind(c[1]);if(c.length===4)c[2]=bind(c[2]);walk(c[c.length-1]);}return;}
    for(const [h,k] of children(x))walk(h[k]);
  };
  walk(n);return n;
}
const swap=t=>t==='I64'?'Bool':t==='Bool'?'I64':null;

// Each operator: (program) => list of [label, mutated program]. Labels name the point.
const OPERATORS={
  'literal-swap':p=>sites(p).flatMap(({e},i)=>{
    const to=e[0]==='int'?['bool',e[1],true]:e[0]==='bool'?['int',e[1],'0']:e[0]==='unit'||e[0]==='bytes'?['int',e[1],'0']:null;
    return to?[[`node ${e[1]}`,q=>{sites(q)[i].holder[sites(q)[i].key]=to;}]]:[];}),
  'prim-swap':p=>sites(p).flatMap(({e},i)=>{const to={add:'lt',lt:'add',not:'neg',neg:'not'}[e[0]==='prim'?e[2]:''];
    return to?[[`node ${e[1]}`,q=>{sites(q)[i].e[2]=to;}]]:[];}),
  'project-index':p=>sites(p).flatMap(({e},i)=>e[0]==='project'?[[`node ${e[1]}`,q=>{const x=sites(q)[i].e;x[3]=String(Number(x[3])+1);}]]:[]),
  'var-unbound':p=>sites(p).flatMap(({e},i)=>e[0]==='var'?[[`node ${e[1]}`,q=>{sites(q)[i].e[2]=freshIds(q)();}]]:[]),
  'signature-swap':p=>p.functions.flatMap((f,i)=>['argument_type','result_type'].filter(k=>swap(f[k])).map(k=>[`${f.name}.${k}`,q=>{q.functions[i][k]=swap(q.functions[i][k]);}])),
  'lambda-swap':p=>sites(p).flatMap(({e},i)=>e[0]!=='lambda'?[]:[3,4].filter(k=>swap(e[k])).map(k=>[`node ${e[1]} ${k===3?'parameter':'result'}`,q=>{const x=sites(q)[i].e;x[k]=swap(x[k]);}])),
  'operation-swap':p=>p.effects.flatMap((d,i)=>d.operations.flatMap((o,j)=>['argument_type','result_type'].filter(k=>swap(o[k])).map(k=>[`${d.name}.${o.name}.${k}`,q=>{const r=q.effects[i].operations[j];r[k]=swap(r[k]);}]))),
  'field-swap':p=>p.datatypes.flatMap((d,i)=>d.constructors.flatMap((c,j)=>c.fields.flatMap((t,k)=>swap(t)?[[`${c.name}.${k}`,q=>{q.datatypes[i].constructors[j].fields[k]=swap(t);}]]:[]))),
  'effects-drop':p=>[...p.functions.flatMap((f,i)=>f.effects.map((x,j)=>[`${f.name} drops ${x}`,q=>{q.functions[i].effects.splice(j,1);}])),
    ...sites(p).flatMap(({e},i)=>e[0]==='lambda'?e[5].map((x,j)=>[`node ${e[1]} drops ${x}`,q=>{sites(q)[i].e[5].splice(j,1);}]):[])],
  'effects-add-emit':p=>[...p.functions.flatMap((f,i)=>f.effects.includes('Emit')?[]:[[f.name,q=>{q.functions[i].effects=[...q.functions[i].effects,'Emit'].sort();}]]),
    ...sites(p).flatMap(({e},i)=>e[0]==='lambda'&&!e[5].includes('Emit')?[[`node ${e[1]}`,q=>{const x=sites(q)[i].e;x[5]=[...x[5],'Emit'].sort();}]]:[])],
  'effects-add-undeclared':p=>p.functions.map((f,i)=>[f.name,q=>{q.functions[i].effects=[...q.functions[i].effects,'Zzz'];}]),
  'effects-reorder':p=>p.functions.flatMap((f,i)=>f.effects.length>1?[[f.name,q=>{q.functions[i].effects.reverse();}]]:[]),
  'entry-add-user-effect':p=>p.effects.slice(0,1).map(d=>[d.name,q=>{const f=q.functions.find(f=>f.name===q.entry);f.effects=[...f.effects,d.name].sort();}]),
  'handle-other-effect':p=>sites(p).flatMap(({e},i)=>e[0]==='handle'?[[`node ${e[1]}`,q=>{const x=sites(q)[i].e;x[2]=q.effects.find(d=>d.name!==x[2])?.name??'Zzz';}]]:[]),
  'perform-unknown-operation':p=>sites(p).flatMap(({e},i)=>e[0]==='perform'?[[`node ${e[1]}`,q=>{sites(q)[i].e[3]='zzz';}]]:[]),
  'call-unknown-function':p=>sites(p).flatMap(({e},i)=>e[0]==='call'?[[`node ${e[1]}`,q=>{sites(q)[i].e[2]='zzz';}]]:[]),
  'clause-drop':p=>sites(p).flatMap(({e},i)=>e[0]==='handle'?[[`node ${e[1]}`,q=>{sites(q)[i].e[3].shift();resync(q);}]]:[]),
  'clause-add-resumption':p=>p.schema_version!=='tc1-handler-demo/2'?[]:sites(p).flatMap(({e},i)=>e[0]!=='handle'?[]:e[3].flatMap((c,j)=>c.length===3?[[`node ${e[1]} clause ${j}`,q=>{const c=sites(q)[i].e[3][j];c.splice(2,0,freshIds(q)());}]]:[])),
  'clause-drop-resumption':p=>sites(p).flatMap(({e},i)=>e[0]!=='handle'?[]:e[3].flatMap((c,j)=>c.length===4?[[`node ${e[1]} clause ${j}`,q=>{sites(q)[i].e[3][j].splice(2,1);}]]:[])),
  'arm-drop':p=>sites(p).flatMap(({e},i)=>e[0]==='match'?[[`node ${e[1]}`,q=>{sites(q)[i].e.pop();resync(q);}]]:[]),
  'arm-duplicate':p=>sites(p).flatMap(({e},i)=>e[0]==='match'&&e.length>4?[[`node ${e[1]}`,q=>{const x=sites(q)[i].e,arm=x[x.length-1],first=x[3];
    if(first[1].length!==arm[1].length)return false;arm[0]=first[0];}]]:[]),
  'resume-to-argument':p=>sites(p).flatMap(({e},i)=>e[0]==='resume'?[[`node ${e[1]}`,q=>{const s=sites(q)[i];s.holder[s.key]=s.e[3];resync(q);}]]:[]),
  'discontinue-to-unit':p=>sites(p).flatMap(({e},i)=>e[0]==='discontinue'?[[`node ${e[1]}`,q=>{const s=sites(q)[i];s.holder[s.key]=['unit',s.e[1]];}]]:[]),
  'resume-twice':p=>sites(p).flatMap(({e},i)=>e[0]==='resume'?[[`node ${e[1]}`,q=>{const s=sites(q)[i],fresh=freshIds(q);
    s.holder[s.key]=['let',fresh(),fresh(),s.e,reid(s.e,fresh)];resync(q);}]]:[]),
  'resume-as-variable':p=>sites(p).flatMap(({e},i)=>e[0]==='resume'?[[`node ${e[1]}`,q=>{const s=sites(q)[i];s.holder[s.key]=['var',s.e[1],s.e[2]];resync(q);}]]:[]),
  'class-swap':p=>p.schema_version!=='tc1-durable-demo/1'?[]:p.effects.map((d,i)=>[d.name,q=>{q.effects[i].class=q.effects[i].class==='durable'?'ordinary':'durable';}]),
  'capacity-edge':p=>sites(p).flatMap(({e},i)=>e[0]==='channel'?['0','9'].map(c=>[`node ${e[1]} capacity ${c}`,q=>{sites(q)[i].e[3]=c;}]):[]),
  'channel-element-arrow':p=>sites(p).flatMap(({e},i)=>e[0]==='channel'?[[`node ${e[1]}`,q=>{sites(q)[i].e[2]=['Arrow','Unit','I64',[]];}]]:[]),
  'channel-element-task':p=>sites(p).flatMap(({e},i)=>e[0]==='channel'?[[`node ${e[1]}`,q=>{sites(q)[i].e[2]=['Task',sites(q)[i].e[2]];}]]:[]),
  'handle-swap':p=>sites(p).flatMap(({e},i)=>{const to={await:'receive',receive:'await',cancel:'close',close:'cancel'}[e[0]];
    return to?[[`node ${e[1]}`,q=>{sites(q)[i].e[0]=to;}]]:[];}),
  'scope-unwrap':p=>sites(p).flatMap(({e},i)=>e[0]==='scope'?[[`node ${e[1]}`,q=>{const s=sites(q)[i];s.holder[s.key]=s.e[2];resync(q);}]]:[]),
  'yield-to-unit':p=>sites(p).flatMap(({e},i)=>e[0]==='yield'?[[`node ${e[1]}`,q=>{const s=sites(q)[i];s.holder[s.key]=['unit',s.e[1]];}]]:[]),
  'spawn-call':p=>sites(p).flatMap(({e},i)=>e[0]==='spawn'?[[`node ${e[1]}`,q=>{const s=sites(q)[i],fresh=freshIds(q);
    s.holder[s.key]=['apply',s.e[1],s.e[2],['unit',fresh()]];resync(q);}]]:[]),
  'resume-unequal-paths':p=>sites(p).flatMap(({e},i)=>e[0]==='resume'?[[`node ${e[1]}`,q=>{const s=sites(q)[i],fresh=freshIds(q);
    s.holder[s.key]=['if',fresh(),['bool',fresh(),true],s.e,['let',fresh(),fresh(),reid(s.e,fresh),reid(s.e,fresh)]];resync(q);}]]:[])
};

export function seeds() {
  const every=(xs,n)=>xs.filter((_,i)=>i%n===0);
  return [...callHand,...dataHand,...handlerCases,...resumptionCases,...generatePureCalls(32).cases,...generatePureData(24).cases,
    ...every(enumeratePureData(5).cases,97),...every(enumerateHandlers(7).cases,97),
    ...durableHand,...taskHand,...enumerateTasks().cases.filter(c=>Number(c.name.split('-').at(-1))%37===0)];
}

export function mutants() {
  const out=[];
  for(const seed of seeds())for(const [operator,points] of Object.entries(OPERATORS))for(const [label,mutate] of points(seed.program)) {
    const program=clone(seed.program);
    if(mutate(program)===false)continue;
    program.module=`mutant-${out.length}`;
    out.push({name:`${seed.name} ${operator} ${label}`,operator,program,input:seed.input});
  }
  return out;
}
