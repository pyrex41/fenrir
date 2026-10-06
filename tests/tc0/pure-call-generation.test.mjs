import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {generatePureCalls} from '../../tools/tc0/pure-call-generate.mjs';
import {pureCallReductions,pureCallMetric} from '../../tools/tc0/pure-call-reduce.mjs';
test('finite32-case family is deterministic, typed, bounded and explicit about truncation',()=>{const g=generatePureCalls();assert.equal(g.cases.length,32);assert.equal(g.truncated,false);assert.deepEqual(generatePureCalls(),g);assert.equal(generatePureCalls(2).truncated,true);for(const c of g.cases){const v=validatePureCallArtifact(encode(c.program),['int','0']);const r=new PureCallMachine(v.artifact,v.input).run();assert.equal(r.execution,'Completed');assert.deepEqual(r.outcome,c.expected_outcome);assert.deepEqual(r.events.filter(e=>e.kind==='Emit').map(e=>e.label),['left','right']);}assert.throws(()=>generatePureCalls(33));});
test('structural proposals remain typed with covered source IDs and smaller ASTs',()=>{const p=generatePureCalls(1).cases[0].program,n=pureCallMetric(p).nodes,proposals=pureCallReductions(p);assert.ok(proposals.length>0);for(const row of proposals){const v=validatePureCallArtifact(encode(row.program),['int','0']);assert.ok(Number(v.node_count)<n);assert.ok(row.metric.nodes<n);}assert.ok(proposals.some(r=>r.rule==='constant-if'));assert.ok(proposals.some(r=>r.rule==='drop-let-if-still-typed'));assert.ok(proposals.some(r=>r.rule==='add-zero'));});
