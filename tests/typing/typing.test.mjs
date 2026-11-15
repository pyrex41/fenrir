// Tests of the typing work (spec/tc1/TYPING.md): the transport tables in typing/, and
// the Shen side run on small cases. The full differential is sh typing/run.sh.
//   node --test tests/typing/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync,existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {resolve,join} from 'node:path';
import {encode} from '../../tools/tc0/canonical.mjs';
import {CLASSES,jsVerdict} from '../../typing/families.mjs';
import {mutants,seeds} from '../../typing/mutate.mjs';
import {probes} from '../../typing/probes.mjs';
import {cases as callHand} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlerCases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {cases as durableHand} from '../../fixtures/tc1/durable-hand-cases.mjs';
import {cases as taskHand} from '../../fixtures/tc1/task-hand-cases.mjs';

const root=resolve(import.meta.dirname,'../..');
const bytes=c=>c.text!==undefined?Buffer.from(c.text,'utf8'):encode(c.program);

test('every message the validator can give is mapped to a check or rule of TYPING.md', () => {
  const source=readFileSync(resolve(root,'tools/tc0/pure-call-artifact.mjs'),'utf8');
  const messages=new Set([...source.matchAll(/fail\('([^']+)'\)|PureCallValidationLimit\('([^']+)'\)/g)].map(m=>m[1]??m[2]));
  assert.ok(messages.size>50);
  for(const m of messages)assert.ok(CLASSES[m],`unmapped validator message: ${m}`);
});

test('the boundary probes: the validator agrees with the contract text on every probe', () => {
  const departs=probes().filter(p=>jsVerdict(bytes(p),p.input).status!==p.contract).map(p=>p.name);
  assert.deepEqual(departs,[]);
});

test('mutants are single changes of valid seeds, deterministic', () => {
  const a=mutants(),b=mutants();
  assert.ok(a.length>5000);
  assert.deepEqual(a.map(m=>encode(m.program).toString()),b.map(m=>encode(m.program).toString()));
  const byName=new Map(seeds().map(s=>[s.name,s.program]));
  for(const m of a.slice(0,500)) {
    const seed=byName.get(m.name.split(' ')[0]);
    assert.ok(seed,m.name);
    assert.notEqual(encode({...m.program,module:''}).toString(),encode({...seed,module:''}).toString(),m.name);
  }
});

// ---------- the Shen side ----------
function shenJit() {
  if(process.env.FENRIR_SHEN_JIT)return process.env.FENRIR_SHEN_JIT;
  const r=spawnSync('sh',['-c','. "$0"/../jit.sh; printf %s "$jit"',resolve(root,'harness/x')],{encoding:'utf8'});
  return r.stdout;
}
const jit=shenJit(),haveShen=existsSync(join(jit,'bin/shen-jit'));
function runCases(cases) {
  const dir=mkdtempSync(join(tmpdir(),'fenrir-typing-')),file=join(dir,'cases.jsonl');
  writeFileSync(file,cases.map(c=>JSON.stringify(c)).join('\n')+'\n');
  const r=spawnSync(join(jit,'bin/shen-jit'),['script',resolve(root,'tests/typing/cases.shen'),join(jit,'lib'),root,file],{encoding:'utf8',input:''});
  const last=r.stdout.trim().split('\n').at(-1);
  return JSON.parse(last.slice(last.indexOf('{')));
}
// main : I64 -> I64 with body add(x, 1), and a derivation written by hand.
const program={contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/1',slice:'TC0-A',module:'hand',datatypes:[],effects:[],
  functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:'I64',effects:[],body:['prim','2','add',['var','3','1'],['int','4','1']]}],
  entry:'main',input_schema:{type:'I64'},source_map:['0','2','3','4'].map(id=>({id,file:'hand',line:'0',column:'0'}))};
const canonical=x=>JSON.parse(encode(x).toString());
function derivation(p,body) {
  const G=[['1','I64']];
  return ['Program',['well-typed',canonical(p),['int','0']],[
    ['Function',['function',canonical(p.functions[0])],[body(G)]],
    ['P-Base',['plain',[],'I64'],[]],['P-Base',['plain',[],'I64'],[]]]];
}
const sound=G=>['T-Prim',['expr',G,['prim','2','add',['var','3','1'],['int','4','1']],'I64',[],[]],[
  ['T-Var',['expr',G,['var','3','1'],'I64',[],[]],[]],['T-Int',['expr',G,['int','4','1'],'I64',[],[]],[]]]];
const textOf=p=>encode(p).toString();

