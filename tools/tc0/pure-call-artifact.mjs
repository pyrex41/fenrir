// UNQUALIFIED integrated pure-call demo. Older demo schemas remain closed.
// Schema /1 is the Unit/Bool/I64 call/closure demo. Schema /2 adds the TC0-A
// data built-ins: Bytes, TrapCode, tuples, declared datatypes,
// construct/match/project, bytes_length/bytes_index/bytes_concat and eq.
// Schema tc1-handler-demo/1 (contract spec/tc1/EFFECTS.md) adds everything in /2
// plus effect declarations, handle and perform, with finite effect sets.
// Schema tc1-handler-demo/2 adds explicit one-shot resumptions: clauses op(x,k),
// resume(k,e) and discontinue(k), with k used exactly once on every path.
// Schema tc1-handler-demo/3 (slice TC1-R1, EFFECTS.md §3, §8, §12.2) adds the remote
// effect class: every effect declaration states its class, "ordinary" or "remote", and
// every operation of a remote effect states read_only. A remote operation op : A -> B
// is declared with the peer's own types. The caller's perform takes tuple(key, a) with
// key : I64 (just a, when the operation is read-only) and has the type ["Remote", B],
// a closed sum with the constructors reply(B), not_delivered and timed_out, in that
// order, which only an exhaustive match takes apart. No handle discharges a remote
// effect, and the entry function may leave it unhandled: the system does.
// Must-use (EFFECTS.md §3, owner ruling of 16 November 2026 on §12.10 question 11): a
// perform of a remote operation is the scrutinee of a match and nothing else, and the
// type ["Remote", B] is written nowhere in an artifact: it is the type of that perform
// node only. So an outcome exists only between a remote perform and the match that
// takes it apart, and none is bound, passed, returned, stored, compared or dropped.
// Schema tc1-handler-demo/4 (slice TC1-P1, EFFECTS.md §8, §12.12) is a PEER's program: it
// serves remote effects. It has no entry and no input: `serves` names, for every operation
// of every served remote effect, the function that implements it, {Tuple(I64, A) -> B} for
// an operation that is not read-only (the request key first) and {A -> B} for a read-only
// one. Its functions may use two effects that are not declared and cannot be declared or
// handled, the peer's store, of the durable class: StoreRead {get : I64 -> I64} and
// StoreWrite {put : Tuple(I64, I64) -> Unit}. The function of a served operation may leave
// only Emit and the store effects unhandled, and the function of a READ-ONLY operation may
// not have StoreWrite in its effect set (owner ruling of 16 November 2026 on §12.10
// question 13). A serving program performs no remote operation.
// Schema tc1-durable-demo/1 (TC1-D1) extends /2 independently of /3 and /4.
// Its effect classes are ordinary and durable, and only Emit and declared
// durable effects may remain in the entry's effect row.
// Schema tc1-task-demo/1 (TC1-C1, spec/tc1/CONCURRENCY.md) independently extends
// /2 with structured tasks and bounded channels, not host or remote effects.
import {decode,encode,decimal} from './canonical.mjs';
export class InvalidPureCallArtifact extends Error {}
export class PureCallValidationLimit extends Error {}
export const PURE_CALL_SCHEMAS=Object.freeze(['tc0-a-pure-call-demo/1','tc0-a-pure-call-demo/2']);
export const TC1_HANDLER_SCHEMA='tc1-handler-demo/1';
export const TC1_RESUMPTION_SCHEMA='tc1-handler-demo/2';
export const TC1_REMOTE_SCHEMA='tc1-handler-demo/3';
export const TC1_SERVING_SCHEMA='tc1-handler-demo/4';
export const TC1_DURABLE_SCHEMA='tc1-durable-demo/1';
export const TC1_TASK_SCHEMA='tc1-task-demo/1';
export const TC1_TIME_SCHEMA='tc1-time-demo/1';
export const isTaskSchema=s=>s===TC1_TASK_SCHEMA||s===TC1_TIME_SCHEMA;
const TASK_RUNTIME_EFFECTS=Object.freeze(['Task','Channel']);
const TASK_TYPES=Object.freeze(['Task','Channel','Outcome','SendResult','ReceiveResult']);
export const taskResults=t=>t==='SendResult'?[{name:'Sent',fields:[]},{name:'Closed',fields:[]}]
 :Array.isArray(t)&&t[0]==='Outcome'?[{name:'Ok',fields:[t[1]]},{name:'Cancelled',fields:[]},{name:'Failed',fields:['TrapCode']}]
 :Array.isArray(t)&&t[0]==='ReceiveResult'?[{name:'Item',fields:[t[1]]},{name:'End',fields:[]}]:null;
