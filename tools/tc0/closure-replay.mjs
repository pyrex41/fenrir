// Standalone UNQUALIFIED closure replay profile. No arithmetic tape compatibility.
import {createHash} from 'node:crypto';
import {encode,decimal} from './canonical.mjs';
export class ClosureReplayDiverged extends Error {}
export class ClosureReplayIncompatible extends Error {}
export const hash=x=>createHash('sha256').update(encode(x)).digest('hex');
const copy=x=>JSON.parse(encode(x));
const equal=(a,b)=>encode(a).equals(encode(b));
const keys=['schema','profile','run_id','program_hash','input_hash','reference_hash','oracle_hash','catalog_hash','candidate_hash','adapter_hash','toolchain_hash','environment_hash','initial_state_hash','bounds'];
function closed(v,fields) {if(!v||Array.isArray(v)||typeof v!=='object'||Object.keys(v).sort().join(',')!==[...fields].sort().join(','))throw new ClosureReplayDiverged('Closed fields');}
function data(x) {
 if(x instanceof Map)return [...x].sort(([a],[b])=>BigInt(a)<BigInt(b)?-1:BigInt(a)>BigInt(b)?1:0).map(([k,v])=>[k,data(v)]);
 if(typeof x==='bigint')return String(x);
 if(Array.isArray(x))return x.map(data);
 if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).map(([k,v])=>[k,data(v)]));
 return x;
}
export function stateHash(m) {return hash(data({control:m.control,environment:m.env,frames:m.frames,codes:m.codes,epoch:m.epoch,terminal:m.terminal,descriptors:m.descriptors}));}
function check(h,m,reference) {
 closed(h,keys);closed(h.bounds,['steps']);decimal(h.bounds.steps,{unsigned:true});
 if(h.schema!=='closure-demo-tape/1'||h.profile!=='pure-closure-demo/1'||BigInt(h.bounds.steps)>1000n)throw new ClosureReplayIncompatible('Profile/bound');
 if(typeof h.run_id!=='string'||!h.run_id.length)throw new ClosureReplayDiverged('Run identity');
 for(const k of keys.filter(k=>k.endsWith('_hash')))if(typeof h[k]!=='string'||! /^[0-9a-f]{64}$/.test(h[k]))throw new ClosureReplayDiverged('Hash spelling');
 if(m.epoch!==0n||m.control.kind!=='Eval'||m.frames.length||m.terminal||m.descriptors.length)throw new ClosureReplayIncompatible('Fresh machine required');
 if(h.initial_state_hash!==stateHash(m)||h.reference_hash!==hash(reference))throw new ClosureReplayIncompatible('Initial state/reference');
 if(!Array.isArray(reference))throw new ClosureReplayIncompatible('Reference records');
}
const domain=[{kind:'Run',task:'0'}];
function choice(h,index,expected,previous) {
 if(expected.epoch!==String(index))throw new ClosureReplayIncompatible('Reference epoch');
 const occurrence=String(previous.filter(c=>{const {occurrence,...site}=c.site;return equal(site,expected.site);}).length);
 return {schema:'closure-demo-choice/1',run_id:h.run_id,index:String(index),scheduler_epoch:String(index),kind:'Run',
  domain_hash:hash(domain),selected:domain[0],site:{...expected.site,occurrence}};
}
function execute(m,reference,h,saved) {
 const choices=[],steps=[];let footer;
 while(!m.terminal&&steps.length<Number(h.bounds.steps)) {
  const expected=reference[steps.length];if(!expected)throw new ClosureReplayIncompatible('Reference ended');
  const next=choice(h,steps.length,expected,choices);
  if(saved&&(!saved.choices[steps.length]||!equal(next,saved.choices[steps.length])))throw new ClosureReplayDiverged('Choice/domain/site/epoch mismatch');
  choices.push(copy(next));const actual=m.step();steps.push(copy(actual));
  if(saved&&(!saved.steps[steps.length-1]||!equal(actual,saved.steps[steps.length-1])))throw new ClosureReplayDiverged('Trace mismatch');
  if(!equal(actual,expected)){footer={kind:'Divergence',epoch:actual.epoch,expected_hash:hash(expected),observed_hash:hash(actual)};break;}
 }
 if(!footer) {
  if(m.terminal&&steps.length!==reference.length)throw new ClosureReplayDiverged('Completed reference suffix');
  footer=m.terminal?{kind:'Completed',outcome:copy(m.terminal)}:{kind:'BudgetExhausted'};
 }
 footer={...footer,state_hash:stateHash(m),trace_hash:hash(steps)};
 if(saved&&(steps.length!==saved.steps.length||choices.length!==saved.choices.length||!equal(footer,saved.footer)))throw new ClosureReplayDiverged('Extra tape or footer mismatch');
 return copy({header:h,choices,steps,footer});
}
export function recordClosure(m,reference,h) {check(h,m,reference);return execute(m,reference,h);}
export function replayClosure(m,reference,h,bundle) {
 check(h,m,reference);closed(bundle,['header','choices','steps','footer']);
 if(!equal(h,bundle.header))throw new ClosureReplayIncompatible('Header identity differs');
 if(!Array.isArray(bundle.steps)||!Array.isArray(bundle.choices))throw new ClosureReplayDiverged('Tape framing');
 const actual=execute(m,reference,h,bundle);
 return {replay:'Exact',conformance:actual.footer.kind==='Completed'?'Admitted':actual.footer.kind==='Divergence'?'Diverged':'Unknown',
  execution:actual.footer.kind==='Divergence'?'StoppedAtDivergence':actual.footer.kind,qualification:'UNKNOWN',scope:'Standalone closure-demo exposed-state development replay'};
}
