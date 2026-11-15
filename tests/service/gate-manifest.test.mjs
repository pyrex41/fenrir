// Structure of the proposed service gate manifest (spec/service/service-requirements.json)
// and its evaluator. Consistency checks on the manifest, NOT gate evidence: only the
// evaluator (harness/service-gate.shen) issues verdicts, and it is unregistered.
import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,readdirSync,readFileSync} from 'node:fs';
const json=path=>JSON.parse(readFileSync(path,'utf8'));
const manifest=json('spec/service/service-requirements.json'),evaluator=readFileSync('harness/service-gate.shen','utf8');
const shenList=name=>[...evaluator.match(new RegExp(`\\(define ${name.replace('.','\\.')}\\s+->\\s+\\[([^\\]]*)\\]\\)`))[1].matchAll(/"([^"]+)"/g)].map(m=>m[1]);
const shenString=name=>evaluator.match(new RegExp(`\\(define ${name.replace('.','\\.')} -> "([^"]*)"\\)`))[1];

test('the service manifest is proposed, reports no authority, and every row is required and names a ledger row', () => {
  assert.equal(manifest.schema,'service-requirement-manifest/1');
  assert.equal(manifest.status,'proposed');
  assert.equal(manifest.evaluator,'harness/service-gate.shen');
  assert.ok(existsSync(manifest.evaluator)&&existsSync('harness/run-service-gate.sh'));
  const ledger=json(manifest.ledger).rows.map(r=>r.id);
  assert.deepEqual(manifest.rows.map(r=>r.id),['source-identity','toolchain-pinned','service-unit-tests','a1-exploration','a1-model-vs-js-differential',
    'a2-refinement','a2-js-agreement','a2-solo5-agreement','a2-handler-mutants','retained-counterexamples-replay']);
  for(const r of manifest.rows) {
    assert.equal(r.required,true,r.id);
    assert.ok(r.ledger.length&&r.ledger.every(id=>ledger.includes(id)),r.id+' names ledger rows that exist');
    assert.ok(evaluator.includes(`"${r.check}" Memo ->`),`the evaluator knows check ${r.check}`);
  }
  assert.ok(/review/.test(Object.keys(manifest).join())&&/PROPOSED/.test(manifest.review)&&/UNREGISTERED/.test(manifest.review));
  // Same aggregation rule as the TC1 gate.
  const tc1=json('spec/tc1/tc1-requirements.json').aggregation;
  const rule='any required row FAIL -> FAIL; else any BLOCKED -> BLOCKED; else any UNKNOWN -> UNKNOWN; else PASS.';
  assert.ok(manifest.aggregation.includes(rule)&&tc1.includes(rule));
  // The TC1 gate has no service row, and this gate is not registered in the workflow.
  assert.ok(!json('spec/tc1/tc1-requirements.json').rows.some(r=>/service/.test(r.id)||/service/.test(r.check)));
  assert.ok(!JSON.stringify(json('.pi/fenrir-workflow.json')).includes('service-gate'));
  for(const [claim,ids] of Object.entries(manifest.claims))
    for(const id of ids)assert.ok(manifest.rows.some(r=>r.id===id),`${claim} names row ${id}`);
  assert.deepEqual(manifest.claim_prerequisites,['source-identity']);
});

test('the ledger row the service rows cite states its gaps, and cites only files that exist', () => {
  const row=json(manifest.ledger).rows.find(r=>r.id==='SERVICE-ACCEPTED-JOB');
  assert.equal(row.status,'DEVELOPMENT-EVIDENCE');
  for(const p of row.evidence)assert.ok(existsSync(p),p);
  for(const p of ['spec/service/ACCEPTED_JOB.md','spec/service/HANDLER.md','harness/service-explore.shen','harness/service-fenrir.shen'])assert.ok(row.evidence.includes(p),p);
  assert.ok(row.gaps.some(g=>/by reading/.test(g)&&/Rocq/.test(g)),'the model correspondence is stated as reading only');
  assert.ok(row.gaps.some(g=>/bounded exploration/.test(g)));
  assert.ok(/not part of slice TC1/.test(manifest.contract)&&/proof/.test(manifest.not_covered));
});

