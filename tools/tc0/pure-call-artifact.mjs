// UNQUALIFIED integrated pure-call demo. Older demo schemas remain closed.
import {decode,encode,decimal} from './canonical.mjs';
export class InvalidPureCallArtifact extends Error {}
export class PureCallValidationLimit extends Error {}
const fail=s=>{throw new InvalidPureCallArtifact(s);};
const same=(a,b)=>encode(a).equals(encode(b));
const object=(v,keys)=>{if(!v||typeof v!=='object'||Array.isArray(v)||Object.keys(v).sort().join(',')!==[...keys].sort().join(','))fail('Closed object fields');};
const array=v=>{if(!Array.isArray(v))fail('Array required');return v;};
const text=v=>{if(typeof v!=='string')fail('String required');};
const unsigned=v=>{try{decimal(v,{unsigned:true});}catch{fail('Unsigned ID');}};
function effects(v){array(v);if(v.length>1||(v.length===1&&v[0]!=='Emit'))fail('Effect set');}
function type(t,depth=0){if(depth>16)throw new PureCallValidationLimit('Type depth');if(['Unit','Bool','I64'].includes(t))return;if(!Array.isArray(t)||t.length!==4||t[0]!=='Arrow')fail('Type');type(t[1],depth+1);type(t[2],depth+1);effects(t[3]);}
function scalar(v,t){array(v);if(t==='Unit'&&v.length===1&&v[0]==='unit')return;if(t==='Bool'&&v.length===2&&v[0]==='bool'&&typeof v[1]==='boolean')return;if(t==='I64'&&v.length===2&&v[0]==='int'){try{decimal(v[1]);const n=BigInt(v[1]);if(n>=-(1n<<63n)&&n<(1n<<63n))return;}catch{}}fail('Scalar type/range');}
const arities={add:2,sub:2,mul:2,div:2,neg:1,lt:2,le:2,gt:2,ge:2,not:1};
export function validatePureCallArtifact(bytes,input,{maxNodes=200,maxDepth=64}={}){
 for(const n of [maxNodes,maxDepth])if(!Number.isSafeInteger(n)||n<1)throw new TypeError('Invalid cap');
 const a=decode(bytes);object(a,['contract_version','schema_version','slice','module','datatypes','effects','functions','entry','input_schema','source_map']);
 if(a.contract_version!=='0.2'||a.schema_version!=='tc0-a-pure-call-demo/1'||a.slice!=='TC0-A')fail('Identity');text(a.module);
 if(array(a.datatypes).length||array(a.effects).length)fail('Declarations unsupported');
 const ids=new Set(),locations=new Set(),functions=new Map(),codes=[];let count=0;
 const fresh=(id,location=false)=>{unsigned(id);if(ids.has(id))fail('Duplicate ID');ids.add(id);if(location)locations.add(id);};
 if(!array(a.functions).length||a.functions.length>32)fail('Function count');
 for(const f of a.functions){object(f,['id','name','parameter_id','argument_type','result_type','effects','body']);fresh(f.id,true);fresh(f.parameter_id);text(f.name);if(functions.has(f.name))fail('Duplicate function name');type(f.argument_type);type(f.result_type);effects(f.effects);functions.set(f.name,f);}
 const entry=functions.get(a.entry);if(!entry)fail('Entry');if(!['Unit','Bool','I64'].includes(entry.argument_type)||!['Unit','Bool','I64'].includes(entry.result_type))fail('Serializable entry');object(a.input_schema,['type']);if(!same(a.input_schema.type,entry.argument_type))fail('Input schema');scalar(input,entry.argument_type);
 const union=rows=>new Set(rows.flatMap(r=>[...r.effects]));
 const free=rows=>new Set(rows.flatMap(r=>[...r.free]));
 function visit(e,env,depth=0){
  if(++count>maxNodes||depth>maxDepth)throw new PureCallValidationLimit('AST cap');array(e);if(e.length<2)fail('Expression');fresh(e[1],true);
  const [tag,node,...x]=e,arity=n=>{if(x.length!==n)fail('Arity');},v=e=>visit(e,env,depth+1);let t,eff=new Set(),fv=new Set();
  if(['unit','bool','int'].includes(tag)){arity(tag==='unit'?0:1);t={unit:'Unit',bool:'Bool',int:'I64'}[tag];scalar([tag,...x],t);}
  else if(tag==='var'){arity(1);unsigned(x[0]);if(!env.has(x[0]))fail('Unknown binding');t=env.get(x[0]);fv.add(x[0]);}
  else if(tag==='let'){arity(3);fresh(x[0]);const init=v(x[1]),inner=new Map(env);inner.set(x[0],init.type);const body=visit(x[2],inner,depth+1);body.free.delete(x[0]);t=body.type;eff=union([init,body]);fv=free([init,body]);}
  else if(tag==='if'){arity(3);const rows=x.map(v);if(rows[0].type!=='Bool'||!same(rows[1].type,rows[2].type))fail('If types');t=rows[1].type;eff=union(rows);fv=free(rows);}
  else if(tag==='prim'){const [op,...operands]=x;if(!Object.hasOwn(arities,op)||operands.length!==arities[op])fail('Primitive');const rows=operands.map(v);if(rows.some(r=>r.type!==(op==='not'?'Bool':'I64')))fail('Primitive type');t=['lt','le','gt','ge','not'].includes(op)?'Bool':'I64';eff=union(rows);fv=free(rows);}
  else if(tag==='emit'){arity(2);text(x[0]);const row=v(x[1]);if(!['Unit','Bool','I64'].includes(row.type))fail('Emit serializable');t='Unit';eff=union([row]);eff.add('Emit');fv=row.free;}
  else if(tag==='lambda'){arity(6);fresh(x[0]);type(x[1]);type(x[2]);effects(x[3]);if(array(x[4]).length)fail('Empty capture support required');const inner=new Map(env);inner.set(x[0],x[1]);const body=visit(x[5],inner,depth+1);if(!same(body.type,x[2])||[...body.effects].some(k=>!x[3].includes(k)))fail('Lambda signature');body.free.delete(x[0]);fv=body.free;t=['Arrow',x[1],x[2],x[3]];codes.push({code_id:node,parameter_id:x[0],free_bindings:[...fv].sort((a,b)=>BigInt(a)<BigInt(b)?-1:1),capture_support:[]});}
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
