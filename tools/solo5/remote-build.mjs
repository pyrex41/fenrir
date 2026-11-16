#!/usr/bin/env node
// Builds the images of the first remote-perform system (spec/tc1/EFFECTS.md §12)
// for a stock Solo5 tender, from its SYSTEM MANIFEST
// (examples/remote/ledger-system.json; --manifest names another): the caller, whose
// program is the source file the manifest names for it, elaborated by the frontend
// (frontend/fenrir.sh emit) and run on the C machine of backends/solo5/pure-call, and
// the abstract counter peer. Guest sources: backends/solo5/remote. Development tooling
// only; no comparison happens here (harness/tc1-remote-run.shen does that).
//   node tools/solo5/remote-build.mjs [--manifest FILE] [--solo5 DIR] [--abi spt|hvt] [--out DIR]
// Prints the output directory, which then holds caller.<abi>, peer.<abi>,
// peer-nostore.<abi>, program.json (the validated artifact, for the Shen model),
// manifest.json (the system manifest with each member's image, as the supervisor
// takes it) and build.json.
//
// What an image says about itself is DERIVED here, from the program's remote-effect
// declarations (artifact schema tc1-handler-demo/3) and the one thing a program does
// not say, which member serves each remote effect. That binding is the manifest's
// (EFFECTS.md §12.6, owner ruling of 16 November 2026 on §12.10 question 14): this file
// holds none, and the supervisor checks the same manifest at assembly.
//   caller  FENRIR-REMOTE-DECL/2 connects=<peers> uses=<peer>/<Effect>.<op>/<mode>,...
//   peer    FENRIR-REMOTE-SERVES/1 store=yes|no operations=<Effect>.<op>/<mode>,...
// mode is keyed or read-only. The supervisor reads both lines from the image files
// before it starts anything (supervisor/src/fenrir_relay.erl); assemblyProblems
// below is the same check, for a build to make before it hands images over.
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {isAbsolute, resolve} from 'node:path';
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

// The system this file builds, unless --manifest names another. Files are named
// relative to the repository, so that the artifact (whose source map carries the
// source's name) is the same in every clone.
export const MANIFEST='examples/remote/ledger-system.json';
export const INPUT=Object.freeze(['int','0']);
export const WIRE_VERSION='3';

// A system manifest (supervisor/README.md, "The system manifest"):
//   {"schema":"fenrir.system-manifest/1",
//    "members":[{"name","kind":"caller","program":SOURCE} | {"name","kind":"peer"}],
//    "connections":[[Caller,Member]],  "bindings":[[Caller,Effect,Member]]}
// Returns it when it is well formed, and throws otherwise. A binding to a name that is
// no member, and a binding with no connection behind it, are well formed: they are
// refusals at assembly (assemblyProblems), which a build and the supervisor both make.
export function checkManifest(manifest) {
  const bad=why=>{throw new Error('System manifest: '+why);};
  const keys=(o,wanted)=>o&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).sort().join(',')===[...wanted].sort().join(',');
  if(!keys(manifest,['schema','members','connections','bindings'])||manifest.schema!=='fenrir.system-manifest/1')bad('schema fenrir.system-manifest/1 with members, connections and bindings');
  const {members,connections,bindings}=manifest,strings=(v,n)=>Array.isArray(v)&&v.length===n&&v.every(x=>typeof x==='string');
  if(!Array.isArray(members)||!members.length)bad('members');
  const names=new Set();
  for(const m of members){
    if(!keys(m,m?.kind==='caller'?['name','kind','program']:['name','kind'])||!['caller','peer'].includes(m.kind))bad('a member is {name, kind: "caller", program} or {name, kind: "peer"}');
    if(typeof m.name!=='string'||!NAME.test(m.name))bad(`member name ${m.name}`);
    if(names.has(m.name))bad(`member ${m.name} is listed twice`);
    if(m.kind==='caller'&&(typeof m.program!=='string'||!m.program||isAbsolute(m.program)))bad(`the program of ${m.name} is a source file named relative to the repository`);
    names.add(m.name);
  }
  if(!Array.isArray(connections))bad('connections');
  for(const c of connections)if(!strings(c,2)||!names.has(c[0])||!names.has(c[1]))bad(`connection ${JSON.stringify(c)} does not join two members`);
  if(!Array.isArray(bindings))bad('bindings');
  const seen=new Set();
  for(const b of bindings){
    if(!strings(b,3)||!EFFECT.test(b[1]))bad(`binding ${JSON.stringify(b)} is not [caller, Effect, member]`);
    if(members.find(m=>m.name===b[0])?.kind!=='caller')bad(`binding ${JSON.stringify(b)} is not for a caller of the system`);
    if(seen.has(b[0]+'/'+b[1]))bad(`effect ${b[1]} of ${b[0]} is bound twice`);
    seen.add(b[0]+'/'+b[1]);
  }
  return manifest;
}
export const readManifest=file=>checkManifest(JSON.parse(readFileSync(resolve(root,file),'utf8')));

