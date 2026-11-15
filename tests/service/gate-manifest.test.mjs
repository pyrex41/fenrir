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
    'a2-refinement','a2-js-agreement','a2-solo5-agreement','a2-handler-mutants','retained-counterexamples-replay','a3-host-quick',
    'a4-model','a4-fenrir-refinement','a4-solo5-agreement','a4-retained-replay']);
  for(const r of manifest.rows) {
    assert.equal(r.required,!['a3-host-quick','a4-model','a4-fenrir-refinement','a4-solo5-agreement','a4-retained-replay'].includes(r.id),r.id);
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

test('the optional A3 row pins what host/service reports, accepts only the documented sync_off miss, and cites a ledger row with its gaps', () => {
  const slice=name=>{const at=evaluator.indexOf(`(define ${name}\n`);return evaluator.slice(at,evaluator.indexOf('\n(define ',at+1));};
  const check=readFileSync('host/service/check.sh','utf8');
  const list=key=>check.match(new RegExp(`${key} => \\[([^\\]]*)\\]`))[1].split(',').map(x=>x.trim());
  assert.deepEqual(shenList('sg.a3-mutants'),[...list('(?<![a-z0-9_])mutants'),...list('a4_mutants')]);
  assert.equal(readdirSync('tests/host/histories').filter(f=>f.endsWith('.json')).length,Number(shenString('sg.a3-negative-tests')));
  const row=manifest.rows.find(r=>r.id==='a3-host-quick');
  assert.equal(row.required,false);
  assert.ok(row.acceptance.includes('check.sh quick')&&row.acceptance.includes('sync_off')&&row.acceptance.includes('31 negative')&&row.acceptance.includes('18 host mutants')&&row.acceptance.includes(`${shenList('sg.a3-campaigns').length} campaigns`));
  assert.deepEqual(Object.keys(manifest.claims).filter(c=>manifest.claims[c].includes('a3-host-quick')),[]);
  const ok=slice('sg.a3-mutant-ok?');
  assert.ok(/"sync_off"/.test(ok)&&/not_detectable_here/.test(ok)&&/"equivalent-control"|"equivalent_control"/.test(ok));
  const host=slice('sg.a3-host-quick');
  assert.ok(/"BLOCKED"/.test(host)&&/"UNKNOWN"/.test(host)&&/did not report/.test(host)&&/sg\.a3-passes\?/.test(host)&&/fenrir-a3-tools/.test(host));
  const passes=slice('sg.a3-passes?');
  assert.ok(/development-pass/.test(passes)&&/histories_rejected|sg\.a3-campaigns-clean\?/.test(passes)&&/flagged/.test(passes));
  assert.ok(/histories_rejected/.test(slice('sg.a3-campaign-clean?'))&&/histories_indeterminate/.test(slice('sg.a3-campaign-clean?'))&&/audits_clean/.test(slice('sg.a3-campaign-clean?')));
  const led=json(manifest.ledger).rows.find(r=>r.id==='SERVICE-A3-HOST');
  assert.equal(led.status,'DEVELOPMENT-EVIDENCE');
  for(const p of led.evidence)assert.ok(existsSync(p),p);
  assert.ok(led.gaps.some(g=>/sync_off/.test(g)&&/fsync|power/.test(g))&&led.gaps.some(g=>/SQLite/.test(g)&&/OTP/.test(g))&&led.gaps.some(g=>/one request per tender boot/i.test(g))&&led.gaps.some(g=>/CONTRACT\.md/.test(g)));
  assert.ok(/a3-host-quick/.test(manifest.not_covered)&&/sync_off/.test(manifest.not_covered));
  // The host report's counts as pinned: 15 campaigns, 18 host mutants (two equivalent controls), 31 negative tests.
  assert.equal(shenList('sg.a3-campaigns').length,15);
  assert.equal(shenList('sg.a3-mutants').length,18);
  assert.ok(shenList('sg.a3-mutants').filter(n=>/^equivalent_control/.test(n)).length===2);
  assert.ok(/15 campaigns/.test(row.acceptance));
  assert.ok(manifest.rows.findLastIndex(r=>r.required)<manifest.rows.findIndex(r=>!r.required));
});

test('the optional A4 rows pin the scope, the model graph, the mutants and the retained counterexamples the repository states, and cannot pass on truncation', () => {
  const slice=name=>{const at=evaluator.indexOf(`(define ${name}\n`);return evaluator.slice(at,evaluator.indexOf('\n(define ',at+1));};
  const ids=['a4-model','a4-fenrir-refinement','a4-solo5-agreement','a4-retained-replay'];
  for(const id of ids){
    const row=manifest.rows.find(r=>r.id===id);
    assert.equal(row.required,false,id);
    assert.deepEqual(row.ledger,['SERVICE-A4-UPGRADE'],id);
    assert.deepEqual(Object.keys(manifest.claims).filter(c=>manifest.claims[c].includes(id)),[],id+' backs no claim');
  }
  // The scope is the default of both A4 run scripts.
  const scope=shenList('sg.a4-scope');
  for(const script of ['harness/run-service-upgrade.sh','harness/run-service-upgrade-fenrir.sh'])
    assert.ok(readFileSync(script,'utf8').includes(scope.join(' ')),`${script} has the pinned default scope`);
  // Mutants: the lists the harness programs hold, and the files under examples/service/mutants-a4.
  const names=text=>[...text.matchAll(/"([a-z0-9-]+)"/g)].map(m=>m[1]);
  const model=names(readFileSync('harness/service-upgrade-mutants.shen','utf8').match(/\(define umu\.mutant-names\s+->\s+\[([^\]]*)\]/)[1]);
  assert.deepEqual(shenList('sg.a4-machines'),model);
  assert.ok(model.includes('equivalent-control'));
  const files=readdirSync('examples/service/mutants-a4').map(f=>f.replace(/\.fen$/,'')).sort();
  assert.deepEqual([...shenList('sg.a4-fenrir-machines')].sort(),files);
  assert.deepEqual(shenList('sg.a4-controls'),['equivalent-control',...files.filter(f=>/equivalent-control$/.test(f))]);
  // Retained counterexamples: all of them are replayed, and none was removed.
  assert.equal(readdirSync('spec/service/counterexamples-a4').filter(f=>f.endsWith('.json')).length,Number(shenString('sg.a4-model-retained')));
  assert.equal(readdirSync('spec/service/counterexamples-a4-fenrir').filter(f=>f.endsWith('.json')).length,Number(shenString('sg.a4-fenrir-retained')));
  const acc=id=>manifest.rows.find(r=>r.id===id).acceptance;
  assert.ok(acc('a4-retained-replay').includes('43')&&acc('a4-retained-replay').includes('16'));
  for(const key of ['sg.a4-model-states','sg.a4-system-states','sg.a4-edges'])
    assert.ok(acc('a4-model').includes(Number(shenString(key)).toLocaleString('en-US')),key);
  assert.ok(acc('a4-model').includes(`${shenList('sg.a4-machines').length-1} mutants`));
  assert.ok(acc('a4-fenrir-refinement').includes(`${shenList('sg.a4-fenrir-machines').length-2} Fenrir mutants`));
  // Truncation, another scope or a missing report is UNKNOWN, never a pass; failures are FAIL.
  for(const name of ['sg.a4-model','sg.a4-fenrir-refinement']){
    const text=slice(name);
    assert.ok(/sg\.a4-scope-matches\?/.test(text)&&/truncated or incomplete/.test(text)&&/"UNKNOWN"/.test(text)&&/"FAIL"/.test(text)&&/did not report/.test(text),name);
    assert.ok(/sg\.untruncated\?/.test(text)&&/sg\.every-untruncated\?/.test(text),name);
  }
  const model1=slice('sg.a4-model');
  assert.ok(/development-pass/.test(model1)&&/all_agree/.test(model1)&&/"agree"/.test(model1)&&/properties_never_failing_on_a_mutant/.test(model1)&&/sg\.a4-uncovered-checks/.test(model1));
  assert.deepEqual(shenList('sg.a4-uncovered-checks'),['recovery.obligations','progress.terminal-stable']);
  const fen=slice('sg.a4-fenrir-refinement');
  assert.ok(/steps_differing/.test(fen)&&/compare_and_swap_failures/.test(fen)&&/agreeing_step_for_step/.test(fen)&&/same_graph_as_a4_model/.test(fen)&&/sandboxed/.test(fen));
  assert.ok(/"BLOCKED"/.test(slice('sg.a4-solo5'))&&/exceeded its time limit/.test(slice('sg.a4-solo5')));
  assert.ok(/sg\.replay-all/.test(slice('sg.a4-retained-replay'))&&/no replay report|gave no replay report/.test(slice('sg.a4-retained-replay')));
  assert.ok(/sg\.a4-controls/.test(slice('sg.a4-machine-ok?')));
  // The ledger row states its gaps and cites only files that exist.
  const led=json(manifest.ledger).rows.find(r=>r.id==='SERVICE-A4-UPGRADE');
  assert.equal(led.status,'DEVELOPMENT-EVIDENCE');
  for(const p of led.evidence)assert.ok(existsSync(p),p);
  const gap=re=>led.gaps.some(g=>re.test(g));
  assert.ok(gap(/Bounded scope/)&&gap(/1 key/)&&gap(/2 submits/),'bounded scope');
  assert.ok(gap(/author lineage/));
  assert.ok(gap(/section 11/)&&gap(/unconfirmed by the owner/));
  assert.ok(gap(/[Nn]o rollback after migrate/));
  assert.ok(gap(/column-count accident/));
  assert.ok(gap(/fsync/)&&gap(/power-loss/));
  assert.ok(/stage A4/.test(manifest.not_covered)&&/a4-model/.test(manifest.not_covered)&&/SERVICE-A4-UPGRADE/.test(manifest.not_covered));
  assert.ok(manifest.rows.findLastIndex(r=>r.required)<manifest.rows.findIndex(r=>!r.required));
  assert.equal(manifest.status,'proposed');
});
