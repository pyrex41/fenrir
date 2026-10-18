// Source-verified generated original/minimized SAME-mutant replay, NOT qualification.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual as equal } from 'node:util';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encode } from './canonical.mjs';
import { validatePureCallArtifact } from './pure-call-artifact.mjs';
import { createMachine } from './pure-call-mutants.mjs';
import { pureCallHeader } from './pure-call-replay-header.mjs';
import { recordPureCall, replayPureCall } from './pure-call-replay.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const digest = p => createHash('sha256').update(readFileSync(p)).digest('hex');
if (process.argv.length !== 4)
  throw new Error('Usage: check-pure-call-failure-replay.mjs REPORT OUTPUT');
const reportPath = resolve(process.argv[2]),
  output = resolve(process.argv[3]);
const rel = relative(resolve(root, 'build'), output);
if (
  !rel ||
  rel.startsWith('..') ||
  !output.endsWith('.json') ||
  output === reportPath ||
  existsSync(output)
)
  throw new Error('Fresh separate output JSON below build required');
const bytes = readFileSync(reportPath),
  reportHash = createHash('sha256').update(bytes).digest('hex'),
  report = JSON.parse(bytes);
// Schema /1 reports are the pure-call family under reverse-operands; /2 names its family and mutant.
const schema2 = report.schema === 'pure-call-reduction-development/2';
const mutants = {
  'reverse-operands': { option: 'reverseOperands', discrepancy: 'reversed-emissions-same-outcome' },
  'arm-by-position': { option: 'armByPosition', discrepancy: 'wrong-match-arm' }
};
const mutantName = schema2 ? report.mutant : 'reverse-operands',
  mutantSpec = mutants[mutantName];
if (
  !Object.hasOwn(mutants, mutantName) ||
  (schema2 &&
    (!['pure-call', 'pure-data'].includes(report.family) ||
      report.expected_discrepancy !== mutantSpec.discrepancy))
)
  throw new Error('Unknown family/mutant');
if (
  !(schema2 || report.schema === 'pure-call-reduction-development/1') ||
  report.qualification !== 'UNKNOWN' ||
  report.cleanup !== 'confirmed' ||
  !report.sources ||
  !report.sources_after ||
  !Array.isArray(report.observations) ||
  report.observations.length > 132
)
  throw new Error('Expected bounded generated development report');
const required = [
  'tools/check-tc0-pure-call-reduction.py',
  'tools/check-tc0-pure-call.py',
  'tools/check-tc0-expression.py',
  'tools/tc0/pure-call-generate.mjs',
  'tools/tc0/pure-call-reduce.mjs',
  'tools/tc0/pure-call-campaign-bridge.mjs',
  'tools/tc0/run-pure-call.mjs',
  'tools/tc0/pure-call-artifact.mjs',
  'tools/tc0/canonical.mjs',
  'models/tc0/pure-call-machine.shen',
  'models/tc0/arithmetic.shen',
  'runtime/tc0/pure-call-machine.mjs',
  'spec/tc0/pure-call-demo.json'
];
if (schema2) required.push('tools/tc0/pure-data-generate.mjs');
for (const p of required)
  if (!Object.hasOwn(report.sources, resolve(root, p)))
    throw new Error('Missing required source identity: ' + p);
if (
  !Object.hasOwn(report.sources, resolve(process.execPath)) ||
  !Object.keys(report.sources).some(p => p.endsWith('/shen.boot')) ||
  !Object.keys(report.sources).some(p => p.endsWith('/bin/shen-scheme'))
)
  throw new Error('Missing oracle toolchain identity');
if (JSON.stringify(report.sources) !== JSON.stringify(report.sources_after))
  throw new Error('Oracle source identity changed');
const verify = () => {
  for (const [p, h] of Object.entries(report.sources))
    if (digest(p) !== h) throw new Error('Retained source/toolchain drift: ' + p);
};
verify();
const replaySources = [
  'tools/tc0/pure-call-replay.mjs',
  'tools/tc0/pure-call-replay-header.mjs',
  'tools/tc0/check-pure-call-failure-replay.mjs'
];
const before = Object.fromEntries(replaySources.map(p => [p, digest(resolve(root, p))]));
const cases = [];
for (const label of ['original', 'minimized']) {
  const row = report[label];
  if (
    !row ||
    row.discrepancy !== mutantSpec.discrepancy ||
    !report.observations.some(o => JSON.stringify(o) === JSON.stringify(row))
  )
    throw new Error('Failure must be a retained observation');
  const checked = validatePureCallArtifact(encode(row.program), row.input);
  const machine = mutated =>
    createMachine(checked.artifact, checked.input, mutated ? { [mutantSpec.option]: true } : {});
  const baseline = machine(false).run(200),
    mutant = machine(true).run(200);
  const labels = run =>
    run.steps.flatMap(s => s.events.filter(e => e.kind === 'Emit').map(e => e.label));
  // Recheck the retained discrepancy class here rather than trusting the report's label.
  const k = baseline.steps.findIndex((s, i) => !equal(s, mutant.steps[i]));
  const shown =
    mutantName === 'reverse-operands'
      ? equal(labels(baseline), ['left', 'right']) &&
        equal(labels(mutant), ['right', 'left']) &&
        equal(mutant.outcome, row.hand_outcome)
      : mutant.execution === 'Completed' &&
        k > 0 &&
        baseline.steps[k - 1].site.rule === 'MatchReturn' &&
        baseline.steps[k].site.rule === 'Dispatch' &&
        mutant.steps[k].site.rule === 'Dispatch' &&
        baseline.steps[k].site.node !== mutant.steps[k].site.node;
  if (
    !equal(baseline, row.candidate) ||
    !equal(baseline, row.equivalent_control) ||
    !equal(baseline.steps, row.model_steps) ||
    !equal(mutant, row.mutant) ||
    !shown
  )
    throw new Error('Retained expected discrepancy or control mismatch');
  const m = machine(true),
    identity = {
      report_hash: reportHash,
      sources: Object.entries(report.sources).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    };
  const header = pureCallHeader(m, checked.artifact, checked.input, row.model_steps, identity, {
    run_id: 'pure-call-generated-' + label
  });
  const bundle = recordPureCall(m, row.model_steps, header),
    result = replayPureCall(machine(true), row.model_steps, header, bundle);
  if (
    result.replay !== 'Exact' ||
    result.conformance !== 'Diverged' ||
    result.execution !== 'StoppedAtDivergence'
  )
    throw new Error('Same-mutant first discrepancy replay failed');
  cases.push({ name: label, program: checked.artifact, input: checked.input, bundle, result });
}
verify();
for (const [p, h] of Object.entries(before))
  if (digest(resolve(root, p)) !== h) throw new Error('Replay source drift');
if (digest(reportPath) !== reportHash) throw new Error('Parsed report bytes drift');
const result = {
  qualification: 'UNKNOWN',
  scope: 'Source-verified original/minimized pure-call exposed-state same-mutant replay',
  family: schema2 ? report.family : 'pure-call',
  mutant: mutantName,
  oracle_report: reportPath,
  oracle_report_hash: reportHash,
  sources: Object.entries(before),
  cases
};
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, encode(result), { flag: 'wx' });
console.log(
  JSON.stringify({ qualification: 'UNKNOWN', exact_diverging_cases: cases.length, output })
);
