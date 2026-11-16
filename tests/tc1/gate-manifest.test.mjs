// Structure of the TC1 gate manifest, its registration, and what moved out of the TC0-A one.
// These are consistency checks on the manifests, NOT gate evidence: only the
// evaluators (harness/tc1-gate.shen, harness/gate.shen) issue verdicts.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {MUTANTS} from '../../tools/tc1/handler-defects.mjs';
import {enumerateHandlers} from '../../tools/tc1/handler-enumerate.mjs';
const json=path=>JSON.parse(readFileSync(path,'utf8'));
const manifest=json('spec/tc1/tc1-requirements.json'),evaluator=readFileSync('harness/tc1-gate.shen','utf8');

test('the TC1 manifest is owner-accepted, closed over its rows, and cites known ledger rows', () => {
  assert.equal(manifest.schema,'tc1-requirement-manifest/1');
  // Accepted by the owner's instruction, not by line review; the record the manifest names says so.
  assert.equal(manifest.status,'owner-accepted');
  const record=manifest.review.split('. ')[0];
  assert.equal(record,'campaigns/tc1/TC1_GATE_REGISTRATION.md');
  assert.match(readFileSync(record,'utf8'),/by instruction/);
  assert.match(manifest.review,/not by line review/);
  // The record is about this manifest, byte for byte: a changed manifest needs a new record.
  assert.ok(readFileSync(record,'utf8').includes(createHash('sha256').update(readFileSync('spec/tc1/tc1-requirements.json')).digest('hex')));
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
    'tc1-random','tc1-guest-random','tc1-random-control','tc1-reduction','tc1-reduced-replay','tc1-remote-model','tc1-remote-run']);
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

test('the gate is registered by the rule the TC0-A gate uses, and the workflow protects what it depends on', () => {
  const workflow=json('.pi/fenrir-workflow.json'),check=workflow.checks['tc1-qualification'],core=readFileSync('harness/gate-core.shen','utf8');
  // The rule itself is shared and unchanged: owner-accepted manifest, and a workflow check whose command runs the gate.
  assert.ok(core.includes('(and (= (fh.field "status" Manifest) "owner-accepted") (cons? Command) (element? Runner Command))'));
  assert.ok(evaluator.includes('(fh.registered-as "tc1-qualification" "harness/run-tc1-gate.sh" Manifest)'));
  assert.ok(readFileSync('harness/gate.shen','utf8').includes('(fh.registered-as "tc0-a-qualification" "harness/run-gate.sh" Manifest)'));
  assert.equal(check.kind,'qualification');
  assert.deepEqual(check.command,['sh','harness/run-tc1-gate.sh']);
  // Everything the TC0-A gate depends on (it is a row of this gate), and the remote-perform system.
  const paths=new Set(check.authorityPaths);
  for(const path of workflow.checks['tc0-a-qualification'].authorityPaths)assert.ok(paths.has(path),path);
  for(const path of ['supervisor','backends/solo5/remote','tools/solo5/remote-build.mjs','models/tc1','spec/tc1','harness','campaigns/tc1','flake.nix','flake.lock'])assert.ok(paths.has(path),path);
  // The caller image is built from a source file through the frontend: both are what the remote-run row depends on.
  for(const path of ['frontend','examples/remote'])assert.ok(paths.has(path),path);
  const build=readFileSync('tools/solo5/remote-build.mjs','utf8');
  // The build takes the source's name from the system manifest, which is under examples/remote too.
  assert.ok(build.includes("MANIFEST='examples/remote/ledger-system.json'")&&build.includes("'frontend/fenrir.sh'"));
  assert.equal(json('examples/remote/ledger-system.json').members[0].program,'examples/remote/ledger-caller.fen');
  // The workflow's completion condition is still the TC0-A slice's: this record does not change it.
  assert.deepEqual(workflow.requiredChecks,['tc0-a-qualification']);
});

