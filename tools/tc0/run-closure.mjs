// Trusted-local standalone closure demo peer, not qualification.
import {readFileSync} from 'node:fs';
import {validateClosureProgram} from './closure-artifact.mjs';
import {ClosureMachine} from '../../runtime/tc0/closure-machine.mjs';
import {encode} from './canonical.mjs';
const checked=validateClosureProgram(readFileSync(process.argv[2]),['int','0']);
process.stdout.write(encode(new ClosureMachine(checked.program,checked.input).run(200)));
