import { randomUUID } from 'node:crypto';
import { constants, writeFileSync } from 'node:fs';
import { access, mkdir, opendir, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { isAbsolute, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  authorityHash, checkedPath, committedJson, decode, executableIdentity, inspectFile,
  localPath, repoRelative, resolvePath, sha, sourceReader, under,
} from './identity.mjs';
import { execute } from './process.mjs';

const CONFIG = '.pi/fenrir-workflow.json';
const RUNS = 'build/evidence-runs';
// Share only the checkout lease with the controller, not approval, state or receipts.
const LOCK_ROOT = '.pi/fenrir-workflow-runs';
const gates = new Map([
  ['tc0-a-qualification', ['build/harness/gate', 'spec/tc0/tc0-a-requirements.json', 'tc0-a-gate-run/3', 'harness/gate.shen', 'harness/run-gate.sh']],
  ['tc1-qualification', ['build/harness/tc1-gate', 'spec/tc1/tc1-requirements.json', 'tc1-gate-run/1', 'harness/tc1-gate.shen', 'harness/run-tc1-gate.sh']],
]);
const statuses = new Map([['PASS', 0], ['FAIL', 1], ['UNKNOWN', 2], ['BLOCKED', 2]]);
const list = (items, limit = 64) => Array.isArray(items) && items.length <= limit &&
  new Set(items).size === items.length && items.every(x => typeof x === 'string' && x.trim() && x.length <= 4096);
const sameSet = (a, b) => a.length === b.length && a.every(value => b.includes(value));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const now = () => new Date().toISOString();

function readCheck(config, id) {
  if (config?.version !== 1 || !config.checks || !Object.hasOwn(config.checks, id)) throw new Error(`Unconfigured check: ${id}`);
  const check = config.checks[id];
  if (!check || !list(check.authorityPaths, 128) || !list(config.protectedPaths ?? [], 128) ||
      !['development', 'qualification'].includes(check.kind) ||
      !Array.isArray(check.command) || check.command.length < 1 || check.command.length > 64 ||
      check.command.some(x => typeof x !== 'string' || x.includes('\0') || x.length > 4096) ||
      !Number.isInteger(check.timeoutSeconds) || check.timeoutSeconds < 1 || check.timeoutSeconds > 3600 ||
      (check.blockedExitCode !== undefined && (check.kind !== 'development' ||
        !Number.isInteger(check.blockedExitCode) || check.blockedExitCode < 2 || check.blockedExitCode > 125)))
    throw new Error(`Invalid check configuration: ${id}`);
  if (check.kind === 'qualification' && (!gates.has(id) || !check.authorityPaths.length ||
      !same(check.command, ['sh', gates.get(id)[4]])))
    throw new Error(`No standalone adapter for evaluator: ${id}`);
  if (gates.has(id) && check.kind !== 'qualification') throw new Error('Registered evaluator must use structured reporting');
  return check;
}

async function gateDirectories(root, base) {
  let directory;
  try { directory = await opendir(await checkedPath(root, base, { directory: true })); }
  catch (error) { if (error.code === 'ENOENT') return new Set(); throw error; }
  const seen = new Set();
  let count = 0;
  for await (const entry of directory) {
    if (++count > 10_000) throw new Error('Gate output directory entry limit');
    seen.add(entry.name);
  }
  return seen;
}

async function jitIdentity(requested) {
  if (!requested || !isAbsolute(requested)) throw new Error('Supply an existing --shen-jit installation (absolute path)');
  const root = await realpath(requested);
  const entry = resolve(root, 'bin/shen-jit');
  await access(entry, constants.X_OK);
  const binary = await realpath(entry);
  const lib = await realpath(resolve(root, 'lib'));
  const library = [];
  let count = 0, bytes = 0;
  async function visit(dir, prefix) {
    const stream = await opendir(dir);
    for await (const item of stream) {
      if (++count > 4_000) throw new Error('Shen/JIT library entry limit');
      const path = resolve(dir, item.name);
      const name = prefix + item.name;
      if (item.isDirectory()) await visit(path, name + '/');
      else if (item.isFile()) {
        const file = await inspectFile(path, Math.min(32 * 1024 * 1024, 128 * 1024 * 1024 - bytes));
        bytes += file.size;
        library.push([name, file.sha256]);
      } else throw new Error(`Unsupported Shen/JIT library entry: ${name}`);
    }
  }
  await visit(lib, '');
  if (!library.length) throw new Error('Shen/JIT library is empty');
  return { root, binary, sha256: (await inspectFile(binary, 256 * 1024 * 1024)).sha256,
    lib, librarySha256: sha(JSON.stringify(library.sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0))) };
}

