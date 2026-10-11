// Typed structural proposals only. Each accepted reduction needs fresh external observations.
import {encode} from './canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from './pure-call-artifact.mjs';
const clone=x=>JSON.parse(JSON.stringify(x));
// Child expression key paths; match arm bodies sit one level down in their arm.
function operands(e){const t=e[0],from=k=>e.slice(k).map((_,i)=>[i+k]);if(t==='let')return [[3],[4]];if(t==='lambda')return [[7]];if(t==='if')return [[2],[3],[4]];if(t==='prim')return from(3);if(t==='apply')return [[2],[3]];if(t==='call'||t==='emit')return [[3]];
 if(t==='tuple')return from(2);if(t==='project')return [[2]];if(t==='construct')return from(4);if(t==='match')return [[2],...e.slice(3).map((_,i)=>[i+3,2])];return [];}
const at=(e,keys)=>keys.reduce((x,k)=>x[k],e);
// Normalize a proposal: keep source-map rows only for surviving nodes, and keep only
// datatypes still reachable from function/lambda signatures or construct nodes.
export function repairPureCallSourceMap(p){
 const ids=new Set(p.functions.map(f=>f.id)),used=new Set();
 const types=t=>{if(Array.isArray(t)){if(t[0]==='Data')used.add(t[1]);else t.forEach(types);}};
 const walk=e=>{ids.add(e[1]);if(e[0]==='lambda'){types(e[3]);types(e[4]);}if(e[0]==='construct')used.add(e[2]);for(const k of operands(e))walk(at(e,k));};
 for(const f of p.functions){types(f.argument_type);types(f.result_type);walk(f.body);}
 for(let grew=true;grew;){grew=false;for(const d of p.datatypes)if(used.has(d.name))for(const c of d.constructors){const before=used.size;types(c.fields);if(used.size>before)grew=true;}}
 p.source_map=p.source_map.filter(r=>ids.has(r.id));p.datatypes=p.datatypes.filter(d=>used.has(d.name));return p;
}
export function pureCallMetric(p){const checked=validatePureCallArtifact(encode(p),['int','0']);return {nodes:Number(checked.node_count),bytes:encode(p).length};}
export function pureCallReductions(program){
 const original=pureCallMetric(program),proposals=[],seen=new Set();
 function propose(p,rule,path){repairPureCallSourceMap(p);let metric;try{metric=pureCallMetric(p);}catch(e){if(e instanceof InvalidPureCallArtifact||e instanceof PureCallValidationLimit)return;throw e;}
  if(metric.nodes>=original.nodes)return;const bytes=encode(p).toString();if(seen.has(bytes))return;seen.add(bytes);proposals.push({rule,path,metric,program:p});
 }
 for(let f=0;f<program.functions.length;f++){
  function walk(e,path){
   const replace=(replacement,rule)=>{const p=clone(program);let parent=p.functions[f];const parts=['body',...path];for(const key of parts.slice(0,-1))parent=parent[key];parent[parts.at(-1)]=clone(replacement);propose(p,rule,[String(f),...path.map(String)]);};
   if(e[0]==='let')replace(e[4],'drop-let-if-still-typed');
   if(e[0]==='if'&&e[2][0]==='bool')replace(e[e[2][2]?3:4],'constant-if');
   if(e[0]==='prim'&&e[2]==='add')for(const [zero,other] of [[3,4],[4,3]])if(e[zero][0]==='int'&&e[zero][2]==='0')replace(e[other],'add-zero');
   // Schema /2 and general typed rules; ill-typed results are discarded by revalidation.
   if(e[0]==='if'&&e[2][0]!=='bool'){replace(e[3],'if-to-branch');replace(e[4],'if-to-branch');}
   if(e[0]==='project'&&e[2][0]==='tuple')replace(e[2][Number(e[3])+2],'project-tuple-literal');
   if(e[0]==='match')for(const arm of e.slice(3))replace(arm[2],'match-to-arm');
   if(e[0]==='call')replace(e[3],'call-to-argument');
   if(e[0]==='tuple'&&e.length>3)for(let i=2;i<e.length;i++)replace([...e.slice(0,i),...e.slice(i+1)],'drop-tuple-element');
   if(e[0]==='prim'&&['add','sub','mul','div','neg','bytes_concat'].includes(e[2]))for(const operand of e.slice(3))replace(operand,'prim-to-operand');
   for(const k of operands(e))walk(at(e,k),[...path,...k]);
  }
  walk(program.functions[f].body,[]);
 }
 for(let f=0;f<program.functions.length;f++)if(program.functions[f].name!==program.entry){const p=clone(program);p.functions.splice(f,1);propose(p,'drop-unused-function',[String(f)]);}
 // Largest reductions first; ties keep traversal order (Array.prototype.sort is stable).
 return proposals.sort((a,b)=>a.metric.nodes-b.metric.nodes);
}
