#!/usr/bin/env node
// Builds the images of the first remote-perform system (spec/tc1/EFFECTS.md §12)
// for a stock Solo5 tender: the caller, whose program is the SOURCE FILE
// examples/remote/ledger-caller.fen, elaborated by the frontend (frontend/fenrir.sh
// emit) and run on the C machine of backends/solo5/pure-call, and the abstract
// counter peer. Guest sources: backends/solo5/remote. Development tooling only; no
// comparison happens here (harness/tc1-remote-run.shen does that).
//   node tools/solo5/remote-build.mjs [--solo5 DIR] [--abi spt|hvt] [--out DIR]
// Prints the output directory, which then holds caller.<abi>, peer.<abi>,
// peer-nostore.<abi>, program.json (the validated artifact, for the Shen model)
// and build.json.
//
// What an image says about itself is DERIVED here, from the program's remote-effect
// declarations (artifact schema tc1-handler-demo/3) and the one thing a program does
// not say, the build's binding of each remote effect to a member:
//   caller  FENRIR-REMOTE-DECL/2 connects=<peers> uses=<peer>/<Effect>.<op>/<mode>,...
//   peer    FENRIR-REMOTE-SERVES/1 store=yes|no operations=<Effect>.<op>/<mode>,...
// mode is keyed or read-only. The supervisor reads both lines from the image files
// before it starts anything (supervisor/src/fenrir_relay.erl); assemblyProblems
// below is the same check, for a build to make before it hands images over.
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {toolchain, defaultSolo5, must, SOLO5_COMMIT} from './freerun.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {validatePureCallArtifact, TC1_REMOTE_SCHEMA} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';

const root=resolve(import.meta.dirname,'../..');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const NAME=/^[a-z0-9-]{1,15}$/,EFFECT=/^[A-Za-z_][A-Za-z0-9_]*$/;
const FLAGS=['-O1','-Wall','-Wextra','-Werror','-I.'];
const DEVICES=names=>JSON.stringify({type:'solo5.manifest',version:1,devices:names.map(name=>({name,type:'BLOCK_BASIC'}))})+'\n';
const same=(a,b)=>encode(a).equals(encode(b));

// The system this file builds. The source is named relative to the repository, so
// that the artifact (whose source map carries the name) is the same in every clone.
export const SOURCE='examples/remote/ledger-caller.fen';
export const BINDINGS=Object.freeze([Object.freeze(['Ledger','peer'])]);
export const INPUT=Object.freeze(['int','0']);
export const WIRE_VERSION='3';

// Every operation of every remote effect the program declares, with the member its
// effect is bound to: [{effect, operation, peer, mode, argument_type, result_type}].
// A remote effect without a binding, and a binding that names no remote effect of
// the program, are errors: the connection list must be exactly what is declared.
export function remoteOperations(artifact,bindings) {
  if(artifact.schema_version!==TC1_REMOTE_SCHEMA)throw new Error(`A caller image is built from an artifact of schema ${TC1_REMOTE_SCHEMA}`);
  const bound=new Map();
  for(const [effect,peer] of bindings){
    if(!EFFECT.test(effect)||!NAME.test(peer))throw new Error('Binding outside the guest alphabet');
    if(bound.has(effect))throw new Error(`Effect ${effect} is bound twice`);
    bound.set(effect,peer);
  }
  const remote=artifact.effects.filter(e=>e.class==='remote');
  for(const effect of bound.keys())if(!remote.some(e=>e.name===effect))throw new Error(`The build binds ${effect}, which the program does not declare as a remote effect`);
  return remote.flatMap(e=>{
    if(!bound.has(e.name))throw new Error(`The program declares the remote effect ${e.name}, and the build binds it to no member`);
    return e.operations.map(o=>({effect:e.name,operation:o.name,peer:bound.get(e.name),mode:o.read_only?'read-only':'keyed',
      argument_type:o.argument_type,result_type:o.result_type}));
  });
}
// What wire format 3 can carry, and what the one peer image can tell apart.
export function wireProblems(operations) {
  const problems=[];
  for(const o of operations){
    const what=`${o.effect}.${o.operation}`;
    if(o.mode==='keyed'&&!(o.argument_type==='I64'&&same(o.result_type,['Tuple','I64','I64'])))problems.push(`${what}: a keyed operation is I64 --> (Tuple I64 I64) in wire format ${WIRE_VERSION}`);
    if(o.mode==='read-only'&&!(o.argument_type==='Unit'&&o.result_type==='I64'))problems.push(`${what}: a read-only operation is Unit --> I64 in wire format ${WIRE_VERSION}`);
    if(operations.some(p=>p!==o&&p.peer===o.peer&&p.mode===o.mode))problems.push(`${what}: wire format ${WIRE_VERSION} does not send the operation's name, so a peer serves one ${o.mode} operation`);
  }
  return problems;
}
const item=o=>`${o.effect}.${o.operation}/${o.mode}`;
export const peersOf=operations=>[...new Set(operations.map(o=>o.peer))];
// The line a caller image carries.
export const callerDeclaration=operations=>
  `FENRIR-REMOTE-DECL/2 connects=${peersOf(operations).join(',')} uses=${operations.map(o=>`${o.peer}/${item(o)}`).join(',')}`;
