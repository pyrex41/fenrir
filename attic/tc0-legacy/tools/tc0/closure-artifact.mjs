// Closed standalone UNQUALIFIED pure-closure demo; does not widen arithmetic-demo/1.
import {decode,encode,decimal} from './canonical.mjs';
export class InvalidClosureProgram extends Error {}
const fail=s=>{throw new InvalidClosureProgram(s);};
const same=(a,b)=>encode(a).equals(encode(b));
function type(t,depth=0) {
 if(depth>16) fail('Type depth limit');
 if(t==='I64') return;
 if(!Array.isArray(t)||t.length!==3||t[0]!=='Arrow') fail('Unsupported type');
 type(t[1],depth+1);type(t[2],depth+1);
}
export function validateClosureProgram(bytes,input) {
 const p=decode(bytes);
 if(!p||Array.isArray(p)||Object.keys(p).sort().join(',')!=='body,input_binding,schema'||p.schema!=='pure-closure-demo/1') fail('Closed program schema');
 const ids=new Set(),codes=[];let count=0;
 function fresh(id) {try {decimal(id,{unsigned:true});}catch{fail('Unsigned ID');}if(ids.has(id)) fail('Duplicate ID');ids.add(id);}
 fresh(p.input_binding);
 const i64=n=>{try {decimal(n);}catch{fail('I64 decimal');}if(BigInt(n)<-(1n<<63n)||BigInt(n)>=(1n<<63n)) fail('I64 range');};
 if(!Array.isArray(input)||input.length!==2||input[0]!=='int') fail('Input I64');i64(input[1]);
 const union=rows=>new Set(rows.flatMap(r=>[...r.free]));
 function visit(e,env,depth=0) {
  if(++count>200||depth>64) fail('Validation limit');
  if(!Array.isArray(e)||e.length<2) fail('Expression');fresh(e[1]);
  const [tag,node,...a]=e;const arity=n=>{if(a.length!==n)fail('Arity');};
  let t,free=new Set();
  if(tag==='int') {arity(1);i64(a[0]);t='I64';}
  else if(tag==='var') {arity(1);if(!env.has(a[0]))fail('Unknown binding');t=env.get(a[0]);free.add(a[0]);}
  else if(tag==='let') {
   arity(3);fresh(a[0]);const init=visit(a[1],env,depth+1),inner=new Map(env);inner.set(a[0],init.type);
   const body=visit(a[2],inner,depth+1);body.free.delete(a[0]);free=union([init,body]);t=body.type;
  } else if(tag==='lambda') {
   // lambda node parameter argument-type result-type effects support body
   arity(6);fresh(a[0]);type(a[1]);type(a[2]);
   if(!Array.isArray(a[3])||a[3].length||!Array.isArray(a[4])||a[4].length) fail('Pure effects and empty capture support required');
   const inner=new Map(env);inner.set(a[0],a[1]);const body=visit(a[5],inner,depth+1);
   if(!same(body.type,a[2]))fail('Lambda result type');body.free.delete(a[0]);free=body.free;t=['Arrow',a[1],a[2]];
   codes.push({code_id:node,parameter_id:a[0],free_bindings:[...free].sort((a,b)=>BigInt(a)<BigInt(b)?-1:1),capture_support:[]});
  } else if(tag==='apply'||tag==='add') {
   arity(2);const lhs=visit(a[0],env,depth+1),rhs=visit(a[1],env,depth+1);free=union([lhs,rhs]);
   if(tag==='add') {if(lhs.type!=='I64'||rhs.type!=='I64')fail('Add type');t='I64';}
   else {if(!Array.isArray(lhs.type)||lhs.type[0]!=='Arrow'||!same(lhs.type[1],rhs.type))fail('Apply type');t=lhs.type[2];}
  } else fail('Unsupported expression');
  return {type:t,free};
 }
 const checked=visit(p.body,new Map([[p.input_binding,'I64']]));if(checked.type!=='I64')fail('Serializable I64 result required');
 codes.sort((a,b)=>BigInt(a.code_id)<BigInt(b.code_id)?-1:1);
 function freeze(v) {if(v&&typeof v==='object'){for(const x of Object.values(v))freeze(x);Object.freeze(v);}return v;}
 return freeze({program:p,input:decode(encode(input)),codes,node_count:String(count)});
}
