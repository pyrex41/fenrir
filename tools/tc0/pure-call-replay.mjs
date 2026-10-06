// Distinct UNQUALIFIED integrated demo tape; never accepts older demo identities.
import {createHash} from 'node:crypto';
import {encode,decimal} from './canonical.mjs';
export class PureCallReplayDiverged extends Error {}
export class PureCallReplayIncompatible extends Error {}
export const hash=x=>createHash('sha256').update(encode(x)).digest('hex');
const copy=x=>JSON.parse(encode(x));
const equal=(a,b)=>encode(a).equals(encode(b));
const keys=['schema','profile','run_id','program_hash','input_hash','reference_hash','oracle_hash','catalog_hash','candidate_hash','adapter_hash','toolchain_hash','environment_hash','initial_state_hash','bounds'];
function closed(v,fields){if(!v||Array.isArray(v)||typeof v!=='object'||Object.keys(v).sort().join(',')!==[...fields].sort().join(','))throw new PureCallReplayDiverged('Closed fields');}
function data(x){
 if(x instanceof Map){const rows=[...x],numeric=rows.every(([k])=>/^\d+$/.test(k));return rows.sort(([a],[b])=>numeric?(BigInt(a)<BigInt(b)?-1:BigInt(a)>BigInt(b)?1:0):Buffer.compare(Buffer.from(a),Buffer.from(b))).map(([k,v])=>[k,data(v)]);}
 if(typeof x==='bigint')return String(x);if(Array.isArray(x))return x.map(data);
 if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).map(([k,v])=>[k,data(v)]));return x;
}
export function stateHash(m){return hash(data({artifact:m.artifact,input:m.input,control:m.control,environment:m.env,frames:m.frames,codes:m.codes,functions:m.functions,epoch:m.epoch,terminal:m.terminal,descriptors:m.descriptors,events:m.events,reverse_operands:m.reverseOperands}));}
function check(h,m,reference){
 closed(h,keys);closed(h.bounds,['steps']);decimal(h.bounds.steps,{unsigned:true});
 if(h.schema!=='pure-call-demo-tape/1'||h.profile!=='pure-call-demo-step/1'||BigInt(h.bounds.steps)>1000n)throw new PureCallReplayIncompatible('Profile/bound');
 if(typeof h.run_id!=='string'||!h.run_id.length)throw new PureCallReplayDiverged('Run identity');
 for(const k of keys.filter(k=>k.endsWith('_hash')))if(typeof h[k]!=='string'||! /^[0-9a-f]{64}$/.test(h[k]))throw new PureCallReplayDiverged('Hash spelling');
 if(m.epoch!==0n||m.control.kind!=='Eval'||m.frames.length||m.terminal||m.descriptors.length||m.events.length)throw new PureCallReplayIncompatible('Fresh machine required');
 if(h.program_hash!==hash(m.artifact)||h.input_hash!==hash(m.input)||h.initial_state_hash!==stateHash(m)||h.reference_hash!==hash(reference))throw new PureCallReplayIncompatible('Artifact/input/state/reference identity');
 if(!Array.isArray(reference))throw new PureCallReplayIncompatible('Reference records');
}
const domain=[{kind:'Run',task:'0'}];
function choice(h,index,expected,previous){
 if(expected.epoch!==String(index))throw new PureCallReplayIncompatible('Reference epoch');
 const occurrence=String(previous.filter(c=>{const {occurrence,...site}=c.site;return equal(site,expected.site);}).length);
 return {schema:'pure-call-demo-choice/1',run_id:h.run_id,index:String(index),scheduler_epoch:String(index),kind:'Run',domain_hash:hash(domain),selected:domain[0],site:{...expected.site,occurrence}};
}
function execute(m,reference,h,saved){
 const choices=[],steps=[];let footer;
 while(!m.terminal&&steps.length<Number(h.bounds.steps)){
  const expected=reference[steps.length];if(!expected)throw new PureCallReplayIncompatible('Reference ended');
  const next=choice(h,steps.length,expected,choices);
  if(saved&&(!saved.choices[steps.length]||!equal(next,saved.choices[steps.length])))throw new PureCallReplayDiverged('Choice/domain/site/epoch mismatch');
  choices.push(copy(next));const actual=m.step();steps.push(copy(actual));
  if(saved&&(!saved.steps[steps.length-1]||!equal(actual,saved.steps[steps.length-1])))throw new PureCallReplayDiverged('Trace mismatch');
  if(!equal(actual,expected)){footer={kind:'Divergence',epoch:actual.epoch,expected_hash:hash(expected),observed_hash:hash(actual)};break;}
 }
 if(!footer){if(m.terminal&&steps.length!==reference.length)throw new PureCallReplayDiverged('Completed reference suffix');footer=m.terminal?{kind:'Completed',outcome:copy(m.terminal)}:{kind:'BudgetExhausted'};}
 footer={...footer,state_hash:stateHash(m),trace_hash:hash(steps)};
 if(saved&&(steps.length!==saved.steps.length||choices.length!==saved.choices.length||!equal(footer,saved.footer)))throw new PureCallReplayDiverged('Extra tape or footer mismatch');
 return copy({header:h,choices,steps,footer});
}
export function recordPureCall(m,reference,h){check(h,m,reference);return execute(m,reference,h);}
export function replayPureCall(m,reference,h,bundle){
 check(h,m,reference);closed(bundle,['header','choices','steps','footer']);if(!equal(h,bundle.header))throw new PureCallReplayIncompatible('Header identity differs');
 if(!Array.isArray(bundle.steps)||!Array.isArray(bundle.choices))throw new PureCallReplayDiverged('Tape framing');
 const actual=execute(m,reference,h,bundle);
 return {replay:'Exact',conformance:actual.footer.kind==='Completed'?'Admitted':actual.footer.kind==='Divergence'?'Diverged':'Unknown',execution:actual.footer.kind==='Divergence'?'StoppedAtDivergence':actual.footer.kind,qualification:'UNKNOWN',scope:'Integrated pure-call exposed-state development replay'};
}
