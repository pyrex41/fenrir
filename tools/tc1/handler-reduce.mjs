// Typed structural proposals for TC1 handler programs; UNQUALIFIED development
// reducer. Each proposal is a whole program, normalized, and revalidated here by the
// validator (types, effect sets, the entry's handled effects, the one-shot rule); one
// the validator rejects is dropped, never offered. A proposal is a candidate only: the
// Shen harness accepts it only on fresh model and implementation observations that show
// the same discrepancy class (harness/tc1-reduction.shen).
//
// Rules, at every expression of every function:
//   drop-let            let v = a in b       ->  b
//   let-to-init         let v = a in b       ->  a          (e.g. drop what a clause does after resume)
//   constant-if         if(true|false, a, b) ->  the branch taken
//   if-to-branch        if(c, a, b)          ->  a, b
//   prim-to-operand     op(a, b)             ->  a, b
//   call-to-argument    f(a)                 ->  a
//   match-to-arm        match e {..., C(xs) => a, ...} -> a
//   handle-to-body      handle(E, cs, b)     ->  b          (valid when b no longer performs E)
//   perform-to-argument perform(E, op, a)    ->  a          (when op : A -> A)
//   resume-to-argument  op(x, k) => C[resume(k, a)]  ->  op(x) => C[a]
//                                            (the clause becomes tail-resumptive; valid when C uses k nowhere else
//                                             and C[a] has the operation's result type)
//   clause-to-binder    a clause body        ->  its binder x
//   expr-to-literal     an expression of two or more nodes -> 0 or (), whichever type checks
// and drop-unused-function for every function but the entry. Normalization keeps only
// the source-map rows of surviving nodes and the declarations still referenced, and
// takes schema tc1-handler-demo/1 when no explicit resumption remains.
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from '../tc0/pure-call-artifact.mjs';
const clone=x=>JSON.parse(JSON.stringify(x));

// Child expression key paths of an expression.
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
  return [];
}
const at=(e,keys)=>keys.reduce((x,k)=>x[k],e);
const nodes=e=>1+children(e).reduce((n,k)=>n+nodes(at(e,k)),0);

// Keep the source-map rows of surviving nodes (adding rows for introduced ones) and the
// declarations still referenced.
export function normalizeHandlerProgram(p) {
  const ids=new Set(p.functions.map(f=>f.id)),effects=new Set(),datatypes=new Set();let explicit=false;
  const walk=e=>{
    ids.add(e[1]);
    if(e[0]==='perform'||e[0]==='handle')effects.add(e[2]);
    if(e[0]==='lambda')for(const k of e[5])effects.add(k);
    if(e[0]==='construct')datatypes.add(e[2]);
    if(e[0]==='match')datatypes.add('Opt');
    if(e[0]==='resume'||e[0]==='discontinue'||(e[0]==='handle'&&e[3].some(c=>c.length===4)))explicit=true;
    for(const k of children(e))walk(at(e,k));
  };
  for(const f of p.functions){for(const k of f.effects)effects.add(k);walk(f.body);}
  p.source_map=p.source_map.filter(r=>ids.has(r.id));
  // A node a rule introduced (a literal or a binder reference) gets a source-map row of its own.
  const mapped=new Set(p.source_map.map(r=>r.id));
  for(const id of ids)if(!mapped.has(id))p.source_map.push({id,file:'tc1-reduced',line:'0',column:'0'});
  p.effects=p.effects.filter(d=>effects.has(d.name));
  p.datatypes=p.datatypes.filter(d=>datatypes.has(d.name));
  if(!explicit){p.schema_version='tc1-handler-demo/1';p.slice='TC1-H1';}
  return p;
}

export function handlerMetric(p) {
  const checked=validatePureCallArtifact(encode(p),['int','0']);
  return {nodes:Number(checked.node_count),bytes:encode(p).length};
}

// One more than every decimal string in the program: a fresh node ID.
function freshId(p) {
  let max=-1n;
  JSON.stringify(p,(k,v)=>{if(typeof v==='string'&&/^\d+$/.test(v)&&BigInt(v)>max)max=BigInt(v);return v;});
  return String(max+1n);
}

export function handlerReductions(program) {
  const original=handlerMetric(program),proposals=[],seen=new Set();
  let rejected=0;
  function propose(p,rule,path) {
    normalizeHandlerProgram(p);
    let metric;
    try{metric=handlerMetric(p);}
    catch(e){if(e instanceof InvalidPureCallArtifact||e instanceof PureCallValidationLimit){rejected++;return;}throw e;}
    if(metric.nodes>=original.nodes)return;
    const bytes=encode(p).toString();if(seen.has(bytes))return;seen.add(bytes);
    proposals.push({rule,path,metric,program:p});
  }
  for(let f=0;f<program.functions.length;f++) {
    const get=(p,path)=>at(p.functions[f].body,path);
    const set=(p,path,value)=>{if(!path.length){p.functions[f].body=value;return;}get(p,path.slice(0,-1))[path.at(-1)]=value;};
    // A copy of the program with the expression at `path` replaced by make(copy).
    const replaced=(path,make)=>{const p=clone(program);set(p,path,make(p));return p;};
    const replace=(path,replacement,rule)=>propose(replaced(path,()=>clone(replacement)),rule,[String(f),...path.map(String)]);
    // clause is the path of the innermost enclosing explicit clause whose k is in scope, or null.
    function walk(e,path,clause) {
      const t=e[0],here=[String(f),...path.map(String)];
      if(t==='let'){replace(path,e[4],'drop-let');replace(path,e[3],'let-to-init');}
      if(t==='if'&&e[2][0]==='bool')replace(path,e[e[2][2]?3:4],'constant-if');
      if(t==='if'){replace(path,e[3],'if-to-branch');replace(path,e[4],'if-to-branch');}
      if(t==='prim')for(const operand of e.slice(3))replace(path,operand,'prim-to-operand');
      if(t==='call')replace(path,e[3],'call-to-argument');
      if(t==='match')for(const arm of e.slice(3))replace(path,arm[2],'match-to-arm');
      if(t==='handle')replace(path,e[4],'handle-to-body');
      if(t==='perform')replace(path,e[4],'perform-to-argument');
      if(t==='resume'&&clause) {
        const p=replaced(path,()=>clone(e[3]));get(p,clause).splice(2,1);
        propose(p,'resume-to-argument',here);
      }
      if(nodes(e)>=2)for(const [tag,...rest] of [['int','0'],['unit']])propose(replaced(path,p=>[tag,freshId(p),...rest]),'expr-to-literal',here);
      for(const k of children(e)) {
        const child=[...path,...k];let inner=clause;
        if(t==='handle'&&k[0]===3) {
          const c=e[3][k[1]];
          inner=c.length===4?[...path,3,k[1]]:null;
          propose(replaced(child,p=>['var',freshId(p),c[1]]),'clause-to-binder',[String(f),...child.map(String)]);
        } else if(t==='lambda')inner=null;
        walk(at(e,k),child,inner);
      }
    }
    walk(program.functions[f].body,[],null);
  }
  for(let f=0;f<program.functions.length;f++)if(program.functions[f].name!==program.entry) {
    const p=clone(program);p.functions.splice(f,1);propose(p,'drop-unused-function',[String(f)]);
  }
  // Largest reductions first; ties keep traversal order (Array.prototype.sort is stable).
  return {metric:original,rejected:String(rejected),proposals:proposals.sort((a,b)=>a.metric.nodes-b.metric.nodes)};
}
