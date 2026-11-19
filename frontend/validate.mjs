#!/usr/bin/env node
// Transport only: hand one artifact file to the artifact validator
// (tools/tc0/pure-call-artifact.mjs) and report its verdict as one JSON line.
// No rule about artifacts lives here. The validator chooses a typed probe for
// a durable entry request; other schemas use the fixed ["int","0"].
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
import {validateFrontendArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from '../tools/tc0/pure-call-artifact.mjs';
import {encode,EncodingError,EncodingLimit} from '../tools/tc0/canonical.mjs';

const path=process.argv[2];
if(!path||process.argv.length!==3){console.error('usage: node frontend/validate.mjs ARTIFACT.json');process.exit(2);}
const bytes=readFileSync(path);
let report;
try {
  const {artifact,node_count}=validateFrontendArtifact(bytes);
  const canonical=encode(artifact);
  report={status:'valid',nodes:node_count,functions:String(artifact.functions.length),canonical:canonical.equals(bytes),
    sha256:createHash('sha256').update(canonical).digest('hex')};
} catch(error) {
  if(error instanceof PureCallValidationLimit||error instanceof EncodingLimit)report={status:'limit',message:error.message};
  else if(error instanceof InvalidPureCallArtifact||error instanceof EncodingError)report={status:'invalid',message:error.message};
  else throw error;
}
console.log(JSON.stringify(report));
