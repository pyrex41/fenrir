// UNQUALIFIED integrated pure-call demo. Older demo schemas remain closed.
// Schema /1 is the Unit/Bool/I64 call/closure demo. Schema /2 adds the TC0-A
// data built-ins: Bytes, TrapCode, tuples, declared datatypes,
// construct/match/project, bytes_length/bytes_index/bytes_concat and eq.
import {decode,encode,decimal} from './canonical.mjs';
export class InvalidPureCallArtifact extends Error {}
export class PureCallValidationLimit extends Error {}
export const PURE_CALL_SCHEMAS=Object.freeze(['tc0-a-pure-call-demo/1','tc0-a-pure-call-demo/2']);
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
function effects(v){array(v);if(v.length>1||(v.length===1&&v[0]!=='Emit'))fail('Effect set');}
const arities={add:2,sub:2,mul:2,div:2,neg:1,lt:2,le:2,gt:2,ge:2,not:1,bytes_length:1,bytes_index:2,bytes_concat:2,eq:2};
const dataPrimitives=new Set(['bytes_length','bytes_index','bytes_concat','eq']);
const dataTags=new Set(['bytes','tuple','project','construct','match']);
export function validatePureCallArtifact(bytes,input,{maxNodes=200,maxDepth=64,maxBytes=256,maxValueNodes=1000}={}){
 for(const n of [maxNodes,maxDepth,maxBytes,maxValueNodes])if(!Number.isSafeInteger(n)||n<1)throw new TypeError('Invalid cap');
 const a=decode(bytes);object(a,['contract_version','schema_version','slice','module','datatypes','effects','functions','entry','input_schema','source_map']);
 if(a.contract_version!=='0.2'||!PURE_CALL_SCHEMAS.includes(a.schema_version)||a.slice!=='TC0-A')fail('Identity');text(a.module);
 const data=a.schema_version==='tc0-a-pure-call-demo/2';
 if(array(a.effects).length)fail('Effect declarations unsupported');
 if(array(a.datatypes).length&&!data)fail('Declarations unsupported');
 // Datatype table: closed declarations, unique names, constructors in declared order.
 const datatypes=new Map();
 if(a.datatypes.length>16)fail('Datatype count');
 for(const d of a.datatypes){object(d,['name','constructors']);identifier(d.name);if(['Unit','Bool','I64','Bytes','TrapCode'].includes(d.name)||datatypes.has(d.name))fail('Datatype name');if(!array(d.constructors).length||d.constructors.length>16)fail('Constructor count');const seen=new Set();for(const c of d.constructors){object(c,['name','fields']);identifier(c.name);if(seen.has(c.name))fail('Duplicate constructor');seen.add(c.name);if(array(c.fields).length>8)fail('Field count');}datatypes.set(d.name,d);}
 const builtin=t=>['Unit','Bool','I64'].includes(t)||(data&&['Bytes','TrapCode'].includes(t));
 function type(t,depth=0){
  if(depth>16)throw new PureCallValidationLimit('Type depth');if(builtin(t))return;array(t);
  if(t[0]==='Arrow'&&t.length===4){type(t[1],depth+1);type(t[2],depth+1);effects(t[3]);return;}
  if(data&&t[0]==='Tuple'&&t.length>=2&&t.length<=9){for(const x of t.slice(1))type(x,depth+1);return;}
  if(data&&t[0]==='Data'&&t.length===2&&datatypes.has(t[1]))return;
  fail('Type');
 }
 // Constructor table for one concrete type: declared datatypes or the TrapCode enum.
 const constructors=t=>t==='TrapCode'?TRAP_CODES.map(name=>({name,fields:[]})):Array.isArray(t)&&t[0]==='Data'?datatypes.get(t[1]).constructors:null;
 for(const d of a.datatypes)for(const c of d.constructors)for(const f of c.fields)type(f);
 // Serializable and equality-compatible coincide in this slice: both exclude
 // functions. Traverse declarations with cycle detection (recursive types).
 function plain(t,visiting=new Set()){
  if(typeof t==='string')return true;if(t[0]==='Arrow')return false;if(t[0]==='Tuple')return t.slice(1).every(x=>plain(x,visiting));
  if(visiting.has(t[1]))return true;visiting.add(t[1]);const ok=datatypes.get(t[1]).constructors.every(c=>c.fields.every(f=>plain(f,visiting)));visiting.delete(t[1]);return ok;
 }
 let valueCount=0;
 function value(v,t,depth=0){
  if(++valueCount>maxValueNodes||depth>maxDepth)throw new PureCallValidationLimit('Value cap');array(v);
  if(t==='Unit'&&v.length===1&&v[0]==='unit')return;if(t==='Bool'&&v.length===2&&v[0]==='bool'&&typeof v[1]==='boolean')return;
  if(t==='I64'&&v.length===2&&v[0]==='int'){try{decimal(v[1]);const n=BigInt(v[1]);if(n>=-(1n<<63n)&&n<(1n<<63n))return;}catch{}}
  if(t==='Bytes'&&v.length===2&&v[0]==='bytes'){hex(v[1]);if(v[1].length/2>maxBytes)throw new PureCallValidationLimit('Bytes cap');return;}
  if(Array.isArray(t)&&t[0]==='Tuple'&&v[0]==='tuple'&&v.length===t.length){t.slice(1).forEach((x,i)=>value(v[i+1],x,depth+1));return;}
  const table=constructors(t);if(table&&v[0]==='data'&&v.length>=3&&same(v[1],t==='TrapCode'?'TrapCode':t[1])){const c=table.find(c=>c.name===v[2]);if(c&&v.length===3+c.fields.length){c.fields.forEach((f,i)=>value(v[i+3],f,depth+1));return;}}
  fail('Value type/range');
 }
 const ID=new Set(),locations=new Set(),functions=new Map(),codes=[];let count=0;
 const fresh=(id,location=false)=>{unsigned(id);if(ID.has(id))fail('Duplicate ID');ID.add(id);if(location)locations.add(id);};
 if(!array(a.functions).length||a.functions.length>32)fail('Function count');
 for(const f of a.functions){object(f,['id','name','parameter_id','argument_type','result_type','effects','body']);fresh(f.id,true);fresh(f.parameter_id);text(f.name);if(functions.has(f.name))fail('Duplicate function name');type(f.argument_type);type(f.result_type);effects(f.effects);functions.set(f.name,f);}
 const entry=functions.get(a.entry);if(!entry)fail('Entry');if(!plain(entry.argument_type)||!plain(entry.result_type))fail('Serializable entry');object(a.input_schema,['type']);if(!same(a.input_schema.type,entry.argument_type))fail('Input schema');value(input,entry.argument_type);
 const union=rows=>new Set(rows.flatMap(r=>[...r.effects]));
 const free=rows=>new Set(rows.flatMap(r=>[...r.free]));
 const primitive={add:['I64','I64','I64'],sub:['I64','I64','I64'],mul:['I64','I64','I64'],div:['I64','I64','I64'],neg:['I64','I64'],lt:['I64','I64','Bool'],le:['I64','I64','Bool'],gt:['I64','I64','Bool'],ge:['I64','I64','Bool'],not:['Bool','Bool'],bytes_length:['Bytes','I64'],bytes_index:['Bytes','I64','I64'],bytes_concat:['Bytes','Bytes','Bytes']};
 function visit(e,env,depth=0){
  if(++count>maxNodes||depth>maxDepth)throw new PureCallValidationLimit('AST cap');array(e);if(e.length<2)fail('Expression');fresh(e[1],true);
  const [tag,node,...x]=e,arity=n=>{if(x.length!==n)fail('Arity');},v=e=>visit(e,env,depth+1);let t,eff=new Set(),fv=new Set();
  if(dataTags.has(tag)&&!data)fail('Unsupported tag');
  if(['unit','bool','int'].includes(tag)){arity(tag==='unit'?0:1);t={unit:'Unit',bool:'Bool',int:'I64'}[tag];value([tag,...x],t);}
  else if(tag==='bytes'){arity(1);t='Bytes';value(['bytes',x[0]],t);}
  else if(tag==='var'){arity(1);unsigned(x[0]);if(!env.has(x[0]))fail('Unknown binding');t=env.get(x[0]);fv.add(x[0]);}
  else if(tag==='let'){arity(3);fresh(x[0]);const init=v(x[1]),inner=new Map(env);inner.set(x[0],init.type);const body=visit(x[2],inner,depth+1);body.free.delete(x[0]);t=body.type;eff=union([init,body]);fv=free([init,body]);}
  else if(tag==='if'){arity(3);const rows=x.map(v);if(rows[0].type!=='Bool'||!same(rows[1].type,rows[2].type))fail('If types');t=rows[1].type;eff=union(rows);fv=free(rows);}
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
   t=result;eff=union(rows);fv=free(rows);
  }
  else if(tag==='emit'){arity(2);text(x[0]);const row=v(x[1]);if(!plain(row.type))fail('Emit serializable');t='Unit';eff=union([row]);eff.add('Emit');fv=row.free;}
  else if(tag==='lambda'){arity(6);fresh(x[0]);type(x[1]);type(x[2]);effects(x[3]);if(array(x[4]).length)fail('Empty capture support required');const inner=new Map(env);inner.set(x[0],x[1]);const body=visit(x[5],inner,depth+1);if(!same(body.type,x[2])||[...body.effects].some(k=>!x[3].includes(k)))fail('Lambda signature');body.free.delete(x[0]);fv=body.free;t=['Arrow',x[1],x[2],x[3]];codes.push({code_id:node,parameter_id:x[0],free_bindings:ids(fv),capture_support:[]});}
  else if(tag==='apply'){arity(2);const rows=x.map(v),arrow=rows[0].type;if(!Array.isArray(arrow)||arrow[0]!=='Arrow'||!same(arrow[1],rows[1].type))fail('Apply type');t=arrow[2];eff=union(rows);for(const k of arrow[3])eff.add(k);fv=free(rows);}
  else if(tag==='call'){arity(2);text(x[0]);const f=functions.get(x[0]);if(!f)fail('Unknown function');const row=v(x[1]);if(!same(row.type,f.argument_type))fail('Call argument');t=f.result_type;eff=union([row]);for(const k of f.effects)eff.add(k);fv=row.free;}
  else fail('Unsupported tag');return {type:t,effects:eff,free:fv};
 }
 for(const f of a.functions){const row=visit(f.body,new Map([[f.parameter_id,f.argument_type]]));if(!same(row.type,f.result_type)||[...row.effects].some(k=>!f.effects.includes(k)))fail('Function signature');if([...row.free].some(k=>k!==f.parameter_id))fail('Named function captures');codes.push({code_id:f.id,parameter_id:f.parameter_id,free_bindings:[],capture_support:[]});}
 const mapped=new Set();for(const r of array(a.source_map)){object(r,['id','file','line','column']);unsigned(r.id);text(r.file);unsigned(r.line);unsigned(r.column);if(!locations.has(r.id)||mapped.has(r.id))fail('Source map location');mapped.add(r.id);}if(mapped.size!==locations.size)fail('Source map incomplete');
 codes.sort((a,b)=>BigInt(a.code_id)<BigInt(b.code_id)?-1:1);
 function freeze(v){if(v&&typeof v==='object'){for(const x of Object.values(v))freeze(x);Object.freeze(v);}return v;}
 return freeze({artifact:a,input:decode(encode(input)),codes,node_count:String(count)});
}