function frame(bytes, receipt) {
  if (!bytes) throw new Error('Evaluator stdout exceeded report limit');
  const text = decode(bytes);
  const report = JSON.parse(text);
  const allowed = ['schema', 'nonce', 'checkId', 'sourceHash', 'configHash', 'verdict', 'cleanup', 'claims', 'evidence', 'summary'];
  if (!report || Array.isArray(report) || Object.keys(report).some(k => !allowed.includes(k)) ||
      report.schema !== 'fenrir.check.v1' || !['nonce', 'checkId', 'sourceHash', 'configHash'].every(k => receipt[k] === report[k]) ||
      !statuses.has(report.verdict) || !['confirmed', 'unresolved'].includes(report.cleanup) ||
      !list(report.claims) || !list(report.evidence) || typeof report.summary !== 'string' || !report.summary.trim() ||
      report.summary.length > 8000) throw new Error('Invalid evaluator report or run identity');
  // The frame has no nested objects. Count keys in the JSON text rather than
  // accepting JSON.parse silently taking the last value of a duplicate field.
  const keys = [...text.matchAll(/"(?:[^"\\]|\\.)*"(\s*:)?/g)].filter(match => match[1]);
  if (keys.length !== Object.keys(report).length) throw new Error('Duplicate evaluator report keys');
  if (statuses.get(report.verdict) !== receipt.exitCode || receipt.exitSignal)
    throw new Error('Evaluator verdict contradicts process exit');
  if (report.verdict === 'PASS' && !report.evidence.length) throw new Error('Evaluator PASS requires fresh retained evidence');
  return report;
}

async function retain(root, directory, previous, gate, report, receipt, claims) {
  const [base, manifestPath, schema, evaluator] = gate;
  // The current stock launchers write exactly one referenced gate.json into
  // build/harness/{gate,tc1-gate}/<epoch>-<pid>, not FENRIR_ARTIFACT_DIR.
  if (report.evidence.length !== 1) throw new Error('Expected one evaluator gate report');
  const path = localPath(report.evidence[0]);
  const parts = path.split('/');
  const run = parts.at(-2);
  if (parts.slice(0, -2).join('/') !== base || !/^\d+-\d+$/.test(run) || previous.has(run) || parts.at(-1) !== 'gate.json')
    throw new Error(`Evidence is stale or outside the evaluator output directory: ${path}`);
  const file = await inspectFile(await checkedPath(root, path), 4 * 1024 * 1024, { capture: true, singleLink: true });
  const detail = JSON.parse(decode(file.bytes));
  if (detail?.schema !== schema || detail.head !== receipt.head || detail.manifest !== manifestPath ||
      detail.evaluator !== evaluator || detail.verdict !== report.verdict || detail.qualification !== report.verdict ||
      detail.authority !== 'owner-accepted, registered' || !list(detail.claims) || !sameSet(detail.claims, report.claims) ||
      report.claims.some(claim => !claims.includes(claim)))
    throw new Error('Retained gate report contradicts the evaluator frame or checked source');
  const copy = resolve(directory, 'evaluator-gate.json');
  await writeFile(copy, file.bytes, { flag: 'wx', mode: 0o600 });
  receipt.evidence = [{ sourcePath: path, retainedPath: repoRelative(root, copy), sha256: file.sha256, bytes: file.size }];
  if (report.verdict === 'PASS' && !sameSet(claims, report.claims)) throw new Error('Evaluator PASS is missing required claims');
}