// The line the image of member `peer` carries: the operations bound to it.
export const peerDeclaration=(operations,peer,store)=>
  `FENRIR-REMOTE-SERVES/1 store=${store?'yes':'no'} operations=${operations.filter(o=>o.peer===peer).map(item).join(',')}`;

// The assembly check, as the supervisor makes it at start (fenrir_relay:assemble_system).
// members: [{name, kind:'caller', operations} | {name, kind:'peer', store, serves:[{effect,operation,mode}]}]
// connections: [[caller, peer]]. Returns the refusals, [] when the system may start:
//   [caller, peer]                       the program declares a connection the manifest lacks
//   [peer, 'no-store', 'E.op']           a peer without a durable store serves an operation that is not read-only
//   [caller, peer, 'unserved', 'E.op']   the caller uses an operation the peer does not serve in that mode
export function assemblyProblems(members,connections) {
  const refusals=[];
  for(const m of members.filter(m=>m.kind==='caller'))
    for(const peer of peersOf(m.operations))if(!connections.some(([a,b])=>a===m.name&&b===peer))refusals.push([m.name,peer]);
  for(const m of members.filter(m=>m.kind==='peer'))
    for(const o of m.serves)if(!m.store&&o.mode!=='read-only')refusals.push([m.name,'no-store',`${o.effect}.${o.operation}`]);
  for(const m of members.filter(m=>m.kind==='caller'))
    for(const o of m.operations){
      const peer=members.find(p=>p.kind==='peer'&&p.name===o.peer);
      if(peer&&!peer.serves.some(s=>s.effect===o.effect&&s.operation===o.operation&&s.mode===o.mode))refusals.push([m.name,o.peer,'unserved',`${o.effect}.${o.operation}`]);
    }
  return refusals;
}

// The artifact of a source file, through the frontend: the bytes it wrote.
export function elaborate(source,out) {
  const r=spawnSync('sh',[resolve(root,'frontend/fenrir.sh'),'emit',source,out],{cwd:root,timeout:300000,maxBuffer:8*1024*1024});
  if(r.error||r.signal||r.status!==0)throw new Error(`frontend/fenrir.sh emit ${source} failed (${r.error?.message||r.signal||'status '+r.status}): ${r.stderr}${r.stdout}`);
  return readFileSync(out);
}

function link(tools,dir,image,units,devices) {
  writeFileSync(resolve(dir,image+'-manifest.json'),DEVICES(devices));
  must(tools.elftool,['gen-manifest',image+'-manifest.json',image+'-manifest.c'],{cwd:dir});
  must(tools.cc,['-c',image+'-manifest.c','-o',image+'-manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi='+tools.abi,image+'-manifest.o',...units.map(u=>u+'.o'),'-o',image+'.'+tools.abi],{cwd:dir});
  return resolve(dir,image+'.'+tools.abi);
}

