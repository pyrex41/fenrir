import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

const installation = process.env.FENRIR_SHEN_JIT;
const root = new URL('../../', import.meta.url);
const fixture = String.raw`
(set fh.*lib* (cn (hd (tl (value *argv*))) "/"))
(set fh.*root* (cn (hd (tl (tl (value *argv*)))) "/"))
(load (cn (value fh.*root*) "harness/gate-core.shen"))
(define fh.check
  "source-identity" Memo -> (fh.source-identity Memo))
(define fh.registered?
  Manifest -> (fh.registered-as "tc0-a-qualification" "harness/run-gate.sh" Manifest)
    where (= (fh.field "slice" Manifest) "TC0-A")
  Manifest -> (fh.registered-as "tc1-qualification" "harness/run-tc1-gate.sh" Manifest))
(fh.gate-main "manifest.json" "fixture/1" "fixture-run/1" "fixture.shen" "test gate")
`;

test('legacy gate platform guard is fail-closed without disabling bare development measurements', {
  skip: installation ? false : 'set FENRIR_SHEN_JIT to an existing Shen/JIT 0.7 install',
}, t => {
  const base = realpathSync(mkdtempSync(join(tmpdir(), 'fenrir-platform-fixture-')));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const tree = join(base, 'source');
  const bin = join(base, 'bin');
  const out = join(base, 'output');
  for (const path of [join(tree, 'harness'), join(tree, '.pi'), join(tree, 'models/tc0'), join(tree, 'models/tc1'), bin, out])
    mkdirSync(path, { recursive: true });
  for (const path of ['harness/common.shen', 'harness/gate-core.shen', '.pi/fenrir-workflow.json',
    'models/tc0/i64.shen', 'models/tc0/pure-call-machine.shen', 'models/tc1/handler-machine.shen'])
    cpSync(new URL(path, root), join(tree, path));
  writeFileSync(join(tree, 'fixture.shen'), fixture);
  writeFileSync(join(tree, 'ledger.json'), '{"rows":[]}');
  const git = (...args) => {
    const r = spawnSync('git', args, { cwd: tree, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
  };
  git('init', '-q');
  const jit = join(installation, 'bin/shen-jit');
  for (const [slice, checkId] of [['TC0-A', 'tc0-a-qualification'], ['TC1', 'tc1-qualification']]) {
    writeFileSync(join(tree, 'manifest.json'), JSON.stringify({
      schema: 'fixture/1', slice, status: 'owner-accepted', ledger: 'ledger.json', aggregation: 'fixture',
      rows: [{ id: 'source-identity', required: true, ledger: [], check: 'source-identity' }],
      claims: { 'test-claim': ['source-identity'] }, claim_prerequisites: ['source-identity'],
    }));
    git('add', '.');
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
      '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', slice);
    const run = (uname, framed, supported) => {
      writeFileSync(join(bin, 'uname'), `#!/bin/sh\n${uname}\n`, { mode: 0o755 });
      const r = spawnSync(jit, ['script', join(tree, 'fixture.shen'), join(installation, 'lib'), tree, out, jit,
        ...(framed ? ['nonce', checkId, 'source', 'config'] : [])], {
        cwd: tree, env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, encoding: 'utf8', timeout: 15_000,
      });
      assert.equal(r.status, framed && !supported ? 2 : 0, r.stdout?.slice(-2500) + r.stderr);
      const detail = JSON.parse(readFileSync(join(out, 'gate.json'), 'utf8'));
      assert.equal(detail.verdict, 'PASS', 'row verdict is development evidence, not suppressed');
      assert.equal(detail.qualification, supported ? 'PASS' : 'UNKNOWN');
      assert.equal(detail.authority, supported ? 'owner-accepted, registered' : 'UNREGISTERED');
      assert.equal(detail.runner.legacy_qualification_platform, supported);
      assert.deepEqual(detail.claims, supported ? ['test-claim'] : []);
      assert.deepEqual(detail.development_claims, supported ? [] : ['test-claim']);
      const frame = r.stdout.split('\n').find(line => line.startsWith('{"schema":"fenrir.check.v1"'));
      if (!framed) assert.equal(frame, undefined);
      else {
        assert.equal(JSON.parse(frame).verdict, supported ? 'PASS' : 'UNKNOWN');
        assert.deepEqual(JSON.parse(frame).claims, supported ? ['test-claim'] : []);
      }
    };
    run("printf 'Linux x86_64\\n'", true, true);
    run("printf 'Linux aarch64\\n'", true, false);
    run("printf 'Linux aarch64\\n'", false, false);
    run("printf 'Darwin x86_64\\n'", true, false);
    run("printf 'Linux x86_64\\n'; exit 1", true, false);
    run("printf 'noise\\nLinux x86_64\\n'", true, false);
  }
});
