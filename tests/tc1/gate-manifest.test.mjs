// Structure of the proposed TC1 gate manifest, and what moved out of the TC0-A one.
// These are consistency checks on the manifests, NOT gate evidence: only the
// evaluators (harness/tc1-gate.shen, harness/gate.shen) issue verdicts.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {MUTANTS} from '../../tools/tc1/handler-defects.mjs';
import {enumerateHandlers} from '../../tools/tc1/handler-enumerate.mjs';
import {FAMILY_SIZE} from '../../tools/tc1/handler-generate.mjs';
import {createHash} from 'node:crypto';
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
    ...Object.keys(MUTANTS).map(key=>'tc1-defect:'+key),'tc1-generated',
    ...['forgotten_resume','double_resume','outermost_handler','shallow_resume'].map(key=>'tc1-reduction:'+key),'tc1-strict-replay',
    'tc1-guest-hand','tc1-guest-exhaustive','tc1-catalog-coverage']);
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

test('the TC0-A manifest no longer carries the TC1 rows, and its evaluator no longer checks them', () => {
  const tc0=json('spec/tc0/tc0-a-requirements.json');
  assert.ok(!tc0.rows.some(r=>/tc1/.test(r.id)||/tc1/.test(r.check)));
  assert.deepEqual(tc0.rows.filter(r=>!r.required).map(r=>r.id),['exact-arithmetic-second-port','solo5-guest-agreement']);
  assert.equal(tc0.rows.filter(r=>r.required).length,15);
  assert.ok(!/"tc1-|tc1\./.test(readFileSync('harness/gate.shen','utf8')));
});

test('the evaluator, the manifest and the generator state the same generated scope and campaigns', () => {
  const programs=evaluator.match(/\(define fh\.tc1-generated-programs -> "(\d+)"\)/)[1];
  assert.equal(programs,String(FAMILY_SIZE));
  assert.ok(manifest.rows.find(r=>r.id==='generated-agreement').acceptance.includes(Number(programs).toLocaleString('en-US')+' programs'));
  const defects=[...evaluator.match(/\(define fh\.tc1-campaign-defects -> \[([^\]]*)\]\)/)[1].matchAll(/"([a-z_]+)"/g)].map(m=>m[1]);
  assert.deepEqual(manifest.rows.filter(r=>r.check.startsWith('tc1-reduction:')).map(r=>r.check.slice('tc1-reduction:'.length)),defects);
  for(const d of defects)assert.ok(Object.hasOwn(MUTANTS,d),d);
  const retained=json('fixtures/tc1/handler-retained-failures.json');
  for(const d of defects)for(const role of ['original','minimized'])assert.equal(retained.cases.filter(c=>c.defect===d&&c.role===role).length,1,d+' '+role);
});

test('the catalog the evaluator pins is the catalog file, and the manifest states the same digest', () => {
  const pinned=evaluator.match(/\(define fh\.tc1-catalog-sha256 -> "([0-9a-f]{64})"\)/)[1];
  const path=evaluator.match(/\(define fh\.tc1-catalog -> "([^"]+)"\)/)[1];
  assert.equal(path,manifest.catalog);
  assert.equal(createHash('sha256').update(readFileSync(path)).digest('hex'),pinned);
  assert.equal(manifest.catalog_sha256,pinned);
  assert.equal(json(path).transitions.length,29);
  assert.ok(manifest.rows.find(r=>r.id==='catalog-coverage').acceptance.includes('29 transitions'));
});
