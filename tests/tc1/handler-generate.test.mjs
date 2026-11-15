// The generated TC1 handler family G (tools/tc1/handler-generate.mjs). Unit checks of
// the generator only: determinism, validity and declared scope. NOT Shen evidence:
// harness/tc1-generated.shen is where the model is compared and the features measured.
import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {generateHandlers,FAMILY_SIZE,mulberry32} from '../../tools/tc1/handler-generate.mjs';

const family=generateHandlers();

test('the family is deterministic, complete at its size, and a smaller count is a declared prefix', () => {
  assert.equal(family.count,String(FAMILY_SIZE));
  assert.equal(family.truncated,false);
  assert.equal(family.cases.length,FAMILY_SIZE);
  assert.equal(JSON.stringify(generateHandlers()),JSON.stringify(family));
  const prefix=generateHandlers(16);
  assert.equal(prefix.truncated,true);
  assert.equal(JSON.stringify(prefix.cases),JSON.stringify(family.cases.slice(0,16)));
  for(const bad of [0,-1,FAMILY_SIZE+1,1.5,'8'])assert.throws(()=>generateHandlers(bad),TypeError);
  // The PRNG is fixed: its first outputs for one seed are part of the family's identity.
  const r=mulberry32(1);assert.deepEqual([r(),r()].map(x=>Math.floor(x*1e6)),[627073,2735]);
});

test('every program is valid, nearly all are distinct, and they go beyond grammar H', () => {
  const texts=new Set();
  let multiOperation=0,closures=0,explicit=0,datatypes=0;
  for(const c of family.cases) {
    const checked=validatePureCallArtifact(encode(c.program),['int','0']);
    assert.equal(checked.node_count,c.nodes,c.name);
    texts.add(JSON.stringify(c.program.functions));
    const text=JSON.stringify(c.program.functions);
    if(c.program.effects.some(e=>e.operations.length>1)&&text.includes('"put"')&&text.includes('"get"'))multiOperation++;
    if(text.includes('"lambda"'))closures++;
    if(c.program.schema_version==='tc1-handler-demo/2')explicit++;
    if(c.program.datatypes.length)datatypes++;
  }
  // Small draws can repeat: 2,046 distinct function lists in 2,048 (measured).
  assert.equal(texts.size,2046);
  for(const [what,n] of Object.entries({multiOperation,closures,explicit,datatypes}))assert.ok(n>20,what+' '+n);
});
