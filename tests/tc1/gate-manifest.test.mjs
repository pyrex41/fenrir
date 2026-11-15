// Structure of the proposed TC1 gate manifest, and what moved out of the TC0-A one.
// These are consistency checks on the manifests, NOT gate evidence: only the
// evaluators (harness/tc1-gate.shen, harness/gate.shen) issue verdicts.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {MUTANTS} from '../../tools/tc1/handler-defects.mjs';
import {enumerateHandlers} from '../../tools/tc1/handler-enumerate.mjs';
const json=path=>JSON.parse(readFileSync(path,'utf8'));
const manifest=json('spec/tc1/tc1-requirements.json'),evaluator=readFileSync('harness/tc1-gate.shen','utf8');

test('the TC1 manifest is proposed, closed over its rows, and cites known ledger rows', () => {
  assert.equal(manifest.schema,'tc1-requirement-manifest/1');
  // Proposed: acceptance and registration are the owner's decision, recorded elsewhere.
  assert.equal(manifest.status,'proposed');
  assert.equal(manifest.evaluator,'harness/tc1-gate.shen');
  const ids=manifest.rows.map(r=>r.id);
  assert.equal(new Set(ids).size,ids.length);
  const ledger=new Set(json(manifest.ledger).rows.map(r=>r.id));
  for(const row of manifest.rows) {
    assert.deepEqual(Object.keys(row).sort(),['acceptance','check','id','ledger','required'],row.id);
    assert.ok(row.ledger.length&&row.ledger.every(id=>ledger.has(id)),row.id);
    // Every check the manifest names is one the evaluator dispatches on.
    assert.ok(evaluator.includes(`  "${row.check}" Memo -> `),row.id);
  }
  for(const [claim,rows] of Object.entries(manifest.claims))for(const id of [...rows,...manifest.claim_prerequisites])assert.ok(ids.includes(id),claim+' names '+id);
});

test('the required rows are the ones the gate was specified with', () => {
  const required=manifest.rows.filter(r=>r.required).map(r=>r.check);
  assert.deepEqual(required,['source-identity','toolchain-pinned','unit-suite','tc0-a-gate','tc1-handlers','tc1-exhaustive',
    ...Object.keys(MUTANTS).map(key=>'tc1-defect:'+key),'tc1-guest-hand','tc1-guest-exhaustive',
    'tc1-random','tc1-guest-random','tc1-random-control','tc1-reduction','tc1-reduced-replay']);
  // An optional row is never among a claim's rows or the prerequisites.
  const optional=manifest.rows.filter(r=>!r.required).map(r=>r.id);
  for(const rows of [...Object.values(manifest.claims),manifest.claim_prerequisites])assert.ok(!rows.some(id=>optional.includes(id)));
});

test('the evaluator, the manifest and the enumerator state the same scope', () => {
  const bound=evaluator.match(/\(define fh\.tc1-bound -> "(\d+)"\)/)[1],programs=evaluator.match(/\(define fh\.tc1-programs -> "(\d+)"\)/)[1];
  assert.equal(enumerateHandlers(Number(bound)).count,programs);
  const grouped=Number(programs).toLocaleString('en-US');
  for(const id of ['exhaustive-small','guest-exhaustive-small']) {
    const text=manifest.rows.find(r=>r.id===id).acceptance;
    assert.ok(text.includes(`at most ${bound} nodes`)&&text.includes(grouped),id);
  }
});

test('the generated-family rows, the manifest and the harness state the same scope and the same defects', () => {
  const rows=readFileSync('harness/tc1-random-rows.shen','utf8'),number=name=>Number(rows.match(new RegExp(`\\(define fh\\.${name} -> (\\d+)\\)`))[1]);
  const seeds=number('tc1-random-seeds'),perSeed=number('tc1-random-per-seed'),control=number('tc1-control-per-seed');
  const text=id=>manifest.rows.find(r=>r.id===id).acceptance,grouped=n=>n.toLocaleString('en-US');
  assert.ok(text('random-family').includes(`${grouped(seeds*perSeed)} handler programs`)&&text('random-family').includes(`${seeds} fixed seeds, ${grouped(perSeed)} programs per seed`));
  assert.ok(text('guest-random-family').includes(grouped(seeds*perSeed)));
  assert.ok(text('random-family-negative-control').includes(`one seed of ${grouped(control)} programs`));
  // The step bound and the node bound the acceptance text names are the harness's own.
  const fuel=readFileSync('harness/tc1-random.shen','utf8').match(/\(define fh\.r-fuel -> (\d+)\)/)[1];
  const nodes=readFileSync('harness/tc1-generate.shen','utf8').match(/\(define fh\.g-max-nodes -> (\d+)\)/)[1];
  assert.ok(text('random-family').includes(`step bound of ${grouped(Number(fuel))}`)&&text('random-family').includes(`at most ${nodes} nodes`));
  // The Shen harness holds the defect names itself; they are the implementation's six.
  const names=readFileSync('harness/tc1-defects.shen','utf8').match(/\(define fh\.defect-names\n  -> \[([^\]]*)\]\)/)[1].match(/[a-z_]+/g);
  assert.deepEqual(names,Object.keys(MUTANTS));
  assert.deepEqual(rows.match(/\(define fh\.tc1-control-defects\n  -> \[([^\]]*)\]\)/)[1].match(/[a-z_]+/g),Object.keys(MUTANTS));
});

test('the TC0-A manifest no longer carries the TC1 rows, and its evaluator no longer checks them', () => {
  const tc0=json('spec/tc0/tc0-a-requirements.json');
  assert.ok(!tc0.rows.some(r=>/tc1/.test(r.id)||/tc1/.test(r.check)));
  assert.deepEqual(tc0.rows.filter(r=>!r.required).map(r=>r.id),['exact-arithmetic-second-port','solo5-guest-agreement']);
  assert.equal(tc0.rows.filter(r=>r.required).length,15);
  assert.ok(!/"tc1-|tc1\./.test(readFileSync('harness/gate.shen','utf8')));
});
