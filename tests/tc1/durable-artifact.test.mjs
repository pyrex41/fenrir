// Validation of schema tc1-durable-demo/1 (spec/tc1/DURABLE.md sections 1 and 2): each
// rejection is checked for its stated reason, not only for failing.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,validateFrontendArtifact,InvalidPureCallArtifact,residualEffects} from '../../tools/tc0/pure-call-artifact.mjs';
import {cases as handlerCases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';

const clone=p=>JSON.parse(JSON.stringify(p));
const Store={name:'Store',class:'durable',operations:[{name:'put',argument_type:'I64',result_type:'I64'}]};
const Ask={name:'Ask',class:'ordinary',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]};
// A one-function artifact whose main body is `body`; '#' node IDs are numbered from 100.
function program(body,{effects=['Store'],declared=[Store,Ask],argument='I64',result='I64',schema='tc1-durable-demo/1',slice='TC1-D1',datatypes=[]}={}) {
  let next=100n;const ids=[];
  const number=e=>{if(!Array.isArray(e))return e;
    if(typeof e[0]==='string'&&e[1]==='#'){const id=String(next++);ids.push(id);e[1]=id;}
    for(const x of e)if(Array.isArray(x))number(x);return e;};
  return {contract_version:'tc1-draft-1',schema_version:schema,slice,module:'t',datatypes,effects:declared,
    functions:[{id:'0',name:'main',parameter_id:'1',argument_type:argument,result_type:result,effects,body:number(clone(body))}],entry:'main',
    input_schema:{type:argument},source_map:['0',...ids].map(id=>({id,file:'t',line:'0',column:'0'}))};
}
const check=(p,input=['int','0'])=>validatePureCallArtifact(encode(p),input);
const rejects=(p,pattern,why,input)=>assert.throws(()=>check(p,input),e=>e instanceof InvalidPureCallArtifact&&pattern.test(e.message),why);
const put=['perform','#','Store','put',['int','#','1']];

