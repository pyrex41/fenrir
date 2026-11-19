import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { runEvidence } from '../../tools/evidence/run.mjs';
import { sha } from '../../tools/evidence/identity.mjs';

const gateId = 'tc1-qualification';
const base = 'build/harness/tc1-gate';
const target = `${base}/123-456/gate.json`;
const manifest = 'spec/tc1/tc1-requirements.json';
const nodeDir = dirname(process.execPath);

async function fixture(t, body, { gate = false, command = ['node', 'check.mjs'], blockedExitCode } = {}) {
  const dir = await mkdtemp(resolve(tmpdir(), 'fenrir-evidence-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const cwd = resolve(dir, 'checkout');
  const shenJit = resolve(dir, 'jit');
  await mkdir(cwd);
  async function put(path, text, mode = 0o644) {
    const target = resolve(cwd, path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, text, { mode });
  }
  const git = (...args) => execFileSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], { cwd, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('config', 'user.email', 'test@example.invalid');
  git('config', 'user.name', 'Fixture');
  git('config', 'commit.gpgsign', 'false');
  await put('.gitignore', '/build/\n/.pi/fenrir-workflow-runs/\n');
  const checkId = gate ? gateId : 'test-check';
  if (gate) {
    await put('harness/run-tc1-gate.sh', 'exec node check.mjs\n');
    await put('harness/tc1-gate.shen', 'mock test fixture\n');
    await put(manifest, JSON.stringify({ status: 'owner-accepted', claims: { a: [], b: [] } }));
    await put('../jit/bin/shen-jit', '#!/bin/sh\nexit 99\n', 0o755);
    await put('../jit/lib/test', 'mock library');
    command = ['sh', 'harness/run-tc1-gate.sh'];
  }
  await put('check.mjs', body);
  await put('.pi/fenrir-workflow.json', JSON.stringify({
    version: 1, checks: { [checkId]: {
      kind: gate ? 'qualification' : 'development', command, timeoutSeconds: 5,
      authorityPaths: ['check.mjs'], blockedExitCode,
    } },
  }));
  const commit = () => { git('add', '.'); git('commit', '-qm', 'Fixture'); return git('rev-parse', 'HEAD'); };
  const head = commit();
  const options = { cwd, checkId, head, path: `${nodeDir}:/usr/bin:/bin`, ...(gate && { shenJit }) };
  return { ...options, commit, git, put, run: overrides => runEvidence({ ...options, ...overrides }) };
}

function mock({ extra = '', report = {}, detail = {}, exit = 0, raw } = {}) {
  return `
import { mkdirSync, writeFileSync, symlinkSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
const path = ${JSON.stringify(target)};
const verdict = ${JSON.stringify(report.verdict ?? 'PASS')};
const claims = ${JSON.stringify(report.claims ?? ['a', 'b'])};
mkdirSync(${JSON.stringify(`${base}/123-456`)}, { recursive: true });
writeFileSync(path, JSON.stringify({
  schema: 'tc1-gate-run/1', head, verdict, qualification: verdict, claims, authority: 'owner-accepted, registered',
  manifest: ${JSON.stringify(manifest)}, evaluator: 'harness/tc1-gate.shen', ...${JSON.stringify(detail)}
}));
${extra}
const frame = {
  schema: 'fenrir.check.v1', nonce: process.env.FENRIR_CHECK_NONCE, checkId: process.env.FENRIR_CHECK_ID,
  sourceHash: process.env.FENRIR_SOURCE_SHA256, configHash: process.env.FENRIR_CONFIG_SHA256, verdict,
  claims, evidence: [path], cleanup: 'confirmed', summary: 'Mock evaluator, not language evidence', ...${JSON.stringify(report)}
};
console.log(${raw ?? 'JSON.stringify(frame)'});
process.exitCode = ${exit};`;
}

test('development PASS retains bound private logs and no qualification', async t => {
  const f = await fixture(t, `
    if (process.env.EVIDENCE_TEST_SECRET || process.argv[2] !== '$(touch surprise)') process.exit(1);
    console.log('development-only'); console.error('separate stderr');
  `, { command: ['node', 'check.mjs', '$(touch surprise)'] });
  process.env.EVIDENCE_TEST_SECRET = 'must not enter the child';
  t.after(() => { delete process.env.EVIDENCE_TEST_SECRET; });
  const receipt = await f.run();
  assert.equal(receipt.verdict, 'PASS', receipt.summary);
  assert.equal(receipt.qualification, 'UNKNOWN');
  assert.equal(receipt.head, f.head);
  assert.equal(receipt.sourceStable, true);
  assert.equal(receipt.leaseRetained, false);
  assert.deepEqual(JSON.parse(await readFile(resolve(f.cwd, receipt.receiptPath), 'utf8')), receipt);
  assert.equal(await readFile(resolve(f.cwd, receipt.stdout), 'utf8'), 'development-only\n');
  assert.equal(receipt.logs[1].sha256, sha('separate stderr\n'));
});

test('clean checkout and exact expected commit are required, even with hidden index flags', async t => {
  const f = await fixture(t, 'throw Error("must never launch")');
  const wrong = await f.run({ head: '0'.repeat(40) });
  assert.match(wrong.summary, /HEAD drift/);
  assert.equal(wrong.cleanup, 'not-launched');
  await f.put('untracked', 'dirty');
  assert.match((await f.run()).summary, /clean source/);
  await rm(resolve(f.cwd, 'untracked'));
  f.git('update-index', '--assume-unchanged', 'check.mjs');
  await f.put('check.mjs', 'changed');
  const hidden = await f.run();
  assert.match(hidden.summary, /does not match HEAD/);
  assert.equal(hidden.verdict, 'UNKNOWN');
});

test('source drift during execution cannot pass, even with another clean commit', async t => {
  const file = await fixture(t, `import { writeFileSync } from 'node:fs'; writeFileSync('check.mjs','changed');`);
  assert.equal((await file.run()).sourceStable, false);
  const head = await fixture(t, `
    import { execFileSync } from 'node:child_process';
    execFileSync('git', ['-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Drift']);
  `);
  const shifted = await head.run();
  assert.match(shifted.summary, /HEAD drift/);
  assert.equal(shifted.verdict, 'UNKNOWN');
});

test('framework confirms structured evaluator result but never claims qualification', async t => {
  const f = await fixture(t, mock(), { gate: true });
  const result = await f.run();
  assert.equal(result.verdict, 'PASS', result.summary);
  assert.equal(result.qualification, 'UNKNOWN');
  assert.equal(result.cleanup, 'confirmed');
  assert.deepEqual(result.evaluator.reportedClaims, ['a', 'b']);
  const evidence = result.evidence[0];
  await f.put(target, 'changed after run');
  assert.equal(sha(await readFile(resolve(f.cwd, evidence.retainedPath))), evidence.sha256);
  const repeated = await f.run();
  assert.equal(repeated.verdict, 'UNKNOWN');
  assert.match(repeated.summary, /stale/);
});

test('structured evaluator receives explicit Solo5 without inheriting unrelated variables', async t => {
  const solo5 = resolve(tmpdir(), 'built Solo5 fixture');
  const f = await fixture(t, mock({ extra: `
    if (process.env.FENRIR_SOLO5 !== ${JSON.stringify(solo5)} || process.env.FENRIR_OTHER_TOOL)
      throw new Error('Wrong child environment');
  ` }), { gate: true });
  const previous = { FENRIR_SOLO5: process.env.FENRIR_SOLO5, FENRIR_OTHER_TOOL: process.env.FENRIR_OTHER_TOOL };
  process.env.FENRIR_SOLO5 = solo5;
  process.env.FENRIR_OTHER_TOOL = 'must not enter the child';
  try {
    const receipt = await f.run();
    assert.equal(receipt.verdict, 'PASS', receipt.summary);
    assert.equal(receipt.qualification, 'UNKNOWN');
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});

test('FAIL, BLOCKED and UNKNOWN remain distinct; missing toolchain blocks before launch', async t => {
  for (const [verdict, exit] of [['FAIL', 1], ['BLOCKED', 2], ['UNKNOWN', 2]]) {
    const f = await fixture(t, mock({ report: { verdict, claims: [] }, exit }), { gate: true });
    assert.equal((await f.run()).verdict, verdict);
    const blocked = await f.run({ shenJit: undefined });
    assert.equal(blocked.verdict, 'BLOCKED');
    assert.equal(blocked.cleanup, 'not-launched');
  }
  const f = await fixture(t, 'process.exitCode = 75;', { blockedExitCode: 75 });
  assert.equal((await f.run()).verdict, 'BLOCKED');
});

test('framing, contradictory exits, identities, missing claims and evidence all fail closed', async t => {
  for (const options of [
    { raw: '"PASS"' }, { raw: 'JSON.stringify(frame) + "\\n" + JSON.stringify(frame)' },
    { raw: `'{"verdict":"FAIL",' + JSON.stringify(frame).slice(1)` },
    { report: { nonce: 'stale' } }, { report: { sourceHash: 'other' } }, { report: { configHash: 'other' } },
    { report: { checkId: 'other' } }, { report: { unexpected: true } }, { exit: 1 },
    { report: { claims: ['a'] } }, { report: { evidence: [] } }, { report: { evidence: ['../gate.json'] } },
    { detail: { verdict: 'FAIL' } }, { detail: { head: 'stale' } },
    { extra: `import { renameSync } from 'node:fs'; renameSync(path, path+'.old'); symlinkSync(path.split('/').at(-1)+'.old', path);` },
  ]) {
    const f = await fixture(t, mock(options), { gate: true });
    const receipt = await f.run();
    assert.equal(receipt.verdict, 'UNKNOWN', JSON.stringify(options));
  }
});

test('toolchain drift and unresolved evaluator cleanup invalidate structured PASS', async t => {
  const drift = await fixture(t, mock({
    extra: `writeFileSync(process.env.FENRIR_SHEN_JIT + '/lib/test', 'changed');`,
  }), { gate: true });
  assert.match((await drift.run()).summary, /identity drift/);
  const unresolved = await fixture(t, mock({ report: { cleanup: 'unresolved' } }), { gate: true });
  const receipt = await unresolved.run();
  assert.equal(receipt.verdict, 'UNKNOWN');
  assert.equal(receipt.leaseRetained, true);
  await assert.rejects(unresolved.run(), /lease occupied/);
});

test('unresolved evaluator cleanup keeps the lease despite other evidence failures', async t => {
  for (const [name, extra, reason] of [
    ['source drift', `writeFileSync('check.mjs', 'changed');`, /Expected clean source/],
    ['unsafe log', `
      import { renameSync } from 'node:fs';
      const log = process.env.FENRIR_ARTIFACT_DIR + '/stdout.log';
      renameSync(log, log + '.old');
      symlinkSync(log + '.old', log);
    `, /Not a regular file/],
  ]) {
    await t.test(name, async t => {
      const f = await fixture(t, mock({ report: { cleanup: 'unresolved' }, extra }), { gate: true });
      const receipt = await f.run();
      assert.equal(receipt.verdict, 'UNKNOWN');
      assert.match(receipt.summary, reason);
      assert.equal(receipt.cleanup, 'unresolved');
      assert.equal(receipt.processGroupCleanup, 'confirmed');
      assert.equal(receipt.leaseRetained, true);
      assert.deepEqual(JSON.parse(await readFile(resolve(f.cwd, receipt.receiptPath), 'utf8')), receipt);
      await assert.rejects(f.run(), /lease occupied/);
    });
  }
});

test('launcher executable drift invalidates an otherwise successful development exit', async t => {
  const f = await fixture(t, `
    import { writeFileSync } from 'node:fs';
    writeFileSync('../bin/fixture-launcher', '#!/bin/sh\\nexit 0\\n');
  `, { command: ['fixture-launcher', 'check.mjs'] });
  await f.put('../bin/fixture-launcher', '#!/bin/sh\nexec node "$@"\n', 0o755);
  const result = await f.run({ path: `${resolve(f.cwd, '../bin')}:${f.path}` });
  assert.equal(result.verdict, 'UNKNOWN');
  assert.equal(result.execution.exitCode, 0);
  assert.match(result.summary, /identity drift/);
});

test('watchdog, output cap, and background children never yield PASS', async t => {
  const timeout = await fixture(t, 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000);');
  const expired = await timeout.run({ timeoutSeconds: 1 });
  assert.equal(expired.verdict, 'UNKNOWN');
  assert.match(expired.execution.issue, /Watchdog/);
  assert.equal(expired.processGroupCleanup, 'confirmed');
  assert.equal(expired.execution.exitSignal, 'SIGKILL');
  const overflow = await fixture(t, 'process.stdout.write(Buffer.alloc(9 * 1024 * 1024));');
  const output = await overflow.run();
  assert.equal(output.verdict, 'UNKNOWN');
  assert.equal(output.execution.outputExceeded, true);
  assert.equal(output.logs[0].bytes, 8 * 1024 * 1024);
  const background = await fixture(t, `
    import { spawn } from 'node:child_process';
    spawn(process.execPath, ['-e','setInterval(() => {}, 1000)'], { stdio: 'ignore' }).unref();
  `);
  const leftover = await background.run();
  assert.equal(leftover.verdict, 'UNKNOWN');
  assert.match(leftover.execution.issue, /background processes/);
});

test('pre-cancellation and a pre-existing unsafe output directory cannot launch', async t => {
  const f = await fixture(t, 'throw Error("must never launch")');
  const cancelled = await f.run({ signal: AbortSignal.abort() });
  assert.equal(cancelled.cleanup, 'not-launched');
  await rm(resolve(f.cwd, 'build'), { recursive: true });
  await symlink(dirname(f.cwd), resolve(f.cwd, 'build'));
  await assert.rejects(f.run(), /Not a real directory/);
});

test('active cancellation joins the group and stays UNKNOWN', async t => {
  const f = await fixture(t, `import { writeFileSync } from 'node:fs';
    writeFileSync('build/started', 'yes'); setInterval(() => {}, 1000);`);
  const controller = new AbortController();
  const pending = f.run({ signal: controller.signal });
  try {
    for (let i = 0; i < 120; i++) {
      try { await readFile(resolve(f.cwd, 'build/started')); break; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await delay(25);
    }
    assert.equal(await readFile(resolve(f.cwd, 'build/started'), 'utf8'), 'yes');
  } finally { controller.abort(); }
  const result = await pending;
  assert.equal(result.verdict, 'UNKNOWN');
  assert.equal(result.execution.issue, 'Cancelled');
  assert.equal(result.processGroupCleanup, 'confirmed');
});

test('escaped descendants holding output pipes leave cleanup unresolved', async t => {
  const f = await fixture(t, `
    import { spawn } from 'node:child_process';
    import { writeFileSync } from 'node:fs';
    const child = spawn(process.execPath, ['-e','setTimeout(() => {}, 10000)'],
      { detached: true, stdio: ['ignore', 'inherit', 'inherit'] });
    writeFileSync('build/escaped', String(child.pid));
    child.unref();
  `);
  try {
    const result = await f.run({ timeoutSeconds: 1 });
    assert.equal(result.verdict, 'UNKNOWN');
    assert.equal(result.processGroupCleanup, 'unresolved');
    assert.equal(result.leaseRetained, true);
    assert.match(result.execution.cleanupIssue, /pipes remained open/);
  } finally {
    try { process.kill(Number(await readFile(resolve(f.cwd, 'build/escaped'), 'utf8')), 'SIGKILL'); }
    catch (error) { if (!['ESRCH', 'ENOENT'].includes(error.code)) throw error; }
  }
});
