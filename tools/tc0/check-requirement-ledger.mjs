// Structural check of the TC0-A requirement ledger, NOT a gate evaluator.
// Usage: node tools/tc0/check-requirement-ledger.mjs [LEDGER]
// Fails if a row is malformed or duplicated, uses a status outside the declared set,
// if that set names a verdict only the evaluator may issue (PASS/QUALIFIED), if a row
// cites evidence that does not exist, or marks evidence/gaps inconsistently.
import {existsSync,readFileSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
export function checkLedger(ledger){
 const problems=[],seen=new Set(),statuses=Object.keys(ledger.statuses??{});
 if(ledger.schema!=='tc0-requirement-ledger/1')problems.push('schema');
 if(statuses.some(s=>/PASS|QUALIFIED/.test(s)))problems.push('status set names a verdict');
 for(const row of ledger.rows??[]){
  const keys=Object.keys(row).sort().join(',');
  if(keys!=='evidence,gaps,id,requirement,source,status')problems.push(`${row.id}: closed fields`);
  if(seen.has(row.id))problems.push(`${row.id}: duplicate`);seen.add(row.id);
  if(!statuses.includes(row.status))problems.push(`${row.id}: status ${row.status}`);
  for(const p of row.evidence??[])if(!existsSync(resolve(root,p)))problems.push(`${row.id}: missing evidence ${p}`);
  if(row.status==='DEVELOPMENT-EVIDENCE'&&!row.evidence.length)problems.push(`${row.id}: evidence status without evidence`);
  if(['UNKNOWN','BLOCKED','NOT-EXECUTED'].includes(row.status)&&!row.gaps.length)problems.push(`${row.id}: open status without a stated gap`);
 }
 const count=s=>String((ledger.rows??[]).filter(r=>r.status===s).length);
 return {problems,summary:Object.fromEntries(statuses.map(s=>[s,count(s)]))};
}
if(import.meta.url===`file://${process.argv[1]}`){
 const path=resolve(process.argv[2]??resolve(root,'spec/tc0/requirement-ledger-a.json'));
 const {problems,summary}=checkLedger(JSON.parse(readFileSync(path,'utf8')));
 console.log(JSON.stringify({qualification:'UNKNOWN',ledger:path,summary,problems}));
 process.exit(problems.length?1:0);
}
