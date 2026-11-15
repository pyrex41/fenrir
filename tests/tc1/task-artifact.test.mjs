// Validation of schema tc1-task-demo/1 (spec/tc1/CONCURRENCY.md sections 2 and 3): each
// rejection is checked for its stated reason, not only for failing.
import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {cases} from '../../fixtures/tc1/task-hand-cases.mjs';
import {cases as handlerCases} from '../../fixtures/tc1/handler-hand-cases.mjs';

const check=p=>validatePureCallArtifact(encode(p),['int','0']);
const clone=p=>JSON.parse(JSON.stringify(p));
const rejects=(p,pattern,why)=>assert.throws(()=>check(p),e=>e instanceof InvalidPureCallArtifact&&pattern.test(e.message),why);
// A one-function artifact whose main body is `body`, IDs from 100 up; every node gets a
// source-map row.
function program(body,{effects=['Channel','Emit','Task'],result='I64',schema='tc1-task-demo/1',slice='TC1-C1',declared=[]}={}) {
  let next=100n;const ids=[];
  const number=e=>{if(!Array.isArray(e)||typeof e[0]!=='string')return e;
    if(e[1]==='#'){const id=String(next++);ids.push(id);e[1]=id;}
    for(const x of e)if(Array.isArray(x))number(x);return e;};
  const b=number(clone(body));
  return {contract_version:'tc1-draft-1',schema_version:schema,slice,module:'t',datatypes:[],effects:declared,
    functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:result,effects,body:b}],entry:'main',input_schema:{type:'I64'},
    source_map:['0',...ids].map(id=>({id,file:'t',line:'0',column:'0'}))};
}
const unit=['unit','#'],zero=['int','#','0'];
// e evaluated for its value and discarded, so main's own result stays I64.
const inLet=e=>['let','#','9',e,['int','#','0']];
const lam=(body,result='I64',effects=[])=>['lambda','#','2','Unit',result,effects,[],body];
const let_=(id,init,body)=>['let','#',id,init,body];