export async function runEvidence({ cwd, checkId, head, shenJit, timeoutSeconds, signal, path = process.env.PATH ?? '' }) {
  if (!['linux', 'darwin'].includes(process.platform)) throw new Error('POSIX runner supported only on Linux and macOS');
  if (!/^[a-z][a-z0-9-]{0,63}$/.test(checkId) || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(head))
    throw new Error('A configured check ID and full expected HEAD are required');
  const root = await realpath(cwd);
  const PATH = await resolvePath(root, path);
  const lockDir = await checkedPath(root, LOCK_ROOT, { directory: true, create: true });
  const lock = resolve(lockDir, 'controller.lock');
  const id = randomUUID();
  const token = randomUUID();
  try { await writeFile(lock, JSON.stringify({ token, pid: process.pid, runId: id, sessionId: 'standalone-evidence' }), { flag: 'wx', mode: 0o600 }); }
  catch (error) {
    if (error.code === 'EEXIST') throw new Error(`Checkout lease occupied: ${lock}; inspect before clearing`);
    throw error;
  }
  const receipt = {
    schema: 'fenrir.standalone-evidence.v1', id, checkId, head, nonce: randomUUID(),
    scope: 'standalone-evidence-only', qualification: 'UNKNOWN', verdict: 'UNKNOWN',
    platform: process.platform, arch: process.arch, node: process.version, path: PATH,
    cleanup: 'not-launched', sourceStable: false, evidence: [], startedAt: now(),
  };
  let directory, retainLock = false;
  async function publish() {
    receipt.leaseRetained = retainLock;
    receipt.finishedAt = now();
    if (!directory) return;
    const path = repoRelative(root, directory);
    await checkedPath(root, path, { directory: true });
    receipt.receiptPath = `${path}/receipt.json`;
    const tmp = resolve(directory, `${randomUUID()}.tmp`);
    await writeFile(tmp, JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    try { await rename(tmp, resolve(root, receipt.receiptPath)); }
    finally { await rm(tmp, { force: true }); }
  }
  try {
    const runs = await checkedPath(root, RUNS, { directory: true, create: true });
    directory = resolve(runs, id);
    await mkdir(directory, { mode: 0o700 });
    const HOME = resolve(directory, 'home');
    await mkdir(HOME, { mode: 0o700 });
    const baseEnv = { PATH, HOME, TMPDIR: directory, LANG: 'C.UTF-8', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_OPTIONAL_LOCKS: '0' };
    const git = await executableIdentity('git', PATH);
    if (under(root, git.path)) throw new Error('Git resolves into the checkout');
    receipt.git = git;
    const source = sourceReader(root, git.path, baseEnv);
    const before = await source(head);
    receipt.sourceHash = before.hash;
    const { value: config, hash } = await committedJson(root, before, CONFIG);
    receipt.configHash = hash;
    const check = readCheck(config, checkId);
    receipt.command = check.command;
    receipt.kind = check.kind;
    const gate = gates.get(checkId);
    receipt.authorityHash = authorityHash(before, [CONFIG, ...(config.protectedPaths ?? []), ...check.authorityPaths,
      ...(gate ? [gate[1], gate[3], gate[4]] : []),
    ]);
    const limit = timeoutSeconds ?? check.timeoutSeconds;
    if (!Number.isInteger(limit) || limit < 1 || limit > check.timeoutSeconds) throw new Error('Timeout may only lower the configured positive bound');
    receipt.timeoutSeconds = limit;
    let previous, claims, jit;
    if (gate) {
      const { value: manifest, hash: manifestHash } = await committedJson(root, before, gate[1]);
      receipt.manifestHash = manifestHash;
      claims = Object.keys(manifest.claims ?? {});
      if (manifest.status !== 'owner-accepted' || !claims.length || !list(claims) ||
          (checkId === 'tc0-a-qualification' && (!list(config.requiredClaims) || !sameSet(config.requiredClaims, claims))))
        throw new Error('Missing or inconsistent registered evaluator claim definitions');
      previous = await gateDirectories(root, gate[0]);
      if (!shenJit) {
        receipt.verdict = 'BLOCKED';
        throw new Error('Supply --shen-jit for this evaluator; no automatic launcher bootstrap');
      }
      try { jit = await jitIdentity(shenJit); }
      catch (error) { if (['ENOENT', 'EACCES', 'ENOTDIR'].includes(error.code)) receipt.verdict = 'BLOCKED'; throw error; }
      receipt.shenJit = jit;
    } else if (shenJit) throw new Error('--shen-jit applies only to structured evaluators');
    let executable;
    try { executable = await executableIdentity(check.command[0], PATH); }
    catch (error) { if (error.message.startsWith('Executable unavailable:')) receipt.verdict = 'BLOCKED'; throw error; }
    if (under(root, executable.path)) throw new Error('Launcher resolves into the checkout');
    receipt.executable = executable;
    if (signal?.aborted) throw new Error('Cancelled before launch');
    const stdoutPath = resolve(directory, 'stdout.log');
    const stderrPath = resolve(directory, 'stderr.log');
    receipt.stdout = repoRelative(root, stdoutPath);
    receipt.stderr = repoRelative(root, stderrPath);
    retainLock = true; // On an unexpected runner exception, require human cleanup.
    receipt.cleanup = 'unresolved';
    const result = await execute({
      executable: executable.path, args: check.command.slice(1), cwd: root, stdoutPath, stderrPath,
      onSpawn: pid => writeFileSync(resolve(directory, 'launch.json'), JSON.stringify({ pid, processGroup: pid, id }),
        { flag: 'wx', mode: 0o600 }),
      timeoutMs: limit * 1000, signal, env: {
        ...baseEnv, ...(jit && { FENRIR_SHEN_JIT: jit.root }),
        FENRIR_CHECK_ID: checkId, FENRIR_CHECK_NONCE: receipt.nonce, FENRIR_SOURCE_SHA256: before.hash,
        FENRIR_CONFIG_SHA256: hash, FENRIR_ARTIFACT_DIR: directory,
      },
    });
    const { report: stdout, ...execution } = result;
    receipt.execution = execution;
    retainLock = Boolean(result.cleanupIssue);
    receipt.processGroupCleanup = retainLock ? 'unresolved' : 'confirmed';
    receipt.logs = await Promise.all([receipt.stdout, receipt.stderr].map(async path => {
      const { sha256, size } = await inspectFile(await checkedPath(root, path), 8 * 1024 * 1024, { singleLink: true });
      return { path, sha256, bytes: size };
    }));
    if (!same(git, await executableIdentity('git', PATH)) ||
        !same(executable, await executableIdentity(check.command[0], PATH)) ||
        (jit && !same(jit, await jitIdentity(shenJit)))) throw new Error('Executable or Shen/JIT identity drift');
    if ((await source(head)).hash !== before.hash) throw new Error('Source identity drift');
    receipt.sourceStable = true;
    if (result.issue || result.cleanupIssue || signal?.aborted || result.exitSignal)
      throw new Error(result.issue || result.cleanupIssue || (signal?.aborted ? 'Cancelled' : `Evaluator terminated: ${result.exitSignal}`));
    if (gate) {
      const report = frame(stdout, { ...receipt, ...execution });
      if (report.cleanup !== 'confirmed') retainLock = true;
      await retain(root, directory, previous, gate, report, receipt, claims);
      receipt.evaluator = { verdict: report.verdict, reportedClaims: report.claims, cleanup: report.cleanup, summary: report.summary };
      if (retainLock) throw new Error('Evaluator cleanup unresolved');
      receipt.verdict = report.verdict;
      receipt.summary = report.summary;
    } else {
      receipt.verdict = result.exitCode === 0 ? 'PASS' : result.exitCode === check.blockedExitCode ? 'BLOCKED' : 'FAIL';
      receipt.summary = `Development command exit ${result.exitCode}; no qualification claims`;
    }
    if (signal?.aborted) { receipt.verdict = 'UNKNOWN'; throw new Error('Cancelled before receipt publication'); }
    receipt.cleanup = 'confirmed';
  } catch (error) {
    receipt.summary = error.message;
  } finally {
    if (signal?.aborted && receipt.cleanup === 'confirmed') {
      receipt.verdict = 'UNKNOWN';
      receipt.cleanup = 'unresolved';
      receipt.summary = 'Cancelled before receipt publication';
    }
    // Retain a receipt before giving the shared checkout lease back. If
    // publishing throws, deliberately leave the lease for manual inspection.
    await publish();
    try {
      if (!retainLock) {
        if (JSON.parse(await readFile(await checkedPath(root, `${LOCK_ROOT}/controller.lock`), 'utf8')).token !== token)
          throw new Error('Checkout lease ownership changed');
        await rm(lock);
      }
    } catch (error) {
      retainLock = true;
      receipt.verdict = 'UNKNOWN';
      receipt.cleanup = 'unresolved';
      receipt.summary = error.message;
      await publish();
    }
  }
  if (!directory) throw new Error(receipt.summary);
  return receipt;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const controller = new AbortController();
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => controller.abort());
  try {
    if (fileURLToPath(import.meta.url) !== resolve(await realpath(process.cwd()), 'tools/evidence/run.mjs'))
      throw new Error('Invoke the runner from the same checkout being checked');
    const [checkId, ...args] = process.argv.slice(2);
    const options = {};
    const names = new Map([['--head', 'head'], ['--shen-jit', 'shenJit'], ['--timeout-seconds', 'timeoutSeconds']]);
    for (let i = 0; i < args.length; i += 2) {
      const name = names.get(args[i]);
      if (!name || Object.hasOwn(options, name) || !args[i + 1]) throw new Error('Invalid CLI arguments');
      options[name] = name === 'timeoutSeconds' ? Number(args[i + 1]) : args[i + 1];
    }
    const receipt = await runEvidence({ cwd: process.cwd(), checkId, ...options, signal: controller.signal });
    console.log(JSON.stringify(receipt, null, 2));
    process.exitCode = statuses.get(receipt.verdict);
  } catch (error) {
    console.error(`UNKNOWN: ${error.message}\nUsage: node tools/evidence/run.mjs CHECK --head FULL_COMMIT [--shen-jit /existing/install] [--timeout-seconds N]`);
    process.exitCode = 2;
  }
}
