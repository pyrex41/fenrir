// UNQUALIFIED strict replay development component for the arithmetic hand fixture.
// Reference steps are independently supplied hand/Shen-checked records, not candidate verdicts.
import { createHash } from 'node:crypto';
import { encode, decimal } from './canonical.mjs';
export class ReplayDiverged extends Error {}
export class ReplayIncompatible extends Error {}
const hash=v=>createHash('sha256').update(encode(v)).digest('hex');
const headerKeys=['schema','contract','slice','profile','run_id','artifact_hash','input_hash','oracle_hash','oracle_source_hash','catalog_hash','monitor_hash','adapter_hash','candidate_hash','compiler_runtime_hash','environment_hash','initial_state_hash','candidate_options','bounds'];
function closed(v, keys) {
  if (!v || Array.isArray(v) || typeof v !== 'object' || Object.keys(v).sort().join(',') !== [...keys].sort().join(',')) throw new ReplayDiverged('Closed schema mismatch');
}
function same(a,b) {return encode(a).equals(encode(b));}
function copy(v) {return JSON.parse(encode(v));}
function data(v) {
  if (v instanceof Map) return [...v].sort((a,b)=>BigInt(a[0]) < BigInt(b[0]) ? -1 : BigInt(a[0]) > BigInt(b[0]) ? 1 : 0).map(([k,x])=>[k,data(x)]);
  if (Array.isArray(v)) return v.map(data);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k,x])=>[k,data(x)]));
  if (typeof v === 'bigint' || typeof v === 'number') return String(v);
  return v;
}
export function candidateStateHash(machine) {
  return hash(data({control:machine.control,environment:machine.env,continuation:machine.frames,
    epoch:machine.epoch,terminal:machine.terminal,events:machine.events,reverse_operands:machine.reverseOperands}));
}
function headerCheck(header, machine, reference) {
  closed(header,headerKeys);
  if (machine.epoch !== 0n || machine.control.kind !== 'Eval' || machine.frames.length || machine.terminal) throw new ReplayIncompatible('Requires fresh initial machine');
  if (header.schema !== 'arithmetic-demo-tape/1' || header.contract !== '0.2' || header.slice !== 'TC0-A' || header.profile !== 'arithmetic-demo-frames/1') throw new ReplayIncompatible('Unsupported profile');
  if (typeof header.run_id !== 'string' || !header.run_id.length) throw new ReplayDiverged('Run identity');
  for (const key of headerKeys.filter(k=>k.endsWith('_hash'))) if (!/^[0-9a-f]{64}$/.test(header[key])) throw new ReplayDiverged('Hash format');
  closed(header.candidate_options,['reverse_operands']);
  if (typeof header.candidate_options.reverse_operands !== 'boolean' || header.candidate_options.reverse_operands !== machine.reverseOperands) throw new ReplayIncompatible('Candidate options differ');
  closed(header.bounds,['reference_steps']); decimal(header.bounds.reference_steps,{unsigned:true});
  if (BigInt(header.bounds.reference_steps) > 1000n) throw new ReplayIncompatible('Development bound unsupported');
  if (header.initial_state_hash !== candidateStateHash(machine) || header.oracle_hash !== hash(reference)) throw new ReplayIncompatible('Initial state/reference identity');
}
const domain=[{kind:'Run',task:'0'}];
function choice(header,index,expected,previous) {
  const occurrence=String(previous.filter(c=>{const {occurrence,...site}=c.site;return same(site,expected.site);}).length);
  return {schema:'arithmetic-demo-choice/1',run_id:header.run_id,index:String(index),scheduler_epoch:String(index),
    kind:'Run',domain_hash:hash(domain),selected:{kind:'Run',task:'0'},site:{...expected.site,occurrence}};
}
function boundary(machine,steps) {return {candidate_state_hash:candidateStateHash(machine),trace_hash:hash(steps)};}
export function record(machine, reference, header) {
  headerCheck(header,machine,reference);
  const choices=[],steps=[]; const fuel=Number(header.bounds.reference_steps);
  let footer;
  while (!machine.terminal && steps.length < fuel) {
    const expected=reference[steps.length];
    if (!expected) throw new ReplayIncompatible('Reference ended before candidate');
    choices.push(copy(choice(header,steps.length,expected,choices)));
    const actual=machine.step();steps.push(copy(actual));
    if (!same(actual,expected)) {
      footer={kind:'Divergence',epoch:actual.epoch,expected_checkpoint:hash(expected),observed_checkpoint:hash(actual),...boundary(machine,steps)};
      break;
    }
  }
  if (!footer) footer=machine.terminal
    ? {kind:'Completed',outcome:copy(machine.terminal),...boundary(machine,steps)}
    : {kind:'BudgetExhausted',...boundary(machine,steps)};
  return copy({header,choices,steps,footer});
}
export function replay(machine, reference, expectedHeader, bundle) {
  closed(bundle,['header','choices','steps','footer']);
  headerCheck(expectedHeader,machine,reference);
  // Whole identity comparison, not a seed fallback or cross-candidate scenario replay.
  if (!same(bundle.header,expectedHeader)) throw new ReplayIncompatible('Header identity differs');
  if (!Array.isArray(bundle.choices) || !Array.isArray(bundle.steps)) throw new ReplayDiverged('Tape framing');
  const choices=[],steps=[];let footer;
  const fuel=Number(expectedHeader.bounds.reference_steps);
  while (!machine.terminal && steps.length < fuel) {
    const expected=reference[steps.length];
    if (!expected) throw new ReplayIncompatible('Reference ended before candidate');
    const required=choice(expectedHeader,steps.length,expected,choices), saved=bundle.choices[steps.length];
    if (!saved || !same(saved,required)) throw new ReplayDiverged('Missing or changed choice/domain/site/epoch');
    choices.push(copy(saved)); const actual=machine.step();steps.push(copy(actual));
    if (!bundle.steps[steps.length-1] || !same(actual,bundle.steps[steps.length-1])) throw new ReplayDiverged('Trace checkpoint differs');
    if (!same(actual,expected)) {
      footer={kind:'Divergence',epoch:actual.epoch,expected_checkpoint:hash(expected),observed_checkpoint:hash(actual),...boundary(machine,steps)};
      break;
    }
  }
  if (!footer) footer=machine.terminal
    ? {kind:'Completed',outcome:copy(machine.terminal),...boundary(machine,steps)}
    : {kind:'BudgetExhausted',...boundary(machine,steps)};
  if (choices.length !== bundle.choices.length || steps.length !== bundle.steps.length) throw new ReplayDiverged('Extra tape/trace suffix');
  if (!same(footer,bundle.footer)) throw new ReplayDiverged('Footer/boundary differs');
  return {replay:'Exact',conformance:footer.kind === 'Divergence' ? 'Diverged' : footer.kind === 'Completed' ? 'Admitted' : 'Unknown',
    execution:footer.kind === 'Divergence' ? 'StoppedAtDivergence' : footer.kind,
    qualification:'UNKNOWN',scope:'Unqualified hand-fixture development replay only'};
}
export { hash as checkpointHash };