// The peer's store: the two effects a serving program is given, with their one operation each.
export const STORE_EFFECTS=Object.freeze({StoreRead:Object.freeze({name:'get',argument_type:'I64',result_type:'I64'}),
  StoreWrite:Object.freeze({name:'put',argument_type:Object.freeze(['Tuple','I64','I64']),result_type:'Unit'})});
export const STORE_WRITE='StoreWrite';
// Whether a serving artifact mentions the store's write effect anywhere: in a function's
// or a lambda's effect set, in a function type, or in a perform. A validated artifact that
// performs it has it in an effect set; all four are looked at all the same.
export function mentionsStoreWrite(artifact){
 const inType=t=>Array.isArray(t)&&(t[0]==='Arrow'?t[3].includes(STORE_WRITE)||inType(t[1])||inType(t[2]):t.slice(1).some(inType));
 const inExpr=e=>Array.isArray(e)&&((e[0]==='perform'&&e[2]===STORE_WRITE)||(e[0]==='lambda'&&(e[5].includes(STORE_WRITE)||inType(e[3])||inType(e[4])))||e.slice(2).some(inExpr));
 return artifact.functions.some(f=>f.effects.includes(STORE_WRITE)||inType(f.argument_type)||inType(f.result_type)||inExpr(f.body))||
  artifact.datatypes.some(d=>d.constructors.some(c=>c.fields.some(inType)));
}
export const EFFECT_CLASSES=Object.freeze(['ordinary','remote']);
const DURABLE_EFFECT_CLASSES=Object.freeze(['ordinary','durable']);
// The outcome of a remote perform: the datatype name its values carry, and its constructors.
export const REMOTE_RESULT='RemoteResult';
export const REMOTE_OUTCOMES=Object.freeze(['reply','not_delivered','timed_out']);
export const RESERVED_EFFECTS=Object.freeze(['Emit','Task','Channel','Time','Resource']);
export const TRAP_CODES=Object.freeze(['Overflow','DivZero','Bounds','InvalidDuration','TaskLimit','ChildFailed']);
const fail=s=>{throw new InvalidPureCallArtifact(s);};
const same=(a,b)=>encode(a).equals(encode(b));
const object=(v,keys)=>{if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).sort().join(',')!==[...keys].sort().join(','))fail('Closed object fields');};
const array=v=>{if(!Array.isArray(v))fail('Array required');return v;};
const text=v=>{if(typeof v!=='string')fail('String required');};
const unsigned=v=>{try{decimal(v,{unsigned:true});}catch{fail('Unsigned ID');}};
const identifier=v=>{text(v);if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(v)||v.length>64)fail('Identifier');};
const hex=v=>{text(v);if(!/^(?:[0-9a-f]{2})*$/.test(v))fail('Bytes hex');};
const ids=a=>[...a].sort((x,y)=>BigInt(x)<BigInt(y)?-1:BigInt(x)>BigInt(y)?1:0);
const arities={add:2,sub:2,mul:2,div:2,neg:1,lt:2,le:2,gt:2,ge:2,not:1,bytes_length:1,bytes_index:2,bytes_concat:2,eq:2};
const dataPrimitives=new Set(['bytes_length','bytes_index','bytes_concat','eq']);
const dataTags=new Set(['bytes','tuple','project','construct','match']);

// Find a smallest witness within the value depth and size bounds; ties use
// declaration order. Memoize failed recursive searches as well as successes;
// shared witness subtrees still count toward the size cap.
function probeInput(type,datatypes,maxDepth,maxNodes){
 const builtin={Unit:['unit'],Bool:['bool',false],I64:['int','0'],Bytes:['bytes',''],TrapCode:['data','TrapCode','Overflow']};
 const memo=[];
 function probe(t,depth){
  if(depth>maxDepth)return null;
  const row=memo[depth]??(memo[depth]=new Map());if(row.has(t))return row.get(t);
  const compound=(head,fields)=>{
   const value=[...head];let size=1;
   for(const field of fields){
    const child=probe(field,depth+1);
    if(!child||size+child.size>maxNodes)return null;
    size+=child.size;value.push(child.value);
   }
   return {value,size};
  };
  let result=null;
  if(typeof t==='string'&&Object.hasOwn(builtin,t))result={value:builtin[t],size:1};
  else if(t[0]==='Tuple')result=compound(['tuple'],t.slice(1));
  else if(t[0]==='Data'){
   for(const c of datatypes.get(t[1]).constructors){
    const candidate=compound(['data',t[1],c.name],c.fields);
    if(candidate&&(!result||candidate.size<result.size))result=candidate;
    if(result?.size===1)break;
   }
  }
  row.set(t,result);return result;
 }
 return probe(type,0)?.value;
}

