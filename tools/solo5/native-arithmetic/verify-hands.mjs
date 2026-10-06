import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const base=resolve(process.argv[2]);
const hash=p=>createHash('sha256').update(readFileSync(p)).digest('hex');
const manifest=JSON.parse(readFileSync(resolve(base,'manifest.json'))),rows=[];
for(const hand of manifest){
 const path=resolve(base,hand.name+'-session.json'),b=JSON.parse(readFileSync(path));
 assert.equal(b.result.conformance,'Admitted');assert.equal(b.result.execution,hand.execution);assert.equal(b.result.cleanup,'confirmed');assert.deepEqual(b.model.outcome,hand.outcome);
 const emits=b.model.steps.flatMap(s=>s.events).filter(e=>e.kind==='Emit').map(e=>e.label);assert.deepEqual(emits,hand.emits);
 if(hand.rules)assert.deepEqual(b.model.steps.map(s=>s.site.rule),hand.rules);
 const samples=b.result.trace.filter(r=>r.kind==='Sample').map(r=>r.sample);assert.deepEqual(samples,b.model.steps);
 rows.push({name:hand.name,report:path,sha256:hash(path),steps:String(samples.length),execution:b.result.execution,hand_outcome_agrees:true,hand_emissions_agree:true,hand_rules_agree:hand.rules?true:null});
}
const report={schema:'fenrir.solo5.native-arithmetic-hand-development/1',qualification:'UNKNOWN',manifest_sha256:hash(resolve(base,'manifest.json')),generator_sha256:hash(new URL('./hand-cases.mjs',import.meta.url)),verifier_sha256:hash(new URL('./verify-hands.mjs',import.meta.url)),cases:rows,cleanup:'confirmed'};
writeFileSync(resolve(base,'hand-summary.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify({qualification:'UNKNOWN',hand_cases:rows.length,hand_agreement:true,report:resolve(base,'hand-summary.json')}));
