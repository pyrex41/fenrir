// The exhaustive-small TC1 handler scope: grammar H of tools/tc1/handler-enumerate.mjs.
// Counts are derived by hand from the grammar, then by a counting recurrence that
// builds no programs. The JavaScript machine here is a scripted peer for UNIT tests,
// NOT Shen evidence: harness/tc1-exhaustive.shen is where the model is compared.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdirSync,mkdtempSync,readFileSync,readdirSync,rmSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,TC1_HANDLER_SCHEMA,TC1_RESUMPTION_SCHEMA} from '../../tools/tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {enumerateHandlers} from '../../tools/tc1/handler-enumerate.mjs';
import {MUTANTS} from '../../tools/tc1/handler-defects.mjs';

const run=(program,options={})=>new HandlerMachine(program,['int','0'],options).run(200);
const emitted=r=>r.events.filter(e=>e.kind==='Emit').map(e=>e.value[1]);

// The number of expressions of H with exactly n nodes, from the productions alone.
// kind 'E' uses no resumption, 'R' uses the innermost one exactly once; ask and bid say
// whether that effect has a handler in scope; v is the number of binders in scope.
function count(kind,n,ask,bid,v) {
  if(n<1)return 0;
  const E=(m,a=ask,b=bid,w=v)=>count('E',m,a,b,w),R=(m,a=ask,b=bid,w=v)=>count('R',m,a,b,w),X=kind==='E'?E:R;
  const sum=(lo,hi,f)=>{let t=0;for(let i=lo;i<=hi;i++)t+=f(i);return t;};
  const unary=1+(ask?2:0)+(bid?1:0);                       // tick; deep and perform Ask; perform Bid
  const conditions=m=>(m===1?2:0)+sum(1,m-2,i=>E(i)*E(m-1-i));  // true, false, lt(E,E)
  const ifs=sum(1,n-3,c=>conditions(c)*sum(1,n-2-c,i=>X(i)*X(n-1-c-i)));
  // handle(Ask|Bid, clause, body): a clause of either form outside the handler, the body under it.
  const handles=sum(1,n-2,i=>(E(i,ask,bid,v+1)+R(i,ask,bid,v+1))*(X(n-1-i,true,bid)+X(n-1-i,ask,true)));
  if(kind==='E')return (n===1?1+v:0)+unary*E(n-1)+sum(1,n-2,i=>E(i)*E(n-1-i))+sum(1,n-2,i=>E(i)*E(n-1-i,ask,bid,v+1))+ifs+handles;
  return E(n-1)+E(n-2)+unary*R(n-1)+sum(1,n-2,i=>R(i)*E(n-1-i)+E(i)*R(n-1-i))
    +sum(1,n-2,i=>R(i)*E(n-1-i,ask,bid,v+1)+E(i)*R(n-1-i,ask,bid,v+1))+ifs+handles;
}

