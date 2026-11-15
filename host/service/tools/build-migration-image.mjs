#!/usr/bin/env node
// Stage A4: build the Solo5 guest image of the v1 -> v2 migration program
// (examples/service/migrate-v1-v2.fen; spec/service/UPGRADE.md section 5) for the OTP host.
//
//   node host/service/tools/build-migration-image.mjs ARTIFACT.json OUTDIR
//
// The program takes Unit, so the image holds one entry, request ["migrate"]; every
// row it reads and stages crosses the control channel as a host request (replies stay
// under the 512-byte limit of control protocol v2). The descriptor claims contract
// "migration" and a step budget of 100000 (the guest's limit), since a migration's steps
// grow with the store. No semantic decision is made here: the batch is built by the A2
// build step tools/solo5/control-durable-build.mjs, unchanged.
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {residualEffects, validatePureCallArtifact} from '../../../tools/tc0/pure-call-artifact.mjs';
import {encode} from '../../../tools/tc0/canonical.mjs';

const root=resolve(import.meta.dirname,'../../..');
const sha=b=>createHash('sha256').update(b).digest('hex');
const [artifactPath,outDir]=process.argv.slice(2);
if(!artifactPath||!outDir||process.argv.length!==4)throw new Error('usage: build-migration-image.mjs ARTIFACT OUTDIR');
const FUEL='100000';
const bytes=readFileSync(resolve(artifactPath));
const program=JSON.parse(bytes.toString('utf8'));
const input=['unit'];
const checked=validatePureCallArtifact(encode(program),input);
mkdirSync(resolve(outDir),{recursive:true});
const programsFile=resolve(outDir,'programs.json');
writeFileSync(programsFile,JSON.stringify({family:'service-a4-migration',fuel:FUEL,programs:[{name:'migrate',program,input,replies:[]}]}));
const batchDir=execFileSync(process.execPath,[resolve(root,'tools/solo5/control-durable-build.mjs'),'--programs',programsFile],
  {encoding:'utf8',maxBuffer:1<<26}).trim().split('\n').pop();
const batch=JSON.parse(readFileSync(resolve(batchDir,'batch.json'),'utf8'));
const artifactSha=sha(encode(checked.artifact));
if(!batch.programs.every(p=>p.artifact_sha256===artifactSha))throw new Error('artifact identity drift');
writeFileSync(resolve(outDir,'image.json'),JSON.stringify({
  schema:'fenrir.host.service-image/1',contract_version:'migration',
  image:batch.control,image_sha256:batch.control_sha256,tender:batch.tender,tender_sha256:batch.tender_sha256,
  solo5_identity:batch.solo5_identity,batch_sha256:batch.batch_sha256,batch_dir:batchDir,
  protocol:'fenrir.solo5.pure-call-control/2',machine_profile:'fenrir.solo5.pure-call-machine/2',
  programs:batch.programs.length,fuel:FUEL,
  artifact_sha256:artifactSha,artifact_file_sha256:sha(bytes),artifact_schema:checked.artifact.schema_version,
  domain:{migration:true},
  residual_effects:residualEffects(checked.artifact),
  datatypes:checked.artifact.datatypes,
  entries:[{request:['migrate'],program:0,input_sha256:batch.programs[0].input_sha256}]})+'\n');
console.log(resolve(outDir,'image.json'));
