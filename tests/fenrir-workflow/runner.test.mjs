import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { CLAIMS, newState } from '../../.pi/extensions/fenrir-workflow/core.mjs';
import {
  acquireLock, evidenceReferences, loadConfig, privateDirectory, protectedIdentity,
  referencesValid, releaseLock, sourceIdentity,
} from '../../.pi/extensions/fenrir-workflow/storage.mjs';
import { runCheck } from '../../.pi/extensions/fenrir-workflow/runner.mjs';

async function fixture(t, body, kind = 'development') {
  const cwd = await mkdtemp(resolve(tmpdir(), 'fenrir-runner-test-'));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  await mkdir(resolve(cwd, '.pi'));
  await writeFile(resolve(cwd, 'evaluator.mjs'), body);
  await writeFile(resolve(cwd, '.pi/fenrir-workflow.json'), JSON.stringify({ version: 1, requiredChecks: ['check'], checks: {
    check: { kind, command: [process.execPath, 'evaluator.mjs'], timeoutSeconds: 5, authorityPaths: ['evaluator.mjs'] },
  } }));
  const { config, configHash } = await loadConfig(cwd);
  const authority = await protectedIdentity(cwd, config);
  const state = newState({ cwd, sessionId: 'test-session', configHash, protectedHash: authority.hash });
  return { cwd, config, state, checkId: 'check' };
}
function qualificationProgram(extra = '', reportPatch = {}, exit = 0) {
  return `
import { writeFileSync } from 'node:fs';
import { relative, resolve } from 'node:path';
const evidence = resolve(process.env.FENRIR_ARTIFACT_DIR, 'proof.json');
writeFileSync(evidence, JSON.stringify({fixture: 'independent evaluator output'}));
${extra}
const report = {
 schema: 'fenrir.check.v1', nonce: process.env.FENRIR_CHECK_NONCE,
 checkId: process.env.FENRIR_CHECK_ID, sourceHash: process.env.FENRIR_SOURCE_SHA256,
 configHash: process.env.FENRIR_CONFIG_SHA256, verdict: 'PASS', cleanup: 'confirmed',
 claims: ${JSON.stringify(CLAIMS)}, evidence: [relative(process.cwd(), evidence)], summary: 'Fixture evaluator result',
 ...${JSON.stringify(reportPatch)}
};
console.log(JSON.stringify(report)); process.exitCode = ${exit};`;
}

test('development checks observe exit status without inventing qualification', async t => {
  const data = await fixture(t, 'console.log("ordinary test output");');
  const receipt = await runCheck(data);
  assert.equal(receipt.verdict, 'PASS');
  assert.equal(receipt.kind, 'development');
  assert.deepEqual(receipt.claims, []);
  assert.equal(receipt.runnerCleanup, 'confirmed');
  assert.equal(receipt.sourceStable, true);
  assert.match(await readFile(resolve(data.cwd, receipt.stdout), 'utf8'), /ordinary test output/);
  data.config.checks.check.command = [process.execPath, '-e', 'process.exit(1)'];
  assert.equal((await runCheck(data)).verdict, 'FAIL');
});

test('qualification checks validate nonce/source/config, retain and hash external evidence', async t => {
  const data = await fixture(t, qualificationProgram(), 'qualification');
  const receipt = await runCheck(data);
  assert.equal(receipt.verdict, 'PASS', receipt.summary);
  assert.deepEqual(receipt.claims, CLAIMS);
  assert.equal(receipt.evidence.length, 1);
  assert.equal(await referencesValid(data.cwd, receipt.evidence), true);
  await writeFile(resolve(data.cwd, receipt.evidence[0].path), 'tampered');
  assert.equal(await referencesValid(data.cwd, receipt.evidence), false);
});

test('plain text/invalid JSON cannot be a qualification PASS', async t => {
  const data = await fixture(t, 'console.log("PASS");', 'qualification');
  assert.equal((await runCheck(data)).verdict, 'UNKNOWN');
});

test('incompatible report identity and missing evidence fail closed', async t => {
  for (const patch of [{ nonce: 'wrong' }, { sourceHash: 'wrong' }, { configHash: 'wrong' }, { claims: null }, { evidence: [] }, { unexpected: true }]) {
    const data = await fixture(t, qualificationProgram('', patch), 'qualification');
    assert.equal((await runCheck(data)).verdict, 'UNKNOWN', JSON.stringify(patch));
  }
});

test('evaluator verdict and exit status must agree', async t => {
  const inconsistent = await fixture(t, qualificationProgram('', {}, 1), 'qualification');
  assert.equal((await runCheck(inconsistent)).verdict, 'UNKNOWN');
  const failure = await fixture(t, qualificationProgram('', { verdict: 'FAIL', claims: [] }, 1), 'qualification');
  assert.equal((await runCheck(failure)).verdict, 'FAIL');
  const unknown = await fixture(t, qualificationProgram('', { verdict: 'UNKNOWN', claims: [] }, 2), 'qualification');
  assert.equal((await runCheck(unknown)).verdict, 'UNKNOWN');
});

