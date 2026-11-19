// Development only. This command never starts a gate, builds a guest, or credits a claim.
import { spawnSync } from 'node:child_process';
import { constants } from 'node:fs';
import { access, readFile, realpath } from 'node:fs/promises';
import { release } from 'node:os';
import { resolve } from 'node:path';
import { SANDBOX_ENV } from '../tc0/sandbox.mjs';
import { committedJson, executableIdentity, resolvePath, sourceReader, under } from './identity.mjs';

export const PROFILE = 'campaigns/arm64/profile-v1.json';
const TARGETS = new Map([
  ['g1', ['shen-jit', 'solo5']],
  ['tc1', ['shen-jit', 'solo5', 'erlang']],
]);
const FULL_HEAD = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

export function profileProblems(profile, snapshot, manifests, gate) {
  const problems = [];
  if (profile?.schema !== 'fenrir.arm64-qualification-proposal/1' ||
      profile.id !== 'fenrir-g1-tc1-aarch64-linux-spt/1' || profile.status !== 'proposed' ||
      profile.platform !== 'linux' || profile.nodeArch !== 'arm64' || profile.kernelMachine !== 'aarch64' ||
      profile.nixSystem !== 'aarch64-linux' || profile.solo5Abi !== 'spt')
    problems.push('Not the proposed native ARM64 Linux SPT profile');
  for (const key of TARGETS.keys()) {
    if (key === 'tc1' && gate !== 'tc1') continue;
    const entry = profile?.manifests?.[key];
    const parsed = manifests[key];
    if (!entry || !parsed || snapshot.files.get(entry.path)?.[1] !== entry.sha256 ||
        !Array.isArray(parsed.rows) || parsed.rows.filter(row => row.required === true).length !== entry.requiredRows ||
        parsed.rows.filter(row => row.required === false).length !== entry.optionalRows ||
        Object.keys(parsed.claims ?? {}).length !== entry.claims)
      problems.push(`${key} manifest not the pinned scope`);
  }
  return problems;
}

export function nixPackagePath(stdout) {
  const path = stdout.trim();
  return /^\/nix\/store\/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+$/.test(path) ? path : null;
}

const REQUIRED = {
  'shen-jit': ['bin/shen-jit'],
  solo5: ['bin/solo5-spt', 'bin/solo5-elftool', 'bin/aarch64-solo5-none-static-cc', 'bin/aarch64-solo5-none-static-ld'],
  erlang: ['bin/erl', 'bin/erlc'],
};

async function installedOutput(name, path, solo5Commit) {
  if (await realpath(path) !== path) throw new Error('Pinned output is not a canonical store directory');
  const description = { path, tools: {} };
  for (const file of REQUIRED[name]) {
    const entry = resolve(path, file);
    await access(entry, constants.X_OK);
    const actual = await realpath(entry);
    if (!under('/nix/store', actual)) throw new Error(`${file} resolves outside the store`);
    description.tools[file] = actual;
  }
  if (name === 'shen-jit') await access(resolve(path, 'lib'), constants.R_OK | constants.X_OK);
  if (name === 'solo5' && (await readFile(resolve(path, 'SOLO5_COMMIT'), 'utf8')).trim() !== solo5Commit)
    throw new Error('Solo5 source marker does not match the profile');
  return description;
}