export function buildRemote(tools,dir) {
  mkdirSync(dir,{recursive:true});
  const bytes=elaborate(SOURCE,resolve(dir,'program.json'));
  const {artifact}=validatePureCallArtifact(bytes,INPUT);
  const operations=remoteOperations(artifact,BINDINGS);
  const unfit=wireProblems(operations);
  if(unfit.length)throw new Error(unfit.join('; '));
  const lowered=lowerBatch([{program:artifact,input:INPUT}]);
  const peers=peersOf(operations);
  if(peers.length!==1||peers[0]!=='peer')throw new Error('This build makes one peer image, for the member named peer');
  const serves=operations.map(({effect,operation,mode})=>({effect,operation,mode}));
  // The system as built must pass the assembly check; the storeless peer below must not.
  const members=store=>[{name:'caller',kind:'caller',operations},{name:'peer',kind:'peer',store,serves}];
  const refused=assemblyProblems(members(true),[['caller','peer']]);
  if(refused.length)throw new Error('The system as built would be refused at assembly: '+JSON.stringify(refused));
  const storeless=assemblyProblems(members(false),[['caller','peer']]);
  if(!storeless.length)throw new Error('The storeless peer image would not be refused: the program has no operation that changes state');
  const declaration=callerDeclaration(operations),string=JSON.stringify;
  writeFileSync(resolve(dir,'data.h'),lowered.header+
    `#define REMOTE_DECL ${string(declaration)}\n`+
    `struct remote_operation { const char *effect,*operation,*peer; int read_only; };\n`+
    `static const struct remote_operation remote_operations[]={${operations.map(o=>`{${string(o.effect)},${string(o.operation)},${string(o.peer)},${o.mode==='read-only'?1:0}}`).join(',')}};\n`+
    `static const unsigned remote_operation_count=${operations.length};\n`+
    `static const char *const remote_peers[]={${peers.map(p=>string(p)).join(',')}};\n`+
    `static const unsigned remote_peer_count=${peers.length};\n`);
  const machine=resolve(root,'backends/solo5/pure-call'),remote=resolve(root,'backends/solo5/remote');
  for(const file of ['machine.c','machine.h','format.c'])copyFileSync(resolve(machine,file),resolve(dir,file));
  for(const file of ['wire.c','wire.h','support.c','support.h','caller.c','peer.c'])copyFileSync(resolve(remote,file),resolve(dir,file));
  // The machine is compiled as the pure-call guest compiles it; the remote sources as C99.
  for(const unit of ['machine','format'])must(tools.cc,['-std=c11',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  for(const unit of ['wire','support','caller'])must(tools.cc,['-std=c99',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  const peerUnit=(unit,store)=>must(tools.cc,['-std=c99',...FLAGS,...(store?[]:['-DPEER_NO_STORE']),
    `-DREMOTE_SERVES=${string(peerDeclaration(operations,'peer',store))}`,'-c','peer.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  peerUnit('peer',true);
  // Not an image of any system: the same peer without a store device, still claiming the
  // keyed operation. It exists so that the supervisor's refusal of it can be exercised.
  peerUnit('peer-nostore',false);
  const caller=link(tools,dir,'caller',['caller','support','wire','machine','format'],['inbox','outbox']);
  const peer=link(tools,dir,'peer',['peer','support','wire'],['inbox','outbox','store']);
  const bare=link(tools,dir,'peer-nostore',['peer-nostore','support','wire'],['inbox','outbox']);
  const info={caller,peer,peer_without_store:bare,tender:tools.tender,abi:tools.abi,tender_sha256:tools.tender_sha256,solo5_commit:SOLO5_COMMIT,
    solo5_source:tools.solo5_source,solo5_path:tools.solo5_path,source:SOURCE,source_sha256:sha(readFileSync(resolve(root,SOURCE))),
    program:resolve(dir,'program.json'),program_sha256:lowered.batch_sha256,artifact_sha256:sha(bytes),
    bindings:BINDINGS,operations:operations.map(o=>[o.effect,o.operation,o.peer,o.mode]),
    caller_declaration:declaration,peer_declaration:peerDeclaration(operations,'peer',true),
    peer_without_store_declaration:peerDeclaration(operations,'peer',false),peer_without_store_refusals:storeless,
    caller_sha256:sha(readFileSync(caller)),peer_sha256:sha(readFileSync(peer)),wire_version:'3'};
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