// Every operation of every remote effect the program of member `caller` declares, with
// the member the manifest's bindings give its effect:
// [{effect, operation, peer, mode, argument_type, result_type}].
// A remote effect without a binding, and a binding that names no remote effect of
// the program, are errors: the bindings of a caller are exactly what it declares.
export function remoteOperations(artifact,caller,bindings) {
  if(artifact.schema_version!==TC1_REMOTE_SCHEMA)throw new Error(`A caller image is built from an artifact of schema ${TC1_REMOTE_SCHEMA}`);
  const bound=new Map();
  for(const [member,effect,peer] of bindings){
    if(member!==caller)continue;
    if(!EFFECT.test(effect)||!NAME.test(peer))throw new Error('Binding outside the guest alphabet');
    if(bound.has(effect))throw new Error(`Effect ${effect} is bound twice`);
    bound.set(effect,peer);
  }
  const remote=artifact.effects.filter(e=>e.class==='remote');
  for(const effect of bound.keys())if(!remote.some(e=>e.name===effect))throw new Error(`The manifest binds ${effect} for ${caller}, whose program does not declare it as a remote effect`);
  return remote.flatMap(e=>{
    if(!bound.has(e.name))throw new Error(`The program of ${caller} declares the remote effect ${e.name}, and the manifest binds it to no member`);
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
// members: [{name, kind:'caller', operations:[{effect,operation,mode}]} | {name, kind:'peer', store, serves:[{effect,operation,mode}]}]
// connections: [[caller, member]]; bindings: [[caller, Effect, member]], both the manifest's.
// Which member an operation goes to is the manifest's binding of its effect, and nothing
// a caller says. Returns the refusals, [] when the system may start:
//   [caller, 'unbound', 'E']               the caller uses remote effect E, and the manifest binds it to no member
//   [caller, 'unknown-member', 'E', name]  the manifest binds E to a name that is no member of the system
//   [caller, member]                       E is bound to a member the manifest declares no connection to from the caller
//   [peer, 'no-store', 'E.op']             a peer without a durable store serves an operation that is not read-only
//   [caller, member, 'unserved', 'E.op']   the caller uses an operation the bound member does not serve in that mode
export function assemblyProblems(members,connections,bindings) {
  const callers=members.filter(m=>m.kind==='caller'),member=name=>members.find(m=>m.name===name);
  const bound=(m,effect)=>bindings.find(([caller,e])=>caller===m.name&&e===effect)?.[2];
  const effects=m=>[...new Set(m.operations.map(o=>o.effect))];
  const unbound=[],unknown=[],missing=[],storeless=[],unserved=[];
  for(const m of callers)for(const effect of effects(m)){
    const to=bound(m,effect);
    if(to===undefined)unbound.push([m.name,'unbound',effect]);
    else if(!member(to))unknown.push([m.name,'unknown-member',effect,to]);
    else if(!connections.some(([a,b])=>a===m.name&&b===to)&&!missing.some(([a,b])=>a===m.name&&b===to))missing.push([m.name,to]);
  }
  for(const m of members.filter(m=>m.kind==='peer'))
    for(const o of m.serves)if(!m.store&&o.mode!=='read-only')storeless.push([m.name,'no-store',`${o.effect}.${o.operation}`]);
  for(const m of callers)for(const o of m.operations){
    const to=member(bound(m,o.effect));
    if(to&&!(to.kind==='peer'&&to.serves.some(s=>s.effect===o.effect&&s.operation===o.operation&&s.mode===o.mode)))unserved.push([m.name,to.name,'unserved',`${o.effect}.${o.operation}`]);
  }
  return [...unbound,...unknown,...missing,...storeless,...unserved];
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

export function buildRemote(tools,dir,manifestFile=MANIFEST) {
  mkdirSync(dir,{recursive:true});
  const manifest=readManifest(manifestFile),callers=manifest.members.filter(m=>m.kind==='caller');
  if(callers.length!==1||callers[0].name!=='caller')throw new Error('This build makes one caller image, for the member named caller');
  const SOURCE=callers[0].program;
  const bytes=elaborate(SOURCE,resolve(dir,'program.json'));
  const {artifact}=validatePureCallArtifact(bytes,INPUT);
  const operations=remoteOperations(artifact,'caller',manifest.bindings);
  const unfit=wireProblems(operations);
  if(unfit.length)throw new Error(unfit.join('; '));
  const lowered=lowerBatch([{program:artifact,input:INPUT}]);
  const peers=peersOf(operations);
  const serves=operations.map(({effect,operation,mode})=>({effect,operation,mode}));
  // The system as built must pass the assembly check, made on the manifest's own
  // connections and bindings; the storeless peer below must not. The check comes before
  // anything is compiled: an effect bound to no member of the manifest, or to one the
  // caller has no declared connection to, is refused here as the supervisor would refuse it.
  const members=store=>manifest.members.map(m=>m.kind==='caller'?{name:m.name,kind:'caller',operations}:{name:m.name,kind:'peer',store,serves:m.name==='peer'?serves:[]});
  const refused=assemblyProblems(members(true),manifest.connections,manifest.bindings);
  if(refused.length)throw new Error('The system as built would be refused at assembly: '+JSON.stringify(refused));
  if(peers.length!==1||peers[0]!=='peer')throw new Error('This build makes one peer image, for the member named peer');
  const storeless=assemblyProblems(members(false),manifest.connections,manifest.bindings);
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
  // The manifest as the supervisor takes it: each member with its image, nothing else changed.
  const images={caller,peer};
  if(manifest.members.some(m=>!images[m.name]))throw new Error('This build has an image for the members caller and peer only');
  const system={members:manifest.members.map(m=>({name:m.name,kind:m.kind,image:images[m.name]})),connections:manifest.connections,bindings:manifest.bindings};
  writeFileSync(resolve(dir,'manifest.json'),JSON.stringify(system)+'\n');
  const info={caller,peer,peer_without_store:bare,manifest:manifestFile,manifest_sha256:sha(readFileSync(resolve(root,manifestFile))),system_manifest:resolve(dir,'manifest.json'),
    connections:manifest.connections,tender:tools.tender,abi:tools.abi,tender_sha256:tools.tender_sha256,solo5_commit:SOLO5_COMMIT,
    solo5_source:tools.solo5_source,solo5_path:tools.solo5_path,source:SOURCE,source_sha256:sha(readFileSync(resolve(root,SOURCE))),
    program:resolve(dir,'program.json'),program_sha256:lowered.batch_sha256,artifact_sha256:sha(bytes),
    bindings:manifest.bindings,operations:operations.map(o=>[o.effect,o.operation,o.peer,o.mode]),
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
  buildRemote(tools,out,option('--manifest',MANIFEST));
  console.log(out);
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
