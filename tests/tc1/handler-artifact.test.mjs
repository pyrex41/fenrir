import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {cases as tc0Cases} from '../../fixtures/tc0/pure-data-hand-cases.mjs';

const check=p=>validatePureCallArtifact(encode(p),['int','0']);
const base=cases.find(c=>c.name==='handler-basic').program;
const clone=p=>JSON.parse(JSON.stringify(p));
// With a pattern, the rejection must be for that reason and not, say, a source-map slip.
const rejects=(p,why,pattern)=>assert.throws(()=>check(p),e=>e instanceof InvalidPureCallArtifact&&(!pattern||pattern.test(e.message)),why);
// handler-basic body: ['handle',id,'Ask',[['ask',x,clause]],body]
const handle=p=>p.functions[0].body;

test('every handler fixture validates and runs to its handwritten outcome', () => {
  for(const c of cases) {
    const checked=check(c.program),run=new HandlerMachine(checked.artifact,checked.input).run(200);
    assert.equal(run.execution,'Completed',c.name);
    assert.deepEqual(run.outcome,c.expected_outcome,c.name);
  }
});
test('a handler must give exactly one clause per operation', () => {
  const missing=clone(base);handle(missing)[3]=[];rejects(missing,'missing clause');
  const duplicate=clone(base);handle(duplicate)[3].push(clone(handle(duplicate)[3][0]));rejects(duplicate,'duplicate clause');
  const unknown=clone(base);handle(unknown)[3][0][0]='tell';rejects(unknown,'clause for an undeclared operation');
});
test('effects must be declared, and reserved names cannot be redeclared', () => {
  const undeclared=clone(base);undeclared.effects=[];rejects(undeclared,'handle of an undeclared effect');
  const reserved=clone(base);reserved.effects[0].name='Emit';rejects(reserved,'reserved effect name');
  const twice=clone(base);twice.effects.push(clone(twice.effects[0]));rejects(twice,'duplicate effect');
});
test('the entry function must handle every user effect', () => {
  const p=clone(base);p.functions[0].body=handle(p)[4]; // the body alone: perform with no handler
  p.source_map=p.source_map.filter(r=>JSON.stringify(p.functions[0].body).includes(`"${r.id}"`)||r.id===p.functions[0].id);
  rejects(p,'unhandled effect at entry');
  const declared=clone(p);declared.functions[0].effects=['Ask'];rejects(declared,'entry may not declare a user effect');
});
test('effect sets have one spelling: byte order, no duplicates, declared names only', () => {
  const f=cases.find(c=>c.name==='clause-sees-definition-bindings').program;
  const duplicate=clone(f);duplicate.functions[1].effects=['Ask','Ask'];rejects(duplicate,'duplicate');
  const unordered=clone(f);unordered.functions[1].effects=['Emit','Ask'];rejects(unordered,'order');
  const unknown=clone(f);unknown.functions[1].effects=['Nope'];rejects(unknown,'undeclared');
  const missing=clone(f);missing.functions[1].effects=[];rejects(missing,'a perform outside a handler needs the effect declared');
  // A superset in byte order is fine, and the caller then owes the extra effect too.
  const ordered=clone(f);ordered.functions[1].effects=['Ask','Emit'];rejects(ordered,'main calls f but does not declare Emit');
  ordered.functions[0].effects=['Emit'];check(ordered);
});
test('perform arguments and clause results are typed by the operation', () => {
  const argument=clone(base);const perform=handle(argument)[4][3];perform[4]=['unit',perform[4][1]];rejects(argument,'perform argument type');
  const result=clone(base);const clause=handle(result)[3][0];clause[2]=['unit',clause[2][1]];
  result.source_map=result.source_map.filter(r=>JSON.stringify(result.functions).includes(`"${r.id}"`));rejects(result,'clause result type');
});
test('operation types must be serializable in this slice', () => {
  const p=clone(base);p.effects[0].operations[0].result_type=['Arrow','I64','I64',[]];rejects(p,'arrow in an operation type');
});
test('TC0-A schemas still reject effects, handle and perform', () => {
  const old=clone(base);old.contract_version='0.2';old.schema_version='tc0-a-pure-call-demo/2';old.slice='TC0-A';rejects(old,'effect declarations under TC0-A');
  old.effects=[];rejects(old,'handle under TC0-A');
});
test('on TC0-A programs the handler machine and the TC0-A implementation give the same run', () => {
  for(const c of tc0Cases) {
    const a=new PureCallMachine(c.program,['int','0']).run(200),b=new HandlerMachine(c.program,['int','0']).run(200);
    assert.deepEqual({steps:b.steps,outcome:b.outcome,descriptors:b.descriptors},{steps:a.steps,outcome:a.outcome,descriptors:a.descriptors},c.name);
  }
});
test('each injected defect changes the trace of at least one fixture', () => {
  for(const option of ['forgottenResume','doubleResume','outermostHandler','dynamicClauseEnvironment']) {
    const differs=cases.some(c=>{
      const checked=check(c.program),good=new HandlerMachine(checked.artifact,checked.input).run(200);
      try{return JSON.stringify(new HandlerMachine(checked.artifact,checked.input,{[option]:true}).run(200).steps)!==JSON.stringify(good.steps);}catch{return false;}
    });
    assert.ok(differs,option);
  }
});