export async function preflight({ cwd, head, gate, path = process.env.PATH ?? '' }) {
  if (!TARGETS.has(gate) || !FULL_HEAD.test(head ?? '')) throw new Error('Expected g1 or tc1 and a full commit ID');
  const report = {
    schema: 'fenrir.arm64-preflight/1', scope: 'development-preflight-only', gate, qualification: 'UNKNOWN',
    requestedHead: head, host: { platform: process.platform, arch: process.arch, kernelRelease: release(), node: process.version },
    sourceStable: false, checks: [],
  };
  const add = (id, status, detail) => report.checks.push({ id, status, detail });
  const finish = () => {
    report.status = report.checks.some(r => r.status === 'UNKNOWN') ? 'UNKNOWN'
      : report.checks.some(r => r.status === 'BLOCKED') ? 'BLOCKED' : 'READY-FOR-DEVELOPMENT';
    return report;
  };
  let root, env, source, snapshot, profile;
  try {
    root = await realpath(cwd);
    env = { PATH: await resolvePath(root, path), LC_ALL: 'C',
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_OPTIONAL_LOCKS: '0' };
    const git = await executableIdentity('git', env.PATH);
    if (under(root, git.path)) throw new Error('Git resolves into the checkout');
    source = sourceReader(root, git.path, env);
    snapshot = await source(head);
    const committed = await committedJson(root, snapshot, PROFILE);
    profile = committed.value;
    if (!profile || typeof profile !== 'object') throw new Error('Invalid profile');
    const manifests = {};
    for (const id of gate === 'tc1' ? ['g1', 'tc1'] : ['g1']) {
      const spec = profile.manifests?.[id];
      if (spec) manifests[id] = (await committedJson(root, snapshot, spec.path)).value;
    }
    const problems = profileProblems(profile, snapshot, manifests, gate);
    if (problems.length) throw new Error(problems.join('; '));
    const flakeHashes = ['flake.nix', 'flake.lock'].map(file => snapshot.files.get(file)?.[1]);
    if (flakeHashes.some(hash => !hash)) throw new Error('Missing tracked flake or lock');
    report.source = {
      head: snapshot.head, sha256: snapshot.hash, git, profileSha256: committed.hash,
      flakeSha256: flakeHashes[0], flakeLockSha256: flakeHashes[1],
      manifests: Object.fromEntries(Object.keys(manifests).map(id => [id, profile.manifests[id].sha256])),
    };
    add('source-and-scope', 'PASS', profile.id);
  } catch (error) {
    add('source-and-scope', 'UNKNOWN', error.message);
    return finish();
  }

  const command = (exe, args, childEnv = env, timeout = 10_000) =>
    spawnSync(exe, args, { cwd: root, env: childEnv, timeout, maxBuffer: 128 * 1024,
      killSignal: 'SIGKILL', encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const uname = command('uname', ['-m']);
  report.host.kernelMachine = uname.status === 0 ? uname.stdout.trim() : null;
  if (report.host.platform !== profile.platform || report.host.arch !== profile.nodeArch ||
      report.host.kernelMachine !== profile.kernelMachine) {
    add('platform', 'BLOCKED', 'Run natively on aarch64 Linux (not macOS or user-mode emulation)');
  } else {
    add('platform', 'PASS', 'Linux Node arm64; uname reports aarch64 (record runner provenance separately)');
    const node = /^v22\.(\d+)\./.exec(process.version);
    add('node-22', node && Number(node[1]) >= 19 ? 'PASS' : 'BLOCKED', process.version);
    for (const [id, childEnv] of [['outer', env], ['candidate', SANDBOX_ENV]]) {
      const probe = command('unshare', ['-n', '--', 'true'], childEnv);
      add(`network-namespace-${id}`, probe.status === 0 ? 'PASS' : 'BLOCKED',
        probe.status === 0 ? 'unshare -n succeeded' : probe.error?.code ?? probe.stderr?.trim().slice(0, 500));
    }
    for (const packageName of TARGETS.get(gate)) {
      const result = command('nix', ['eval', '--raw', '--no-update-lock-file', '--no-write-lock-file',
        '--option', 'allow-import-from-derivation', 'false',
        `.#packages.${profile.nixSystem}.${packageName}.outPath`], env, 30_000);
      const pinned = result.status === 0 && nixPackagePath(result.stdout);
      try {
        if (!pinned) throw new Error(result.error?.code ?? (result.stderr?.trim().slice(0, 500) || 'No canonical Nix store output'));
        add(`output-${packageName}`, 'PASS', await installedOutput(packageName, pinned, profile.solo5Commit));
      } catch (error) {
        add(`output-${packageName}`, 'BLOCKED', { path: pinned || null, reason: error.message });
      }
    }
  }
  try {
    if ((await source(head)).hash !== snapshot.hash) throw new Error('Source changed during preflight');
    report.sourceStable = true;
  } catch (error) { add('source-stability', 'UNKNOWN', error.message); }
  return finish();
}

async function main() {
  const [gate, option, head, ...extra] = process.argv.slice(2);
  if (!TARGETS.has(gate) || option !== '--head' || !FULL_HEAD.test(head ?? '') || extra.length)
    throw new Error('Usage: node tools/evidence/arm64-preflight.mjs {g1|tc1} --head FULL_COMMIT');
  const report = await preflight({ cwd: process.cwd(), head, gate });
  console.log(JSON.stringify(report, null, 2));
  if (report.status !== 'READY-FOR-DEVELOPMENT') process.exitCode = 2;
}

if (process.argv[1] && resolve(process.argv[1]) === import.meta.filename) {
  main().catch(error => { console.error(error.message); process.exitCode = 2; });
}
