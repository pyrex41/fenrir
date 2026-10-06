import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validateClosureProgram} from '../../tools/tc0/closure-artifact.mjs';
import {ClosureMachine} from '../../runtime/tc0/closure-machine.mjs';
const program=JSON.parse(readFileSync(new URL('../../fixtures/tc0/closure-capture-program.json',import.meta.url)));
const clone=x=>JSON.parse(JSON.stringify(x));
function run(p=program,fuel=200){const c=validateClosureProgram(encode(p),['int','0']);return new ClosureMachine(c.program,c.input).run(fuel);}
test('lexical captures retain pure value and checked empty support across tail application',()=>{
 const c=validateClosureProgram(encode(program),['int','0']);assert.deepEqual(c.codes,[{code_id:'7',parameter_id:'8',free_bindings:['2'],capture_support:[]}]);
 const result=run();assert.deepEqual(result.outcome,['Ok',['int','12']]);
 assert.deepEqual(result.descriptors,[{code_id:'7',captures:[['2',['int','7']]],capture_support:[]}]);
 // Hand-derived staging: literal/lambda do not consume their frame; collection does not apply.
 assert.deepEqual(result.steps.map(s=>[s.after,s.depth]),[
 ['Eval','1'],['Value','1'],['Eval','0'],['Eval','1'],['Value','1'],['Eval','0'],
 ['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Eval','0'],
 ['Eval','1'],['Value','1'],['Eval','1'],['Value','1'],['Ready','0'],['Value','0'],
 ['Join','0'],['Terminate','0'],['Terminal','0']]);
 assert.equal(run(program,20).execution,'BudgetExhausted');assert.equal(run(program,21).execution,'Completed');
});
test('higher-order parameter preserves closure descriptor and captures',()=>{
 const p=clone(program);p.body[4][4]=['apply','21',
 ['lambda','15','16',['Arrow','I64','I64'],'I64',[],[],['apply','17',['var','18','16'],['int','19','5']]],['var','20','5']];
 const result=run(p);assert.deepEqual(result.outcome,['Ok',['int','12']]);
 assert.deepEqual(result.descriptors[0].capture_support,[]);assert.deepEqual(result.descriptors[1],{code_id:'15',captures:[],capture_support:[]});
 assert.ok(result.steps.every(s=>Number(s.depth)<=1));
});
test('non-tail apply restores explicit caller frame before sibling operand',()=>{
 const p=clone(program),app=p.body[4][4];p.body[4][4]=['add','22',app,['int','23','1']];
 const result=run(p);assert.deepEqual(result.outcome,['Ok',['int','13']]);
 assert.ok(result.steps.some(s=>s.site.rule==='ReturnReturn'));
 assert.ok(Number(result.steps.find(s=>s.site.node==='12'&&s.site.rule==='Ready').depth)>0);
});
test('nested returned closure captures outer argument and retained lexical value',()=>{
 const p=clone(program);
 p.body[4][3]=['lambda','7','8','I64',['Arrow','I64','I64'],[],[],
  ['lambda','15','16','I64','I64',[],[],['add','17',['add','9',['var','10','2'],['var','11','8']],['var','18','16']]]];
 p.body[4][4]=['apply','12',['apply','19',['var','13','5'],['int','14','3']],['int','20','5']];
 const result=run(p);assert.deepEqual(result.outcome,['Ok',['int','15']]);
 assert.deepEqual(result.descriptors[1],{code_id:'15',captures:[['2',['int','7']],['8',['int','3']]],capture_support:[]});
});
test('captures sort numerically rather than by visitation or decimal lexical order',()=>{
 const p={schema:'pure-closure-demo/1',input_binding:'1',body:['let','2','20',['int','3','7'],
  ['apply','9',['lambda','4','5','I64','I64',[],[],['add','6',['var','7','20'],['var','8','1']]],['int','10','0']]]};
 const result=run(p);assert.deepEqual(result.descriptors[0].captures.map(r=>r[0]),['1','20']);
});
test('validator rejects captures with support, effects, missing names and incorrect application types',()=>{
 for(const mutate of [p=>p.body[4][3][6].push('99'),p=>p.body[4][3][5].push('Emit'),
 p=>p.body[4][3][7][2][2]='999',p=>p.body[4][4][2]=['int','13','1'],p=>p.body[4][3][4]=['Arrow','I64','I64']]) {
  const p=clone(program);mutate(p);assert.throws(()=>validateClosureProgram(encode(p),['int','0']));
 }
});
