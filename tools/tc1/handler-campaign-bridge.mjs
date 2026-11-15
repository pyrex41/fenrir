// Bounded JSON transport for TC1 handler generation and reduction; no model
// transitions and no implementation runs.
//   generate COUNT     the first COUNT programs of family G (handler-generate.mjs)
//   reduce PROGRAM     {metric, rejected, proposals} for one program file (handler-reduce.mjs)
import {readFileSync} from 'node:fs';
import {generateHandlers} from './handler-generate.mjs';
import {handlerReductions} from './handler-reduce.mjs';
const [action,arg]=process.argv.slice(2);
if(action==='generate'&&/^[1-9][0-9]*$/.test(arg??'')&&process.argv.length===4)console.log(JSON.stringify(generateHandlers(Number(arg))));
else if(action==='reduce'&&arg&&process.argv.length===4)console.log(JSON.stringify(handlerReductions(JSON.parse(readFileSync(arg,'utf8')))));
else throw new Error('Usage: handler-campaign-bridge.mjs generate COUNT | reduce PROGRAM');
