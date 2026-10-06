// Development evidence aggregation only; no evaluator registration/credit.
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const base=resolve(process.argv[2]),hash=p=>createHash('sha256').update(readFileSync(p)).digest('hex'),load=p=>JSON.parse(readFileSync(p));
const manifest=load(resolve(base,'manifest.json'));assert.equal(manifest.cases.length,16);
const generator=fileURLToPath(new URL('./generated-cases.mjs',import.meta.url));assert.equal(hash(generator),manifest.generator_sha256);
function check(name,dir){
 const normal=load(resolve(dir,name+'-normal.json')),mutant=load(resolve(dir,name+'-mutant.json'));assert.equal(normal.result.conformance,'Admitted');assert.equal(normal.result.execution,'Completed');assert.equal(normal.result.cleanup,'confirmed');assert.equal(mutant.result.cleanup,'confirmed');return {normal,mutant};
}
const original=load(resolve(base,'case_00-mutant.json')),control=load(resolve(base,'case_00-control.json'));assert.equal(control.result.conformance,'Admitted');assert.equal(original.result.conformance,'Diverged');assert.equal(original.result.first_error.epoch,'1');assert.equal(original.result.choices.length,2);
for(const [path,h]of Object.entries(original.sources))assert.equal(hash(path),h,'original identity drift: '+path);
const replay=load(resolve(base,'case_00-mutant-replay.json'));assert.equal(replay.replay,'Exact');assert.equal(replay.result.conformance,'Diverged');assert.equal(replay.original_sha256,hash(resolve(base,'case_00-mutant.json')));
const red=resolve(base,'reduction'),proposals=load(resolve(red,'manifest.json'));assert.equal(proposals.cases.length,3);
const attempts=[];let bestNodes=Number(manifest.cases[0].nodes),best='case_00';
for(const c of proposals.cases){const {normal,mutant}=check(c.name,red);const accepted=mutant.result.conformance==='Diverged';if(accepted){assert(Number(c.nodes)<bestNodes);assert.equal(mutant.result.first_error.kind,'RecordMismatch');assert.equal(mutant.result.first_error.epoch,'1');bestNodes=Number(c.nodes);best=c.name;}else{assert.equal(mutant.result.conformance,'Admitted');assert.equal(mutant.result.execution,'Completed');}
 attempts.push({name:c.name,nodes:c.nodes,accepted,reason:accepted?'fresh normal agreement and mutant divergence preserved':'valid artifact loses divergence',normal_sha256:hash(resolve(red,c.name+'-normal.json')),mutant_sha256:hash(resolve(red,c.name+'-mutant.json')),build_sha256:hash(resolve(red,c.name+'-build/build.json'))});}
const smallReplay=load(resolve(red,'attempt_2-replay.json'));assert.equal(smallReplay.replay,'Exact');assert.equal(smallReplay.result.conformance,'Diverged');
const report={schema:'fenrir.solo5.native-arithmetic-discovery-development/1',qualification:'UNKNOWN',generator_sha256:hash(generator),verifier_sha256:hash(fileURLToPath(import.meta.url)),generated:'16',evaluated_until_first_failure:'1',unevaluated:'15',stop_reason:'first generated native discrepancy',bounds:manifest.bounds,original:{name:'case_00',nodes:manifest.cases[0].nodes,artifact_sha256:manifest.cases[0].artifact_sha256,control_sha256:hash(resolve(base,'case_00-control.json')),mutant_sha256:hash(resolve(base,'case_00-mutant.json')),replay_sha256:hash(resolve(base,'case_00-mutant-replay.json')),guest_sha256:hash(resolve(base,'case_00-build/guest.spt')),build_sha256:hash(resolve(base,'case_00-build/build.json')),first_error:original.result.first_error},attempts,retained_smaller:{name:best,nodes:String(bestNodes),replay_sha256:hash(resolve(red,'attempt_2-replay.json'))},reduction_limit:'3 attempts',global_minimality:false,independent_repair:'NOT_EXECUTED',cleanup:'confirmed',limitations:['Development-only source-bound evidence','No native startup/counter closure','No crash/watchdog exact-replay claim','No generated coverage beyond first evaluated case']};
writeFileSync(resolve(base,'discovery-summary.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify({qualification:'UNKNOWN',generated:16,evaluated:1,original_nodes:report.original.nodes,smaller_nodes:report.retained_smaller.nodes,rejected_attempts:attempts.filter(a=>!a.accepted).length,original_replay:'Exact/Diverged',cleanup:'confirmed',report:resolve(base,'discovery-summary.json')}));
