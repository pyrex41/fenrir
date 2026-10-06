// Source-verified retained independent Shen observations, NOT qualification.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve,relative,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {encode} from './canonical.mjs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {pureCallHeader} from './pure-call-replay-header.mjs';
import {recordPureCall,replayPureCall} from './pure-call-replay.mjs';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
if(process.argv.length!==4)throw new Error('Usage: check-pure-call-replay.mjs REPORT OUTPUT');
const reportPath=resolve(process.argv[2]),output=resolve(process.argv[3]);
if(!relative(resolve(root,'build'),output)||relative(resolve(root,'build'),output).startsWith('..')||!output.endsWith('.json')||output===reportPath)throw new Error('Separate output JSON below build required');
const reportBytes=readFileSync(reportPath),reportHash=createHash('sha256').update(reportBytes).digest('hex'),report=JSON.parse(reportBytes);
if(report.qualification!=='UNKNOWN'||!Array.isArray(report.cases)||!report.sources||report.cases.length<1||report.cases.length>32)throw new Error('Expected bounded development oracle report');
const required=['tools/check-tc0-pure-call.py','tools/check-tc0-expression.py','tools/tc0/run-pure-call.mjs','tools/tc0/pure-call-artifact.mjs','tools/tc0/canonical.mjs','models/tc0/pure-call-machine.shen','models/tc0/arithmetic.shen','runtime/tc0/pure-call-machine.mjs','spec/tc0/pure-call-demo.json','fixtures/tc0/pure-call-forward.json','fixtures/tc0/pure-call-hand-cases.mjs','tests/tc0/pure-call-machine.test.mjs','tests/tc0/pure-call-artifact.test.mjs'];
for(const p of required)if(!Object.hasOwn(report.sources,resolve(root,p)))throw new Error('Missing required source identity: '+p);
if(!Object.hasOwn(report.sources,resolve(process.execPath))||!Object.keys(report.sources).some(p=>p.endsWith('/shen.boot'))||!Object.keys(report.sources).some(p=>p.endsWith('/bin/shen-scheme')))throw new Error('Missing oracle toolchain identity');
for(const [path,expected] of Object.entries(report.sources))if(digest(path)!==expected)throw new Error('Retained source/toolchain drift: '+path);
const before=Object.fromEntries(['tools/tc0/pure-call-replay.mjs','tools/tc0/pure-call-replay-header.mjs','tools/tc0/check-pure-call-replay.mjs'].map(p=>[p,digest(resolve(root,p))]));
const names=new Set(),cases=[];
for(const row of report.cases){
 if(typeof row.name!=='string'||names.has(row.name))throw new Error('Unique case names');names.add(row.name);
 const checked=validatePureCallArtifact(encode(row.program),row.input),machine=()=>new PureCallMachine(checked.artifact,checked.input),m=machine();
 const header=pureCallHeader(m,checked.artifact,checked.input,row.model_steps,{sources:Object.entries(report.sources).sort(([a],[b])=>a<b?-1:a>b?1:0),report_hash:reportHash},{run_id:'pure-call-'+row.name});
 const bundle=recordPureCall(m,row.model_steps,header),result=replayPureCall(machine(),row.model_steps,header,bundle);
 if(result.execution!=='Completed'||result.conformance!=='Admitted')throw new Error('Unexpected development disagreement: '+row.name);
 cases.push({name:row.name,bundle,result});
}
for(const [path,expected] of Object.entries(report.sources))if(digest(path)!==expected)throw new Error('Oracle drift during replay');
for(const [p,expected] of Object.entries(before))if(digest(resolve(root,p))!==expected)throw new Error('Replay source drift');
if(digest(reportPath)!==reportHash)throw new Error('Parsed report bytes drift during replay');
const result={qualification:'UNKNOWN',scope:'Source-verified retained Shen cases, integrated pure-call exposed-state development replay',oracle_report:reportPath,oracle_report_hash:reportHash,sources:Object.entries(before),cases};
mkdirSync(dirname(output),{recursive:true});writeFileSync(output,encode(result));
console.log(JSON.stringify({qualification:'UNKNOWN',exact_completing_cases:cases.length,output}));
