import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const mockShen = `#!/usr/bin/env node
const fs = require('node:fs');
const [, script, , , out, mode, file, artifacts, artifact] = process.argv.slice(2);
if (script.endsWith('/frontend/main.shen') && mode === 'emit') {
  fs.writeFileSync(out + '/result', 'mock emit\\n');
  fs.writeFileSync(artifact, '{}');
} else if (mode === 'replay') {
  if (script.endsWith('/service-fenrir.shen') && !fs.existsSync(artifacts + '/accepted-job.json')) {
    process.exit(2);
  }
  const fixture = JSON.parse(fs.readFileSync(file, 'utf8'));
  const report = {
    schema: 'fenrir.service.replay/1', status: 'reproduced', qualification: 'UNKNOWN',
    file, machine: fixture.machine, check: fixture.check, length: fixture.length,
    schedule_enabled: true, first_failure_at: fixture.length,
  };
  console.log('loaded Shen replay evaluator');
  switch (process.env.MOCK_REPLAY) {
    case 'exit-mismatch': process.exitCode = 1; break;
    case 'status-mismatch': report.status = 'not-reproduced'; break;
    case 'wrong-file': report.file += '.other'; break;
    case 'wrong-step': report.first_failure_at++; break;
    case 'wrong-schema': report.schema += '.other'; break;
    case 'nested-status':
      console.log(JSON.stringify({ diagnostic: { status: 'reproduced' } }));
      return;
    case 'malformed':
      console.log('not a JSON report: {"status":"reproduced"}');
      return;
  }
  console.log(JSON.stringify(report));
} else {
  process.exitCode = 2;
}
`;

for (const [name, suffix] of [['explore', ''], ['fenrir', '-a2']]) {
  test(`${name} retained replay requires an agreeing exit and structured report`, async t => {
    const cwd = mkdtempSync(join(tmpdir(), 'fenrir-retained-replay-'));
    t.after(() => rmSync(cwd, { recursive: true, force: true }));
    const script = `harness/run-service-${name}.sh`;
    const copy = path => {
      mkdirSync(join(cwd, dirname(path)), { recursive: true });
      copyFileSync(join(root, path), join(cwd, path));
    };
    for (const path of [script, 'harness/jit.sh', 'harness/solo5.sh', 'frontend/fenrir.sh',
      'examples/service/accepted-job.fen', 'examples/service/mutants/no-key-check.fen']) copy(path);
    copy('harness/service-retained-replay.sh');
    const jit = join(cwd, 'mock-jit');
    mkdirSync(join(jit, 'bin'), { recursive: true });
    writeFileSync(join(jit, 'bin/shen-jit'), mockShen, { mode: 0o755 });
    const fixtureDir = `spec/service/counterexamples${suffix}`;
    mkdirSync(join(cwd, fixtureDir), { recursive: true });
    writeFileSync(join(cwd, fixtureDir, 'fixture.json'), JSON.stringify({
      machine: 'retry-mutant', check: 'retry.replay', length: 2,
    }));

    for (const scenario of ['success', 'exit-mismatch', 'status-mismatch', 'wrong-file', 'wrong-step',
      'wrong-schema', 'nested-status', 'malformed']) {
      await t.test(scenario, () => {
        const result = spawnSync('sh', [script, 'replay-retained'], {
          cwd, encoding: 'utf8', timeout: 10_000,
          env: { ...process.env, FENRIR_SHEN_JIT: jit, MOCK_REPLAY: scenario },
        });
        assert.ifError(result.error);
        assert.equal(result.status, scenario === 'success' ? 0 : 1, result.stdout + result.stderr);
        assert.match(result.stdout, new RegExp(`^${scenario === 'success' ? 'reproduced' : 'NOT reproduced'}: ${fixtureDir}/fixture.json`, 'm'));
      });
    }
  });
}
