// Development reducer for the closed arithmetic demo; no qualification authority.
import {validateArtifact, InvalidArtifact, ValidationLimit} from './artifact.mjs';
import {encode} from './canonical.mjs';
const clone=x=>JSON.parse(encode(x));
function children(e) {
  switch(e[0]) {
    case 'let': return [3,4]; case 'if': return [2,3,4];
    case 'prim': return e.slice(3).map((_,i)=>i+3); case 'emit': return [3];
    default: return [];
  }
}
function walk(e,path=[],rows=[]) {
  rows.push({e,path}); for(const i of children(e)) walk(e[i],[...path,i],rows); return rows;
}
function pruneMap(a) {
  const ids=new Set([a.functions[0].id,...walk(a.functions[0].body).map(r=>r.e[1])]);
  a.source_map=a.source_map.filter(r=>ids.has(r.id)); return a;
}
export function metric(artifact,input) {
  const checked=validateArtifact(encode(artifact),input);
  return [Number(checked.node_count),encode(artifact).length];
}
function less(a,b) {return a[0]<b[0] || a[0]===b[0] && a[1]<b[1];}
export function* proposals(artifact,input) {
  const baseline=metric(artifact,input), seen=new Set();
  for(const {e,path} of walk(artifact.functions[0].body)) {
    const replacements=[...children(e).map(i=>e[i]), ['unit',e[1]],
      ['bool',e[1],false],['bool',e[1],true], ...['0','1','-1'].map(n=>['int',e[1],n])];
    for(const replacement of replacements) {
      const next=clone(artifact); let parent=next.functions[0]; let key='body';
      for(const i of path) {parent=parent[key];key=i;}
      parent[key]=clone(replacement);pruneMap(next);
      let size;
      try {size=metric(next,input);} catch(err) {
        if(err instanceof InvalidArtifact || err instanceof ValidationLimit) continue; throw err;
      }
      if(!less(size,baseline)) continue;
      const bytes=encode(next).toString(); if(seen.has(bytes)) continue;seen.add(bytes);
      yield {artifact:next,metric:size};
    }
  }
}
// observe must freshly execute/model-check each case and return a discrepancy ID or null.
// Equality of IDs preserves classification, not necessarily the original epoch/site.
export function reduce(artifact,input,observe,{maxAttempts=100}={}) {
  if(!Number.isSafeInteger(maxAttempts)||maxAttempts<1) throw new TypeError('Invalid reduction cap');
  const original=clone(artifact);validateArtifact(encode(original),input);
  const classify=a=>{const id=observe(clone(a),clone(input));
    if(id!==null && (typeof id!=='string'||!id.length)) throw new TypeError('Expected discrepancy ID or null');return id;};
  const target=classify(original);if(target===null) throw new Error('Original does not reproduce failure');
  let current=original,attempts=0;const history=[];
  for(;;) {
    let changed=false;
    for(const proposal of proposals(current,input)) {
      if(attempts===maxAttempts) return finish(true);
      attempts++;const id=classify(proposal.artifact);
      history.push({attempt:String(attempts),metric:proposal.metric.map(String),discrepancy:id,accepted:id===target});
      if(id===target) {current=proposal.artifact;changed=true;break;}
    }
    if(!changed) return finish(false);
  }
  function finish(capHit) {return {original,minimized:current,discrepancy:target,attempts:String(attempts),history,
    cap_hit:capHit,scope:'Smallest-found under deterministic demo proposals; not globally minimal',qualification:'UNKNOWN'};}
}
