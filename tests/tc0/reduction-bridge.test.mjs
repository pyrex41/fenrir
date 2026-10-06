import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {encode,decode} from '../../tools/tc0/canonical.mjs';
const bridge=fileURLToPath(new URL('../../tools/tc0/reduction-bridge.mjs',import.meta.url));
function call(request) {
 const result=spawnSync(process.execPath,[bridge],{input:encode(request),timeout:10000,maxBuffer:4*1024*1024});
 assert.ifError(result.error);assert.equal(result.status,0,result.stderr.toString());return decode(result.stdout);
}
test('bridge proposes canonical string metrics, not forbidden JSON numbers',()=>{
 const row=call({action:'generate',max_cases:'4'})[3];
 const proposals=call({action:'proposals',artifact:row.artifact,input:row.input});
 assert.ok(proposals.length>0);
 for(const p of proposals) for(const n of p.metric) assert.match(n,/^(0|[1-9][0-9]*)$/);
});
test('generated trap has independently hand-predicted terminal and emission behavior',()=>{
 const row=call({action:'generate',max_cases:'4'})[3];
 // if true: add(div(-2,0), let ignored=emit(rhs,-2) in -2).
 // Left div traps; normal trace must never enter RHS. Reversed ordering emits first.
 const result=call({action:'run',artifact:row.artifact,input:row.input});
 assert.deepEqual(result.control.outcome,['Trap','DivZero']);
 assert.deepEqual(result.mutant.outcome,['Trap','DivZero']);
 assert.deepEqual(result.control.events.filter(e=>e.kind==='Emit'),[]);
 assert.equal(result.mutant.events.filter(e=>e.kind==='Emit').length,1);
 assert.equal(result.metric[0],'11');
});
test('malformed artifact fails before candidate execution',()=>{
 const result=spawnSync(process.execPath,[bridge],{input:encode({action:'run',artifact:{},input:['unit']}),timeout:10000});
 assert.ifError(result.error);assert.notEqual(result.status,0);assert.equal(result.stdout.length,0);
});
