// UNQUALIFIED integrated pure-call demo. Older demo schemas remain closed.
// Schema /1 is the Unit/Bool/I64 call/closure demo. Schema /2 adds the TC0-A
// data built-ins: Bytes, TrapCode, tuples, declared datatypes,
// construct/match/project, bytes_length/bytes_index/bytes_concat and eq.
// Schema tc1-handler-demo/1 (contract spec/tc1/EFFECTS.md) adds everything in /2
// plus effect declarations, handle and perform, with finite effect sets.
// Schema tc1-handler-demo/2 adds explicit one-shot resumptions: clauses op(x,k),
// resume(k,e) and discontinue(k), with k used exactly once on every path.
// Schema tc1-task-demo/1 (contract spec/tc1/CONCURRENCY.md, slice TC1-C1) adds
// everything in tc1-handler-demo/2 plus structured tasks and bounded channels:
// scope, spawn, await, cancel, yield, channel, send, receive, close; the types Task,
// Channel, Outcome, SendResult, ReceiveResult; and the runtime effects Task and
// Channel in effect sets. Everything it adds is gated on that schema, so the older
// schemas validate exactly as before.
// Schema tc1-durable-demo/1 (contract spec/tc1/DURABLE.md, slice TC1-D1) adds to
// tc1-handler-demo/2 effect classes: every effect declaration has a class, ordinary or
// durable, and the entry's effect set may contain durable effects (the residual row).
// It has no task forms. Everything it adds is gated on that schema.
import {decode,encode,decimal} from './canonical.mjs';
export class InvalidPureCallArtifact extends Error {}
export class PureCallValidationLimit extends Error {}
export const PURE_CALL_SCHEMAS=Object.freeze(['tc0-a-pure-call-demo/1','tc0-a-pure-call-demo/2']);
export const TC1_HANDLER_SCHEMA='tc1-handler-demo/1';
export const TC1_RESUMPTION_SCHEMA='tc1-handler-demo/2';
export const TC1_TASK_SCHEMA='tc1-task-demo/1';
export const TC1_DURABLE_SCHEMA='tc1-durable-demo/1';
export const EFFECT_CLASSES=Object.freeze(['ordinary','durable']);
// Runtime effects a TC1-C1 artifact may name in effect sets (CONCURRENCY.md section 2).
const TASK_RUNTIME_EFFECTS=Object.freeze(['Task','Channel']);
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
export function validatePureCallArtifact(bytes,input,{maxNodes=200,maxDepth=64,maxBytes=256,maxValueNodes=1000,maxCapacity=8}={}){
 for(const n of [maxNodes,maxDepth,maxBytes,maxValueNodes,maxCapacity])if(!Number.isSafeInteger(n)||n<1)throw new TypeError('Invalid cap');
 const a=decode(bytes);object(a,['contract_version','schema_version','slice','module','datatypes','effects','functions','entry','input_schema','source_map']);
 const tasks=a.schema_version===TC1_TASK_SCHEMA,durable=a.schema_version===TC1_DURABLE_SCHEMA,resumptions=tasks||durable||a.schema_version===TC1_RESUMPTION_SCHEMA,handlers=resumptions||a.schema_version===TC1_HANDLER_SCHEMA;
 if(handlers?(a.contract_version!=='tc1-draft-1'||a.slice!==(tasks?'TC1-C1':durable?'TC1-D1':resumptions?'TC1-H2':'TC1-H1')):(a.contract_version!=='0.2'||!PURE_CALL_SCHEMAS.includes(a.schema_version)||a.slice!=='TC0-A'))fail('Identity');text(a.module);
 const data=handlers||a.schema_version==='tc0-a-pure-call-demo/2';
 if(array(a.effects).length&&!handlers)fail('Effect declarations unsupported');
 // Effect sets: at most Emit before TC1; under TC1 any declared effect or Emit, in
 // unsigned UTF-8 byte order with no duplicates (one canonical spelling per set).
 const declared=new Map();
 function effects(v){
  array(v);
  if(!handlers){if(v.length>1||(v.length===1&&v[0]!=='Emit'))fail('Effect set');return;}
  v.forEach((k,i)=>{text(k);if(k!=='Emit'&&!declared.has(k)&&!(tasks&&TASK_RUNTIME_EFFECTS.includes(k)))fail('Effect set');if(i&&Buffer.compare(Buffer.from(v[i-1]),Buffer.from(k))>=0)fail('Effect set order');});
 }
 if(array(a.datatypes).length&&!data)fail('Declarations unsupported');
 // Datatype table: closed declarations, unique names, constructors in declared order.
 const datatypes=new Map();
 if(a.datatypes.length>16)fail('Datatype count');
 for(const d of a.datatypes){object(d,['name','constructors']);identifier(d.name);if(['Unit','Bool','I64','Bytes','TrapCode'].includes(d.name)||datatypes.has(d.name))fail('Datatype name');if(!array(d.constructors).length||d.constructors.length>16)fail('Constructor count');const seen=new Set();for(const c of d.constructors){object(c,['name','fields']);identifier(c.name);if(seen.has(c.name))fail('Duplicate constructor');seen.add(c.name);if(array(c.fields).length>8)fail('Field count');}datatypes.set(d.name,d);}
 const builtin=t=>['Unit','Bool','I64'].includes(t)||(data&&['Bytes','TrapCode'].includes(t))||(tasks&&t==='SendResult');
 function type(t,depth=0){
  if(depth>16)throw new PureCallValidationLimit('Type depth');if(builtin(t))return;array(t);
  if(t[0]==='Arrow'&&t.length===4){type(t[1],depth+1);type(t[2],depth+1);effects(t[3]);return;}
  if(data&&t[0]==='Tuple'&&t.length>=2&&t.length<=9){for(const x of t.slice(1))type(x,depth+1);return;}
  if(data&&t[0]==='Data'&&t.length===2&&datatypes.has(t[1]))return;
  // TC1-C1: handles Task(T), Channel(T) and the built-in results Outcome(T), ReceiveResult(T).
  if(tasks&&['Task','Channel','Outcome','ReceiveResult'].includes(t[0])&&t.length===2){type(t[1],depth+1);return;}
  fail('Type');
 }
 // Constructor table for one concrete type: declared datatypes or the TrapCode enum.
 const constructors=t=>t==='TrapCode'?TRAP_CODES.map(name=>({name,fields:[]})):Array.isArray(t)&&t[0]==='Data'?datatypes.get(t[1]).constructors:tasks?taskResults(t):null;
 // TC1-C1 built-in result families, matched like declared datatypes (CONCURRENCY.md section 2).
 const taskResults=t=>t==='SendResult'?[{name:'Sent',fields:[]},{name:'Closed',fields:[]}]
  :Array.isArray(t)&&t[0]==='Outcome'?[{name:'Ok',fields:[t[1]]},{name:'Cancelled',fields:[]},{name:'Failed',fields:['TrapCode']}]
  :Array.isArray(t)&&t[0]==='ReceiveResult'?[{name:'Item',fields:[t[1]]},{name:'End',fields:[]}]:null;
 // The type name a data value of type t carries.
 const dataName=t=>t==='TrapCode'||t==='SendResult'?t:tasks&&Array.isArray(t)&&t[0]!=='Data'?t[0]:t[1];
 for(const d of a.datatypes)for(const c of d.constructors)for(const f of c.fields)type(f);
 // Serializable and equality-compatible coincide in this slice: both exclude
 // functions. Traverse declarations with cycle detection (recursive types).
 function plain(t,visiting=new Set()){
  if(typeof t==='string')return true;if(t[0]==='Arrow')return false;if(t[0]==='Tuple')return t.slice(1).every(x=>plain(x,visiting));
  // TC1-C1: handles are neither serializable nor equality-compatible; results are when their T is.
  if(t[0]==='Task'||t[0]==='Channel')return false;if(t[0]==='Outcome'||t[0]==='ReceiveResult')return plain(t[1],visiting);
  if(visiting.has(t[1]))return true;visiting.add(t[1]);const ok=datatypes.get(t[1]).constructors.every(c=>c.fields.every(f=>plain(f,visiting)));visiting.delete(t[1]);return ok;
 }
 // Effect declarations: operations A -> B. In this slice A and B are serializable
 // types, so no closure crosses an operation boundary.
 if(a.effects.length>8)fail('Effect count');
 for(const d of a.effects){object(d,durable?['name','class','operations']:['name','operations']);identifier(d.name);
  // TC1-D1: every declaration names its class (DURABLE.md section 1).
  if(durable&&!EFFECT_CLASSES.includes(d.class))fail('Effect class');if(RESERVED_EFFECTS.includes(d.name)||declared.has(d.name))fail('Effect name');
  if(!array(d.operations).length||d.operations.length>8)fail('Operation count');const seen=new Set();
  for(const o of d.operations){object(o,['name','argument_type','result_type']);identifier(o.name);if(seen.has(o.name))fail('Duplicate operation');seen.add(o.name);type(o.argument_type);type(o.result_type);if(!plain(o.argument_type)||!plain(o.result_type))fail('Operation types must be serializable');}
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
 const entry=functions.get(a.entry);if(!entry)fail('Entry');if(entry.effects.some(k=>k!=='Emit'&&!(tasks&&TASK_RUNTIME_EFFECTS.includes(k))&&!(durable&&declared.get(k)?.class==='durable')))fail('Entry must handle every user effect');if(!plain(entry.argument_type)||!plain(entry.result_type))fail('Serializable entry');object(a.input_schema,['type']);if(!same(a.input_schema.type,entry.argument_type))fail('Input schema');value(input,entry.argument_type);
 const union=rows=>new Set(rows.flatMap(r=>[...r.effects]));
 const free=rows=>new Set(rows.flatMap(r=>[...r.free]));
 const primitive={add:['I64','I64','I64'],sub:['I64','I64','I64'],mul:['I64','I64','I64'],div:['I64','I64','I64'],neg:['I64','I64'],lt:['I64','I64','Bool'],le:['I64','I64','Bool'],gt:['I64','I64','Bool'],ge:['I64','I64','Bool'],not:['Bool','Bool'],bytes_length:['Bytes','I64'],bytes_index:['Bytes','I64','I64'],bytes_concat:['Bytes','Bytes','Bytes']};
 // One-shot resumptions: uses[k] counts the uses of resumption binder k on the path
 // through the expression just visited. Children add into the enclosing count; if and
 // match, whose branches are alternatives, require equal counts and count one branch.
 let uses={};
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
   if(x.length<2)fail('Arity');const [scrutinee,...arms]=x,row=v(scrutinee),table=constructors(row.type);if(!table)fail('Match scrutinee type');
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
   arity(3);const [name,opName,operand]=x;text(name);text(opName);const o=declared.get(name)?.operations.find(o=>o.name===opName);if(!o)fail('Unknown effect operation');
   const row=v(operand);if(!same(row.type,o.argument_type))fail('Perform argument');t=o.result_type;eff=union([row]);eff.add(name);fv=row.free;
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
  else if(tasks&&['scope','spawn','await','cancel','yield','channel','send','receive','close'].includes(tag)){
   // TC1-C1 (CONCURRENCY.md sections 2 and 3). A value that leaves a scope or a task is
   // serializable: the scope's result, a spawned function's result, a channel's elements.
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
 const mapped=new Set();for(const r of array(a.source_map)){object(r,['id','file','line','column']);unsigned(r.id);text(r.file);unsigned(r.line);unsigned(r.column);if(!locations.has(r.id)||mapped.has(r.id))fail('Source map location');mapped.add(r.id);}if(mapped.size!==locations.size)fail('Source map incomplete');
 codes.sort((a,b)=>BigInt(a.code_id)<BigInt(b.code_id)?-1:1);
 function freeze(v){if(v&&typeof v==='object'){for(const x of Object.values(v))freeze(x);Object.freeze(v);}return v;}
 return freeze({artifact:a,input:decode(encode(input)),codes,node_count:String(count)});
}
// TC1-D1 (DURABLE.md section 2): the residual row of a validated artifact, its
// capability manifest. The durable effects in the entry's effect set, each with its
// full declaration. Empty for every older schema.
export function residualEffects(artifact){
 if(artifact.schema_version!==TC1_DURABLE_SCHEMA)return [];
 const entry=artifact.functions.find(f=>f.name===artifact.entry);
 return artifact.effects.filter(d=>d.class==='durable'&&entry.effects.includes(d.name));
}
