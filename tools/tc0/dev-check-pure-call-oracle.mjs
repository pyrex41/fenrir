// Development-tier launcher for the pure-call oracle loop, NOT qualification.
// Runs fresh Shen-vs-candidate hand-case agreement, then strict exposed-state
// replay of that fresh report. Transport only: semantic checks live in the
// invoked tools. Exit 0 = both passed, 1 = a check failed, 2 = a prerequisite
// is unavailable (registered as the check's blockedExitCode).
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
// Fixed, ignored location so the controller's minimal environment needs no
// variables. Point it at a pinned shen-scheme build: ln -s <shen>/_build/bin/shen-scheme
const shenLink = resolve(root, 'build/toolchain/shen-scheme');
const out = resolve(root, 'build/tc0/dev-check');
const agreement = resolve(out, 'pure-call-shen-agreement.json');
const replay = resolve(out, 'pure-call-replay.json');

function blocked(message) {
  console.error('BLOCKED: ' + message);
  process.exit(2);
}
function run(label, argv, timeoutSeconds) {
  const started = Date.now();
  const r = spawnSync(argv[0], argv.slice(1), {
    cwd: root,
    stdio: ['ignore', 'pipe', 'inherit'],
    timeout: timeoutSeconds * 1000,
    maxBuffer: 1 << 20
  });
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  if (r.error?.code === 'ENOENT') blocked(`${argv[0]} not found for ${label}`);
  if (r.error || r.signal)
    throw new Error(`${label}: ${r.error?.message ?? 'signal ' + r.signal} after ${seconds}s`);
  process.stdout.write(r.stdout);
  if (r.status !== 0) {
    console.error(`FAIL: ${label} exited ${r.status} after ${seconds}s`);
    process.exit(1);
  }
  console.error(`ok: ${label} (${seconds}s)`);
}

// Prefer the Yggdrasil-shaken oracle (tools/tc0/build-shaken-oracle.mjs) while its
// stamp still matches the model sources; otherwise run the driver on host Shen.
const shaken = resolve(root, 'build/toolchain/tc0-pure-call-oracle');
const digest = p => createHash('sha256').update(readFileSync(p)).digest('hex');
function shakenFresh() {
  try {
    const stamp = JSON.parse(readFileSync(resolve(shaken, 'oracle-stamp.json'), 'utf8'));
    return (
      stamp.schema === 'fenrir.shaken-oracle.v1' &&
      stamp.parity?.identical === true &&
      Object.entries(stamp.sources).every(([p, h]) => digest(resolve(root, p)) === h) &&
      [
        'models/tc0/arithmetic.shen',
        'models/tc0/pure-call-machine.shen',
        'models/tc0/pure-call-oracle.shen'
      ].every(p => p in stamp.sources)
    );
  } catch {
    return false;
  }
}
let oracleArgs;
if (shakenFresh()) {
  oracleArgs = ['--oracle-artifact', shaken];
  console.error('oracle: Yggdrasil-shaken artifact ' + shaken);
} else {
  if (existsSync(shaken))
    console.error(
      'oracle: shaken artifact is stale (model changed); using host Shen. Rebuild with tools/tc0/build-shaken-oracle.mjs'
    );
  if (!existsSync(shenLink))
    blocked(
      `no fresh shaken oracle and no Shen executable at ${shenLink}; link a pinned shen-scheme build there (see .pi/extensions/fenrir-workflow/README.md)`
    );
  const shen = realpathSync(shenLink);
  if (
    !shen.endsWith('/bin/shen-scheme') ||
    !existsSync(resolve(shen, '../../lib/shen-scheme/shen.boot'))
  )
    blocked(`${shen} is not a shen-scheme build with lib/shen-scheme/shen.boot`);
  oracleArgs = ['--shen-executable', shen];
  console.error('oracle: host Shen ' + shen);
}

// Stale outputs must never stand in for this run's observations.
rmSync(agreement, { force: true });
rmSync(replay, { force: true });
mkdirSync(out, { recursive: true });
run(
  'Shen/candidate hand-case agreement',
  [
    'python3',
    '-I',
    resolve(root, 'tools/check-tc0-pure-call.py'),
    ...oracleArgs,
    '--output',
    agreement
  ],
  240
);
run(
  'strict replay of fresh agreement report',
  [process.execPath, resolve(root, 'tools/tc0/check-pure-call-replay.mjs'), agreement, replay],
  60
);
console.log(
  JSON.stringify({
    qualification: 'UNKNOWN',
    scope: 'pure-call hand cases: fresh Shen agreement + strict replay (development)',
    outputs: [agreement, replay]
  })
);
