// Typed structural proposals only. Each accepted reduction needs fresh external observations.
import {encode} from './canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from './pure-call-artifact.mjs';
const clone=x=>JSON.parse(JSON.stringify(x));
function operands(e){const t=e[0];if(t==='let')return [3,4];if(t==='lambda')return [7];if(t==='if')return [2,3,4];if(t==='prim')return e.slice(3).map((_,i)=>i+3);if(t==='apply')return [2,3];if(t==='call'||t==='emit')return [3];return [];}
export function repairPureCallSourceMap(p){const ids=new Set(p.functions.map(f=>f.id));const walk=e=>{ids.add(e[1]);for(const i of operands(e))walk(e[i]);};for(const f of p.functions)walk(f.body);p.source_map=p.source_map.filter(r=>ids.has(r.id));return p;}
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
   for(const i of operands(e))walk(e[i],[...path,i]);
  }
  walk(program.functions[f].body,[]);
 }
 for(let f=0;f<program.functions.length;f++)if(program.functions[f].name!==program.entry){const p=clone(program);p.functions.splice(f,1);propose(p,'drop-unused-function',[String(f)]);}
 return proposals;
}
