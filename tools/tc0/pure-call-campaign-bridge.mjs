// Bounded JSON transport for pure-call generation/reduction; no oracle transitions.
import {readFileSync} from 'node:fs';
import {generatePureCalls} from './pure-call-generate.mjs';
import {pureCallReductions,pureCallMetric} from './pure-call-reduce.mjs';
const [action,arg]=process.argv.slice(2);
if(action==='generate')console.log(JSON.stringify(generatePureCalls(Number(arg??32))));
else if(action==='reduce'&&arg){const program=JSON.parse(readFileSync(arg));console.log(JSON.stringify({metric:pureCallMetric(program),proposals:pureCallReductions(program)}));}
else throw new Error('Usage: pure-call-campaign-bridge.mjs generate COUNT | reduce PROGRAM');
