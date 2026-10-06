import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';
import { realpath } from 'node:fs/promises';
import { finished } from 'node:stream/promises';
import { randomUUID } from 'node:crypto';
import { relative, resolve } from 'node:path';
import {
  RUN_ROOT, atomicJson, evidenceReferences, executableIdentity, privateDirectory,
  protectedIdentity, sourceIdentity, sha,
} from './storage.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
export function processGroupAlive(pid) {
  if (pid !== undefined && pid !== null && (!Number.isSafeInteger(pid) || pid <= 1)) throw new Error('Invalid recorded process-group identity');
  if (!pid) return false;
  try { process.kill(-pid, 0); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}
function killGroup(pid, signal) {
  if (!pid) return;
  try { process.kill(-pid, signal); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
}
function reportFrom(stdout, expected) {
  const report = JSON.parse(stdout);
  const allowed = ['schema', 'nonce', 'checkId', 'sourceHash', 'configHash', 'verdict', 'cleanup', 'claims', 'evidence', 'summary'];
  if (!report || Array.isArray(report) || Object.keys(report).some(k => !allowed.includes(k)) ||
      report.schema !== 'fenrir.check.v1' || report.nonce !== expected.nonce ||
      report.checkId !== expected.checkId || report.sourceHash !== expected.sourceHash ||
      report.configHash !== expected.configHash || !['PASS', 'FAIL', 'UNKNOWN', 'BLOCKED'].includes(report.verdict) ||
      !['confirmed', 'unresolved'].includes(report.cleanup) ||
      typeof report.summary !== 'string' || !report.summary.trim() || report.summary.length > 8000) throw new Error('Invalid or incompatible evaluator report');
  for (const key of ['claims', 'evidence']) {
    if (!Array.isArray(report[key]) || report[key].length > 64 || new Set(report[key]).size !== report[key].length ||
        report[key].some(x => typeof x !== 'string' || !x.trim() || x.length > 4096)) throw new Error(`Invalid evaluator ${key}`);
  }
  if (report.verdict === 'PASS' && !report.evidence.length) throw new Error('Qualification PASS requires retained evidence');
  return report;
}
/** Synchronous-to-caller runner. It never backgrounds commands or accepts shell text. */
export async function runCheck({ cwd, state, config, checkId, signal, onUpdate, timeoutMs, outputLimit = 8 * 1024 * 1024 }) {
  cwd = await realpath(cwd); // Match child process.cwd(), including macOS /var → /private/var.
  if (!Object.hasOwn(config.checks, checkId)) throw new Error(`Unconfigured check: ${checkId}. Human approval of evaluator commands is required.`);
  if (process.platform === 'win32') throw new Error('Process-group cleanup is not implemented for Windows; no qualification claim');
  if (signal?.aborted) throw new Error('Check cancelled before launch');
  const check = config.checks[checkId];
  const id = randomUUID();
  const nonce = randomUUID();
  const directory = await privateDirectory(cwd, `${RUN_ROOT}/${sha(state.sessionId).slice(0, 16)}/${state.id}/checks/${id}`);
  const home = await privateDirectory(cwd, `${relative(cwd, directory)}/home`);
  const stdoutPath = resolve(directory, 'stdout.log');
  const stderrPath = resolve(directory, 'stderr.log');
  const before = await sourceIdentity(cwd, config);
  const authority = await protectedIdentity(cwd, config);
  if (authority.hash !== state.protectedHash) throw new Error('Evaluator authority drift before execution');
  const executable = await executableIdentity(check.command[0], cwd);
  const stdoutLog = createWriteStream(stdoutPath, { flags: 'wx', mode: 0o600 });
  const stderrLog = createWriteStream(stderrPath, { flags: 'wx', mode: 0o600 });
  // Attach rejection handlers now, before a filesystem error can become unhandled.
  const stdoutFinished = finished(stdoutLog); stdoutFinished.catch(() => {});
  const stderrFinished = finished(stderrLog); stderrFinished.catch(() => {});
  let child, timer, killTimer, forcedTimer, forceJoin;
  let interrupted = null, spawnError = null, logError = null, cleanupError = null, forcedReturn = false;
  let captured = [], capturedBytes = 0, bytes = 0, outputExceeded = false;
  const interrupt = reason => {
    interrupted ||= reason;
    try { killGroup(child?.pid, 'SIGTERM'); } catch (error) { cleanupError ||= error; }
    killTimer ||= setTimeout(() => {
      try { killGroup(child?.pid, 'SIGKILL'); } catch (error) { cleanupError ||= error; }
      // Escaped descendants can keep inherited pipes open even after the parent exited.
      child?.stdout?.destroy(); child?.stderr?.destroy();
      forcedTimer = setTimeout(() => { forcedReturn = true; forceJoin?.(); }, 500);
    }, 500);
  };
  const abort = () => interrupt('Cancelled');
  const logFailure = error => { logError = error; interrupt('LogError'); };
  stdoutLog.on('error', logFailure); stderrLog.on('error', logFailure);
  let exitCode = null, exitSignal = null, runnerCleanup = 'unresolved', strayProcess = false;
  try {
    child = spawn(executable.path, check.command.slice(1), {
      cwd, detached: true, shell: false, stdio: ['ignore', 'pipe', 'pipe'],
      env: {
        PATH: process.env.PATH || '', HOME: home, TMPDIR: directory, LANG: 'C.UTF-8',
        FENRIR_CHECK_NONCE: nonce, FENRIR_CHECK_ID: checkId,
        FENRIR_SOURCE_SHA256: before.hash, FENRIR_CONFIG_SHA256: state.configHash,
        FENRIR_ARTIFACT_DIR: directory,
      },
    });
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
    const consume = (data, log, capture) => {
      const remaining = Math.max(0, outputLimit - bytes);
      bytes += data.length;
      const kept = data.subarray(0, remaining);
      if (kept.length) log.write(kept);
      if (capture && capturedBytes < 512 * 1024) {
        const part = kept.subarray(0, 512 * 1024 - capturedBytes);
        captured.push(part); capturedBytes += part.length;
      }
      if (bytes > outputLimit) { outputExceeded = true; interrupt('OutputLimit'); }
    };
    child.stdout.on('data', data => consume(data, stdoutLog, true));
    child.stderr.on('data', data => consume(data, stderrLog, false));
    const exited = new Promise(resolve => {
      child.on('error', error => { spawnError = error; });
      child.on('close', (code, signal) => { exitCode = code; exitSignal = signal; resolve(); });
    });
    timer = setTimeout(() => interrupt('HarnessTimeout'), timeoutMs ?? check.timeoutSeconds * 1000);
    onUpdate?.(`Running approved ${check.kind} check ${checkId}; logs: ${relative(cwd, directory)}`);
    const boundedJoin = new Promise(resolve => { forceJoin = resolve; });
    await Promise.race([exited, boundedJoin]);
  } finally {
    clearTimeout(timer); clearTimeout(killTimer); clearTimeout(forcedTimer); signal?.removeEventListener('abort', abort);
    // A successful parent exit is not permission to leave its process group alive.
    try {
      if (processGroupAlive(child?.pid)) {
        strayProcess = !interrupted;
        killGroup(child.pid, 'SIGKILL');
        for (let i = 0; i < 30 && processGroupAlive(child.pid); i++) await sleep(50);
      }
      runnerCleanup = processGroupAlive(child?.pid) || forcedReturn || cleanupError ? 'unresolved' : 'confirmed';
    } catch (error) { cleanupError ||= error; runnerCleanup = 'unresolved'; }
    if (runnerCleanup !== 'confirmed') child?.unref();
    stdoutLog.end(); stderrLog.end();
    try { await Promise.all([stdoutFinished, stderrFinished]); }
    catch (error) { logError ||= error; }
  }
  let sourceStable = false, evidenceStable = false, refs = [], claims = [];
  let verdict = 'UNKNOWN', cleanup = runnerCleanup, summary;
  try {
    const after = await sourceIdentity(cwd, config);
    const authorityAfter = await protectedIdentity(cwd, config);
    const executableAfter = await executableIdentity(executable.path, cwd);
    sourceStable = before.hash === after.hash && authority.hash === authorityAfter.hash && executable.sha256 === executableAfter.sha256;
    if (interrupted || spawnError || logError || cleanupError || forcedReturn || outputExceeded || strayProcess || runnerCleanup !== 'confirmed' || !sourceStable) {
      summary = interrupted || spawnError?.message || logError?.message || cleanupError?.message || (strayProcess ? 'Runner left background processes' : !sourceStable ? 'Source/evaluator/executable changed during check' : 'Cleanup unresolved');
      cleanup = 'unresolved'; // Process cleanup alone cannot establish evaluator/fixture teardown.
    } else if (check.kind === 'development') {
      verdict = exitCode === 0 && !exitSignal ? 'PASS' : 'FAIL';
      summary = `Development command exit ${exitCode ?? exitSignal}; not a language qualification verdict`;
      evidenceStable = true;
    } else {
      const report = reportFrom(Buffer.concat(captured).toString('utf8'), { nonce, checkId, sourceHash: before.hash, configHash: state.configHash });
      const consistentExit = (report.verdict === 'PASS' && exitCode === 0 && !exitSignal) ||
        (report.verdict === 'FAIL' && exitCode === 1 && !exitSignal) ||
        (['UNKNOWN', 'BLOCKED'].includes(report.verdict) && exitCode === 2 && !exitSignal);
      if (!consistentExit) throw new Error('Evaluator verdict contradicts process exit; PASS=0, FAIL=1, UNKNOWN/BLOCKED=2 required');
      refs = await evidenceReferences(cwd, report.evidence);
      claims = report.claims; verdict = report.verdict; cleanup = report.cleanup; summary = report.summary;
      evidenceStable = true;
    }
  } catch (error) { summary = error.message; verdict = 'UNKNOWN'; }
  const receipt = {
    version: 1, id, runId: state.id, checkId, kind: check.kind, phase: state.phase,
    configHash: state.configHash, protectedHash: state.protectedHash, sourceHash: before.hash,
    sourceStable, evidenceStable, executable, command: [...check.command],
    verdict, cleanup, runnerCleanup, claims, evidence: refs, exitCode, exitSignal,
    interrupted, outputExceeded, forcedReturn, summary, pid: child?.pid ?? null, processGroup: child?.pid ?? null, recordedAt: Date.now(),
    stdout: relative(cwd, stdoutPath), stderr: relative(cwd, stderrPath),
  };
  await atomicJson(resolve(directory, 'receipt.json'), receipt);
  return receipt;
}