// ---------- Slice H2: explicit one-shot resumption ----------
import {resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
const h2=resumptionCases.find(c=>c.name==='clause-continues-after-resume').program;
// its handle: ['handle',id,'Ask',[['ask',x,k,clauseBody]],body]; clauseBody = let r = resume(k, x+1) in r*2
const clauseOf=p=>handle(p)[3][0];
const remap=p=>{p.source_map=p.source_map.filter(r=>JSON.stringify(p.functions).includes(`"${r.id}"`));return p;};
let nextId=5000;const id=()=>String(nextId++);
const located=(p,...ids)=>{for(const i of ids)p.source_map.push({id:i,file:'t',line:'0',column:'0'});return p;};

test('every resumption fixture validates and runs to its handwritten outcome', () => {
  for(const c of resumptionCases) {
    const checked=check(c.program),run=new HandlerMachine(checked.artifact,checked.input).run(200);
    assert.equal(run.execution,'Completed',c.name);
    assert.deepEqual(run.outcome,c.expected_outcome,c.name);
  }
});
test('a resumption must be used: zero uses is rejected', () => {
  const p=clone(h2),clause=clauseOf(p),a=id();clause[3]=['int',a,'0'];rejects(located(remap(p),a),'k never used',/exactly once/);
});
test('a resumption must be used once: two uses are rejected', () => {
  const p=clone(h2),clause=clauseOf(p),[k]=[clause[2]],a=id(),b=id(),c=id(),d=id(),e=id();
  clause[3]=['prim',a,'add',['resume',b,k,['int',c,'1']],['resume',d,k,['int',e,'2']]];
  rejects(located(remap(p),a,b,c,d,e),'k used twice',/exactly once/);
});
test('a resumption must be used on every path', () => {
  const p=clone(h2),clause=clauseOf(p),k=clause[2],a=id(),b=id(),c=id(),d=id(),e=id();
  clause[3]=['if',a,['bool',b,true],['resume',c,k,['int',d,'1']],['int',e,'0']];
  rejects(located(remap(p),a,b,c,d,e),'k used in one branch only',/every path/);
});
test('a resumption is not a value and cannot be captured', () => {
  const asValue=clone(h2),c1=clauseOf(asValue),a=id();c1[3]=['var',a,c1[2]];rejects(located(remap(asValue),a),'k as a variable',/not a value/);
  const captured=clone(h2),c2=clauseOf(captured),k=c2[2],l=id(),u=id(),r=id(),n=id(),ap=id(),un=id();
  c2[3]=['apply',ap,['lambda',l,u,'Unit','I64',[],[],['resume',r,k,['int',n,'1']]],['unit',un]];
  rejects(located(remap(captured),l,r,n,ap,un),'k captured by a closure',/Unknown resumption/);
});
test('resume takes the operation result type and yields the handle type', () => {
  const p=clone(h2),clause=clauseOf(p),k=clause[2],a=id(),b=id();clause[3]=['resume',a,k,['unit',b]];rejects(located(remap(p),a,b),'resume argument type',/Resume argument/);
});
test('an inner clause cannot use an outer clause\'s resumption', () => {
  const p=clone(h2),clause=clauseOf(p),k=clause[2],h=id(),x=id(),r=id(),n=id(),pf=id(),pa=id();
  // outer clause body: handle Ask { ask(x2) => resume(outerK, 1) } in perform ask 0
  clause[3]=['handle',h,'Ask',[['ask',x,['resume',r,k,['int',n,'1']]]],['perform',pf,'Ask','ask',['int',pa,'0']]];
  rejects(located(remap(p),h,r,n,pf,pa),'outer k used inside an inner clause',/Unknown resumption/);
});
test('the tail-resumptive schema rejects explicit resumptions', () => {
  const p=clone(h2);p.schema_version='tc1-handler-demo/1';p.slice='TC1-H1';rejects(p,'H2 forms under the H1 schema',/Handler clause/);
});
test('each resumption defect changes the trace of at least one fixture', () => {
  for(const option of ['resumeReturnsArgument','shallowResume']) {
    const differs=resumptionCases.some(c=>{
      const checked=check(c.program),good=new HandlerMachine(checked.artifact,checked.input).run(200);
      try{return JSON.stringify(new HandlerMachine(checked.artifact,checked.input,{[option]:true}).run(200).steps)!==JSON.stringify(good.steps);}catch{return false;}
    });
    assert.ok(differs,option);
  }
});
