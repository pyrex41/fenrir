// Batch candidate peer, UNQUALIFIED development transport: validates each artifact in a
// JSON array file, runs the candidate, and writes one JSON line per program to OUTPUT.
import { readFileSync, writeFileSync } from 'node:fs';
import { encode } from './canonical.mjs';
import { validatePureCallArtifact } from './pure-call-artifact.mjs';
import { PureCallMachine } from '../../runtime/tc0/pure-call-machine.mjs';
const [input, output] = process.argv.slice(2);
if (!input || !output?.endsWith('.jsonl'))
  throw new Error('Usage: run-pure-call-batch.mjs PROGRAMS.json OUTPUT.jsonl');
const lines = JSON.parse(readFileSync(input)).map(program => {
  const checked = validatePureCallArtifact(encode(program), ['int', '0']),
    r = new PureCallMachine(checked.artifact, checked.input).run(200);
  return JSON.stringify({ execution: r.execution, outcome: r.outcome, steps: r.steps });
});
writeFileSync(output, lines.join('\n') + '\n', { flag: 'wx' });
console.log(JSON.stringify({ programs: String(lines.length), output }));
