import test from 'node:test';
import assert from 'node:assert/strict';
import {catalogKeys,coveredKeys,coverage} from '../../tools/tc0/pure-call-coverage.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases as dataCases} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as callCases} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
const rows=[...callCases,...dataCases].map(c=>({name:c.name,program:c.program,steps:new PureCallMachine(c.program,['int','0']).run(200).steps}));
const keysOf=name=>{const r=rows.find(r=>r.name===name);return coveredKeys(r.program,r.steps);};

test('catalog keys are stable and every observed hand key is a catalog key',()=>{
 assert.equal(catalogKeys().size,112);
 const c=coverage(rows);assert.deepEqual(c.unknown_observed,[]);
});
test('trap routing and frame kinds are attributed from the simulated frame stack',()=>{
 assert.ok(keysOf('sub-overflow-in-let-initializer').has('UnwindFrame let'));
 assert.ok(keysOf('neg-min-overflow-in-if-condition').has('UnwindFrame if'));
 assert.ok(keysOf('div-min-by-minus-one').has('Ready prim.div -> Unwind Overflow'));
 assert.ok(keysOf('match-scrutinee-trap').has('UnwindFrame match'));
 assert.ok(keysOf('left-call-trap-suppresses-emit').has('UnwindFrame return'));
});
test('tail positions: match arm and function body tail calls, non-tail calls push Return',()=>{
 const tail=keysOf('match-arm-tail-call');assert.ok(tail.has('Tail call in match arm'));assert.ok(!tail.has('Ready call -> Eval non-tail'));
 assert.ok(keysOf('non-tail-recursive-sum').has('Ready call -> Eval non-tail'));
 assert.ok(keysOf('mutual-tail-countdown').has('Tail call in if branch'));
});
test('a step record inconsistent with the simulated frames fails closed',()=>{
 const r=rows.find(r=>r.name==='recursive-datatype-sum'),steps=structuredClone(r.steps);steps[3].depth=String(Number(steps[3].depth)+1);
 assert.throws(()=>coveredKeys(r.program,steps),/lost sync/);
});
