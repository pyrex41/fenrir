// Runs the benign boundary probes. Where no network namespace can be created the
// probe suite exits 2 and this test is reported SKIPPED, never passed.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
test('every probed capability is obtained without the sandbox and denied inside it', t => {
  mkdirSync(resolve('build/tc0'), { recursive: true });
  const dir = mkdtempSync(resolve('build/tc0/sandbox-test-'));
  try {
    const out = resolve(dir, 'probes.json'),
      r = spawnSync(process.execPath, ['tools/tc0/check-sandbox.mjs', out], {
        encoding: 'utf8',
        timeout: 120000
      });
    if (r.status === 2) {
      t.skip('no network namespace available: ' + r.stderr.trim());
      return;
    }
    assert.equal(r.status, 0, r.stderr);
    const report = JSON.parse(readFileSync(out));
    assert.equal(report.all_enforced, true);
    assert.deepEqual(
      report.rows.map(x => x.probe),
      [
        'baseline',
        'write-protected-model',
        'write-new-file',
        'read-secret-file',
        'read-model-source',
        'read-environment-credential',
        'spawn-process',
        'worker-thread',
        'network-connect'
      ]
    );
    for (const row of report.rows.slice(1)) {
      assert.equal(row.control.obtained, true, row.probe + ' control');
      assert.equal(row.sandboxed.obtained, false, row.probe + ' sandboxed');
    }
    assert.equal(report.rows[0].semantics_preserved, true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