test('the evaluator pins the scope, the machines and the retained counterexamples the manifest and the repository state', () => {
  const scope=shenList('sg.scope');
  assert.deepEqual(scope,['2','2','2','3','2','2','1','2000000']);
  for(const script of ['harness/run-service-explore.sh','harness/run-service-fenrir.sh'])
    assert.ok(readFileSync(script,'utf8').includes(scope.join(' ')),`${script} has the pinned default scope`);
  assert.ok(manifest.scope.includes('2,000,000'));
  // Mutants: the lists the harness programs hold, and the files under examples/service/mutants.
  const names=text=>[...text.matchAll(/"([a-z-]+)"/g)].map(m=>m[1]);
  const a1=names(readFileSync('harness/service-mutants.shen','utf8').match(/\(define smu\.mutant-names\s+->\s+\[([^\]]*)\]/)[1]);
  assert.deepEqual(shenList('sg.a1-machines'),a1);
  const a2=names(readFileSync('harness/service-fenrir.shen','utf8').match(/\(define sfx\.handler-mutants\s+->\s+\[([^\]]*)\]/)[1]);
  assert.deepEqual(shenList('sg.a2-machines'),a2);
  const files=readdirSync('examples/service/mutants').map(f=>f.replace(/\.fen$/,'')).sort();
  assert.deepEqual([...shenList('sg.a2-machines'),...shenList('sg.a2-static')].sort(),files);
  // Retained counterexamples: all of them are replayed, and none was removed.
  assert.equal(readdirSync('spec/service/counterexamples').filter(f=>f.endsWith('.json')).length,Number(shenString('sg.a1-retained')));
  assert.equal(readdirSync('spec/service/counterexamples-a2').filter(f=>f.endsWith('.json')).length,Number(shenString('sg.a2-retained')));
  const row=id=>manifest.rows.find(r=>r.id===id).acceptance;
  assert.ok(row('retained-counterexamples-replay').includes('22')&&row('retained-counterexamples-replay').includes('13'));
  assert.ok(row('a1-exploration').includes(Number(shenString('sg.model-states')).toLocaleString('en-US')));
  assert.ok(row('a1-model-vs-js-differential').includes(Number(shenString('sg.runtime-edges')).toLocaleString('en-US')));
  assert.ok(row('a1-exploration').includes(`${a1.length-1} mutants`));
  assert.ok(row('a2-handler-mutants').includes(`${a2.length-1} handler mutants`));
});

test('a truncated, absent or disagreeing exploration cannot be a pass in the evaluator', () => {
  const slice=name=>{const at=evaluator.indexOf(`(define ${name}\n`);return evaluator.slice(at,evaluator.indexOf('\n(define ',at+1));};
  for(const name of ['sg.a1-explore','sg.a1-differential','sg.a2-refinement','sg.a2-js','sg.a2-solo5','sg.a2-mutants','sg.retained-replay'])assert.ok(slice(name).length>200,name);
  for(const name of ['sg.a1-explore','sg.a2-refinement','sg.a2-mutants'])assert.ok(/truncated or incomplete/.test(slice(name))&&/"UNKNOWN"/.test(slice(name)),name);
  assert.ok(/did not report/.test(slice('sg.a1-explore'))&&/did not report/.test(slice('sg.a2-refinement')));
  const untruncated=slice('sg.untruncated?');
  assert.ok(/\(= \(fh\.member "complete" E\) true\)/.test(untruncated)&&/\(= \(fh\.member "truncated" E\) false\)/.test(untruncated),'truncated must be stated false, absence is not a pass');
  assert.ok(/"equivalent-control"/.test(slice('sg.machine-ok?'))&&/empty\? \(fh\.member "caught_by" M\)/.test(slice('sg.machine-ok?')));
  assert.ok(/"BLOCKED"/.test(slice('sg.a2-solo5'))&&/exceeded its time limit/.test(slice('sg.a2-solo5')));
  assert.ok(/rejected_statically/.test(slice('sg.a2-mutants')));
  assert.ok(/reproduced/.test(slice('sg.replay-all'))&&/no replay report/.test(slice('sg.retained-replay')));
  assert.ok(/fh\.registered-as "service-qualification"/.test(evaluator));
});