test('the fixed checker accepts a derivation written by hand, and rejects forgeries of it', {skip:!haveShen&&'Shen/JIT not found'}, () => {
  const ill={...canonical(program),functions:[{...canonical(program).functions[0],body:['bool','2',true]}],source_map:['0','2'].map(id=>({column:'0',file:'hand',id,line:'0'}))};
  const other={...canonical(program),module:'other'};
  const cases=[
    {name:'hand-written',text:textOf(program),derivation:derivation(program,sound),expect:'accept'},
    {name:'wrong rule name',text:textOf(program),derivation:derivation(program,G=>['T-Add',...sound(G).slice(1)]),expect:'reject'},
    {name:'literal claims Bool',text:textOf(program),derivation:derivation(program,G=>{const d=sound(G);d[2][1]=['T-Int',['expr',G,['int','4','1'],'Bool',[],[]],[]];return d;}),expect:'reject'},
    {name:'premises swapped',text:textOf(program),derivation:derivation(program,G=>{const d=sound(G);d[2].reverse();return d;}),expect:'reject'},
    {name:'premise missing',text:textOf(program),derivation:derivation(program,G=>{const d=sound(G);d[2].pop();return d;}),expect:'reject'},
    {name:'effect invented',text:textOf(program),derivation:derivation(program,G=>{const d=sound(G);d[1][4]=['Emit'];return d;}),expect:'reject'},
    {name:'derivation of another program',text:textOf(other),derivation:derivation(program,sound),expect:'reject'},
    {name:'ill-typed body, T-Bool claimed at I64',text:textOf(ill),
      derivation:derivation(ill,G=>['T-Bool',['expr',G,['bool','2',true],'I64',[],[]],[]]),expect:'reject'},
    {name:'ill-typed body, T-Int claimed for a bool',text:textOf(ill),
      derivation:derivation(ill,G=>['T-Int',['expr',G,['bool','2',true],'I64',[],[]],[]]),expect:'reject'},
    {name:'not a derivation',text:textOf(program),derivation:'proof',expect:'reject'}];
  const r=runCases(cases);
  assert.deepEqual(r.failures,[]);
  assert.equal(r.cases,String(cases.length));
});

test('search finds a derivation for every hand fixture, and it survives a JSON round trip', {skip:!haveShen&&'Shen/JIT not found'}, () => {
  const all=[...callHand,...dataHand,...handlerCases,...resumptionCases,...durableHand,...taskHand];
  const r=runCases(all.map(c=>({name:c.name,text:textOf(c.program),expect:'accept',...c.input?{input:c.input}:{}})));
  assert.deepEqual(r.failures,[]);
  assert.equal(r.cases,String(all.length));
});

test('both validators accept an effectful datatype field (the validator defect of TYPING.md §11, fixed)', {skip:!haveShen&&'Shen/JIT not found'}, () => {
  const r=spawnSync('sh',[resolve(root,'frontend/fenrir.sh'),'check',resolve(root,'tests/typing/datatype-field-effect.fen')],
    {encoding:'utf8',env:{...process.env,FENRIR_SHEN_JIT:jit}});
  assert.equal(r.status,0,r.stdout+r.stderr);
  assert.match(r.stdout,/^ok: /);
});

test('durable and task rules: forged derivations of new rules are rejected', {skip:!haveShen&&'Shen/JIT not found'}, () => {
  // main : I64 -> I64 ! [Task] with body scope(1)
  const p={...program,schema_version:'tc1-task-demo/1',slice:'TC1-C1',contract_version:'tc1-draft-1',module:'task',
    functions:[{...program.functions[0],effects:['Task'],body:['scope','2',['int','3','1']]}],source_map:['0','2','3'].map(id=>({id,file:'hand',line:'0',column:'0'}))};
  const G=[['1','I64']];
  const scope=(F,plain=true)=>['T-Scope',['expr',G,['scope','2',['int','3','1']],'I64',F,[]],
    [['T-Int',['expr',G,['int','3','1'],'I64',[],[]],[]],...plain?[['P-Base',['plain',[],'I64'],[]]]:[]]];
  const r=runCases([
    {name:'scope by hand',text:textOf(p),derivation:derivation(p,()=>scope(['Task'])),expect:'accept'},
    {name:'scope without its Task effect',text:textOf(p),derivation:derivation(p,()=>scope([])),expect:'reject'},
    {name:'scope without its serializability premise',text:textOf(p),derivation:derivation(p,()=>scope(['Task'],false)),expect:'reject'},
    {name:'T-Scope under schema tc1-handler-demo/2',text:textOf({...p,schema_version:'tc1-handler-demo/2',slice:'TC1-H2'}),
      derivation:derivation({...p,schema_version:'tc1-handler-demo/2',slice:'TC1-H2'},()=>scope(['Task'])),expect:'reject'}]);
  assert.deepEqual(r.failures,[]);
});
