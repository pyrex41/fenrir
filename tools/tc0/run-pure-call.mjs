// Host validation precedes execution; UNQUALIFIED development peer.
import {readFileSync} from 'node:fs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const [path,...flags]=process.argv.slice(2);
// Candidate-only mutants: --reverse-operands (collection order), --arm-by-position
// (match arm chosen by constructor declaration position instead of name).
const mutants={'--reverse-operands':'reverseOperands','--arm-by-position':'armByPosition'};
if(!path||flags.some(f=>!Object.hasOwn(mutants,f))||new Set(flags).size!==flags.length)throw new Error('Usage: run-pure-call.mjs PROGRAM [--reverse-operands] [--arm-by-position]');
const checked=validatePureCallArtifact(readFileSync(path),['int','0']);
console.log(JSON.stringify(new PureCallMachine(checked.artifact,checked.input,Object.fromEntries(flags.map(f=>[mutants[f],true]))).run(200)));
