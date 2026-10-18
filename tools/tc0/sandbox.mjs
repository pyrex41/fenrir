// Candidate execution boundary, development tier, NOT a qualified isolation claim.
// Usage: node tools/tc0/sandbox.mjs --read PATH... [--write PATH...] -- SCRIPT [ARGS...]
// Runs `node SCRIPT ARGS` with:
//   * a new, empty network namespace (unshare -n): no interfaces but loopback, down;
//   * Node's permission model: file reads only below the --read paths, writes only to
//     the --write paths, no child processes, worker threads, native addons or WASI;
//   * an empty environment apart from PATH, so inherited credentials are not visible.
// What this does NOT bound: CPU, memory and wall time (callers keep their watchdogs);
// reads Node itself performs to start; side channels. tools/tc0/check-sandbox.mjs
// measures each enforced property with benign probes.
// Exit 2 when the boundary cannot be established (never falls back to running unsandboxed).
import { spawnSync } from 'node:child_process';
import { realpathSync, existsSync } from 'node:fs';
export function sandboxArgv({ read = [], write = [], script, args = [] }) {
  if (!script || !read.length) throw new TypeError('script and at least one read path required');
  const real = p => (existsSync(p) ? realpathSync(p) : p);
  return [
    'unshare',
    '-n',
    '--',
    process.execPath,
    '--permission',
    ...read.map(p => '--allow-fs-read=' + real(p)),
    ...write.map(p => '--allow-fs-write=' + p),
    script,
    ...args
  ];
}
export const SANDBOX_ENV = Object.freeze({ PATH: '/usr/bin:/bin' });
if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2),
    sep = argv.indexOf('--');
  if (sep < 0)
    throw new Error('Usage: sandbox.mjs --read PATH... [--write PATH...] -- SCRIPT [ARGS...]');
  const read = [],
    write = [];
  let list = null;
  for (const a of argv.slice(0, sep)) {
    if (a === '--read') list = read;
    else if (a === '--write') list = write;
    else if (list) list.push(a);
    else throw new Error('Unknown argument ' + a);
  }
  const [script, ...args] = argv.slice(sep + 1);
  // Preflight: the network namespace must be creatable, or nothing runs.
  const pre = spawnSync('unshare', ['-n', '--', 'true']);
  if (pre.error || pre.status !== 0) {
    console.error('BLOCKED: cannot create a network namespace');
    process.exit(2);
  }
  const argvFull = sandboxArgv({ read, write, script, args }),
    r = spawnSync(argvFull[0], argvFull.slice(1), { stdio: 'inherit', env: SANDBOX_ENV });
  if (r.error) {
    console.error('BLOCKED: sandbox unavailable: ' + r.error.message);
    process.exit(2);
  }
  process.exit(r.status ?? 1);
}