test('every TC1-C1 fixture validates', () => {for(const c of cases)check(c.program);});
test('a minimal program with each C1 form validates', () => {
  check(program(let_('3',['channel','#','I64','2'],let_('4',['spawn','#',lam(['send','#',['var','#','3'],zero],'SendResult',['Channel'])],
    let_('5',['await','#',['var','#','4']],let_('6',['cancel','#',['var','#','4']],let_('7',['yield','#'],let_('8',['receive','#',['var','#','3']],
      let_('9',['close','#',['var','#','3']],['scope','#',zero])))))))));
});
test('the result of a scope must be serializable: no handle leaves its scope', () => {
  rejects(program(inLet(['scope','#',['channel','#','I64','1']])),/A scope result must be serializable/,'channel out of a scope');
  rejects(program(inLet(['scope','#',['spawn','#',lam(zero)]])),/A scope result must be serializable/,'task out of a scope');
  rejects(program(inLet(['scope','#',lam(zero)])),/A scope result must be serializable/,'closure out of a scope');
});
test('a spawned function takes Unit and returns a serializable result', () => {
  rejects(program(inLet(['spawn','#',['lambda','#','2','I64','I64',[],[],zero]])),/Spawn needs a function from Unit/);
  rejects(program(inLet(['spawn','#',lam(['channel','#','I64','1'],['Channel','I64'],['Channel'])])),/A task result must be serializable/);
  rejects(program(inLet(['spawn','#',zero])),/Spawn needs a function from Unit/,'not a function');
});
test('await and cancel need a task handle; send, receive and close a channel handle', () => {
  rejects(program(inLet(['await','#',zero])),/Task handle required/);
  rejects(program(inLet(['cancel','#',zero])),/Task handle required/);
  rejects(program(inLet(['receive','#',zero])),/Channel handle required/);
  rejects(program(inLet(['close','#',['spawn','#',lam(zero)]])),/Channel handle required/,'a task is not a channel');
  rejects(program(let_('3',['channel','#','I64','1'],inLet(['send','#',['var','#','3'],unit]))),/Send value type/);
});
test('channel capacity is 1..maximum and channel elements are serializable', () => {
  rejects(program(inLet(['channel','#','I64','0'])),/Channel capacity/,'zero capacity');
  rejects(program(inLet(['channel','#','I64','9'])),/Channel capacity/,'above the default maximum of 8');
  assert.doesNotThrow(()=>validatePureCallArtifact(encode(program(let_('3',['channel','#','I64','9'],zero))),['int','0'],{maxCapacity:9}),'the maximum is a configured cap');
  rejects(program(inLet(['channel','#',['Arrow','Unit','I64',[]],'1'])),/Channel elements must be serializable/);
  rejects(program(inLet(['channel','#',['Task','I64'],'1'])),/Channel elements must be serializable/);
});
test('handles are neither serializable nor equality-compatible', () => {
  rejects(program(let_('3',['channel','#','I64','1'],let_('4',['emit','#','x',['var','#','3']],zero))),/Emit serializable/);
  rejects(program(let_('3',['channel','#','I64','1'],['prim','#','eq',['var','#','3'],['var','#','3']]),{result:'Bool'}),/Equality type/);
  rejects(program(['channel','#','I64','1'],{result:['Channel','I64']}),/Serializable entry/,'entry result');
});
test('runtime effects must be declared, in canonical order, and are reserved', () => {
  rejects(program(inLet(['yield','#']),{effects:[]}),/Function signature/,'yield needs Task');
  rejects(program(inLet(['channel','#','I64','1']),{effects:['Task']}),/Function signature/,'channel needs Channel');
  rejects(program(zero,{effects:['Task','Channel']}),/Effect set order/);
  rejects(program(zero,{declared:[{name:'Task',operations:[{name:'op',argument_type:'I64',result_type:'I64'}]}]}),/Effect name/,'Task is reserved');
  // The effects of a spawned function are required at the spawn site.
  rejects(program(inLet(['spawn','#',lam(['yield','#'],'Unit',['Task'])]),{effects:['Channel']}),/Function signature/);
});
test('Outcome, SendResult and ReceiveResult are matched, exhaustively, and not constructed', () => {
  const t=['spawn','#',lam(zero)];
  check(program(['match','#',['await','#',t],['Ok',['3'],['var','#','3']],['Cancelled',[],zero],['Failed',['4'],zero]]));
  rejects(program(['match','#',['await','#',t],['Ok',['3'],['var','#','3']],['Cancelled',[],zero]]),/Non-exhaustive/);
  rejects(program(['match','#',['await','#',t],['Ok',[],zero],['Cancelled',[],zero],['Failed',['4'],zero]]),/Match binders/);
  rejects(program(inLet(['construct','#','Outcome','Cancelled'])),/Unknown datatype/);
});
test('the identity of a TC1-C1 artifact is checked', () => {
  rejects(program(zero,{slice:'TC1-H2'}),/Identity/);
  const p=program(zero);p.contract_version='0.2';rejects(p,/Identity/);
});
test('older schemas still reject every C1 form and the runtime effects', () => {
  for(const [schema,slice] of [['tc1-handler-demo/2','TC1-H2'],['tc1-handler-demo/1','TC1-H1']]) {
    rejects(program(inLet(['yield','#']),{schema,slice,effects:[]}),/Unsupported tag/,schema+' yield');
    rejects(program(['scope','#',zero],{schema,slice,effects:[]}),/Unsupported tag/,schema+' scope');
    rejects(program(zero,{schema,slice,effects:['Task']}),/Effect set/,schema+' Task in an effect set');
    rejects(program(zero,{schema,slice,effects:[],result:'SendResult'}),/Array required/,schema+' SendResult is not a type there');
  }
  for(const c of handlerCases)check(c.program);
});
