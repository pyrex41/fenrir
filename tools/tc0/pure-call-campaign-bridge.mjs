// Bounded JSON transport for pure-call generation/reduction; no oracle transitions.
import {readFileSync} from 'node:fs';
import {generatePureCalls} from './pure-call-generate.mjs';
import {generatePureData} from './pure-data-generate.mjs';
import {pureCallReductions,pureCallMetric} from './pure-call-reduce.mjs';
const [action,arg]=process.argv.slice(2);
const family=process.argv[4]??'pure-call';
if(action==='generate'&&['pure-call','pure-data'].includes(family))console.log(JSON.stringify((family==='pure-data'?generatePureData:generatePureCalls)(Number(arg??(family==='pure-data'?24:32)))));
else if(action==='reduce'&&arg){const program=JSON.parse(readFileSync(arg));console.log(JSON.stringify({metric:pureCallMetric(program),proposals:pureCallReductions(program)}));}
else throw new Error('Usage: pure-call-campaign-bridge.mjs generate COUNT [pure-call|pure-data] | reduce PROGRAM');
