import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateArtifact, InvalidArtifact, ValidationLimit } from '../../tools/tc0/artifact.mjs';
import { encode, canonicalHash } from '../../tools/tc0/canonical.mjs';
import { ExpressionMachine } from '../../runtime/tc0/expression-machine.mjs';
const fixture=readFileSync(new URL('../../fixtures/tc0/left-trap-program.json',import.meta.url));
const expected=JSON.parse(readFileSync(new URL('../../fixtures/tc0/left-trap-trace.json',import.meta.url)));
const clone=()=>JSON.parse(fixture);
function checkedMachine(a=fixture, input=['unit'], options={}) {
  const graph=validateArtifact(a,input), fn=graph.artifact.functions[0];
  return new ExpressionMachine(fn.body,fn.parameter_id,graph.input,options);
}
function withBody(body,result='I64',effects=[]) {
  const a=clone(); a.functions[0].body=body;a.functions[0].result_type=result;a.functions[0].effects=effects;
  const ids=['0'];
  function visit(e) {ids.push(e[1]);for(const v of e.slice(2)) if(Array.isArray(v)) visit(v);}
  visit(body);a.source_map=ids.map(id=>({id,file:'test.tc0',line:'1',column:'0'}));return encode(a);
}

test('canonical program validates without rewriting source-map identity',()=>{
  const graph=validateArtifact(fixture,['unit']);assert.equal(graph.node_count,'8');
  assert.equal(encode(graph.artifact).toString(),fixture.toString().trim());
  assert.ok(Object.isFrozen(graph.artifact.functions[0].body));
  const a=clone();a.source_map[0].file='different.tc0';
  assert.notEqual(canonicalHash(fixture),canonicalHash(encode(a)));
});
test('candidate agrees with hand-derived eleven-step trap trace',()=>{
  const actual=checkedMachine().run(11);
  assert.equal(actual.execution,expected.expected_execution);assert.deepEqual(actual.outcome,expected.expected_outcome);
  assert.deepEqual(actual.steps,expected.steps);
  assert.equal(actual.events.filter(e=>e.kind==='Emit').length,0);
});
test('completion at last allowed step; incomplete unwind is not completion',()=>{
  const machine=checkedMachine(), prefix=machine.run(10);assert.equal(prefix.execution,'BudgetExhausted');
  assert.equal(prefix.outcome,null);assert.deepEqual(machine.run(1).outcome,['Trap','DivZero']);
  assert.throws(()=>machine.step(),/after termination/);
  assert.equal(checkedMachine().run(0).execution,'BudgetExhausted');
});
test('reversed operands emit before trapping and diverge at the second selected site',()=>{
  const faulty=checkedMachine(fixture,['unit'],{reverseOperands:true}).run(50);
  assert.deepEqual(faulty.outcome,['Trap','DivZero']);
  assert.deepEqual(faulty.events.filter(e=>e.kind==='Emit').map(e=>e.value),[['int','7']]);
  assert.deepEqual(faulty.steps[0],expected.steps[0]);
  assert.notDeepEqual(faulty.steps[1].site,expected.steps[1].site);
});
test('let uses immutable lexical values; if enters exactly the selected branch',()=>{
  const body=['let','2','20',['int','3','7'],['if','4',['bool','5',true],['var','6','20'],['prim','7','div',['int','8','1'],['int','9','0']]]];
  assert.deepEqual(checkedMachine(withBody(body)).run(30).outcome,['Ok',['int','7']]);
});
test('host validation rejects invalid artifacts before creating a candidate',()=>{
  const mutations=[
    a=>{a.extra=null;}, a=>{a.schema_version='tc0-a/1';},a=>{a.slice='TC0-C';},
    a=>{a.functions.push(a.functions[0]);},a=>{a.entry='absent';},a=>{a.functions[0].extra=[];},
    a=>{a.functions[0].parameter_id='0';},a=>{a.functions[0].body[1]='0';},
    a=>{a.functions[0].body[3][3][2]='9223372036854775808';},
    a=>{a.functions[0].body[3][3][2]='-0';},a=>{a.functions[0].result_type='Bool';},
    a=>{a.functions[0].effects=[];},a=>{a.source_map.pop();},
    a=>{a.source_map[0].id='999';},a=>{a.source_map.push(a.source_map[0]);},
    a=>{a.input_schema.type='I64';},a=>{a.functions[0].body[0]='spawn';},
    a=>{a.functions[0].body[2]='__proto__';},a=>{a.functions[0].body.push(['unit','50']);},
  ];
  for (const mutate of mutations) {const a=clone();mutate(a);assert.throws(()=>validateArtifact(encode(a),['unit']),InvalidArtifact);}
  assert.throws(()=>validateArtifact(fixture,['int','1']),InvalidArtifact);
  assert.throws(()=>validateArtifact(withBody(['var','2','999']),['unit']),InvalidArtifact);
  assert.throws(()=>validateArtifact(withBody(['prim','2','add',['bool','3',true],['int','4','1']]),['unit']),InvalidArtifact);
});
test('validation caps have distinct nonacceptance classification',()=>{
  assert.throws(()=>validateArtifact(fixture,['unit'],{maxNodes:7}),ValidationLimit);
  assert.throws(()=>validateArtifact(fixture,['unit'],{maxDepth:1}),ValidationLimit);
});
test('arithmetic boundaries and comparison/not',()=>{
  for(const [op,args,outcome,resultType] of [
    ['add',['9007199254740992','1'],['Ok',['int','9007199254740993']],'I64'],
    ['mul',['9223372036854775807','2'],['Trap','Overflow'],'I64'],
    ['div',['-7','3'],['Ok',['int','-2']],'I64'],
    ['neg',['-9223372036854775808'],['Trap','Overflow'],'I64'],
    ['lt',['-1','0'],['Ok',['bool',true]],'Bool']]) {
    const body=['prim','2',op,...args.map((n,i)=>['int',String(i+3),n])];
    assert.deepEqual(checkedMachine(withBody(body,resultType)).run(30).outcome,outcome);
  }
  assert.deepEqual(checkedMachine(withBody(['prim','2','not',['bool','3',true]],'Bool')).run(20).outcome,['Ok',['bool',false]]);
});
