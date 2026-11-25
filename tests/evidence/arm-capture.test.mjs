import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { ARM_SPEC, captureBinding, readArmFrame, retainArmReports, validateArmReport } from '../../tools/evidence/arm-capture.mjs';
import { sha } from '../../tools/evidence/identity.mjs';
import { runEvidence } from '../../tools/evidence/run.mjs';

const receiptBase = { head: '1'.repeat(40), nonce: 'test-run', sourceHash: 'a'.repeat(64) };
const profile = 'b'.repeat(64), g1Hash = 'c'.repeat(64), tc1Hash = 'd'.repeat(64);
const binding = captureBinding('tc1', receiptBase, profile, tc1Hash, g1Hash);
const child = captureBinding('nested-g1', receiptBase, profile, g1Hash, g1Hash);
const row = (id, status = 'PASS', detail = {}) => ({ id, status, required: true, detail });
const manifests = { g1: { rows: [row('source-identity')] }, tc1: { rows: [row('source-identity'), row('tc0-a-gate')] } };
const marker = frame => Buffer.from(`diagnostics\nFENRIR_ARM_CAPTURE ${JSON.stringify(frame)}\n`);
const frameFor = (hash, verdict = 'PASS') => ({ schema: 'fenrir.arm-development-frame/1', binding, report_sha256: hash, verdict });
const base = (role, capture, rows, verdict = 'PASS') => {
  const [manifest, schema, evaluator] = ARM_SPEC[role];
  return { schema, manifest, evaluator, head: receiptBase.head, capture, verdict, authority: 'UNREGISTERED',
    qualification: 'UNKNOWN', claims: [], waivers: [], rows,
    runner: { uname_sm: 'Linux aarch64\n', uname_exit: '0', legacy_qualification_platform: false } };
};

test('capture frame binds one exit, nonce, source, profile and manifest pair', () => {
  const frame = frameFor('e'.repeat(64));
  const bytes = marker(frame);
  assert.deepEqual(readArmFrame(bytes, binding, 0), frame);
  assert.throws(() => readArmFrame(bytes, binding, 1), /Invalid ARM/);
  assert.throws(() => readArmFrame(Buffer.concat([bytes, bytes]), binding, 0), /Expected one/);
  for (const key of Object.keys(binding))
    assert.throws(() => readArmFrame(marker({ ...frame, binding: { ...binding, [key]: 'wrong' } }), binding, 0), /Invalid ARM/);
  assert.throws(() => readArmFrame(Buffer.from(bytes.toString().replace('"verdict":"PASS"', '"verdict":"FAIL","verdict":"PASS"')), binding, 0), /Invalid ARM/);
});

test('invalid required row inventories, authorities, and aggregations cannot pass', () => {
  const args = { role: 'nested-g1', receipt: receiptBase, binding: child, manifest: manifests.g1 };
  const report = base('g1', child, [row('source-identity')]);
  validateArmReport(report, args);
  for (const changes of [
    { authority: 'owner-accepted, registered' }, { claims: ['fake-claim'] }, { qualification: 'PASS' },
    { rows: [] }, { rows: [...report.rows, ...report.rows] }, { rows: [row('source-identity', 'DEFERRED')] },
    { rows: [row('source-identity', 'BLOCKED')] }, { rows: [row('source-identity'), row('outside-manifest')] },
  ]) assert.throws(() => validateArmReport({ ...report, ...changes }, args));
});

