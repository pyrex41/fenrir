// Host validation precedes execution; UNQUALIFIED development peer.
import {readFileSync} from 'node:fs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const [path,...flags]=process.argv.slice(2);
if(!path||flags.some(f=>f!=='--reverse-operands'))throw new Error('Usage: run-pure-call.mjs PROGRAM [--reverse-operands]');
const checked=validatePureCallArtifact(readFileSync(path),['int','0']);
console.log(JSON.stringify(new PureCallMachine(checked.artifact,checked.input,{reverseOperands:flags.includes('--reverse-operands')}).run(200)));