test('a residual durable perform at the entry validates, and is the manifest', () => {
  const r=check(program(put));
  assert.deepEqual(encode(residualEffects(r.artifact)),encode([Store]));
});
test('every effect declaration names its class, ordinary or durable', () => {
  rejects(program(put,{declared:[{name:'Store',operations:Store.operations}]}),/Closed object fields/,'class missing');
  rejects(program(put,{declared:[{...Store,class:'volatile'}]}),/Effect class/,'unknown class');
  rejects(program(put,{declared:[{...Store,class:'runtime'}]}),/Effect class/,'runtime is not declarable');
  rejects(program(put,{declared:[{...Store,class:'remote'}]}),/Effect class/,'R1/P1 classes do not cross into D1');
  rejects(program(put,{declared:[{...Store,name:'Emit'}]}),/Effect name/,'reserved names stay reserved');
  rejects(program(put,{declared:[{...Store,operations:[{...Store.operations[0],read_only:true}]}]}),/Closed object fields/,'no remote operation metadata');
});
test('D1 declarations are not allowed in the PR10 schemas', () => {
  const r1=program(put,{schema:'tc1-handler-demo/3',slice:'TC1-R1'});
  rejects(r1,/Effect class/);
  const {entry,input_schema,...p1}=r1;
  rejects({...p1,schema_version:'tc1-handler-demo/4',slice:'TC1-P1',serves:[]},/Effect class/);
  assert.deepEqual(residualEffects(r1),[]);
  assert.deepEqual(residualEffects(p1),[]);
});
test('only durable effects may stay at the entry; ordinary ones must be handled', () => {
  const ask=['perform','#','Ask','ask',['int','#','1']];
  rejects(program(ask,{effects:['Ask']}),/Entry must handle every user effect/);
  check(program(['handle','#','Ask',[['ask','2',['var','#','2']]],ask],{effects:[]}));
});
test('a user handler may enclose a durable effect (provisional, DURABLE.md section 3)', () => {
  const r=check(program(['handle','#','Store',[['put','2',['var','#','2']]],put],{effects:[]}));
  assert.deepEqual(residualEffects(r.artifact),[],'handled everywhere: not residual');
});
test('the effect set still has to cover what the body performs', () => {
  rejects(program(put,{effects:[]}),/Function signature/);
});
test('the entry may take any serializable argument; the input is checked against it', () => {
  const datatypes=[{name:'Req',constructors:[{name:'Req',fields:['I64','Bytes']}]}];
  const p=program(['int','#','0'],{effects:[],argument:['Data','Req'],datatypes});
  check(p,['data','Req','Req',['int','5'],['bytes','ab']]);
  rejects(p,/Value type\/range/,'wrong input',['int','0']);
  rejects(program(['int','#','0'],{effects:[],argument:['Arrow','I64','I64',[]]}),/Serializable entry/);
});
test('durable operation types are serializable, as every operation type', () => {
  rejects(program(put,{declared:[{...Store,operations:[{name:'put',argument_type:['Arrow','I64','I64',[]],result_type:'I64'}]}]}),/Operation types must be serializable/);
});
test('D1 reads effect names before checking datatype fields', () => {
  const fields=[['Arrow','I64','I64',['Ask','Store']]];
  const datatypes=[{name:'Holder',constructors:[{name:'Hold',fields}]}];
  check(program(put,{datatypes}));
  rejects(program(put,{datatypes,declared:[Store]}),/Effect set/);
  rejects(program(put,{datatypes,declared:[Store,Ask,Ask]}),/Effect name/);
});
test('the frontend probe finds a finite request but still validates the artifact', () => {
  const datatypes=[{name:'Req',constructors:[{name:'Branch',fields:[['Data','Req'],['Data','Req']]},{name:'Leaf',fields:['Bool']}]}];
  const p=program(put,{argument:['Data','Req'],datatypes});
  const validated=validateFrontendArtifact(encode(p));
  assert.deepEqual(validated.input,['data','Req','Leaf',['bool',false]]);
  check(p,validated.input);
  assert.throws(()=>validateFrontendArtifact(encode({...p,input_schema:{type:'I64'}})),/Input schema/);
  assert.throws(()=>validateFrontendArtifact(encode({...p,datatypes:[{...datatypes[0],constructors:[datatypes[0].constructors[0]]}]})),/No bounded durable entry input/);
});
test('the accepted-job pin validates with the typed probe and only Store.commit residual', () => {
  const bytes=readFileSync(new URL('../../host/service/artifacts/accepted-job.json',import.meta.url));
  const {artifact,input}=validateFrontendArtifact(bytes);
  check(artifact,input);
  const manifest=residualEffects(artifact);
  assert.deepEqual(manifest.map(d=>[d.name,d.class,...d.operations.map(o=>[o.name,o.argument_type,o.result_type])]),
    [['Store','durable',['commit',['Data','Tx'],['Data','Reply']]]]);
});
test('the durable schema has no task forms', () => {
  rejects(program(['yield','#'],{effects:[]}),/Unsupported tag/);
});
test('identity: slice TC1-D1 and contract tc1-draft-1', () => {
  rejects(program(put,{slice:'TC1-H2'}),/Identity/);
  rejects(program(put,{schema:'tc1-handler-demo/2'}),/Identity/,'an older schema with the D1 slice');
});
test('older schemas are untouched: no class field, no residual effect at the entry', () => {
  for(const c of [...handlerCases,...resumptionCases])check(c.program);
  const old=clone(handlerCases[0].program);old.effects[0].class='ordinary';
  assert.throws(()=>check(old),/Closed object fields/);
  const p=clone(handlerCases[0].program),main=p.functions.find(f=>f.name==='main');main.effects=['Ask'];
  assert.throws(()=>check(p),/Entry must handle every user effect|Function signature/);
  assert.deepEqual(residualEffects(check(handlerCases[0].program).artifact),[]);
});
