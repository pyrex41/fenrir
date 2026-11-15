// Strict tape record/replay of the TC1 handler machine against a reference trace;
// UNQUALIFIED development replay. The TC1 counterpart of tools/tc0/pure-call-replay.mjs,
// with the same structure: a closed, source-bound header; one singleton Run choice per
// step, bound to the reference step's site and epoch; the implementation's steps; a
// footer with the final state and trace hashes. Replay re-executes a fresh machine
// against the same reference and requires every choice, step and the footer to equal
// the tape. A step that differs from the reference ends the tape with a Divergence
// footer at that epoch. Never accepts a TC0 tape or another profile.
import {createHash} from 'node:crypto';
import {encode,decimal} from '../tc0/canonical.mjs';
export class HandlerReplayDiverged extends Error {}
export class HandlerReplayIncompatible extends Error {}
export const TAPE_SCHEMA='tc1-handler-tape/1',TAPE_PROFILE='tc1-handler-step/1',MAX_TAPE_STEPS=1000n;
export const hash=x=>createHash('sha256').update(encode(x)).digest('hex');
const copy=x=>JSON.parse(encode(x));
const equal=(a,b)=>encode(a).equals(encode(b));
export const HEADER_KEYS=Object.freeze(['schema','profile','run_id','program_hash','input_hash','reference_hash','oracle_hash','catalog_hash','candidate_hash','adapter_hash','toolchain_hash','environment_hash','initial_state_hash','bounds']);
function closed(v,fields){if(!v||Array.isArray(v)||typeof v!=='object'||Object.keys(v).sort().join(',')!==[...fields].sort().join(','))throw new HandlerReplayDiverged('Closed fields');}
// Machine state as transport data: maps become sorted pairs, big integers decimal strings.
function data(x){
 if(x instanceof Map){const rows=[...x],numeric=rows.every(([k])=>/^\d+$/.test(k));return rows.sort(([a],[b])=>numeric?(BigInt(a)<BigInt(b)?-1:BigInt(a)>BigInt(b)?1:0):Buffer.compare(Buffer.from(a),Buffer.from(b))).map(([k,v])=>[k,data(v)]);}
 if(typeof x==='bigint')return String(x);if(Array.isArray(x))return x.map(data);
 if(typeof x==='boolean'||x===null)return x;
 if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).map(([k,v])=>[k,data(v)]));return x;
}
// Everything the handler machine holds, including its defect switches.
export function stateHash(m){return hash(data({functions:m.functions,codes:m.codes,control:m.control,environment:m.env,frames:m.frames,
 epoch:m.epoch,terminal:m.terminal,descriptors:m.descriptors,events:m.events,options:m.options}));}
function check(h,m,artifact,input,reference){
 closed(h,HEADER_KEYS);closed(h.bounds,['steps']);decimal(h.bounds.steps,{unsigned:true});
 if(h.schema!==TAPE_SCHEMA||h.profile!==TAPE_PROFILE||BigInt(h.bounds.steps)>MAX_TAPE_STEPS)throw new HandlerReplayIncompatible('Profile/bound');
 if(typeof h.run_id!=='string'||!h.run_id.length)throw new HandlerReplayDiverged('Run identity');
 for(const k of HEADER_KEYS.filter(k=>k.endsWith('_hash')))if(typeof h[k]!=='string'||!/^[0-9a-f]{64}$/.test(h[k]))throw new HandlerReplayDiverged('Hash spelling');
 if(m.epoch!==0n||m.control.kind!=='Eval'||m.frames.length||m.terminal||m.descriptors.length||m.events.length)throw new HandlerReplayIncompatible('Fresh machine required');
 if(h.program_hash!==hash(artifact)||h.input_hash!==hash(input)||h.initial_state_hash!==stateHash(m)||h.reference_hash!==hash(reference))throw new HandlerReplayIncompatible('Artifact/input/state/reference identity');
 if(!Array.isArray(reference))throw new HandlerReplayIncompatible('Reference records');
}
const domain=[{kind:'Run',task:'0'}];
function choice(h,index,expected,previous){
 if(expected.epoch!==String(index))throw new HandlerReplayIncompatible('Reference epoch');
 const occurrence=String(previous.filter(c=>{const {occurrence,...site}=c.site;return equal(site,expected.site);}).length);
 return {schema:'tc1-handler-choice/1',run_id:h.run_id,index:String(index),scheduler_epoch:String(index),kind:'Run',domain_hash:hash(domain),selected:domain[0],site:{...expected.site,occurrence}};
}
function execute(m,reference,h,saved){
 const choices=[],steps=[];let footer;
 while(!m.terminal&&steps.length<Number(h.bounds.steps)){
  const expected=reference[steps.length];if(!expected)throw new HandlerReplayIncompatible('Reference ended');
  const next=choice(h,steps.length,expected,choices);
  if(saved&&(!saved.choices[steps.length]||!equal(next,saved.choices[steps.length])))throw new HandlerReplayDiverged('Choice/domain/site/epoch mismatch');
  choices.push(copy(next));const actual=m.step();steps.push(copy(actual));
  if(saved&&(!saved.steps[steps.length-1]||!equal(actual,saved.steps[steps.length-1])))throw new HandlerReplayDiverged('Trace mismatch');
  if(!equal(actual,expected)){footer={kind:'Divergence',epoch:actual.epoch,expected_hash:hash(expected),observed_hash:hash(actual)};break;}
 }
 if(!footer){if(m.terminal&&steps.length!==reference.length)throw new HandlerReplayDiverged('Completed reference suffix');footer=m.terminal?{kind:'Completed',outcome:copy(m.terminal)}:{kind:'BudgetExhausted'};}
 footer={...footer,state_hash:stateHash(m),trace_hash:hash(steps)};
 if(saved&&(steps.length!==saved.steps.length||choices.length!==saved.choices.length||!equal(footer,saved.footer)))throw new HandlerReplayDiverged('Extra tape or footer mismatch');
 return copy({header:h,choices,steps,footer});
}
export function recordHandlers(m,artifact,input,reference,h){check(h,m,artifact,input,reference);return execute(m,reference,h);}
export function replayHandlers(m,artifact,input,reference,h,bundle){
 check(h,m,artifact,input,reference);closed(bundle,['header','choices','steps','footer']);if(!equal(h,bundle.header))throw new HandlerReplayIncompatible('Header identity differs');
 if(!Array.isArray(bundle.steps)||!Array.isArray(bundle.choices))throw new HandlerReplayDiverged('Tape framing');
 const actual=execute(m,reference,h,bundle);
 return {replay:'Exact',conformance:actual.footer.kind==='Completed'?'Admitted':actual.footer.kind==='Divergence'?'Diverged':'Unknown',execution:actual.footer.kind==='Divergence'?'StoppedAtDivergence':actual.footer.kind,qualification:'UNKNOWN',scope:'TC1 handler exposed-state development replay'};
}
