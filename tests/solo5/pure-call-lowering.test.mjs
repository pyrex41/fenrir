import test from 'node:test';
import assert from 'node:assert/strict';
import {lowerBatch, lowerProgram, UnsupportedGuestProgram} from '../../tools/solo5/pure-call/lower.mjs';
import {cases as callHand} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../../fixtures/tc0/pure-data-hand-cases.mjs';

const items=[...callHand,...dataHand].map(c=>({program:c.program,input:['int','0']}));

test('every hand case lowers, and the batch identity is deterministic', () => {
  const a=lowerBatch(items),b=lowerBatch(items);
  assert.equal(a.header,b.header);
  assert.match(a.header,new RegExp(`pc_program_count=${items.length};`));
  assert.equal(a.artifact_sha256.length,items.length);
  assert.notEqual(lowerBatch(items.slice(1)).batch_sha256,a.batch_sha256);
});
test('the header carries data only: no transition or outcome names', () => {
  const {header}=lowerBatch(items);
  for(const word of ['Dispatch','CollectReturn','UnwindFrame','expected'])assert.ok(!header.includes(word),word);
});
test('lambda free bindings are lowered in numeric, not lexicographic, order', () => {
  // Bindings 100 and 20: lexicographic order would put "100" first.
  const lambda=['lambda','5','4','I64','I64',[],[],['prim','6','add',['var','7','100'],['prim','8','add',['var','9','20'],['var','11','4']]]];
  const program={...items[0].program,functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:'I64',effects:[],
    body:['let','2','100',['int','3','1'],['let','12','20',['int','13','2'],['apply','14',lambda,['int','15','3']]]]}],
    source_map:['0','2','3','5','6','7','8','9','11','12','13','14','15'].map(id=>({id,file:'t',line:'0',column:'0'}))};
  const {text}=lowerProgram(program,['int','0'],'t');
  assert.match(text,/\{UINT64_C\(20\),UINT64_C\(100\)\}/);
});
test('entry inputs the guest cannot hold are refused, not approximated', () => {
  assert.throws(()=>lowerProgram(items[0].program,['bytes','00'],'t'));
});
