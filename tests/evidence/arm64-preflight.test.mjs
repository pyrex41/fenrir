import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { nixPackagePath, preflight, PROFILE, profileProblems } from '../../tools/evidence/arm64-preflight.mjs';
import { sha } from '../../tools/evidence/identity.mjs';

const root = new URL('../../', import.meta.url);
const bytes = file => readFileSync(new URL(file, root));
const profile = JSON.parse(bytes(PROFILE));
const entries = Object.entries(profile.manifests);
const manifests = Object.fromEntries(entries.map(([id, { path }]) => [id, JSON.parse(bytes(path))]));
const files = new Map(entries.map(([, { path }]) => [path, ['100644', sha(bytes(path))]]));

test('the proposed ARM64 scope pins the actual stock manifests without changing their status', () => {
  assert.deepEqual(profileProblems(profile, { files }, manifests, 'tc1'), []);
  assert.equal(manifests.g1.status, 'owner-accepted');
  assert.equal(manifests.tc1.status, 'owner-accepted');
  assert.notDeepEqual(profileProblems({ ...profile, status: 'owner-accepted' }, { files }, manifests, 'tc1'), []);
  assert.notDeepEqual(profileProblems({ ...profile, solo5Abi: 'hvt' }, { files }, manifests, 'tc1'), []);
  const mismatch = new Map(files);
  mismatch.set(profile.manifests.tc1.path, ['100644', 'f'.repeat(64)]);
  assert.deepEqual(profileProblems(profile, { files: mismatch }, manifests, 'tc1'), ['tc1 manifest not the pinned scope']);
  assert.deepEqual(profileProblems(profile, { files: mismatch }, manifests, 'g1'), []);
  const g1 = structuredClone(manifests.g1);
  g1.rows[0].required = false;
  assert.deepEqual(profileProblems(profile, { files }, { ...manifests, g1 }, 'tc1'), ['g1 manifest not the pinned scope']);
});

test('only a single canonical Nix store output is accepted', () => {
  const pinned = `/nix/store/${'0'.repeat(32)}-foo-0.7`;
  assert.equal(nixPackagePath(pinned + '\n'), pinned);
  for (const wrong of ['', '/tmp/solo5', `${pinned}\n${pinned}`, `${pinned}/bin/solo5-spt`, pinned.replace('/0', '/e')])
    assert.equal(nixPackagePath(wrong), null, wrong);
});

test('clean source-bound preflight never promotes qualification; dirty and wrong HEAD are unknown', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'fenrir-arm64-preflight-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const path of [PROFILE, 'flake.nix', 'flake.lock', ...files.keys()]) {
    mkdirSync(dirname(join(dir, path)), { recursive: true });
    cpSync(new URL(path, root), join(dir, path));
  }
  // Don't let this test consult nix or unshare on an ARM64 Linux runner.
  const bin = mkdtempSync(join(tmpdir(), 'fenrir-arm64-preflight-bin-'));
  t.after(() => rmSync(bin, { recursive: true, force: true }));
  for (const cmd of ['nix', 'unshare']) writeFileSync(join(bin, cmd), '#!/bin/sh\nexit 127\n', { mode: 0o755 });
  const git = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-q');
  git('add', '.');
  git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
    '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture');
  const head = git('rev-parse', 'HEAD');
  const options = { cwd: dir, head, gate: 'tc1', path: `${bin}:/usr/bin:/bin` };
  const report = await preflight(options);
  assert.equal(report.qualification, 'UNKNOWN');
  assert.equal(report.status, 'BLOCKED');
  assert.equal(report.sourceStable, true);
  assert.equal(report.source.head, head);
  assert.equal(report.source.profileSha256, sha(bytes(PROFILE)));
  assert.deepEqual(report.source.manifests, Object.fromEntries(entries.map(([id, v]) => [id, v.sha256])));
  assert.equal(Object.hasOwn(report, 'claims'), false);
  const wrong = await preflight({ ...options, head: 'a'.repeat(head.length) });
  assert.equal(wrong.status, 'UNKNOWN');
  assert.match(wrong.checks[0].detail, /HEAD drift/);
  writeFileSync(join(dir, 'untracked'), 'dirty');
  const dirty = await preflight(options);
  assert.equal(dirty.status, 'UNKNOWN');
  assert.match(dirty.checks[0].detail, /Expected clean source/);
});
