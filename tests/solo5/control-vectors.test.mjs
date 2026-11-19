// Independent check of the frame layout in spec/solo5/pure-call-control-v1.vectors
// (the host checks the same vectors in Shen on every run) and of the identity header
// the controlled guest is built with. No Solo5 needed.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {controlHeader} from '../../tools/solo5/control-pure-call-build.mjs';

const root=resolve(import.meta.dirname,'../..');
const readVectors=version=>readFileSync(resolve(root,`spec/solo5/pure-call-control-v${version}.vectors`),'utf8')
  .split('\n').filter(l=>l&&!l.startsWith('#')).map(l=>{const [name,role,expected,hex]=l.split(' ');return {name,role,expected,bytes:Buffer.from(hex,'hex')};});
const vectors=readVectors(1);

function frame(bytes) {
  const h=bytes.subarray(0,26).toString('latin1');
  const m=/^FGC1 ([HGT])([A-Z]) (\d{8}) (\d{8})\n$/.exec(h);
  if(!m)return null;
  const n=Number(m[4]),payload=bytes.subarray(26,26+n);
  if(bytes.length!==27+n||bytes[26+n]!==10||![...payload].every(b=>b>=0x20&&b<=0x7e))return null;
  return {dir:m[1],type:m[2],seq:Number(m[3]),payload:JSON.parse(payload.toString('latin1'))};
}

test('host and guest vectors are single well-formed frames with canonical payloads',()=>{
  const good=vectors.filter(v=>v.role==='host'||v.role==='guest');
  assert.equal(good.length,8);
  for(const v of good) {
    const f=frame(v.bytes);
    assert.ok(f,v.name);
    assert.equal(f.dir,v.role==='host'?'H':'G',v.name);
    const text=v.bytes.subarray(26,v.bytes.length-1).toString('latin1');
    const sorted=Object.keys(f.payload).slice().sort();
    assert.deepEqual(Object.keys(f.payload),sorted,`${v.name}: keys sorted`);
    assert.equal(JSON.stringify(f.payload),text,`${v.name}: no whitespace, one spelling`);
    assert.ok(Object.values(f.payload).every(x=>typeof x==='string'),`${v.name}: string fields only`);
  }
});

test('reject vectors are not well-formed guest frames',()=>{
  const bad=vectors.filter(v=>v.role==='reject');
  assert.equal(bad.length,8);
  const guestFrame=b=>{const f=frame(b);return f&&f.dir==='G'&&'HYSDBE'.includes(f.type)?f:null;};
  for(const v of bad)assert.equal(guestFrame(v.bytes),null,v.name);
});

test('the identity header refuses spellings it cannot embed safely',()=>{
  const ok=controlHeader({artifact_sha256:['a'.repeat(64)]},[{artifact:{schema_version:'tc0-a-pure-call-demo/2'}}]);
  assert.match(ok,/pc_program_sha256\[\]=\{"a{64}"\}/);
  assert.match(ok,/pc_program_schema\[\]=\{"tc0-a-pure-call-demo\/2"\}/);
  assert.throws(()=>controlHeader({artifact_sha256:['a"b']},[{artifact:{schema_version:'x'}}]),/Unsupported identity/);
});

test('v2 adds host Reply and guest HostWait without changing frame layout',()=>{
  const parsed=readVectors(2).map(({name,bytes,expected})=>({name,expected,...frame(bytes)}));
  const [reply,data,error,waiting,bad]=parsed;
  assert.deepEqual([reply.dir,reply.type,reply.seq,reply.payload],['H','A',5,{kind:'Reply',request:'0',value:['int','1']}]);
  assert.deepEqual(data.payload.value,['data','Answer','Busy']);
  assert.equal(error.payload.code,'BadReply');
  assert.equal(waiting.payload.execution,'HostWait');
  assert.equal(waiting.payload.steps[0].events[0].kind,'HostRequest');
  assert.equal(bad.dir,'G');
  assert.equal(bad.type,'A');
  assert.equal(bad.expected,'UnknownType');
});
