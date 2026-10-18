// S3 clean-room repair packet, development tier, NOT qualification.
// Usage: node tools/tc0/s3-prepare.mjs S2_REPORT OUT_DIR
//   S2_REPORT  an arm-by-position pure-data reduction report (schema /2)
//   OUT_DIR    fresh directory below build/ receiving packet/ and workspace/
// packet/ is evaluator-side: the preserved defective original, the failure bundle,
// the workspace manifest and the allowed path. workspace/ is what a repairer gets:
// a git-archive export of HEAD (no history) with the defective candidate in place,
// project narrative that names the injected defect removed, and S3_TASK.md.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encode } from './canonical.mjs';
import { validatePureCallArtifact } from './pure-call-artifact.mjs';
import { makeDefective } from './s3-defect.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const sha = b => createHash('sha256').update(b).digest('hex');
const [reportArg, outArg] = process.argv.slice(2);
if (!reportArg || !outArg) throw new Error('Usage: s3-prepare.mjs S2_REPORT OUT_DIR');
const out = resolve(outArg),
  rel = relative(resolve(root, 'build'), out);
if (!rel || rel.startsWith('..') || existsSync(out))
  throw new Error('Fresh OUT_DIR below build/ required');
const reportBytes = readFileSync(resolve(reportArg)),
  report = JSON.parse(reportBytes);
if (
  report.schema !== 'pure-call-reduction-development/2' ||
  report.family !== 'pure-data' ||
  report.mutant !== 'arm-by-position' ||
  report.qualification !== 'UNKNOWN'
)
  throw new Error('Expected a pure-data arm-by-position reduction report');
