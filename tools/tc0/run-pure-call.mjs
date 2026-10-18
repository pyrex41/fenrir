// Host validation precedes execution; UNQUALIFIED development peer.
import { readFileSync } from 'node:fs';
import { validatePureCallArtifact } from './pure-call-artifact.mjs';
import { PureCallMachine } from '../../runtime/tc0/pure-call-machine.mjs';
const [path, ...flags] = process.argv.slice(2);
if (!path || flags.length > 1) throw new Error('Usage: run-pure-call.mjs PROGRAM [MUTANT-FLAG]');
const checked = validatePureCallArtifact(readFileSync(path), ['int', '0']);
// An optional candidate-only mutant flag; mutants live with the evaluator tooling and
// load only when one is requested.
let machine;
if (flags.length) {
  const { MUTANTS, createMachine } = await import('./pure-call-mutants.mjs');
  const option = Object.keys(MUTANTS).find(k => MUTANTS[k].flag === flags[0]);
  if (!option) throw new Error('Unknown mutant flag: ' + flags[0]);
  machine = createMachine(checked.artifact, checked.input, { [option]: true });
} else machine = new PureCallMachine(checked.artifact, checked.input);
console.log(JSON.stringify(machine.run(200)));