test('TC1 retains exact matching nested G1 bytes, never an old run or changed report', async t => {
  const root = mkdtempSync(join(tmpdir(), 'fenrir-arm-capture-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  async function capture(nested, { staleDigest, staleTop, omitG1, rowStatus = nested.verdict } = {}) {
    const directory = mkdtempSync(join(root, 'run-'));
    mkdirSync(join(directory, 'tc0-a-gate'));
    const nestedText = JSON.stringify(nested);
    const digest = sha(nestedText);
    const top = base('tc1', binding, [row('source-identity'),
      row('tc0-a-gate', rowStatus, { report_sha256: staleDigest ? 'f'.repeat(64) : digest })], rowStatus);
    const topText = JSON.stringify(top);
    writeFileSync(join(directory, 'gate.json'), topText);
    if (!omitG1) writeFileSync(join(directory, 'tc0-a-gate/gate.json'), nestedText);
    const receipt = { ...receiptBase, qualification: 'UNKNOWN' };
    await retainArmReports(root, directory, receipt, frameFor(staleTop ? digest : sha(topText), top.verdict), binding, manifests);
    return receipt;
  }
  const nested = base('g1', child, [row('source-identity')]);
  const receipt = await capture(nested);
  assert.equal(receipt.qualification, 'UNKNOWN');
  assert.deepEqual(receipt.evaluator.reportedClaims, []);
  assert.equal(receipt.evidence.length, 2);
  assert.equal(receipt.evidence[1].sha256, sha(JSON.stringify(nested)));
  for (const key of ['nonce', 'role', 'manifest_sha256', 'source_sha256', 'profile_sha256'])
    await assert.rejects(capture({ ...nested, capture: { ...child, [key]: 'stale' } }), /nested-g1 report identity/);
  await assert.rejects(capture(nested, { staleDigest: true }), /same-run G1/);
  await assert.rejects(capture(nested, { staleTop: true }), /contradicts/);
  await assert.rejects(capture(nested, { rowStatus: 'FAIL' }), /same-run G1/);
  await assert.rejects(capture(nested, { omitG1: true }), /ENOENT/);
});

test('capture does not accept a caller-selected Shen/JIT install', async () => {
  await assert.rejects(runEvidence({ cwd: process.cwd(), head: receiptBase.head, checkId: 'arm-development-tc1',
    shenJit: '/tmp/custom' }), /preflight-pinned/);
});

test('actual Shen TC1 dispatch binds a fresh nested G1 in development mode', {
  skip: !process.env.FENRIR_SHEN_JIT && 'set FENRIR_SHEN_JIT to an existing Shen/JIT 0.12 install',
}, async t => {
  // Exercise the real two Shen entry points with tiny fixture manifests. Only
  // platform observation is mocked; no fixture row executes candidate code.
  const scratch = realpathSync(mkdtempSync(join(tmpdir(), 'fenrir-arm-shen-')));
  t.after(() => rmSync(scratch, { recursive: true, force: true }));
  const root = join(scratch, 'source');
  const bin = join(scratch, 'bin');
  const out = join(scratch, 'out');
  const write = (path, text, opts) => {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text, opts);
  };
  for (const file of ['harness/gate-core.shen', 'harness/common.shen', 'harness/jit-process.shen', 'harness/gate.shen', 'harness/tc1-gate.shen',
    'harness/tc1-random-rows.shen', 'harness/tc1-random-guest.shen', 'harness/tc1-remote-rows.shen',
    'models/tc0/i64.shen', 'models/tc0/pure-call-machine.shen', 'models/tc1/handler-machine.shen']) {
    const dest = join(root, file);
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(new URL(`../../${file}`, import.meta.url), dest);
  }
  write(join(bin, 'uname'), "#!/bin/sh\nprintf 'Linux aarch64\\n'\n", { mode: 0o755 });
  write(join(root, 'campaigns/arm64/profile-v1.json'), '{}');
  write(join(root, 'ledger.json'), '{"rows":[]}');
  const scopes = {};
  for (const [role, schema] of [['g1', 'tc0-a-requirement-manifest/1'], ['tc1', 'tc1-requirement-manifest/1']]) {
    const rows = manifests[role].rows.map(({ id, required }) => ({ id, required, check: id, ledger: [] }));
    scopes[role] = { schema, status: 'owner-accepted', ledger: 'ledger.json', aggregation: 'fixture', rows,
      claims: { test: ['source-identity'] }, claim_prerequisites: ['source-identity'] };
    write(join(root, ARM_SPEC[role][0]), JSON.stringify(scopes[role]));
  }
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim();
  git('init', '-q');
  git('add', '.');
  git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
    '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture');
  const receipt = { ...receiptBase, head: git('rev-parse', 'HEAD'), qualification: 'UNKNOWN' };
  const arm = captureBinding('tc1', receipt, sha('{}'), sha(JSON.stringify(scopes.tc1)), sha(JSON.stringify(scopes.g1)));
  const lib = join(process.env.FENRIR_SHEN_JIT, 'lib');
  const jit = join(process.env.FENRIR_SHEN_JIT, 'bin/shen-jit');
  const run = (directory, expected) => {
    mkdirSync(directory);
    return spawnSync(jit, ['script', join(root, ARM_SPEC.tc1[2]), lib, root, directory, jit, 'arm-development/1', ...Object.values(expected)],
      { cwd: root, env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, timeout: 15_000 });
  };
  const passed = run(out, arm);
  assert.equal(passed.status, 0, passed.stdout?.toString().slice(-3000) + passed.stderr?.toString());
  await retainArmReports(scratch, out, receipt, readArmFrame(passed.stdout, arm, passed.status), arm, scopes);
  assert.equal(receipt.evidence.length, 2);
  assert.equal(receipt.qualification, 'UNKNOWN');
  const nested = JSON.parse(readFileSync(join(out, 'evaluator-nested-g1.json'), 'utf8'));
  assert.equal(nested.capture.role, 'nested-g1');
  assert.equal(nested.capture.nonce, arm.nonce);
  const wrong = run(join(scratch, 'wrong'), { ...arm, g1_manifest_sha256: 'd'.repeat(64) });
  assert.notEqual(wrong.status, 0);
  assert.match(wrong.stderr.toString(), /ARM development platform, profile or manifest mismatch/);
});
