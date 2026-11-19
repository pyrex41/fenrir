import { spawn } from 'node:child_process';
import { open } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';

const OUTPUT_LIMIT = 8 * 1024 * 1024;
const REPORT_LIMIT = 512 * 1024;

function group(pid, signal = 0) {
  if (!pid) return false;
  try { process.kill(-pid, signal); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}

// Captured output is capped in memory and on disk. Keep separate stdout/stderr
// files; stdout is the evaluator protocol, not a log stream to search for PASS.
export async function execute({ executable, args, cwd, env, timeoutMs, signal, stdoutPath, stderrPath, onSpawn }) {
  let stdoutFile, stderrFile;
  try {
    stdoutFile = await open(stdoutPath, 'wx', 0o600);
    stderrFile = await open(stderrPath, 'wx', 0o600);
    if (signal?.aborted) throw new Error('Cancelled before launch');
    const child = spawn(executable, args, { cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'], shell: false });
    const pid = child.pid ?? null;
    let timeout, hardKill, forcedJoin, join;
    let exitCode = null, exitSignal = null, issue = null, cleanupIssue = null, forced = false;
    let outputBytes = 0, stdoutBytes = 0;
    const stdout = [], stderr = [];
    const stop = reason => {
      if (issue) return;
      issue = reason;
      try { group(pid, 'SIGTERM'); } catch (error) { cleanupIssue = error.message; }
      hardKill = setTimeout(() => {
        try { group(pid, 'SIGKILL'); } catch (error) { cleanupIssue = error.message; }
        if (child.exitCode !== null || child.signalCode !== null)
          cleanupIssue ??= 'Output pipes remained open after evaluator exit; inspect for escaped descendants';
        child.stdout.destroy();
        child.stderr.destroy();
        forcedJoin = setTimeout(() => { forced = true; join(); }, 500);
      }, 500);
    };
    const abort = () => stop('Cancelled');
    const collect = (data, buffers) => {
      const keep = Math.min(data.length, Math.max(0, OUTPUT_LIMIT - outputBytes));
      if (keep) buffers.push(data.subarray(0, keep));
      outputBytes += data.length;
      if (buffers === stdout) stdoutBytes += data.length;
      if (outputBytes > OUTPUT_LIMIT) stop('Output limit exceeded');
    };
    const closed = new Promise(resolve => {
      child.on('error', error => stop(`Launch failed: ${error.message}`));
      child.on('close', (code, sig) => { exitCode = code; exitSignal = sig; resolve(); });
    });
    child.stdout.on('data', data => collect(data, stdout));
    child.stderr.on('data', data => collect(data, stderr));
    child.stdout.on('error', error => stop(`stdout: ${error.message}`));
    child.stderr.on('error', error => stop(`stderr: ${error.message}`));
    timeout = setTimeout(() => stop('Watchdog expired'), timeoutMs);
    signal?.addEventListener('abort', abort, { once: true });
    try { if (pid) onSpawn(pid); }
    catch (error) { stop(`Could not record process group: ${error.message}`); }
    if (signal?.aborted) abort();
    await Promise.race([closed, new Promise(resolve => { join = resolve; })]);
    clearTimeout(timeout);
    clearTimeout(hardKill);
    clearTimeout(forcedJoin);
    signal?.removeEventListener('abort', abort);
    try {
      if (group(pid)) {
        issue ??= 'Evaluator left background processes';
        group(pid, 'SIGKILL');
        for (let i = 0; i < 30 && group(pid); i++) await delay(50);
      }
      if (group(pid)) cleanupIssue ??= 'Process group still exists';
    } catch (error) { cleanupIssue ??= error.message; }
    if (forced) cleanupIssue ??= 'Process join could not be confirmed';
    if (cleanupIssue) child.unref();
    const bytes = Buffer.concat(stdout);
    try {
      await Promise.allSettled([
        stdoutFile.writeFile(bytes), stderrFile.writeFile(Buffer.concat(stderr)),
      ]).then(results => { for (const r of results) if (r.status === 'rejected') throw r.reason; });
    } catch (error) { issue ??= `Could not retain output: ${error.message}`; }
    return {
      pid, exitCode, exitSignal, outputBytes, issue, cleanupIssue,
      outputExceeded: outputBytes > OUTPUT_LIMIT,
      report: stdoutBytes <= REPORT_LIMIT ? bytes : null,
    };
  } finally {
    await Promise.all([stdoutFile?.close(), stderrFile?.close()]);
  }
}
