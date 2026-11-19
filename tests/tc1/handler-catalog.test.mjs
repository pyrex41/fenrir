// The versioned handler transition catalog (spec/tc1/handler-catalog.json) and the
// handler-aware reducer (tools/tc1/handler-reduce.mjs) with the retained failures.
// Consistency checks only, NOT gate evidence. The PR10 coverage row is unchanged;
// this catalog is bound to the separate development tapes.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {MUTANTS} from '../../tools/tc1/handler-defects.mjs';
import {handlerReductions,normalizeHandlerProgram} from '../../tools/tc1/handler-reduce.mjs';
import {cases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
const json=path=>JSON.parse(readFileSync(path,'utf8'));
const sha=b=>createHash('sha256').update(b).digest('hex');
const catalog=json('spec/tc1/handler-catalog.json');

test('the catalog is versioned, its transitions hashed, and its TC0-A source pinned', () => {
  assert.equal(catalog.version,'tc1-handler-catalog/1');
  assert.equal(catalog.transitions_sha256,sha(encode(catalog.transitions)));
  assert.equal(catalog.derived_from.tc0_a_catalog.sha256,sha(readFileSync(catalog.derived_from.tc0_a_catalog.path)));
  assert.equal(catalog.derived_from.tc0_a_catalog.version,json(catalog.derived_from.tc0_a_catalog.path).version);
  assert.match(readFileSync('harness/tc1-strict-replay.shen','utf8'),
    new RegExp(`\\(define fh\\.s-catalog-pin -> "${sha(readFileSync('spec/tc1/handler-catalog.json'))}"\\)`));
  const keys=catalog.transitions.map(t=>t.key),ids=catalog.transitions.map(t=>t.id);
  assert.equal(new Set(keys).size,keys.length);assert.equal(new Set(ids).size,ids.length);
  for(const t of catalog.transitions) {
    assert.deepEqual(Object.keys(t).sort(),['depth','frames','id','key','site','source'],t.id);
    assert.ok(['+1','0','-1','<=0','>=0','>=+1','>=+2'].includes(t.depth),t.id);
  }
  // Check representative kinds from the separate PR10 coverage table.
  for(const kind of ['Dispatch handle -> Eval','Dispatch perform -> Eval','Dispatch resume -> Eval','Ready perform, clause op(x) -> Eval',
    'Ready perform, clause op(x,k) -> Eval','ClauseReturn -> Value','ClauseExitReturn -> Value','Ready resume, not in tail position -> Value',
    'Ready resume, in tail position -> Value','ResumeReturn -> Value','Ready discontinue -> Abandon','DiscontinueReturn -> Value',
    'HandleReturn -> Value','UnwindFrame at a clause frame -> Unwind'])assert.ok(keys.includes(kind),kind);
  assert.ok(keys.filter(k=>k.startsWith('AbandonFrame ')).length>1);
});

const ask={name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]};
const artifact=(body,explicit=false)=>{
  const ids=new Set(['0']);JSON.stringify(body,(k,v)=>{if(Array.isArray(v)&&['handle','perform','resume','var','int','prim'].includes(v[0])&&typeof v[1]==='string'&&/^\d+$/.test(v[1]))ids.add(v[1]);return v;});
  return {contract_version:'tc1-draft-1',schema_version:explicit?'tc1-handler-demo/2':'tc1-handler-demo/1',slice:explicit?'TC1-H2':'TC1-H1',module:'t',datatypes:[],effects:[ask],
    functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:'I64',effects:['Emit'],body}],entry:'main',input_schema:{type:'I64'},
    source_map:[...ids].map(id=>({id,file:'t',line:'0',column:'0'}))};
};

test('handler-aware rules: handle-to-body only once the body no longer performs; resume-to-argument makes the clause tail-resumptive', () => {
  // handle(Ask, ask(x) => x, add(perform(Ask, ask, 3), 0))
  const p=artifact(['handle','2','Ask',[['ask','3',['var','4','3']]],['prim','5','add',['perform','6','Ask','ask',['int','7','3']],['int','8','0']]]);
  validatePureCallArtifact(encode(p),['int','0']);
  const rules=handlerReductions(p).proposals.map(x=>x.rule);
  assert.ok(!rules.includes('handle-to-body'),'the body still performs Ask');
  assert.ok(rules.includes('perform-to-argument'));
  const after=handlerReductions(p).proposals.find(x=>x.rule==='perform-to-argument').program;
  assert.ok(handlerReductions(after).proposals.some(x=>x.rule==='handle-to-body'),'once the perform is gone, the handler can go');
  // handle(Ask, ask(x, k) => resume(k, x), perform(Ask, ask, 3))
  const q=artifact(['handle','2','Ask',[['ask','3','4',['resume','5','4',['var','6','3']]]],['perform','7','Ask','ask',['int','8','3']]],true);
  const tail=handlerReductions(q).proposals.find(x=>x.rule==='resume-to-argument').program;
  assert.deepEqual(tail.functions[0].body[3],[['ask','3',['var','6','3']]]);
  assert.equal(tail.schema_version,'tc1-handler-demo/1');
});

test('every proposal is valid, smaller, normalized and ordered, on every hand fixture', () => {
  for(const c of [...cases,...resumptionCases]) {
    const {metric,proposals}=handlerReductions(c.program);
    let last=0;
    for(const x of proposals) {
      const checked=validatePureCallArtifact(encode(x.program),['int','0']);
      assert.equal(Number(checked.node_count),x.metric.nodes);
      assert.ok(x.metric.nodes<metric.nodes&&x.metric.nodes>=last,c.name+' '+x.rule);last=x.metric.nodes;
      assert.equal(encode(normalizeHandlerProgram(JSON.parse(JSON.stringify(x.program)))).toString(),encode(x.program).toString());
    }
  }
});

test('the retained failures are valid, minimized below their originals, and still show their defect at the retained epoch', () => {
  const retained=json('fixtures/tc1/handler-retained-failures.json');
  assert.equal(retained.cases.length,8);
  for(const c of retained.cases) {
    const checked=validatePureCallArtifact(encode(c.program),['int','0']);
    assert.equal(checked.node_count,c.nodes,c.name);
    // The defect-free implementation as a scripted reference: the defective run's first
    // differing step is the retained epoch. The Shen harness checks this against the model.
    const fixed=new HandlerMachine(checked.artifact,checked.input).run(1000).steps;
    const broken=new HandlerMachine(checked.artifact,checked.input,{[MUTANTS[c.defect]]:true}).run(1000).steps;
    assert.equal(String(broken.findIndex((s,i)=>encode(s).toString()!==encode(fixed[i]??null).toString())),c.divergence_epoch,c.name);
  }
  for(const d of new Set(retained.cases.map(c=>c.defect))) {
    const [o,m]=['original','minimized'].map(role=>retained.cases.find(c=>c.defect===d&&c.role===role));
    assert.ok(Number(m.nodes)<Number(o.nodes),d);assert.equal(m.discrepancy,o.discrepancy,d);
  }
});
