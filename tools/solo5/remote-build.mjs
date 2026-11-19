#!/usr/bin/env node
// Builds the images of a remote-perform system (spec/tc1/EFFECTS.md §12) for a stock
// Solo5 tender, from its SYSTEM MANIFEST (examples/remote/ledger-system.json; --manifest
// names another). Every member's program is a source file the manifest names, elaborated
// by the frontend (frontend/fenrir.sh emit) and run on the C machine of
// backends/solo5/pure-call: a caller's program has a main and performs remote operations
// (artifact schema tc1-handler-demo/3); a peer's program serves a remote effect (schema
// tc1-handler-demo/4) and is run by the peer's runtime once for each request. Guest
// sources: backends/solo5/remote. Development tooling only; no comparison happens here
// (harness/tc1-remote-run.shen does that).
//   node tools/solo5/remote-build.mjs [--manifest FILE] [--solo5 DIR] [--abi spt|hvt] [--out DIR]
// Prints the output directory, which then holds <member>.<abi> and <member>.json (the
// validated artifact, for the Shen model) for every member, manifest.json (the system
// manifest with each member's image, as the supervisor takes it) and build.json. For the
// ledger system it also holds two peer images that belong to no system, made so that the
// supervisor's refusal of each can be exercised: peer-nostore, the ledger peer without a
// store device, and peer-other-signature, a peer whose program declares the effect
// differently (OTHER_SIGNATURE below).
//
// What an image says about itself is DERIVED here, from its own program and the one thing
// a caller's program does not say, which member serves each remote effect. That binding
// is the manifest's (EFFECTS.md §12.6): this file holds none.
//   caller  FENRIR-REMOTE-DECL/3 connects=<peers> uses=<peer>/<Effect>.<op>/<mode>,... signatures=<Effect>:<digest>,...
//   peer    FENRIR-REMOTE-SERVES/2 store=yes|no writes=yes|no operations=<Effect>.<op>/<mode>,... signatures=<Effect>:<digest>,...
// mode is keyed or read-only. writes says whether the peer's program mentions StoreWrite
// at all. A digest is signatureDigest below: SHA-256 of a canonical encoding of the
// effect's signature, read-only markers included (owner ruling of 16 November 2026 on
// §12.10 question 15). The supervisor reads both lines from the image files before it
// starts anything (supervisor/src/fenrir_relay.erl); assemblyProblems below is the same
// check, for a build to make before it hands images over.
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {isAbsolute, resolve} from 'node:path';
import {toolchain, defaultSolo5, must, SOLO5_COMMIT} from './freerun.mjs';
import {lowerBatch} from './pure-call/lower.mjs';
import {validatePureCallArtifact, mentionsStoreWrite, TC1_REMOTE_SCHEMA, TC1_SERVING_SCHEMA} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';

const root=resolve(import.meta.dirname,'../..');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const NAME=/^[a-z0-9-]{1,15}$/,EFFECT=/^[A-Za-z_][A-Za-z0-9_]*$/;
const FLAGS=['-O1','-Wall','-Wextra','-Werror','-I.'];
const DEVICES=names=>JSON.stringify({type:'solo5.manifest',version:1,devices:names.map(name=>({name,type:'BLOCK_BASIC'}))})+'\n';
const same=(a,b)=>encode(a).equals(encode(b));
const string=JSON.stringify;

// The system this file builds, unless --manifest names another. Files are named
// relative to the repository, so that an artifact (whose source map carries the
// source's name) is the same in every clone.
export const MANIFEST='examples/remote/ledger-system.json';
export const OTHER_SIGNATURE='tests/remote/ledger-peer-other-signature.fen';
export const INPUT=Object.freeze(['int','0']);
export const WIRE_VERSION='4';

