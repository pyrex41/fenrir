// Replay retained, source-verified Shen development cases. NOT a qualification evaluator.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve,relative,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {encode} from './canonical.mjs';
import {validateClosureProgram} from './closure-artifact.mjs';
import {ClosureMachine} from '../../runtime/tc0/closure-machine.mjs';
import {closureHeader} from './closure-replay-header.mjs';
import {recordClosure,replayClosure} from './closure-replay.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
const reportPath=resolve(process.argv[2]),output=resolve(process.argv[3]);
if(!relative(resolve(root,'build'),output)||relative(resolve(root,'build'),output).startsWith('..')||!output.endsWith('.json')||output===reportPath)throw new Error('Output must be a separate JSON below build/');
const reportBytes=readFileSync(reportPath),reportHash=createHash('sha256').update(reportBytes).digest('hex');
const report=JSON.parse(reportBytes);
if(report.qualification!=='UNKNOWN'||!Array.isArray(report.cases)||!report.sources)throw new Error('Expected development oracle report');
const required=['tools/check-tc0-closure.py','models/tc0/closure-machine.shen','runtime/tc0/closure-machine.mjs','spec/tc0/pure-closure-demo.json'];
for(const p of required)if(!Object.hasOwn(report.sources,resolve(root,p)))throw new Error('Missing required oracle/source identity');
for(const [path,expected] of Object.entries(report.sources))if(digest(path)!==expected)throw new Error('Retained oracle source/toolchain drift: '+path);
const before=Object.fromEntries(['tools/tc0/closure-replay.mjs','tools/tc0/closure-replay-header.mjs','tools/tc0/check-closure-replay.mjs'].map(p=>[p,digest(resolve(root,p))]));
const cases=[];
for(const row of report.cases) {
 const checked=validateClosureProgram(encode(row.program),['int','0']);
 const machine=()=>new ClosureMachine(checked.program,checked.input),m=machine();
 const header=closureHeader(m,checked.program,checked.input,row.model_steps,{sources:Object.entries(report.sources).sort(([a],[b])=>a<b?-1:a>b?1:0),report_hash:reportHash}, {run_id:'closure-'+row.name});
 const bundle=recordClosure(m,row.model_steps,header),result=replayClosure(machine(),row.model_steps,header,bundle);
 if(result.execution!=='Completed'||result.conformance!=='Admitted')throw new Error('Development case unexpectedly diverges: '+row.name);
 cases.push({name:row.name,bundle,result});
}
for(const [path,expected] of Object.entries(report.sources))if(digest(path)!==expected)throw new Error('Oracle drift during replay');
for(const [p,expected] of Object.entries(before))if(digest(resolve(root,p))!==expected)throw new Error('Replay source drift');
if(digest(reportPath)!==reportHash)throw new Error('Oracle report drift during replay');
const result={qualification:'UNKNOWN',scope:'Source-verified retained Shen cases, standalone closure development replay',oracle_report:reportPath,oracle_report_hash:reportHash,sources:Object.entries(before),cases};
mkdirSync(dirname(output),{recursive:true});writeFileSync(output,encode(result));
console.log(JSON.stringify({qualification:'UNKNOWN',exact_completing_cases:cases.length,output}));
