#!/usr/bin/env node
// Test support for frontend/test.sh: put artifacts the frontend produced into a
// Solo5 guest image, in the batch layout harness/solo5-pure-call.shen reads
// (what tools/solo5/freerun-pure-call.mjs --build-only writes for the fixtures).
// Only assembles: lowering, validation and the guest build are the existing
// tools, imported unchanged; the comparison is the Shen harness's.
//
//   node tests/frontend/solo5-batch.mjs ARTIFACT.json...
// prints the batch directory. Needs Solo5 built at the pinned commit: FENRIR_SOLO5,
// else build/vendor/solo5 (defaultSolo5 of tools/solo5/freerun.mjs).
import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {toolchain,defaultSolo5} from '../../tools/solo5/freerun.mjs';
import {buildGuest} from '../../tools/solo5/freerun-pure-call.mjs';
import {lowerBatch} from '../../tools/solo5/pure-call/lower.mjs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';

const root=resolve(import.meta.dirname,'../..'),INPUT=['int','0'];
const files=process.argv.slice(2);
if(!files.length){console.error('usage: node tests/frontend/solo5-batch.mjs ARTIFACT.json...');process.exit(2);}
const tools=toolchain(defaultSolo5());
const out=resolve(root,'build/frontend/solo5',`${Date.now()}-${process.pid}`);
const artifacts=files.map(file=>validatePureCallArtifact(readFileSync(file),INPUT).artifact);
const lowered=lowerBatch(artifacts.map(program=>({program,input:INPUT})));
const guest=buildGuest(tools,lowered.header,out);
mkdirSync(out,{recursive:true});
writeFileSync(resolve(out,'programs.json'),JSON.stringify(artifacts));
writeFileSync(resolve(out,'batch.json'),JSON.stringify({guest,tender:tools.tender,batch_sha256:lowered.batch_sha256,
  programs:resolve(out,'programs.json'),count:String(artifacts.length)})+'\n');
console.log(out);
