import {test} from 'node:test';
import assert from 'node:assert/strict';
import {compileArtifact,proofInstance,UnsupportedProfile} from '../../tools/aarch64/compile.mjs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {fixture} from '../../tools/aarch64/fixtures.mjs';
test('fixed encodings and byte-bound proof instance',()=>{
 const r=compileArtifact(encode(fixture([['add',4095],['sub',0],['neg']])));
 assert.deepEqual(r.words,[0xb13ffc00,0x54000067,0xd2800021,0xd65f03c0,0xf1000000,0x54000067,0xd2800021,0xd65f03c0,0xeb0003e0,0x54000067,0xd2800021,0xd65f03c0,0xd2800001,0xd65f03c0]);
 assert.match(proofInstance(r),/Theorem exact_image_correct/);
});
test('unsupported well-typed syntax is rejected',()=>{
 for(const ops of [[['mul',2]],[['add',4096]],[['sub',-1]]])assert.throws(()=>compileArtifact(encode(fixture(ops))),UnsupportedProfile);
 const a=fixture([]);a.functions[0].body=['int','2','7'];assert.throws(()=>compileArtifact(encode(a)),UnsupportedProfile);
});
test('malformed input still goes through full closed TC0 validator',()=>{
 const a=fixture([['add',1]]);a.functions[0].body[1]='0';assert.throws(()=>compileArtifact(encode(a)),/Duplicate ID/);
 const b=fixture([]);b.functions[0].effects=['Emit'];assert.throws(()=>compileArtifact(encode(b)),UnsupportedProfile);
});
test('source overflow is observable even when later subtraction could cancel it',()=>{
 const a=fixture([['add',1],['sub',1]]);
 assert.deepEqual(new PureCallMachine(a,['int','9223372036854775807']).run(200).outcome,['Trap','Overflow']);
});
