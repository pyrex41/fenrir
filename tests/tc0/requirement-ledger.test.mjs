import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {checkLedger} from '../../tools/tc0/check-requirement-ledger.mjs';
const ledger=()=>JSON.parse(readFileSync(new URL('../../spec/tc0/requirement-ledger-a.json',import.meta.url)));
test('the TC0-A requirement ledger is well formed and cites only existing evidence',()=>{
 const {problems,summary}=checkLedger(ledger());assert.deepEqual(problems,[]);
 assert.ok(Number(summary.UNKNOWN)>=1,'open rows stay visible');
 const repair=ledger().rows.find(r=>r.id==='TC0-INDEPENDENT-REPAIR');assert.ok(repair.gaps.some(g=>/instruction-only/.test(g)),'repair keeps its isolation caveat');
});
test('the ledger checker rejects verdict statuses, missing evidence, silent gaps and duplicates',()=>{
 const mutations=[
  l=>{l.statuses.PASS='x';l.rows[0].status='PASS';},
  l=>{l.rows[4].evidence.push('tools/does-not-exist.mjs');},
  l=>{const r=l.rows.find(r=>r.status==='UNKNOWN');r.gaps=[];},
  l=>{l.rows.push(structuredClone(l.rows[0]));},
  l=>{l.rows[4].evidence=[];},
  l=>{l.rows[0].verdict='PASS';}
 ];
 for(const m of mutations){const l=ledger();m(l);assert.ok(checkLedger(l).problems.length>0,m.toString());}
});