test('exact counts per size, derived by hand and by recurrence', () => {
  // Hand derivation. main's body is an E with no handler and no binder in scope.
  //   size 1: 0                                                                       = 1
  //   size 2: tick(0)                                                                 = 1
  //   size 3: tick(tick(0)) 1; div(0,0) 1; let v = 0 in {0, v} 2;
  //           handle(X, x => {0, x}, 0) for X in Ask, Bid: 2 x 2 = 4                  = 8
  //   size 4: tick(size 3) 8; div(0, tick(0)), div(tick(0), 0) 2;
  //           let v = 0 in {tick(0), tick(v)} 2, let v = tick(0) in {0, v} 2;
  //           if({true, false}, 0, 0) 2;
  //           handle with a 1-node clause {0, x} and a 2-node body, which under Ask is
  //             tick(0), deep(0) or perform(Ask, 0) and under Bid tick(0) or perform(Bid, 0):
  //             2 x 3 + 2 x 2 = 10;
  //           handle with a 2-node clause and body 0: the clause is tick(0), tick(x),
  //             (x, k) => resume(k, 0) or (x, k) => resume(k, x): 4 x 2 effects = 8    = 34
  //   size 5: tick(size 4) 34;
  //           div with operand sizes (1,3) 8, (2,2) 1, (3,1) 8 = 17;
  //           let: with one binder v in scope there are 2 one-node, 2 two-node and 24
  //             three-node expressions (tick(tick(.)) 2, div 4, let w = . in {0, v, w} 6,
  //             handle(X, x => {0, v, x}, {0, v}) 12), so sizes (1,3) 24, (2,2) 2, (3,1) 16 = 42;
  //           if({true, false}, ., .) with branch sizes (1,2), (2,1): 4 (lt(0,0) leaves no room);
  //           handle: clauses with binder x number 2 of one node, 4 of two nodes, and 30 of
  //             three: 24 tail-resumptive (as counted for let) and 6 explicit
  //             (resume(k, tick(.)) 2, let u = discontinue(k) in {0, x} 2, tick(resume(k, .)) 2).
  //             Bodies under Ask number 1, 3, and 16 of three nodes (unary of unary 9,
  //             div(0,0) 1, let 2, handle(Y, y => {0, y}, 0) 4); under Bid 1, 2 and 11 (4+1+2+4).
  //             Ask: 2 x 16 + 4 x 3 + 30 x 1 = 74; Bid: 2 x 11 + 4 x 2 + 30 x 1 = 60; 134
  //           34 + 17 + 42 + 4 + 134                                                  = 231
  const byHand={1:'1',2:'1',3:'8',4:'34',5:'231'};
  assert.deepEqual(enumerateHandlers(5).counts_by_nodes,byHand);
  assert.equal(enumerateHandlers(5).count,'275');
  // Sizes 6 and 7 are too long to derive by hand; the recurrence, checked against the
  // hand derivation above, gives them without building any program.
  for(const [n,expected] of Object.entries(byHand))assert.equal(String(count('E',Number(n),false,false,0)),expected);
  const all=enumerateHandlers(7);
  assert.deepEqual(all.counts_by_nodes,{...byHand,6:'1478',7:'10940'});
  for(const n of [6,7])assert.equal(String(count('E',n,false,false,0)),all.counts_by_nodes[n]);
  assert.equal(all.count,'12693');
  assert.equal(all.truncated,false);
});

test('the enumeration is deterministic, duplicate-free and fails closed', () => {
  const e=enumerateHandlers(6);
  assert.deepEqual(enumerateHandlers(6),e);
  assert.equal(new Set(e.cases.map(c=>JSON.stringify(c.template))).size,e.cases.length);
  assert.equal(new Set(e.cases.map(c=>c.name)).size,e.cases.length);
  assert.throws(()=>enumerateHandlers(6,{maxCases:1000}),RangeError);
  assert.throws(()=>enumerateHandlers(8),TypeError);
  assert.throws(()=>enumerateHandlers(0),TypeError);
});

test('every program is valid at its enumerated size, declares what it uses, and completes', () => {
  for(const c of enumerateHandlers(6).cases) {
    const checked=validatePureCallArtifact(encode(c.program),['int','0']),text=JSON.stringify(c.template);
    const explicit=text.includes('"explicit"');
    assert.equal(c.program.schema_version,explicit?TC1_RESUMPTION_SCHEMA:TC1_HANDLER_SCHEMA,c.name);
    assert.deepEqual(c.program.functions.map(f=>f.name),['main',...['tick','deep'].filter(f=>text.includes(`"${f}"`))],c.name);
    assert.deepEqual(c.program.effects.map(d=>d.name),['Ask','Bid'].filter(X=>text.includes(`"${X}"`)||(X==='Ask'&&text.includes('"deep"'))),c.name);
    assert.deepEqual(c.program.functions[0].effects,['Emit'],c.name);
    const r=run(checked.artifact);
    assert.equal(r.execution,'Completed',c.name);
    assert.ok(r.outcome[0]==='Ok'?r.outcome[1][0]==='int':r.outcome[1]==='DivZero',c.name);
  }
});

