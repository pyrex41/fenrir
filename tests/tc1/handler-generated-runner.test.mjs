// The JavaScript peer of the generated-family harness (tools/tc1/run-handler-generated.mjs):
// what it writes in each mode. Transport checks only: the programs here are hand fixtures,
// the generator is harness/tc1-generate.shen, and the comparing is done in Shen.
import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync,mkdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {MUTANTS} from '../../tools/tc1/handler-defects.mjs';
import {cases,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';

const fixtures=[...cases,...resumptionCases];
function run(lines,mode,fuel='200') {
  const dir=mkdtempSync(join(tmpdir(),'fenrir-generated-'));
  try {
    const input=join(dir,'in.jsonl'),out=join(dir,'out');mkdirSync(out);
    writeFileSync(input,lines.map(l=>JSON.stringify(l)).join('\n')+'\n');
    const r=spawnSync(process.execPath,['tools/tc1/run-handler-generated.mjs',input,out,fuel,mode],{encoding:'utf8'});
    if(r.status!==0)return {status:r.status,stderr:r.stderr};
    const header=JSON.parse(readFileSync(join(out,'family.json'),'utf8')),rows=[];
    for(let i=0;i<Number(header.chunks);i++)rows.push(...readFileSync(join(out,`chunk-${i}.jsonl`),'utf8').split('\n').filter(Boolean).map(l=>JSON.parse(l)));
    return {status:0,header,rows};
  } finally {rmSync(dir,{recursive:true});}
}
const lines=fixtures.map(c=>({name:c.name,program:c.program}));

test('family mode reports one row per program, in order, and a rejection is a row, not a stop', () => {
  const broken={name:'broken',program:{...fixtures[0].program,slice:'TC0-A'}};
  const {header,rows}=run([lines[0],broken,...lines.slice(1)],'family');
  assert.equal(header.count,String(lines.length+1));assert.equal(header.invalid,'1');
  assert.deepEqual(rows.map(r=>r.name),[lines[0].name,'broken',...lines.slice(1).map(l=>l.name)]);
  assert.deepEqual(rows[1],{name:'broken',valid:false,error:'Identity'});
  for(const row of rows.filter(r=>r.valid)){assert.equal(row.candidate.execution,'Completed');assert.deepEqual(row.mutants,{});assert.match(row.nodes,/^[1-9][0-9]*$/);}
});

test('a defect switched on in family mode is reported as the implementation, and changes some trace', () => {
  const clean=run(lines,'family'),defective=run(lines,'family:forgotten_resume');
  assert.equal(defective.header.mode,'family:forgotten_resume');
  assert.ok(defective.rows.some((row,i)=>JSON.stringify(row.candidate)!==JSON.stringify(clean.rows[i].candidate)));
});

test('mutants mode carries the six defective runs; shrink mode keeps only differing programs, smallest first', () => {
  const all=run(lines,'mutants');
  for(const row of all.rows)assert.deepEqual(Object.keys(row.mutants),Object.keys(MUTANTS));
  const kept=run(lines,'shrink:forgotten_resume');
  assert.ok(kept.rows.length>=1&&kept.rows.length<=5);assert.ok(Number(kept.header.differing)>=kept.rows.length);
  const sizes=kept.rows.map(r=>Number(r.nodes));assert.deepEqual(sizes,[...sizes].sort((a,b)=>a-b));
  for(const row of kept.rows) {
    assert.deepEqual(Object.keys(row.mutants),['forgotten_resume']);
    assert.equal(row.mutants.forgotten_resume.execution,'Completed');
    assert.notDeepEqual(row.mutants.forgotten_resume.steps,row.candidate.steps);
  }
});

test('the step bound is honoured and unknown modes are refused', () => {
  assert.ok(run(lines,'family','3').rows.every(r=>r.candidate.execution==='BudgetExhausted'&&r.candidate.steps.length===3));
  assert.notEqual(run(lines,'family:no_such_defect').status,0);
  assert.notEqual(run(lines,'shrink').status,0);
});