// The frontend has no real host request at check/emit time. This explicitly
// selects a typed probe while retaining the same validator, including value checks.
const DURABLE_INPUT_PROBE=Symbol('durable input probe');
export function validateFrontendArtifact(bytes,limits){
 return validatePureCallArtifact(bytes,DURABLE_INPUT_PROBE,limits);
}

// D1 capability manifest, from a validated artifact rather than from a run.
// PR10's remote and serving effects belong to a different ABI.
export function residualEffects(artifact){
 if(artifact.schema_version!==TC1_DURABLE_SCHEMA)return [];
 const entry=artifact.functions.find(f=>f.name===artifact.entry);
 return artifact.effects.filter(d=>d.class==='durable'&&entry.effects.includes(d.name));
}

export function validatePureCallArtifact(bytes,input,{maxNodes=200,maxDepth=64,maxBytes=256,maxValueNodes=1000,maxCapacity=8}={}){
 for(const n of [maxNodes,maxDepth,maxBytes,maxValueNodes])if(!Number.isSafeInteger(n)||n<1)throw new TypeError('Invalid cap');
 const a=decode(bytes),serving=a?.schema_version===TC1_SERVING_SCHEMA;
 object(a,serving?['contract_version','schema_version','slice','module','datatypes','effects','functions','serves','source_map']:['contract_version','schema_version','slice','module','datatypes','effects','functions','entry','input_schema','source_map']);
 const remote=serving||a.schema_version===TC1_REMOTE_SCHEMA,durable=a.schema_version===TC1_DURABLE_SCHEMA;
 const timed=a.schema_version===TC1_TIME_SCHEMA, tasks=isTaskSchema(a.schema_version);
 const runtimeEffects=timed?[...TASK_RUNTIME_EFFECTS,'Time']:TASK_RUNTIME_EFFECTS;
 if(tasks&&(!Number.isSafeInteger(maxCapacity)||maxCapacity<1))throw new TypeError('Invalid cap');
 const resumptions=tasks||remote||durable||a.schema_version===TC1_RESUMPTION_SCHEMA,handlers=resumptions||a.schema_version===TC1_HANDLER_SCHEMA;
 if(handlers?(a.contract_version!=='tc1-draft-1'||a.slice!==(serving?'TC1-P1':remote?'TC1-R1':durable?'TC1-D1':timed?'TC1-T1':tasks?'TC1-C1':resumptions?'TC1-H2':'TC1-H1')):(a.contract_version!=='0.2'||!PURE_CALL_SCHEMAS.includes(a.schema_version)||a.slice!=='TC0-A'))fail('Identity');text(a.module);
 const data=handlers||a.schema_version==='tc0-a-pure-call-demo/2';
 if(array(a.effects).length&&!handlers)fail('Effect declarations unsupported');
 if(a.effects.length>8&&durable)fail('Effect count');
 // Effect sets: at most Emit before TC1; under TC1 any declared effect or Emit, in
 // unsigned UTF-8 byte order with no duplicates (one canonical spelling per set).
 const declared=new Map();
 // In D1 a datatype field can be an arrow naming a declared effect even
 // though its operation types are checked only after the datatype table.
 const effectNames=durable||tasks?new Set(a.effects.map(d=>d?.name)):declared;
 function effects(v){
  array(v);
  if(!handlers){if(v.length>1||(v.length===1&&v[0]!=='Emit'))fail('Effect set');return;}
  v.forEach((k,i)=>{text(k);if(k!=='Emit'&&!effectNames.has(k)&&!(serving&&Object.hasOwn(STORE_EFFECTS,k))&&!(tasks&&runtimeEffects.includes(k)))fail('Effect set');if(i&&Buffer.compare(Buffer.from(v[i-1]),Buffer.from(k))>=0)fail('Effect set order');});
 }
 if(array(a.datatypes).length&&!data)fail('Declarations unsupported');
 // Datatype table: closed declarations, unique names, constructors in declared order.
 const datatypes=new Map();
 if(a.datatypes.length>16)fail('Datatype count');
 for(const d of a.datatypes){object(d,['name','constructors']);identifier(d.name);if(['Unit','Bool','I64','Bytes','TrapCode'].includes(d.name)||(remote&&d.name===REMOTE_RESULT)||(tasks&&TASK_TYPES.includes(d.name))||datatypes.has(d.name))fail('Datatype name');if(!array(d.constructors).length||d.constructors.length>16)fail('Constructor count');const seen=new Set();for(const c of d.constructors){object(c,['name','fields']);identifier(c.name);if(seen.has(c.name))fail('Duplicate constructor');seen.add(c.name);if(array(c.fields).length>8)fail('Field count');}datatypes.set(d.name,d);}
 const builtin=t=>['Unit','Bool','I64'].includes(t)||(data&&['Bytes','TrapCode'].includes(t))||(tasks&&t==='SendResult');
 function type(t,depth=0){
  if(depth>16)throw new PureCallValidationLimit('Type depth');if(builtin(t))return;array(t);
  if(t[0]==='Arrow'&&t.length===4){type(t[1],depth+1);type(t[2],depth+1);effects(t[3]);return;}
  if(data&&t[0]==='Tuple'&&t.length>=2&&t.length<=9){for(const x of t.slice(1))type(x,depth+1);return;}
  if(data&&t[0]==='Data'&&t.length===2&&datatypes.has(t[1]))return;
  if(tasks&&t[0]!=='SendResult'&&TASK_TYPES.includes(t[0])&&t.length===2){type(t[1],depth+1);return;}
  if(remote&&t[0]==='Remote')fail('The outcome type Remote cannot be written');
  fail('Type');
 }
 // Constructor table for one concrete type: declared datatypes, the TrapCode enum, or
 // the three outcomes of a remote perform.
 const constructors=t=>t==='TrapCode'?TRAP_CODES.map(name=>({name,fields:[]})):Array.isArray(t)&&t[0]==='Data'?datatypes.get(t[1]).constructors:
  Array.isArray(t)&&t[0]==='Remote'?REMOTE_OUTCOMES.map((name,i)=>({name,fields:i?[]:[t[1]]})):tasks?taskResults(t):null;
 const dataName=t=>typeof t==='string'?t:t[0]==='Remote'?REMOTE_RESULT:t[0]==='Data'?t[1]:t[0];
 for(const d of a.datatypes)for(const c of d.constructors)for(const f of c.fields)type(f);
 // Serializable and equality-compatible coincide in this slice: both exclude
 // functions. Traverse declarations with cycle detection (recursive types).
 function plain(t,visiting=new Set()){
  if(typeof t==='string')return true;if(t[0]==='Arrow')return false;if(t[0]==='Tuple')return t.slice(1).every(x=>plain(x,visiting));if(t[0]==='Remote')return plain(t[1],visiting);
  if(tasks&&(t[0]==='Task'||t[0]==='Channel'))return false;
  if(tasks&&(t[0]==='Outcome'||t[0]==='ReceiveResult'))return plain(t[1],visiting);
  if(visiting.has(t[1]))return true;visiting.add(t[1]);const ok=datatypes.get(t[1]).constructors.every(c=>c.fields.every(f=>plain(f,visiting)));visiting.delete(t[1]);return ok;
 }
 // Effect declarations: operations A -> B. In this slice A and B are serializable
 // types, so no closure crosses an operation boundary.
 if(!durable&&a.effects.length>8)fail('Effect count');
 // R1/P1 and D1 have closed, distinct class sets. Only remote operations
 // can carry read_only, and H1/H2 have no class field.
 for(const d of a.effects){object(d,remote||durable?['name','class','operations']:['name','operations']);if((remote&&!EFFECT_CLASSES.includes(d.class))||(durable&&!DURABLE_EFFECT_CLASSES.includes(d.class)))fail('Effect class');const far=d.class==='remote';identifier(d.name);if(RESERVED_EFFECTS.includes(d.name)||(serving&&Object.hasOwn(STORE_EFFECTS,d.name))||declared.has(d.name))fail('Effect name');
  if(!array(d.operations).length||d.operations.length>8)fail('Operation count');const seen=new Set();
  for(const o of d.operations){object(o,far?['name','argument_type','result_type','read_only']:['name','argument_type','result_type']);if(far&&typeof o.read_only!=='boolean')fail('Operation read_only');identifier(o.name);if(seen.has(o.name))fail('Duplicate operation');seen.add(o.name);type(o.argument_type);type(o.result_type);if(!plain(o.argument_type)||!plain(o.result_type))fail('Operation types must be serializable');}
  declared.set(d.name,d);}
 let valueCount=0;
 function value(v,t,depth=0){
  if(++valueCount>maxValueNodes||depth>maxDepth)throw new PureCallValidationLimit('Value cap');array(v);
  if(t==='Unit'&&v.length===1&&v[0]==='unit')return;if(t==='Bool'&&v.length===2&&v[0]==='bool'&&typeof v[1]==='boolean')return;
  if(t==='I64'&&v.length===2&&v[0]==='int'){try{decimal(v[1]);const n=BigInt(v[1]);if(n>=-(1n<<63n)&&n<(1n<<63n))return;}catch{}}
  if(t==='Bytes'&&v.length===2&&v[0]==='bytes'){hex(v[1]);if(v[1].length/2>maxBytes)throw new PureCallValidationLimit('Bytes cap');return;}
  if(Array.isArray(t)&&t[0]==='Tuple'&&v[0]==='tuple'&&v.length===t.length){t.slice(1).forEach((x,i)=>value(v[i+1],x,depth+1));return;}
  const table=constructors(t);if(table&&v[0]==='data'&&v.length>=3&&same(v[1],dataName(t))){const c=table.find(c=>c.name===v[2]);if(c&&v.length===3+c.fields.length){c.fields.forEach((f,i)=>value(v[i+3],f,depth+1));return;}}
  fail('Value type/range');
 }
 const ID=new Set(),locations=new Set(),functions=new Map(),codes=[];let count=0;
 const fresh=(id,location=false)=>{unsigned(id);if(ID.has(id))fail('Duplicate ID');ID.add(id);if(location)locations.add(id);};
 if(!array(a.functions).length||a.functions.length>32)fail('Function count');
 for(const f of a.functions){object(f,['id','name','parameter_id','argument_type','result_type','effects','body']);fresh(f.id,true);fresh(f.parameter_id);text(f.name);if(functions.has(f.name))fail('Duplicate function name');type(f.argument_type);type(f.result_type);effects(f.effects);functions.set(f.name,f);}
 if(!serving){
  const entry=functions.get(a.entry);if(!entry)fail('Entry');
  if(entry.effects.some(k=>k!=='Emit'&&!(remote&&declared.get(k)?.class==='remote')&&!(durable&&declared.get(k)?.class==='durable')&&!(tasks&&runtimeEffects.includes(k))))fail('Entry must handle every user effect');
  if(!plain(entry.argument_type)||!plain(entry.result_type))fail('Serializable entry');object(a.input_schema,['type']);if(!same(a.input_schema.type,entry.argument_type))fail('Input schema');
  if(input===DURABLE_INPUT_PROBE){
   input=durable?probeInput(entry.argument_type,datatypes,maxDepth,maxValueNodes):['int','0'];
   if(!input)throw new PureCallValidationLimit('No bounded durable entry input');
  }
  value(input,entry.argument_type);
 }
 if(input===DURABLE_INPUT_PROBE)input=['int','0']; // Serving artifacts have no entry input.
 const union=rows=>new Set(rows.flatMap(r=>[...r.effects]));
 const free=rows=>new Set(rows.flatMap(r=>[...r.free]));
 const primitive={add:['I64','I64','I64'],sub:['I64','I64','I64'],mul:['I64','I64','I64'],div:['I64','I64','I64'],neg:['I64','I64'],lt:['I64','I64','Bool'],le:['I64','I64','Bool'],gt:['I64','I64','Bool'],ge:['I64','I64','Bool'],not:['Bool','Bool'],bytes_length:['Bytes','I64'],bytes_index:['Bytes','I64','I64'],bytes_concat:['Bytes','Bytes','Bytes']};
 // One-shot resumptions: uses[k] counts the uses of resumption binder k on the path
 // through the expression just visited. Children add into the enclosing count; if and
 // match, whose branches are alternatives, require equal counts and count one branch.
 let uses={};
 // Must-use: the node a match is about to scrutinise. A remote perform must be that node.
 let scrutinised=null;
 const sameUses=(a,b)=>{const keys=new Set([...Object.keys(a),...Object.keys(b)]);for(const k of keys)if((a[k]??0)!==(b[k]??0))return false;return true;};
 const discount=u=>{for(const [k,n] of Object.entries(u))uses[k]-=n;};
 const plainEnv=env=>new Map([...env].filter(([,t])=>!(Array.isArray(t)&&t[0]==='Resumption')));
 function visit(e,env,depth=0){
  const outer=uses;uses={};const row=visitNode(e,env,depth);row.uses=uses;
  for(const [k,n] of Object.entries(uses))outer[k]=(outer[k]??0)+n;uses=outer;return row;
 }
 function visitNode(e,env,depth=0){
  if(++count>maxNodes||depth>maxDepth)throw new PureCallValidationLimit('AST cap');array(e);if(e.length<2)fail('Expression');fresh(e[1],true);
  const [tag,node,...x]=e,arity=n=>{if(x.length!==n)fail('Arity');},v=e=>visit(e,env,depth+1);let t,eff=new Set(),fv=new Set();
  if(dataTags.has(tag)&&!data)fail('Unsupported tag');
  if(['unit','bool','int'].includes(tag)){arity(tag==='unit'?0:1);t={unit:'Unit',bool:'Bool',int:'I64'}[tag];value([tag,...x],t);}
  else if(tag==='bytes'){arity(1);t='Bytes';value(['bytes',x[0]],t);}
  else if(tag==='var'){arity(1);unsigned(x[0]);if(!env.has(x[0]))fail('Unknown binding');t=env.get(x[0]);if(Array.isArray(t)&&t[0]==='Resumption')fail('A resumption is not a value');fv.add(x[0]);}
  else if(tag==='let'){arity(3);fresh(x[0]);const init=v(x[1]),inner=new Map(env);inner.set(x[0],init.type);const body=visit(x[2],inner,depth+1);body.free.delete(x[0]);t=body.type;eff=union([init,body]);fv=free([init,body]);}
  else if(tag==='if'){arity(3);const rows=x.map(v);if(rows[0].type!=='Bool'||!same(rows[1].type,rows[2].type))fail('If types');if(!sameUses(rows[1].uses,rows[2].uses))fail('A resumption must be used on every path');discount(rows[2].uses);t=rows[1].type;eff=union(rows);fv=free(rows);}
  else if(tag==='prim'){
   const [op,...operands]=x;if(!Object.hasOwn(arities,op)||operands.length!==arities[op]||(dataPrimitives.has(op)&&!data))fail('Primitive');const rows=operands.map(v);
   if(op==='eq'){if(!same(rows[0].type,rows[1].type)||!plain(rows[0].type))fail('Equality type');t='Bool';}
   else{const sig=primitive[op];if(rows.some((r,i)=>!same(r.type,sig[i])))fail('Primitive type');t=sig.at(-1);}
   eff=union(rows);fv=free(rows);
  }
  else if(tag==='tuple'){if(x.length<1||x.length>8)fail('Tuple arity');const rows=x.map(v);t=['Tuple',...rows.map(r=>r.type)];eff=union(rows);fv=free(rows);}
  else if(tag==='project'){arity(2);unsigned(x[1]);const row=v(x[0]);if(!Array.isArray(row.type)||row.type[0]!=='Tuple'||BigInt(x[1])>=BigInt(row.type.length-1))fail('Projection');t=row.type[Number(x[1])+1];eff=row.effects;fv=row.free;}
  else if(tag==='construct'){
   if(x.length<2)fail('Arity');const [name,ctor,...operands]=x;text(name);text(ctor);const ty=name==='TrapCode'?'TrapCode':['Data',name];if(name!=='TrapCode'&&!datatypes.has(name))fail('Unknown datatype');
   const c=constructors(ty).find(c=>c.name===ctor);if(!c||operands.length!==c.fields.length)fail('Constructor');const rows=operands.map(v);if(rows.some((r,i)=>!same(r.type,c.fields[i])))fail('Constructor field type');t=ty;eff=union(rows);fv=free(rows);
  }
  else if(tag==='match'){
   if(x.length<2)fail('Arity');const [scrutinee,...arms]=x;scrutinised=scrutinee;const row=v(scrutinee),table=constructors(row.type);if(!table)fail('Match scrutinee type');
   if(arms.length!==table.length)fail('Non-exhaustive or duplicate match arms');const seen=new Set(),rows=[row];let result;
   for(const arm of arms){array(arm);if(arm.length!==3)fail('Match arm');const [ctor,binders,body]=arm;text(ctor);const c=table.find(c=>c.name===ctor);if(!c||seen.has(ctor))fail('Non-exhaustive or duplicate match arms');seen.add(ctor);
    if(array(binders).length!==c.fields.length)fail('Match binders');const inner=new Map(env);binders.forEach((b,i)=>{fresh(b);inner.set(b,c.fields[i]);});
    const out=visit(body,inner,depth+1);for(const b of binders)out.free.delete(b);if(result!==undefined&&!same(result,out.type))fail('Match arm types');result=out.type;rows.push(out);}
   for(const arm of rows.slice(2)){if(!sameUses(rows[1].uses,arm.uses))fail('A resumption must be used on every path');discount(arm.uses);}
   t=result;eff=union(rows);fv=free(rows);
  }
  else if(tag==='emit'){arity(2);text(x[0]);const row=v(x[1]);if(!plain(row.type))fail('Emit serializable');t='Unit';eff=union([row]);eff.add('Emit');fv=row.free;}
  else if(tag==='lambda'){arity(6);fresh(x[0]);type(x[1]);type(x[2]);effects(x[3]);if(array(x[4]).length)fail('Empty capture support required');const inner=plainEnv(env);inner.set(x[0],x[1]);const body=visit(x[5],inner,depth+1);if(!same(body.type,x[2])||[...body.effects].some(k=>!x[3].includes(k)))fail('Lambda signature');body.free.delete(x[0]);fv=body.free;t=['Arrow',x[1],x[2],x[3]];codes.push({code_id:node,parameter_id:x[0],free_bindings:ids(fv),capture_support:[]});}
  else if(tag==='apply'){arity(2);const rows=x.map(v),arrow=rows[0].type;if(!Array.isArray(arrow)||arrow[0]!=='Arrow'||!same(arrow[1],rows[1].type))fail('Apply type');t=arrow[2];eff=union(rows);for(const k of arrow[3])eff.add(k);fv=free(rows);}
  else if(tag==='call'){arity(2);text(x[0]);const f=functions.get(x[0]);if(!f)fail('Unknown function');const row=v(x[1]);if(!same(row.type,f.argument_type))fail('Call argument');t=f.result_type;eff=union([row]);for(const k of f.effects)eff.add(k);fv=row.free;}
  else if(tag==='perform'&&handlers){
   // A remote operation op : A -> B is performed with tuple(key, a), key : I64, or with a
   // alone when it is read-only, and yields one of the three outcomes: Remote B.
   arity(3);const [name,opName,operand]=x;text(name);text(opName);const store=serving&&Object.hasOwn(STORE_EFFECTS,name)?STORE_EFFECTS[name]:null;
   const d=store?{class:'durable'}:declared.get(name),o=store?(store.name===opName?store:null):d?.operations.find(o=>o.name===opName);if(!o)fail('Unknown effect operation');
   const far=d.class==='remote';if(far&&serving)fail('A serving program performs no remote operation');if(far&&scrutinised!==e)fail('A remote outcome must be matched where it is performed');
   const wanted=far&&!o.read_only?['Tuple','I64',o.argument_type]:o.argument_type;
   const row=v(operand);if(!same(row.type,wanted))fail('Perform argument');t=far?['Remote',o.result_type]:o.result_type;eff=union([row]);eff.add(name);fv=row.free;
  }
  else if(tag==='handle'&&handlers){
   // One clause per declared operation. A clause sees the bindings in scope at the handle
   // node plus its own binder. Outward requirement: (body effects minus the handled
   // effect) union the clauses' effects.
   //   op(x) => c       tail-resumptive: c has the operation's result type
   //   op(x,k) => c     k is the one-shot resumption: c has the handle's type, and uses k
   //                    exactly once on every path. A clause cannot use an outer clause's k:
   //                    it may run any number of times.
   arity(3);const [name,clauses,bodyExpr]=x;text(name);const d=declared.get(name);if(!d)fail('Unknown effect');
   // A remote effect is discharged by the system the image is assembled into, never by the program.
   if(d.class==='remote')fail('A remote effect cannot be handled');
   const body=v(bodyExpr);
   if(array(clauses).length!==d.operations.length)fail('Handler clauses');const seen=new Set(),rows=[];
   for(const clause of clauses){array(clause);const explicit=clause.length===4;if(clause.length!==3&&!(explicit&&resumptions))fail('Handler clause');
    const [opName,binder]=clause,k=explicit?clause[2]:null,clauseBody=clause.at(-1);text(opName);const o=d.operations.find(o=>o.name===opName);if(!o||seen.has(opName))fail('Handler clauses');seen.add(opName);
    fresh(binder);const inner=plainEnv(env);inner.set(binder,o.argument_type);if(explicit){fresh(k);inner.set(k,['Resumption',o.result_type,body.type]);}
    const out=visit(clauseBody,inner,depth+1);if(!same(out.type,explicit?body.type:o.result_type))fail('Handler clause type');
    if(explicit){if((out.uses[k]??0)!==1)fail('A resumption must be used exactly once on every path');discount({[k]:1});delete uses[k];}
    out.free.delete(binder);rows.push(out);}
   t=body.type;eff=union(rows);for(const e of body.effects)if(e!==name)eff.add(e);fv=free([...rows,body]);
  }
  else if(tag==='resume'&&resumptions){
   arity(2);unsigned(x[0]);const k=env.get(x[0]);if(!Array.isArray(k)||k[0]!=='Resumption')fail('Unknown resumption');
   const row=v(x[1]);if(!same(row.type,k[1]))fail('Resume argument');uses[x[0]]=(uses[x[0]]??0)+1;t=k[2];eff=union([row]);fv=row.free;
  }
  else if(tag==='discontinue'&&resumptions){
   arity(1);unsigned(x[0]);const k=env.get(x[0]);if(!Array.isArray(k)||k[0]!=='Resumption')fail('Unknown resumption');
   uses[x[0]]=(uses[x[0]]??0)+1;t='Unit';
  }
  else if(timed&&tag==='now'){arity(0);t='I64';eff.add('Time');}
  else if(timed&&tag==='sleep'){arity(1);const duration=v(x[0]);if(duration.type!=='I64')fail('Sleep duration must be I64');t='Unit';eff=union([duration]);eff.add('Time');fv=duration.free;}
  else if(tasks&&['scope','spawn','await','cancel','yield','channel','send','receive','close'].includes(tag)){
   const handle=(row,kind)=>{if(!Array.isArray(row.type)||row.type[0]!==kind)fail(kind+' handle required');return row.type[1];};
   if(tag==='scope'){arity(1);const body=v(x[0]);if(!plain(body.type))fail('A scope result must be serializable');t=body.type;eff=union([body]);eff.add('Task');fv=body.free;}
   else if(tag==='spawn'){arity(1);const row=v(x[0]),f=row.type;if(!Array.isArray(f)||f[0]!=='Arrow'||f[1]!=='Unit')fail('Spawn needs a function from Unit');if(!plain(f[2]))fail('A task result must be serializable');
    t=['Task',f[2]];eff=union([row]);for(const k of f[3])eff.add(k);eff.add('Task');fv=row.free;}
   else if(tag==='await'){arity(1);const row=v(x[0]);t=['Outcome',handle(row,'Task')];eff=union([row]);eff.add('Task');fv=row.free;}
   else if(tag==='cancel'){arity(1);const row=v(x[0]);handle(row,'Task');t='Unit';eff=union([row]);eff.add('Task');fv=row.free;}
   else if(tag==='yield'){arity(0);t='Unit';eff.add('Task');}
   else if(tag==='channel'){arity(2);type(x[0]);if(!plain(x[0]))fail('Channel elements must be serializable');unsigned(x[1]);if(BigInt(x[1])<1n||BigInt(x[1])>BigInt(maxCapacity))fail('Channel capacity');t=['Channel',x[0]];eff.add('Channel');}
   else if(tag==='send'){arity(2);const rows=x.map(v);if(!same(handle(rows[0],'Channel'),rows[1].type))fail('Send value type');t='SendResult';eff=union(rows);eff.add('Channel');fv=free(rows);}
   else if(tag==='receive'){arity(1);const row=v(x[0]);t=['ReceiveResult',handle(row,'Channel')];eff=union([row]);eff.add('Channel');fv=row.free;}
   else {arity(1);const row=v(x[0]);handle(row,'Channel');t='Unit';eff=union([row]);eff.add('Channel');fv=row.free;}
  }
  else fail('Unsupported tag');return {type:t,effects:eff,free:fv};
 }
 for(const f of a.functions){const row=visit(f.body,new Map([[f.parameter_id,f.argument_type]]));if(!same(row.type,f.result_type)||[...row.effects].some(k=>!f.effects.includes(k)))fail('Function signature');if([...row.free].some(k=>k!==f.parameter_id))fail('Named function captures');codes.push({code_id:f.id,parameter_id:f.parameter_id,free_bindings:[],capture_support:[]});}
 if(serving){
  // No entry and no input. Every operation of a served effect has its function, of the
  // operation's types; what such a function leaves unhandled is the runtime's to carry
  // out; and a read-only operation's function cannot write the store.
  if(!array(a.serves).length)fail('Serves');const served=new Set(),used=new Set();
  for(const s of a.serves){object(s,['effect','operations']);text(s.effect);const d=declared.get(s.effect);if(!d||d.class!=='remote'||served.has(s.effect))fail('Served effect');served.add(s.effect);
   if(array(s.operations).length!==d.operations.length)fail('Served operations');
   s.operations.forEach((x,i)=>{object(x,['name','function']);const o=d.operations[i];if(x.name!==o.name)fail('Served operations');text(x.function);const f=functions.get(x.function);if(!f||used.has(x.function))fail('Served function');used.add(x.function);
    if(!same(f.argument_type,o.read_only?o.argument_type:['Tuple','I64',o.argument_type])||!same(f.result_type,o.result_type))fail('Served function type');
    if(f.effects.some(k=>k!=='Emit'&&!Object.hasOwn(STORE_EFFECTS,k)))fail('A served operation must handle every user effect');
    if(o.read_only&&f.effects.includes(STORE_WRITE))fail('A read-only operation cannot write the store');});}
 }
 const mapped=new Set();for(const r of array(a.source_map)){object(r,['id','file','line','column']);unsigned(r.id);text(r.file);unsigned(r.line);unsigned(r.column);if(!locations.has(r.id)||mapped.has(r.id))fail('Source map location');mapped.add(r.id);}if(mapped.size!==locations.size)fail('Source map incomplete');
 codes.sort((a,b)=>BigInt(a.code_id)<BigInt(b.code_id)?-1:1);
 function freeze(v){if(v&&typeof v==='object'){for(const x of Object.values(v))freeze(x);Object.freeze(v);}return v;}
 // A serving artifact has no input: what is given for one is not looked at.
 return freeze({artifact:a,input:serving?null:decode(encode(input)),codes,node_count:String(count)});
}