// Landmarks: programs the scope must contain, with the behaviour EFFECTS.md gives them,
// written by hand. Binders are named by depth, so x is '$v0' both in a top-level clause and
// in the clause of a handler in its body (the outer clause's binder is not in scope there).
const zero=['int','0'],x=['var','$v0'];
const tick=e=>['call','tick',e],ask=e=>['perform','Ask','ask',e];
const landmarks=[
  // The clause's value is the perform's result; clause effects precede the resumed body's.
  {what:'tail-resumptive clause',body:['handle','Ask',['tail','$v0',tick(x)],tick(ask(zero))],outcome:['Ok',['int','2']],emitted:['0','1'],performs:1},
  // A resume in tail position behaves as the tail-resumptive clause does.
  {what:'resume in tail position',body:['handle','Ask',['explicit','$v0',['resume',tick(x)]],tick(ask(zero))],outcome:['Ok',['int','2']],emitted:['0','1'],performs:1},
  // resume(k, v) yields what the handled body finally produces: the body ticks 0 to 1, the clause ticks 1 to 2.
  {what:'resume not in tail position',body:['handle','Ask',['explicit','$v0',tick(['resume',x])],tick(ask(zero))],outcome:['Ok',['int','2']],emitted:['0','1'],performs:1},
  // discontinue abandons the body: its tick never runs, and the clause's value is the handle's.
  {what:'discontinue',body:['handle','Ask',['explicit','$v0',['drop',x]],tick(ask(zero))],outcome:['Ok',['int','0']],emitted:[],performs:1},
  // In a clause the selected handler is inactive: the same effect forwards outward.
  {what:'forwarding from a clause',body:['handle','Ask',['tail','$v0',x],['handle','Ask',['tail','$v0',ask(x)],ask(zero)]],outcome:['Ok',['int','0']],emitted:[],performs:2},
  // The innermost handler of the same effect answers.
  {what:'nested handlers, same effect',body:['handle','Ask',['tail','$v0',tick(x)],['handle','Ask',['tail','$v0',x],ask(zero)]],outcome:['Ok',['int','0']],emitted:[],performs:1},
  // A handler of another effect between the perform and its handler is passed over.
  {what:'nested handlers, different effects',body:['handle','Ask',['tail','$v0',tick(x)],['handle','Bid',['tail','$v0',x],ask(zero)]],outcome:['Ok',['int','1']],emitted:['0'],performs:1},
  // The left operand's tick has happened when the right operand performs, and is not repeated on resume.
  {what:'perform in an operand',body:['handle','Ask',['tail','$v0',x],['prim','div',tick(zero),ask(zero)]],outcome:['Trap','DivZero'],emitted:['0'],performs:1},
  {what:'perform in a let',body:['handle','Ask',['tail','$v0',tick(x)],['let','$v0',ask(zero),x]],outcome:['Ok',['int','1']],emitted:['0'],performs:1},
  {what:'perform in a branch',body:['handle','Ask',['tail','$v0',x],['if',['bool',false],zero,ask(zero)]],outcome:['Ok',['int','0']],emitted:[],performs:1},
  {what:'trap in the body',body:['handle','Ask',['tail','$v0',x],['prim','div',zero,zero]],outcome:['Trap','DivZero'],emitted:[],performs:0},
  {what:'trap in a clause',body:['handle','Ask',['tail','$v0',['prim','div',x,x]],tick(ask(zero))],outcome:['Trap','DivZero'],emitted:[],performs:1},
  // The resumed body has returned through the resume (a ResumeReturn step) when the clause traps.
  {what:'trap after a resume',body:['handle','Ask',['explicit','$v0',['prim','div',['resume',x],zero]],ask(zero)],outcome:['Trap','DivZero'],emitted:[],performs:1,rule:'ResumeReturn'},
  // deep(1) handles Ask around deep(0), which performs: the answer is deep(1)'s own q, 1, not
  // the q of the perform site (0) and not the outer handler's (which would tick).
  {what:'a clause runs in its handler\'s bindings',body:['handle','Ask',['tail','$v0',tick(x)],['call','deep',tick(zero)]],outcome:['Ok',['int','1']],emitted:['0'],performs:1}
];

