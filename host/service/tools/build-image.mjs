#!/usr/bin/env node
// Stage A3: build the Solo5 guest image of the accepted-job handler for the OTP host.
//
//   node host/service/tools/build-image.mjs ARTIFACT.json OUTDIR TENANTS KEYS DIGESTS JOBS [CONTRACT]
//
// CONTRACT (A4, spec/service/UPGRADE.md section 2) is the storage-contract version the image
// claims, 1 (default) or 2; the host refuses a descriptor whose claim differs from the
// contract its manifest matches (host/service/src/fenrir_manifest.erl).
//
// Control protocol v2 lowers each entry input INTO the image (spec/solo5/pure-call-control-v2.md
// section 3: one image entry is one (artifact, input) pair; Init selects an entry by index).
// A request cannot travel over the channel, so the image holds one entry per request of a
// finite request domain: every Submit (Tenant t) k d payload with payload the single octet d
// (A2's abstraction, models/service-a2/store-contract.shen sst.command), and every
// Complete (Tenant t) j ok for j < JOBS. The worker refuses a request outside the domain.
//
// This makes no semantic decision: it writes the batch file that
// tools/solo5/control-durable-build.mjs reads (the A2 build step, unchanged), runs it, and
// writes OUTDIR/image.json: the image, its identities, the entry table and the artifact's
// residual effect row (tools/tc0/pure-call-artifact.mjs residualEffects).
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {residualEffects, validatePureCallArtifact} from '../../../tools/tc0/pure-call-artifact.mjs';
import {encode} from '../../../tools/tc0/canonical.mjs';

const root=resolve(import.meta.dirname,'../../..');
const sha=b=>createHash('sha256').update(b).digest('hex');
const [artifactPath,outDir,...rest]=process.argv.slice(2);
const nums=rest.slice(0,4);
const contract=rest.length>4?Number(rest[4]):1;
if(contract!==1&&contract!==2)throw new Error('CONTRACT is 1 or 2');
const [tenants,keys,digests,jobs]=nums.map(Number);
if(!artifactPath||!outDir||![tenants,keys,digests,jobs].every(n=>Number.isSafeInteger(n)&&n>=1&&n<=64))
  throw new Error('usage: build-image.mjs ARTIFACT OUTDIR TENANTS KEYS DIGESTS JOBS (each 1..64)');
if(digests>256)throw new Error('a digest is one octet');
const bytes=readFileSync(resolve(artifactPath));
const program=JSON.parse(bytes.toString('utf8'));
const int=n=>['int',String(n)];
const cap=t=>['data','Cap','Tenant',int(t)];
const hex=d=>d.toString(16).padStart(2,'0');
const entries=[];
for(let t=0;t<tenants;t++)for(let k=0;k<keys;k++)for(let d=0;d<digests;d++)
  entries.push({request:['submit',t,k,d],input:['data','Command','Submit',cap(t),int(k),int(d),['bytes',hex(d)]]});
for(let t=0;t<tenants;t++)for(let j=0;j<jobs;j++)for(const ok of [true,false])
  entries.push({request:['complete',t,j,ok],input:['data','Command','Complete',cap(t),int(j),['bool',ok]]});
if(entries.length>4096)throw new Error('more than 4096 entries');
const checked=validatePureCallArtifact(encode(program),entries[0].input);
mkdirSync(resolve(outDir),{recursive:true});
const programsFile=resolve(outDir,'programs.json');
writeFileSync(programsFile,JSON.stringify({family:'service-a3',
  programs:entries.map(e=>({name:e.request.join('-'),program,input:e.input,replies:[]}))}));
const batchDir=execFileSync(process.execPath,[resolve(root,'tools/solo5/control-durable-build.mjs'),'--programs',programsFile],
  {encoding:'utf8',maxBuffer:1<<26}).trim().split('\n').pop();
const batch=JSON.parse(readFileSync(resolve(batchDir,'batch.json'),'utf8'));
const artifactSha=sha(encode(checked.artifact));
if(!batch.programs.every(p=>p.artifact_sha256===artifactSha))throw new Error('artifact identity drift');
writeFileSync(resolve(outDir,'image.json'),JSON.stringify({
  schema:'fenrir.host.service-image/1',contract_version:contract,
  image:batch.control,image_sha256:batch.control_sha256,tender:batch.tender,tender_sha256:batch.tender_sha256,
  solo5_identity:batch.solo5_identity,batch_sha256:batch.batch_sha256,batch_dir:batchDir,
  protocol:'fenrir.solo5.pure-call-control/2',machine_profile:'fenrir.solo5.pure-call-machine/2',
  programs:batch.programs.length,fuel:'5000',
  artifact_sha256:artifactSha,artifact_file_sha256:sha(bytes),artifact_schema:checked.artifact.schema_version,
  domain:{tenants,keys,digests,jobs},
  residual_effects:residualEffects(checked.artifact),
  datatypes:checked.artifact.datatypes,
  entries:entries.map((e,i)=>({request:e.request,program:i,input_sha256:batch.programs[i].input_sha256}))})+'\n');
console.log(resolve(outDir,'image.json'));
