// Catalog coverage over Shen-agreeing traces, UNQUALIFIED development measure.
// Usage: node tools/tc0/check-pure-call-coverage.mjs HAND_REPORT EXHAUSTIVE_REPORT OUTPUT
//   HAND_REPORT        tools/check-tc0-pure-call.py output (Shen model_steps per case)
//   EXHAUSTIVE_REPORT  tools/check-tc0-pure-data-exhaustive.py output; each program is
//                      re-run on the candidate here and admitted only if its trace hash
//                      equals the Shen-agreeing trace hash recorded in the report.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { encode } from './canonical.mjs';
import { enumeratePureData } from './pure-data-enumerate.mjs';
import { PureCallMachine } from '../../runtime/tc0/pure-call-machine.mjs';
import { coverage } from './pure-call-coverage.mjs';
const sha = b => createHash('sha256').update(b).digest('hex');
const [handPath, exhaustivePath, output] = process.argv.slice(2);
if (!handPath || !exhaustivePath || !output?.endsWith('.json') || existsSync(output))
  throw new Error(
    'Usage: check-pure-call-coverage.mjs HAND_REPORT EXHAUSTIVE_REPORT FRESH_OUTPUT.json'
  );
const hand = JSON.parse(readFileSync(handPath)),
  exhaustive = JSON.parse(readFileSync(exhaustivePath));
if (hand.qualification !== 'UNKNOWN' || !Array.isArray(hand.cases))
  throw new Error('Expected a hand-case agreement report');
if (
  exhaustive.schema !== 'pure-data-exhaustive-small-development/1' ||
  exhaustive.disagreements.length
)
  throw new Error('Expected a fully agreeing exhaustive report');
const rows = hand.cases.map(c => ({
  name: 'hand:' + c.name,
  program: c.program,
  steps: c.model_steps
}));
const family = enumeratePureData(Number(exhaustive.bounds.max_nodes));
if (family.count !== exhaustive.enumeration.count)
  throw new Error('Enumeration differs from the report');
const recorded = new Map(exhaustive.cases.map(c => [c.name, c.trace_sha256]));
for (const c of family.cases) {
  const steps = new PureCallMachine(c.program, ['int', '0']).run(200).steps;
  if (sha(encode(steps)) !== recorded.get(c.name))
    throw new Error('Trace is not the Shen-agreeing one recorded for ' + c.name);
  rows.push({ name: 'exhaustive:' + c.name, program: c.program, steps });
}
const result = {
  qualification: 'UNKNOWN',
  scope:
    'Catalog transition keys exercised by Shen-agreeing traces: ' +
    String(hand.cases.length) +
    ' hand cases and ' +
    family.count +
    ' exhaustive-small programs',
  hand_report_sha256: sha(readFileSync(handPath)),
  exhaustive_report_sha256: sha(readFileSync(exhaustivePath)),
  ...coverage(rows)
};
writeFileSync(output, JSON.stringify(result, null, 1) + '\n', { flag: 'wx' });
console.log(
  JSON.stringify({
    qualification: 'UNKNOWN',
    catalog_keys: result.catalog_keys,
    covered: result.covered,
    missing: result.missing,
    unknown_observed: result.unknown_observed
  })
);
