#!/usr/bin/env node
// Transport only: hand one artifact file to the artifact validator
// (tools/tc0/pure-call-artifact.mjs) and report its verdict as one JSON line.
// No rule about artifacts lives here. Entry input is the harness's fixed ["int","0"].
//
//   node frontend/validate.mjs ARTIFACT.json
//
// status "valid"   with the node count, the function count, whether the file's
//                  bytes are already the canonical encoding, and the SHA-256 of
//                  the canonical encoding (the artifact's identity)
// status "invalid" the validator's or the decoder's reason
// status "limit"   a size or work cap of the validator, not a judgement of the program
// The exit status is 0 whenever a verdict was reached.
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from '../tools/tc0/pure-call-artifact.mjs';
import {encode,EncodingError,EncodingLimit} from '../tools/tc0/canonical.mjs';

const path=process.argv[2];
if(!path||process.argv.length!==3){console.error('usage: node frontend/validate.mjs ARTIFACT.json');process.exit(2);}
const bytes=readFileSync(path);
// TC1-D1 (spec/tc1/DURABLE.md section 10): a durable program's entry may take a request
// of any serializable type, supplied by its host. The artifact does not depend on the
// input, so it is validated with the least value of that type (its first constructor
// that ends, recursively); the real request is validated where the host supplies it.
function least(t,datatypes,depth=0) {
  if(depth>16)return null;
  if(t==='Unit')return ['unit'];if(t==='Bool')return ['bool',false];if(t==='I64')return ['int','0'];
  if(t==='Bytes')return ['bytes',''];if(t==='TrapCode')return ['data','TrapCode','Overflow'];
  if(Array.isArray(t)&&t[0]==='Tuple'){const vs=t.slice(1).map(x=>least(x,datatypes,depth+1));return vs.includes(null)?null:['tuple',...vs];}
  if(Array.isArray(t)&&t[0]==='Data'){
    for(const c of datatypes.find(d=>d.name===t[1])?.constructors??[]){
      const vs=c.fields.map(f=>least(f,datatypes,depth+1));if(!vs.includes(null))return ['data',t[1],c.name,...vs];
    }
  }
  return null;
}
function input(bytes) {
  try{const a=JSON.parse(bytes.toString('utf8'));
    if(a?.schema_version==='tc1-durable-demo/1')return least(a.input_schema?.type,a.datatypes??[])??['int','0'];}catch{}
  return ['int','0'];
}
let report;
try {
  const {artifact,node_count}=validatePureCallArtifact(bytes,input(bytes));
  const canonical=encode(artifact);
  report={status:'valid',nodes:node_count,functions:String(artifact.functions.length),canonical:canonical.equals(bytes),
    sha256:createHash('sha256').update(canonical).digest('hex')};
} catch(error) {
  if(error instanceof PureCallValidationLimit||error instanceof EncodingLimit)report={status:'limit',message:error.message};
  else if(error instanceof InvalidPureCallArtifact||error instanceof EncodingError)report={status:'invalid',message:error.message};
  else throw error;
}
console.log(JSON.stringify(report));
