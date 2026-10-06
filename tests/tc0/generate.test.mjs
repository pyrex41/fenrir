import test from 'node:test';
import assert from 'node:assert/strict';
import {generate} from '../../tools/tc0/generate.mjs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validateArtifact} from '../../tools/tc0/artifact.mjs';
import {ExpressionMachine} from '../../runtime/tc0/expression-machine.mjs';
test('bounded deterministic generation validates every artifact and reports truncation',()=>{
 const rows=[...generate({maxCases:17})];assert.equal(rows.length,17);
 assert.deepEqual(rows,[...generate({maxCases:17})]);
 for(const r of rows) {validateArtifact(encode(r.artifact),r.input);assert.equal(r.enumeration.truncated,true);assert.equal(r.enumeration.qualification,'UNKNOWN');}
 const all=[...generate({maxCases:500})];assert.equal(all.length,400);assert.equal(all.at(-1).enumeration.truncated,false);
});
test('enumeration exposes ordering mutants even when terminal outcomes agree',()=>{
 let killed=0,agree=0;
 for(const row of generate({maxCases:32})) {
  const f=row.artifact.functions[0];
  const run=mutant=>new ExpressionMachine(f.body,f.parameter_id,row.input,{reverseOperands:mutant}).run(200);
  const control=run(false),mutant=run(true);
  assert.equal(control.execution,'Completed');assert.equal(mutant.execution,'Completed');
  const emissions=r=>r.events.filter(e=>e.kind==='Emit');
  if(control.outcome[0]==='Trap'&&emissions(control).length===0&&emissions(mutant).length>0) killed++;
  assert.deepEqual(control,run(false)); // Equivalent unmodified control repeats exactly.
  if(encode(control.outcome).equals(encode(mutant.outcome))) agree++; // Outcome agreement alone is insufficient.
 }
 assert.ok(killed>0);assert.ok(agree>0);
});
test('domain and cap errors fail before yielding any case',()=>{
 for(const options of [{maxCases:0},{maxCases:1.5},{integers:[]},{integers:['01']},{integers:['9223372036854775808']}]) assert.throws(()=>[...generate(options)]);
});