// A system manifest (supervisor/README.md, "The system manifest"):
//   {"schema":"fenrir.system-manifest/2",
//    "members":[{"name","kind":"caller","program":SOURCE} | {"name","kind":"peer","program":SOURCE,"store":true|false}],
//    "connections":[[Caller,Member]],  "bindings":[[Caller,Effect,Member]]}
// Returns it when it is well formed, and throws otherwise. A binding to a name that is
// no member, and a binding with no connection behind it, are well formed: they are
// refusals at assembly (assemblyProblems), which a build and the supervisor both make.
export function checkManifest(manifest) {
  const bad=why=>{throw new Error('System manifest: '+why);};
  const keys=(o,wanted)=>o&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).sort().join(',')===[...wanted].sort().join(',');
  if(!keys(manifest,['schema','members','connections','bindings'])||manifest.schema!=='fenrir.system-manifest/2')bad('schema fenrir.system-manifest/2 with members, connections and bindings');
  const {members,connections,bindings}=manifest,strings=(v,n)=>Array.isArray(v)&&v.length===n&&v.every(x=>typeof x==='string');
  if(!Array.isArray(members)||!members.length)bad('members');
  const names=new Set();
  for(const m of members){
    if(!keys(m,m?.kind==='caller'?['name','kind','program']:['name','kind','program','store'])||!['caller','peer'].includes(m.kind))bad('a member is {name, kind: "caller", program} or {name, kind: "peer", program, store}');
    if(typeof m.name!=='string'||!NAME.test(m.name))bad(`member name ${m.name}`);
    if(names.has(m.name))bad(`member ${m.name} is listed twice`);
    if(typeof m.program!=='string'||!m.program||isAbsolute(m.program))bad(`the program of ${m.name} is a source file named relative to the repository`);
    if(m.kind==='peer'&&typeof m.store!=='boolean')bad(`the peer ${m.name} says whether it has a durable store: "store": true or false`);
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

// The digest of a remote effect's signature, as every image that uses or serves the effect
// carries it: SHA-256, in lowercase hexadecimal, of the canonical encoding
// (tools/tc0/canonical.mjs) of
//   {"effect": Name, "operations": [{"argument_type", "name", "read_only", "result_type"}, ...], "schema": "fenrir.remote-signature/1"}
// with the operations in unsigned UTF-8 byte order of their names: a signature is a set of
// operations, and the order they are declared in is not part of it. Types are as the
// artifact writes them. A declared datatype appears by its name only: its constructors are
// not in the digest (no datatype crosses the wire yet).
export function signatureDigest(effect) {
  if(effect?.class!=='remote')throw new Error('The signature digest is of a remote effect');
  const operations=effect.operations.map(o=>({argument_type:o.argument_type,name:o.name,read_only:o.read_only,result_type:o.result_type}))
    .sort((a,b)=>Buffer.compare(Buffer.from(a.name),Buffer.from(b.name)));
  return sha(encode({effect:effect.name,operations,schema:'fenrir.remote-signature/1'}));
}
// {Effect: digest} for the named remote effects of an artifact.
export const signatures=(artifact,effects)=>Object.fromEntries([...new Set(effects)].map(name=>[name,signatureDigest(artifact.effects.find(e=>e.name===name))]));

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
// Every operation a peer's program serves, with the function that implements it:
// [{effect, operation, mode, function, argument_type, result_type}].
export function servedOperations(artifact) {
  if(artifact.schema_version!==TC1_SERVING_SCHEMA)throw new Error(`A peer image is built from an artifact of schema ${TC1_SERVING_SCHEMA}: a program with a (serve ...) form`);
  return artifact.serves.flatMap(s=>{
    const effect=artifact.effects.find(e=>e.name===s.effect);
    return s.operations.map((x,i)=>({effect:s.effect,operation:x.name,mode:effect.operations[i].read_only?'read-only':'keyed',function:x.function,
      argument_type:effect.operations[i].argument_type,result_type:effect.operations[i].result_type}));
  });
}
// What wire format 4 can carry. A request names its operation, so a peer serves any
// number of operations of each mode; the types are still these.
export function wireProblems(operations) {
  const problems=[];
  for(const o of operations){
    const what=`${o.effect}.${o.operation}`;
    if(what.length>63)problems.push(`${what}: an operation's name, Effect.operation, is at most 63 bytes in wire format ${WIRE_VERSION}`);
    if(o.mode==='keyed'&&!(o.argument_type==='I64'&&same(o.result_type,['Tuple','I64','I64'])))problems.push(`${what}: a keyed operation is I64 --> (Tuple I64 I64) in wire format ${WIRE_VERSION}`);
    if(o.mode==='read-only'&&!(o.argument_type==='Unit'&&o.result_type==='I64'))problems.push(`${what}: a read-only operation is Unit --> I64 in wire format ${WIRE_VERSION}`);
  }
  return problems;
}
const item=o=>`${o.effect}.${o.operation}/${o.mode}`;
const digests=map=>Object.keys(map).sort().map(effect=>`${effect}:${map[effect]}`).join(',');
export const peersOf=operations=>[...new Set(operations.map(o=>o.peer))];
// The line a caller image carries.
export const callerDeclaration=(operations,signed)=>
  `FENRIR-REMOTE-DECL/3 connects=${peersOf(operations).join(',')} uses=${operations.map(o=>`${o.peer}/${item(o)}`).join(',')} signatures=${digests(signed)}`;
// The line a peer image carries: what its own program serves.
export const peerDeclaration=(serves,store,writes,signed)=>
  `FENRIR-REMOTE-SERVES/2 store=${store?'yes':'no'} writes=${writes?'yes':'no'} operations=${serves.map(item).join(',')} signatures=${digests(signed)}`;

// The assembly check, as the supervisor makes it at start (fenrir_relay:assemble_system).
// members: [{name, kind:'caller', operations:[{effect,operation,mode}], signatures:{Effect:digest}}
//          | {name, kind:'peer', store, writes, serves:[{effect,operation,mode}], signatures:{Effect:digest}}]
// connections: [[caller, member]]; bindings: [[caller, Effect, member]], both the manifest's.
// Which member an operation goes to is the manifest's binding of its effect, and nothing
// a caller says. Returns the refusals, [] when the system may start:
//   [caller, 'unbound', 'E']               the caller uses remote effect E, and the manifest binds it to no member
//   [caller, 'unknown-member', 'E', name]  the manifest binds E to a name that is no member of the system
//   [caller, member]                       E is bound to a member the manifest declares no connection to from the caller
//   [peer, 'no-store', 'E.op']             a peer without a durable store serves an operation that is not read-only
//   [peer, 'no-store', 'StoreWrite']       a peer without a durable store whose program mentions the write effect
//   [caller, member, 'unserved', 'E.op']   the caller uses an operation the bound member does not serve in that mode
//   [caller, member, 'signature', 'E']     the bound member serves E, and its digest of E's signature is not the caller's
export function assemblyProblems(members,connections,bindings) {
  const callers=members.filter(m=>m.kind==='caller'),member=name=>members.find(m=>m.name===name);
  const bound=(m,effect)=>bindings.find(([caller,e])=>caller===m.name&&e===effect)?.[2];
  const effects=m=>[...new Set(m.operations.map(o=>o.effect))];
  const unbound=[],unknown=[],missing=[],storeless=[],unserved=[],unsigned=[];
  for(const m of callers)for(const effect of effects(m)){
    const to=bound(m,effect);
    if(to===undefined)unbound.push([m.name,'unbound',effect]);
    else if(!member(to))unknown.push([m.name,'unknown-member',effect,to]);
    else if(!connections.some(([a,b])=>a===m.name&&b===to)&&!missing.some(([a,b])=>a===m.name&&b===to))missing.push([m.name,to]);
  }
  for(const m of members.filter(m=>m.kind==='peer')){
    for(const o of m.serves)if(!m.store&&o.mode!=='read-only')storeless.push([m.name,'no-store',`${o.effect}.${o.operation}`]);
    if(!m.store&&m.writes)storeless.push([m.name,'no-store','StoreWrite']);
  }
  for(const m of callers)for(const o of m.operations){
    const to=member(bound(m,o.effect));
    if(to&&!(to.kind==='peer'&&to.serves.some(s=>s.effect===o.effect&&s.operation===o.operation&&s.mode===o.mode)))unserved.push([m.name,to.name,'unserved',`${o.effect}.${o.operation}`]);
  }
  for(const m of callers)for(const effect of effects(m)){
    const to=member(bound(m,effect));
    if(to?.kind==='peer'&&to.serves.some(s=>s.effect===effect)&&to.signatures[effect]!==m.signatures[effect])unsigned.push([m.name,to.name,'signature',effect]);
  }
  return [...unbound,...unknown,...missing,...storeless,...unserved,...unsigned];
}

// The artifact of a source file, through the frontend: the bytes it wrote.
export function elaborate(source,out) {
  const r=spawnSync('sh',[resolve(root,'frontend/fenrir.sh'),'emit',source,out],{cwd:root,timeout:300000,maxBuffer:8*1024*1024});
  if(r.error||r.signal||r.status!==0)throw new Error(`frontend/fenrir.sh emit ${source} failed (${r.error?.message||r.signal||'status '+r.status}): ${r.stderr}${r.stdout}`);
  return readFileSync(out);
}

// What a member's program says, before anything is compiled: its artifact and what its image will declare.
export function describe(member,manifest,dir) {
  const program=resolve(dir,member.name+'.json'),bytes=elaborate(member.program,program);
  const {artifact}=validatePureCallArtifact(bytes,INPUT);
  const base={name:member.name,kind:member.kind,source:member.program,source_sha256:sha(readFileSync(resolve(root,member.program))),program,artifact_sha256:sha(bytes),artifact};
  if(member.kind==='caller'){
    const operations=remoteOperations(artifact,member.name,manifest.bindings),signed=signatures(artifact,operations.map(o=>o.effect));
    return {...base,operations,signatures:signed,unfit:wireProblems(operations),declaration:callerDeclaration(operations,signed)};
  }
  const serves=servedOperations(artifact),signed=signatures(artifact,serves.map(o=>o.effect)),writes=mentionsStoreWrite(artifact);
  return {...base,store:member.store,writes,serves,signatures:signed,unfit:wireProblems(serves),declaration:peerDeclaration(serves,member.store,writes,signed)};
}

function compile(tools,dir,member) {
  mkdirSync(dir,{recursive:true});
  const caller=member.kind==='caller',lowered=lowerBatch([{program:member.artifact,input:caller?INPUT:['unit']}]);
  writeFileSync(resolve(dir,'data.h'),lowered.header+(caller?
    `#define REMOTE_DECL ${string(member.declaration)}\n`+
    `struct remote_operation { const char *effect,*operation,*peer; int read_only; const char *wire; };\n`+
    `static const struct remote_operation remote_operations[]={${member.operations.map(o=>`{${string(o.effect)},${string(o.operation)},${string(o.peer)},${o.mode==='read-only'?1:0},${string(o.effect+'.'+o.operation)}}`).join(',')}};\n`+
    `static const unsigned remote_operation_count=${member.operations.length};\n`+
    `static const char *const remote_peers[]={${peersOf(member.operations).map(p=>string(p)).join(',')}};\n`+
    `static const unsigned remote_peer_count=${peersOf(member.operations).length};\n`:
    `#define REMOTE_SERVES ${string(member.declaration)}\n`+
    `struct serve_operation { const char *name; unsigned function; int read_only; };\n`+
    `static const struct serve_operation serve_operations[]={${member.serves.map(o=>`{${string(o.effect+'.'+o.operation)},${lowered.function_index[0][o.function]},${o.mode==='read-only'?1:0}}`).join(',')}};\n`+
    `static const unsigned serve_operation_count=${member.serves.length};\n`));
  const machine=resolve(root,'backends/solo5/pure-call'),remote=resolve(root,'backends/solo5/remote');
  for(const file of ['machine.c','machine.h','format.c'])copyFileSync(resolve(machine,file),resolve(dir,file));
  for(const file of ['wire.c','wire.h','support.c','support.h','serve.c','serve.h','caller.c','peer.c'])copyFileSync(resolve(remote,file),resolve(dir,file));
  // The machine is compiled as the pure-call guest compiles it; the remote sources as C99.
  for(const unit of ['machine','format'])must(tools.cc,['-std=c11',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  const units=caller?['wire','support','caller']:['wire','support','serve','peer'];
  for(const unit of units)must(tools.cc,['-std=c99',...FLAGS,...(!caller&&!member.store?['-DPEER_NO_STORE']:[]),'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  const devices=caller||!member.store?['inbox','outbox']:['inbox','outbox','store'];
  writeFileSync(resolve(dir,'image-manifest.json'),DEVICES(devices));
  must(tools.elftool,['gen-manifest','image-manifest.json','image-manifest.c'],{cwd:dir});
  must(tools.cc,['-c','image-manifest.c','-o','image-manifest.o'],{cwd:dir});
  const image=resolve(dir,'..',member.name+'.'+tools.abi);
  must(tools.ld,['-z','solo5-abi='+tools.abi,'image-manifest.o',...units.map(u=>u+'.o'),'machine.o',...(caller?['format.o']:[]),'-o',image],{cwd:dir});
  return {image,image_sha256:sha(readFileSync(image)),program_sha256:lowered.batch_sha256};
}

export function buildRemote(tools,dir,manifestFile=MANIFEST) {
  mkdirSync(dir,{recursive:true});
  const manifest=readManifest(manifestFile);
  const members=manifest.members.map(m=>describe(m,manifest,dir));
  const unfit=members.flatMap(m=>m.unfit);
  if(unfit.length)throw new Error(unfit.join('; '));
  // The system as built must pass the assembly check, made on the manifest's own
  // connections and bindings, before anything is compiled: a system that would be refused
  // is not built.
  const refused=assemblyProblems(members,manifest.connections,manifest.bindings);
  if(refused.length)throw new Error('The system as built would be refused at assembly: '+JSON.stringify(refused));
  // For the ledger system, two peer images that are not images of any system. Each stands
  // in for the member peer in a manifest the supervisor must refuse, and the build's own
  // check must refuse it too.
  const extras=manifestFile!==MANIFEST?[]:[
    {key:'peer_without_store',name:'peer-nostore',program:manifest.members.find(m=>m.name==='peer').program,store:false},
    {key:'peer_other_signature',name:'peer-other-signature',program:OTHER_SIGNATURE,store:true}].map(x=>{
      const made={...describe({name:x.name,kind:'peer',program:x.program,store:x.store},manifest,dir),key:x.key};
      const refusals=assemblyProblems(members.map(m=>m.name==='peer'?{...made,name:'peer'}:m),manifest.connections,manifest.bindings);
      if(!refusals.length)throw new Error(`The image ${x.name} would not be refused in place of the peer`);
      return {...made,refusals};
    });
  const record=m=>{
    const built=compile(tools,resolve(dir,'build-'+m.name),m),{artifact,unfit,key,...rest}=m;
    return {...rest,...built,...(m.kind==='caller'?{operations:m.operations.map(o=>[o.effect,o.operation,o.peer,o.mode])}:{serves:m.serves.map(o=>[`${o.effect}.${o.operation}`,o.mode,o.function])})};
  };
  const built=members.map(record);
  // The manifest as the supervisor takes it: each member with its image, nothing else changed.
  const system={members:built.map(m=>({name:m.name,kind:m.kind,image:m.image})),connections:manifest.connections,bindings:manifest.bindings};
  writeFileSync(resolve(dir,'manifest.json'),JSON.stringify(system)+'\n');
  const info={manifest:manifestFile,manifest_sha256:sha(readFileSync(resolve(root,manifestFile))),system_manifest:resolve(dir,'manifest.json'),
    connections:manifest.connections,bindings:manifest.bindings,tender:tools.tender,abi:tools.abi,tender_sha256:tools.tender_sha256,solo5_commit:SOLO5_COMMIT,
    solo5_source:tools.solo5_source,solo5_path:tools.solo5_path,wire_version:'4',members:built,
    extras:Object.fromEntries(extras.map(x=>[x.key,record(x)]))};
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