test('the scope holds the landmark programs, and they behave as the contract says', () => {
  const cases=new Map(enumerateHandlers(7).cases.map(c=>[JSON.stringify(c.template),c]));
  for(const mark of landmarks) {
    const c=cases.get(JSON.stringify(mark.body));
    assert.ok(c,mark.what+' is not in the scope');
    const r=run(c.program),performNodes=new Set(JSON.stringify(c.program.functions).match(/\["perform","\d+"/g)?.map(m=>m.match(/\d+/)[0]));
    assert.deepEqual(r.outcome,mark.outcome,mark.what);
    assert.deepEqual(emitted(r),mark.emitted,mark.what);
    // A perform is the Ready step at a perform node; user effects produce no events.
    assert.equal(r.steps.filter(s=>s.site.rule==='Ready'&&performNodes.has(s.site.node)).length,mark.performs,mark.what);
    if(mark.rule)assert.ok(r.steps.some(s=>s.site.rule===mark.rule),mark.what);
  }
});

test('each injected defect changes a completed trace somewhere in the scope', () => {
  const cases=enumerateHandlers(7).cases,changed=Object.fromEntries(Object.keys(MUTANTS).map(k=>[k,null]));
  for(const c of cases) {
    const pending=Object.entries(MUTANTS).filter(([key])=>!changed[key]);
    if(!pending.length)break;
    const reference=JSON.stringify(run(c.program).steps);
    for(const [key,option] of pending) {
      let r;try{r=run(c.program,{[option]:true});}catch{continue;}   // a crash is not a kill
      if(r.execution==='Completed'&&JSON.stringify(r.steps)!==reference)changed[key]=c.nodes;
    }
  }
  // The size of the smallest program on which each defect shows.
  assert.deepEqual(changed,{forgotten_resume:'4',double_resume:'4',outermost_handler:'5',dynamic_clause_environment:'5',resume_returns_argument:'7',shallow_resume:'5'});
});

test('the batch runner writes the whole family in chunks and refuses a bad bound', () => {
  const parent=resolve('build/tc1');mkdirSync(parent,{recursive:true});const dir=mkdtempSync(resolve(parent,'handler-exhaustive-'));
  try {
    const go=(...args)=>spawnSync(process.execPath,['tools/tc1/run-handler-exhaustive.mjs',...args],{encoding:'utf8',timeout:60000});
    assert.equal(go('5',dir).status,0);
    const header=JSON.parse(readFileSync(resolve(dir,'family.json'),'utf8'));
    assert.deepEqual([header.count,header.max_nodes,header.truncated,header.chunks],['275','5',false,'1']);
    assert.deepEqual(readdirSync(dir).sort(),['chunk-0.jsonl','family.json']);
    const rows=readFileSync(resolve(dir,'chunk-0.jsonl'),'utf8').trim().split('\n').map(l=>JSON.parse(l));
    assert.equal(rows.length,275);
    for(const row of rows) {
      assert.equal(row.candidate.execution,'Completed',row.name);
      assert.deepEqual(Object.keys(row.mutants),Object.keys(MUTANTS),row.name);
    }
    // Existing output is never overwritten, and bounds outside 1..7 are refused.
    assert.notEqual(go('5',dir).status,0);
    for(const bound of ['0','8','x'])assert.notEqual(go(bound,dir).status,0);
  } finally {rmSync(dir,{recursive:true,force:true});}
});
