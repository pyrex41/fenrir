#!/usr/bin/env node
// Builds the two images of the first remote-perform system (spec/tc1/EFFECTS.md §12)
// for a stock Solo5 tender: the caller, which runs the TC1 program of
// fixtures/tc1/remote-caller.mjs on the C machine of backends/solo5/pure-call, and
// the abstract counter peer. Guest sources: backends/solo5/remote. Development
// tooling only; no comparison happens here (harness/tc1-remote-run.shen does that).
//   node tools/solo5/remote-build.mjs [--solo5 DIR] [--abi spt|hvt] [--out DIR]
// Prints the output directory, which then holds caller.<abi>, peer.<abi>,
// program.json (the validated artifact, for the Shen model) and build.json.
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {toolchain, defaultSolo5, must, SOLO5_COMMIT} from './freerun.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
import {program, bindings, input} from '../../fixtures/tc1/remote-caller.mjs';

const root=resolve(import.meta.dirname,'../..');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const NAME=/^[a-z0-9-]{1,15}$/,EFFECT=/^[A-Za-z_][A-Za-z0-9_]*$/;
const FLAGS=['-O1','-Wall','-Wextra','-Werror','-I.'];
const DEVICES=names=>JSON.stringify({type:'solo5.manifest',version:1,devices:names.map(name=>({name,type:'BLOCK_BASIC'}))})+'\n';

function link(tools,dir,image,units,devices) {
  writeFileSync(resolve(dir,image+'-manifest.json'),DEVICES(devices));
  must(tools.elftool,['gen-manifest',image+'-manifest.json',image+'-manifest.c'],{cwd:dir});
  must(tools.cc,['-c',image+'-manifest.c','-o',image+'-manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi='+tools.abi,image+'-manifest.o',...units.map(u=>u+'.o'),'-o',image+'.'+tools.abi],{cwd:dir});
  return resolve(dir,image+'.'+tools.abi);
}

export function buildRemote(tools,dir) {
  mkdirSync(dir,{recursive:true});
  for(const [effect,peer] of bindings)if(!EFFECT.test(effect)||!NAME.test(peer))throw new Error('Binding outside the guest alphabet');
  const options={remoteEffects:bindings.map(([effect])=>effect)};
  const lowered=lowerBatch([{program,input}],options);
  const {artifact}=validatePureCallArtifact(encode(program),input,options);
  const peers=[...new Set(bindings.map(([,peer])=>peer))];
  // The declaration the supervisor reads from the image file before it starts anything.
  const declaration=`FENRIR-REMOTE-DECL/1 connects=${peers.join(',')}`;
  writeFileSync(resolve(dir,'data.h'),lowered.header+
    `#define REMOTE_DECL ${JSON.stringify(declaration)}\n`+
    `struct remote_binding { const char *effect,*peer; };\n`+
    `static const struct remote_binding remote_bindings[]={${bindings.map(([e,p])=>`{${JSON.stringify(e)},${JSON.stringify(p)}}`).join(',')}};\n`+
    `static const unsigned remote_binding_count=${bindings.length};\n`);
  const machine=resolve(root,'backends/solo5/pure-call'),remote=resolve(root,'backends/solo5/remote');
  for(const file of ['machine.c','machine.h','format.c'])copyFileSync(resolve(machine,file),resolve(dir,file));
  for(const file of ['wire.c','wire.h','support.c','support.h','caller.c','peer.c'])copyFileSync(resolve(remote,file),resolve(dir,file));
  // The machine is compiled as the pure-call guest compiles it; the remote sources as C99.
  for(const unit of ['machine','format'])must(tools.cc,['-std=c11',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  for(const unit of ['wire','support','caller','peer'])must(tools.cc,['-std=c99',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  const caller=link(tools,dir,'caller',['caller','support','wire','machine','format'],['inbox','outbox']);
  const peer=link(tools,dir,'peer',['peer','support','wire'],['inbox','outbox','store']);
  writeFileSync(resolve(dir,'program.json'),JSON.stringify(artifact)+'\n');
  const info={caller,peer,tender:tools.tender,abi:tools.abi,tender_sha256:tools.tender_sha256,solo5_commit:SOLO5_COMMIT,
    solo5_source:tools.solo5_source,solo5_path:tools.solo5_path,program:resolve(dir,'program.json'),program_sha256:lowered.batch_sha256,
    bindings,caller_sha256:sha(readFileSync(caller)),peer_sha256:sha(readFileSync(peer)),wire_version:'1'};
  writeFileSync(resolve(dir,'build.json'),JSON.stringify(info)+'\n');
  return info;
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const tools=toolchain(resolve(option('--solo5',defaultSolo5())),option('--abi','spt'));
  const out=resolve(option('--out',resolve(root,'build/solo5/remote',`${Date.now()}-${process.pid}`)));
  buildRemote(tools,out);
  console.log(out);
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