test('source or authority mutation during a check invalidates its result', async t => {
  const changed = await fixture(t, qualificationProgram('writeFileSync("candidate.mjs", "changed");'), 'qualification');
  const receipt = await runCheck(changed);
  assert.equal(receipt.verdict, 'UNKNOWN');
  assert.equal(receipt.sourceStable, false);
  const authority = await fixture(t, qualificationProgram('writeFileSync("evaluator.mjs", "changed");'), 'qualification');
  assert.equal((await runCheck(authority)).verdict, 'UNKNOWN');
});

test('evidence traversal and symlink sources are rejected', async t => {
  const outside = await fixture(t, qualificationProgram('', { evidence: ['../outside'] }), 'qualification');
  assert.equal((await runCheck(outside)).verdict, 'UNKNOWN');
  const linked = await fixture(t, 'console.log("should never launch");');
  await symlink(resolve(linked.cwd, 'evaluator.mjs'), resolve(linked.cwd, 'link.mjs'));
  await assert.rejects(runCheck(linked), /symlink/i);
  await assert.rejects(evidenceReferences(linked.cwd, ['link.mjs']), /Symlink/);
});

test('watchdog and cancellation stop processes, never complete the semantic claim', async t => {
  const data = await fixture(t, 'setInterval(() => {}, 1000);');
  const timed = await runCheck({ ...data, timeoutMs: 50 });
  assert.equal(timed.interrupted, 'HarnessTimeout');
  assert.equal(timed.verdict, 'UNKNOWN');
  assert.equal(timed.runnerCleanup, 'confirmed');
  assert.equal(timed.cleanup, 'unresolved');
  const controller = new AbortController();
  const pending = runCheck({ ...data, signal: controller.signal });
  setTimeout(() => controller.abort(), 80);
  const cancelled = await pending;
  assert.equal(cancelled.interrupted, 'Cancelled');
  assert.equal(cancelled.verdict, 'UNKNOWN');
  assert.equal(cancelled.runnerCleanup, 'confirmed');
  const preaborted = new AbortController(); preaborted.abort();
  await assert.rejects(runCheck({ ...data, signal: preaborted.signal }), /before launch/);
});

test('a process ignoring graceful termination is forcibly joined', async t => {
  const data = await fixture(t, 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000);');
  const receipt = await runCheck({ ...data, timeoutMs: 150 });
  assert.equal(receipt.interrupted, 'HarnessTimeout');
  assert.equal(receipt.verdict, 'UNKNOWN');
  assert.equal(receipt.runnerCleanup, 'confirmed');
  assert.equal(receipt.forcedReturn, false);
});

test('oversized output is retained only within the cap and cannot pass', async t => {
  const data = await fixture(t, 'process.stdout.write("x".repeat(4096));');
  const receipt = await runCheck({ ...data, outputLimit: 256 });
  assert.equal(receipt.outputExceeded, true);
  assert.equal(receipt.verdict, 'UNKNOWN');
  assert.ok((await readFile(resolve(data.cwd, receipt.stdout))).length <= 256);
});

test('a parent exiting with background children cannot pass', async t => {
  const data = await fixture(t, `import { spawn } from 'node:child_process';
const child = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)'], {stdio:'ignore'}); child.unref();`);
  const receipt = await runCheck(data);
  assert.equal(receipt.verdict, 'UNKNOWN');
  assert.equal(receipt.cleanup, 'unresolved');
});

test('runner does not inherit arbitrary credentials and does not interpret argv as shell', async t => {
  const secret = process.env.FENRIR_TEST_SECRET;
  process.env.FENRIR_TEST_SECRET = 'must-not-inherit';
  t.after(() => { if (secret === undefined) delete process.env.FENRIR_TEST_SECRET; else process.env.FENRIR_TEST_SECRET = secret; });
  const data = await fixture(t, `if (process.env.FENRIR_TEST_SECRET) process.exit(1); console.log(process.env.HOME);`);
  const receipt = await runCheck(data);
  assert.equal(receipt.verdict, 'PASS');
  assert.match(await readFile(resolve(data.cwd, receipt.stdout), 'utf8'), /fenrir-workflow-runs.*home/);
  data.config.checks.check.command = [process.execPath, '-e', 'process.stdout.write(process.argv[1])', '$(touch should-not-exist)'];
  const literal = await runCheck(data);
  assert.equal(await readFile(resolve(data.cwd, literal.stdout), 'utf8'), '$(touch should-not-exist)');
});

test('lease ownership fails closed; stale locks are not automatically stolen', async t => {
  const cwd = await mkdtemp(resolve(tmpdir(), 'fenrir-lease-test-'));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  const lock = await acquireLock(cwd, { runId: 'a' });
  await assert.rejects(acquireLock(cwd, { runId: 'b' }), /occupied/);
  await assert.rejects(releaseLock({ ...lock, token: 'wrong' }), /ownership/);
  await releaseLock(lock);
  await releaseLock(await acquireLock(cwd, { runId: 'b' }));
});

test('runtime outputs do not change source identity; ordinary source changes do', async t => {
  const data = await fixture(t, '');
  const before = await sourceIdentity(data.cwd, data.config);
  const directory = await privateDirectory(data.cwd, '.pi/fenrir-workflow-runs/test');
  await writeFile(resolve(directory, 'receipt.json'), '{}');
  assert.equal((await sourceIdentity(data.cwd, data.config)).hash, before.hash);
  await writeFile(resolve(data.cwd, 'new-source.mjs'), 'source');
  assert.notEqual((await sourceIdentity(data.cwd, data.config)).hash, before.hash);
});