if (execFileSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' }).trim())
  throw new Error('Commit first: the workspace is exported from HEAD');
const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();

const CANDIDATE = 'runtime/tc0/pure-call-machine.mjs';
const defective = makeDefective(readFileSync(resolve(root, CANDIDATE), 'utf8'));

// Evaluator-side material withheld from the repairer: narrative naming the defect,
// mutation/generation/reduction tooling for it, held-out scopes and the S3 tools.
const WITHHELD = [
  'README.md',
  'PI_CLM_HANDOFF.md',
  'campaigns',
  '.pi',
  'tests/tc0/pure-data-generation.test.mjs',
  'tests/tc0/pure-call-failure-runner.test.mjs',
  'tests/tc0/s3-repair.test.mjs',
  'tests/tc0/sandbox.test.mjs',
  'tools/check-tc0-pure-call-reduction.py',
  'tools/check-tc0-pure-data-exhaustive.py',
  'tools/check-tc0-s3-repair.py',
  'tools/tc0/pure-data-generate.mjs',
  'tools/tc0/pure-data-enumerate.mjs',
  'tools/tc0/pure-data-invalid.mjs',
  'tools/tc0/run-pure-data-exhaustive.mjs',
  'tools/tc0/pure-call-campaign-bridge.mjs',
  'tools/tc0/check-pure-call-failure-replay.mjs',
  'tools/tc0/s3-prepare.mjs',
  'tools/tc0/s3-defect.mjs',
  'tools/tc0/s3-replay.mjs',
  'tools/tc0/s3-task-template.md',
  'tools/tc0/check-sandbox.mjs',
  'spec/tc0/requirement-ledger-a.json',
  'tools/tc0/check-requirement-ledger.mjs',
  'tests/tc0/requirement-ledger.test.mjs',
  'spec/tc0/tc0-a-requirements.json',
  'tools/check-tc0-a-gate.py',
  'attic',
  'tools/tc0/pure-call-mutants.mjs',
  'tests/tc0/pure-call-mutants.test.mjs'
];
const packet = join(out, 'packet'),
  workspace = join(out, 'workspace');
mkdirSync(packet, { recursive: true });
mkdirSync(workspace, { recursive: true });
writeFileSync(join(packet, 'defective-pure-call-machine.mjs'), defective);
const { PureCallMachine: Defective } = await import(
  join(packet, 'defective-pure-call-machine.mjs')
);

// Failure bundle: Shen-observed reference traces for the retained original and
// minimized failures, plus the defective original's first divergence on each.
const failures = ['original', 'minimized'].map(label => {
  const row = report[label];
  if (row.discrepancy !== 'wrong-match-arm')
    throw new Error('Retained failure must be wrong-match-arm');
  const checked = validatePureCallArtifact(encode(row.program), row.input),
    observed = new Defective(checked.artifact, checked.input).run(200);
  const k = row.model_steps.findIndex(
    (s, i) => encode(s).compare(encode(observed.steps[i] ?? null)) !== 0
  );
  if (
    k < 1 ||
    row.model_steps[k - 1].site.rule !== 'MatchReturn' ||
    row.model_steps[k].site.node === observed.steps[k].site.node
  )
    throw new Error('Defective original does not reproduce ' + label);
  return {
    label,
    program: row.program,
    input: row.input,
    model_steps: row.model_steps,
    model_outcome: row.hand_outcome,
    defective_outcome: observed.outcome,
    first_divergence_epoch: String(k),
    expected_model_step: row.model_steps[k],
    defective_step: observed.steps[k]
  };
});
const bundle = {
  schema: 'tc0-s3-failure-bundle/1',
  qualification: 'UNKNOWN',
  start_revision: head,
  source_report_sha256: sha(reportBytes),
  defective_candidate_sha256: sha(defective),
  candidate_path: CANDIDATE,
  discrepancy:
    'Trace divergence immediately after a MatchReturn step: a different node is dispatched',
  failures
};

// Workspace: HEAD without history; the defective candidate in place; narrative that
// names the injected defect or its campaigns removed. Plans/spec stay.
execFileSync('sh', ['-c', `git archive --format=tar HEAD | tar -x -C "${workspace}"`], {
  cwd: root
});
for (const p of WITHHELD) rmSync(join(workspace, p), { recursive: true, force: true });
writeFileSync(join(workspace, CANDIDATE), defective);
// A shipped test that fails on the defective candidate localizes the defect for the
// repairer, so it is withheld too; the evaluator runs it as a held-out regression.
const failingTests = readdirSync(join(workspace, 'tests/tc0'))
  .filter(n => n.endsWith('.test.mjs'))
  .sort()
  .filter(n => {
    try {
      execFileSync(process.execPath, ['--test', 'tests/tc0/' + n], {
        cwd: workspace,
        stdio: 'pipe'
      });
      return false;
    } catch {
      return true;
    }
  })
  .map(n => 'tests/tc0/' + n);
for (const p of failingTests) rmSync(join(workspace, p));
// What remains must pass as a whole on the defective candidate, or the packet is refused.
const shipped = readdirSync(join(workspace, 'tests/tc0'))
  .filter(n => n.endsWith('.test.mjs'))
  .map(n => 'tests/tc0/' + n);
try {
  execFileSync(process.execPath, ['--test', ...shipped], { cwd: workspace, stdio: 'pipe' });
} catch {
  throw new Error('Shipped regression suite fails on the defective candidate after withholding');
}
// Those runs leave caches under build/, which the evaluator ignores; ship none.
rmSync(join(workspace, 'build'), { recursive: true, force: true });
mkdirSync(join(workspace, 's3'), { recursive: true });
writeFileSync(join(workspace, 's3/failure-bundle.json'), JSON.stringify(bundle, null, 1) + '\n');
writeFileSync(
  join(workspace, 'S3_TASK.md'),
  readFileSync(resolve(root, 'tools/tc0/s3-task-template.md'), 'utf8')
    .replaceAll('{{start_revision}}', head)
    .replaceAll('{{candidate}}', CANDIDATE)
);
const files = {};
const walk = d => {
  for (const name of readdirSync(d).sort()) {
    const p = join(d, name);
    if (statSync(p).isDirectory()) walk(p);
    else files[relative(workspace, p)] = sha(readFileSync(p));
  }
};
walk(workspace);
writeFileSync(
  join(packet, 'workspace-manifest.json'),
  JSON.stringify(
    {
      schema: 'tc0-s3-workspace/2',
      start_revision: head,
      allowed_paths: [CANDIDATE],
      ignored_prefixes: ['build/'],
      withheld_failing_tests: failingTests,
      files
    },
    null,
    1
  ) + '\n'
);
writeFileSync(join(packet, 'failure-bundle.json'), JSON.stringify(bundle, null, 1) + '\n');
const leaks = Object.keys(files).filter(p =>
  /arm.by.position|armByPosition|arm_by_position|wrong-match-arm/i.test(
    readFileSync(join(workspace, p), 'utf8')
  )
);
if (leaks.length) throw new Error('Workspace still names the injected defect: ' + leaks.join(', '));
console.log(
  JSON.stringify({
    qualification: 'UNKNOWN',
    start_revision: head,
    packet,
    workspace,
    files: Object.keys(files).length,
    withheld_failing_tests: failingTests,
    failures: failures.map(f => ({
      label: f.label,
      first_divergence_epoch: f.first_divergence_epoch
    }))
  })
);