test('the remote rows, the manifest and the checks state the same scope', () => {
  const rows=readFileSync('harness/tc1-remote-rows.shen','utf8'),number=name=>Number(rows.match(new RegExp(`\\(define fh\\.${name} -> (\\d+)\\)`))[1]);
  const text=id=>manifest.rows.find(r=>r.id===id).acceptance;
  const model=readFileSync('harness/tc1-remote.shen','utf8'),run=readFileSync('harness/tc1-remote-run.shen','utf8');
  const count=(source,from,to,pattern)=>source.slice(source.indexOf(from),source.indexOf(to)).match(pattern).length;
  // Model check: systems, mutants, hand schedules.
  assert.equal(count(model,'(define fr.systems','(define fr.system\n',/\[remote-config \[\[/g),number('remote-model-systems'));
  assert.equal(count(model,'(define fr.mutants','(define fr.aimed',/\[[a-z-]+ "[a-z0-9-]+" "[a-z-]+"\]/g),number('remote-model-mutants'));
  assert.equal(count(model,'(define fr.hand-schedules','(define fr.required-kinds',/\(fr\.hand "/g),number('remote-model-hand'));
  assert.ok(model.includes(`["hand_schedules" (if Control "0" "${number('remote-model-hand')}")]`));
  assert.ok(text('remote-model').includes(`${number('remote-model-systems')} small systems`)&&text('remote-model').includes(`${number('remote-model-mutants')} model mutants`)&&
    text('remote-model').includes(`${number('remote-model-hand')} hand schedules`)&&text('remote-model').includes('Model-level bounded exploration'));
  // Run check: hand schedules, seeds, free runs, defect switches.
  assert.equal(count(run,'(define fx.hand\n','(define fx.drop-last',/^ +\[?\["[a-z0-9-]+" \(?(fx\.declared\)|\[\]) (true|false)$/gm),number('remote-run-hand'));
  assert.equal(Number(run.match(/\(set fx\.\*seeds\* (\d+)\)/)[1]),number('remote-run-seeds'));
  assert.equal(count(run,'(define fx.free-runs','(define fx.free\n',/\["free[a-z-]*" \[object/g),number('remote-run-free'));
  assert.equal(count(run,'(define fx.defects','(define fx.command\n',/^ +\[?\["[a-z0-9-]+" \(?(fx\.declared\)|\[\]) (true|false)$/gm),number('remote-run-defects'));
  assert.ok(text('remote-run').includes(`${number('remote-run-hand')} hand schedules, ${number('remote-run-seeds')} seeded schedules and ${number('remote-run-free')} free-running runs`)&&
    text('remote-run').includes(`${number('remote-run-defects')} defect switches`)&&text('remote-run').includes('Observed histories on spt accepted by the model'));
  // The two claims say what kind of evidence they are, and rest on these rows only.
  assert.deepEqual(manifest.claim_evidence,{'remote-perform-model-properties-bounded':'model-level bounded exploration','remote-perform-observed-histories-spt':'observed histories on spt accepted by the model'});
  assert.deepEqual(manifest.claims['remote-perform-model-properties-bounded'],['toolchain-pinned','remote-model']);
  assert.deepEqual(manifest.claims['remote-perform-observed-histories-spt'],['toolchain-pinned','remote-model','remote-run']);
  // One Erlang lookup, used by the runner and by the gate row.
  assert.ok(readFileSync('harness/run-tc1-remote-run.sh','utf8').includes('harness/find-erlang.sh')&&rows.includes('harness/find-erlang.sh'));
});

test('the registration record carries its amendments, and the remote checks agree on names, properties and the wire version', () => {
  const record=readFileSync('campaigns/tc1/TC1_GATE_REGISTRATION.md','utf8');
  const first=record.indexOf('## Amendment 1, 2026-11-16'),second=record.indexOf('## Amendment 2, 2026-11-16'),third=record.indexOf('## Amendment 3, 2026-11-16'),amendment=record.slice(third);
  // The amendments are at the end, in order, by instruction and not by line review; the last is the part that names the manifest as it is now.
  const instructed=/given in\s+conversation, not line\s+review/;
  assert.ok(first>0&&second>first&&third>second&&instructed.test(record.slice(first,second))&&instructed.test(record.slice(second,third))&&instructed.test(amendment));
  const hash=createHash('sha256').update(readFileSync('spec/tc1/tc1-requirements.json')).digest('hex');
  assert.ok(amendment.includes(hash)&&!record.slice(0,third).includes(hash));
  assert.match(manifest.review,/Amended on 2026-11-16 a second time \(Amendment 2/);
  assert.match(manifest.review,/Amended on 2026-11-16 a third time \(Amendment 3/);
  assert.match(manifest.contract,/draft 8/);
  assert.match(readFileSync('spec/tc1/EFFECTS.md','utf8'),/^Draft 8 /m);
  // Questions 13 and 15 of the contract are open, and the record does not say otherwise.
  assert.match(amendment,/Questions 13 and 15[^.]*open/);
  // The outcome renamed on 16 November 2026 is not left under its old name in anything that runs.
  const sources=['models/tc1/remote-system.shen','models/tc1/remote-tc1-caller.shen','harness/tc1-remote.shen','harness/tc1-remote-properties.shen',
    'harness/tc1-remote-run.shen','harness/tc1-remote-rows.shen','supervisor/src/fenrir_relay.erl','supervisor/src/fenrir_run.erl','supervisor/src/fenrir_main.erl',
    'supervisor/src/fenrir_wire.erl','backends/solo5/remote/caller.c','backends/solo5/remote/peer.c','backends/solo5/remote/wire.c','examples/remote/ledger-caller.fen','tools/solo5/remote-build.mjs'];
  for(const file of sources)assert.ok(!/peer[-_]down/i.test(readFileSync(file,'utf8')),file);
  // Both checks report the same properties, and every model mutant is aimed at one of them.
  const model=readFileSync('harness/tc1-remote.shen','utf8'),run=readFileSync('harness/tc1-remote-run.shen','utf8');
  const properties=source=>source.match(/\["properties" \[([^\]]*)\]\]/)[1].match(/"[a-z-]+"/g);
  assert.deepEqual(properties(model),properties(run));
  assert.equal(properties(model).length,11);
  const aimed=model.slice(model.indexOf('(define fr.mutants'),model.indexOf('(define fr.aimed')).match(/"[a-z-]+"\]/g).map(s=>s.slice(0,-1));
  for(const property of aimed)assert.ok(properties(model).includes(property),property);
  // Every defect switch the run check uses is one the supervisor accepts.
  const known=readFileSync('supervisor/src/fenrir_main.erl','utf8').match(/Known = \[([^\]]*)\]/s)[1].match(/[a-z-]+(?=">>)/g);
  const used=run.slice(run.indexOf('(define fx.defects'),run.indexOf('(define fx.command\n')).match(/^ +\[?\["[a-z0-9-]+"/gm).map(s=>s.match(/"([a-z0-9-]+)"/)[1]);
  assert.deepEqual([...used].sort(),[...known].sort());
  // One wire version: the C side, the Erlang side, the build and the images' greeting.
  const version=readFileSync('backends/solo5/remote/wire.h','utf8').match(/#define FRW_VERSION (\d+)u/)[1];
  assert.equal(readFileSync('supervisor/src/fenrir_wire.erl','utf8').match(/-define\(VERSION, (\d+)\)\./)[1],version);
  assert.ok(readFileSync('tools/solo5/remote-build.mjs','utf8').includes(`wire_version:'${version}'`));
  for(const image of ['caller','peer'])assert.ok(readFileSync(`backends/solo5/remote/${image}.c`,'utf8').includes(`\\"wire\\":\\"${version}\\"`),image);
});

test('the TC0-A manifest no longer carries the TC1 rows, and its evaluator no longer checks them', () => {
  const tc0=json('spec/tc0/tc0-a-requirements.json');
  assert.ok(!tc0.rows.some(r=>/tc1/.test(r.id)||/tc1/.test(r.check)));
  assert.deepEqual(tc0.rows.filter(r=>!r.required).map(r=>r.id),['exact-arithmetic-second-port','solo5-guest-agreement']);
  assert.equal(tc0.rows.filter(r=>r.required).length,15);
  assert.ok(!/"tc1-|tc1\./.test(readFileSync('harness/gate.shen','utf8')));
});
