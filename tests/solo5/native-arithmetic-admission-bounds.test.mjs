import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import {maxAdmissionBytes,readAdmissionFile} from '../../tools/solo5/native-arithmetic/lower.mjs';

test('bounded data reader accepts exact cap and rejects one extra byte',()=>{
 const dir=mkdtempSync(join(tmpdir(),'fenrir-reader-'));
 try {
  const p=join(dir,'data');
  writeFileSync(p,Buffer.alloc(maxAdmissionBytes));
  assert.equal(readAdmissionFile(p).length,maxAdmissionBytes);
  writeFileSync(p,Buffer.alloc(maxAdmissionBytes+1));
  assert.throws(()=>readAdmissionFile(p),/NativeAdmissionByteLimit/);
 } finally {rmSync(dir,{recursive:true,force:true});}
});

test('both Node CLIs cap artifact and input before semantic decoding; no output',()=>{
 const dir=mkdtempSync(join(tmpdir(),'fenrir-cli-bounds-'));
 const output=resolve('build/solo5',`admission-bounds-${process.pid}.h`);
 assert.equal(existsSync(output),false);
 try {
  const small=join(dir,'small'),huge=join(dir,'huge');
  writeFileSync(small,'{}');
  writeFileSync(huge,' '.repeat(maxAdmissionBytes+1));
  for(const endpoint of ['admit.mjs','lower.mjs']) {
   for(const files of [[huge,small],[small,huge]]) {
    const args=[resolve('tools/solo5/native-arithmetic',endpoint),...files];
    if(endpoint==='lower.mjs')args.push(output);
    const r=spawnSync(process.execPath,args,{encoding:'utf8',timeout:10000,maxBuffer:65536});
    assert.equal(r.error,undefined);
    assert.notEqual(r.status,0);
    assert.match(r.stderr,/NativeAdmissionByteLimit/);
    assert.equal(r.stdout,'');
    assert.equal(existsSync(output),false);
   }
  }
 } finally {rmSync(dir,{recursive:true,force:true});}
});
