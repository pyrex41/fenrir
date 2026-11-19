// Artifact schema tc1-handler-demo/3 (slice TC1-R1): the remote effect class
// (spec/tc1/EFFECTS.md §3, §8, §12.2), and what a build derives from it for the
// images of a system (tools/solo5/remote-build.mjs).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,TC1_REMOTE_SCHEMA,REMOTE_OUTCOMES} from '../../tools/tc0/pure-call-artifact.mjs';
import {HandlerMachine} from '../../runtime/tc1/handler-machine.mjs';
import {cases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {createHash} from 'node:crypto';
import {remoteOperations,servedOperations,signatureDigest,wireProblems,callerDeclaration,peerDeclaration,assemblyProblems,checkManifest,readManifest,MANIFEST} from '../../tools/solo5/remote-build.mjs';

const check=p=>validatePureCallArtifact(encode(p),['int','0']);
const clone=p=>JSON.parse(JSON.stringify(p));
const rejects=(p,why,pattern)=>assert.throws(()=>check(p),e=>e instanceof InvalidPureCallArtifact&&pattern.test(e.message),why);

// A hand-assembled program of schema /3:
//   remote effect Ledger { add : I64 -> (I64, I64); read-only total : Unit -> I64 }
//   effect Note { note : I64 -> I64 }
//   main(i) = handle Note { note(x) => x } in
//             match perform(Ledger, add, (7, i)) {
//               reply(r) => match perform(Ledger, total, ()) { reply(n) => n; not_delivered => -1; timed_out => -2 }
//               not_delivered => -1
//               timed_out => perform(Note, note, -2) }
function program() {
  let next=0;const locations=[];
  const fresh=()=>String(next++),node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const int=n=>node('int',String(n));
  const id=fresh(),parameter_id=fresh();locations.push(id);
  const x=fresh(),r=fresh(),n=fresh();
  const read=node('match',node('perform','Ledger','total',node('unit')),['reply',[n],node('var',n)],['not_delivered',[],int(-1)],['timed_out',[],int(-2)]);
  const body=node('handle','Note',[['note',x,node('var',x)]],
    node('match',node('perform','Ledger','add',node('tuple',int(7),node('var',parameter_id))),
      ['reply',[r],read],['not_delivered',[],int(-1)],['timed_out',[],node('perform','Note','note',int(-2))]));
  return {contract_version:'tc1-draft-1',schema_version:TC1_REMOTE_SCHEMA,slice:'TC1-R1',module:'remote-unit',datatypes:[],
    effects:[{name:'Ledger',class:'remote',operations:[{name:'add',argument_type:'I64',result_type:['Tuple','I64','I64'],read_only:false},
                                                         {name:'total',argument_type:'Unit',result_type:'I64',read_only:true}]},
             {name:'Note',class:'ordinary',operations:[{name:'note',argument_type:'I64',result_type:'I64'}]}],
    functions:[{id,name:'main',parameter_id,argument_type:'I64',result_type:'I64',effects:['Ledger'],body}],
    entry:'main',input_schema:{type:'I64'},source_map:locations.map(id=>({id,file:'remote-unit',line:'0',column:'0'}))};
}
// body: ['handle',id,'Note',clauses,match]; match: ['match',id,perform,reply-arm,not_delivered-arm,timed_out-arm]
const outer=p=>p.functions[0].body[4],inner=p=>outer(p)[3][2];
// Drop the source-map rows of nodes that an edit removed.
const remap=p=>{const text=JSON.stringify(p.functions);p.source_map=p.source_map.filter(r=>text.includes(`"${r.id}"`));return p;};

test('a program that declares a remote effect validates, and its entry function may leave that effect unhandled', () => {
  const {artifact}=check(program());
  assert.deepEqual(artifact.functions[0].effects,['Ledger']);
  assert.deepEqual(REMOTE_OUTCOMES,['reply','not_delivered','timed_out']);
});
test('every effect of schema /3 states its class, and an operation of a remote effect states read_only', () => {
  const classless=program();delete classless.effects[1].class;rejects(classless,'no class',/Closed object fields/);
  const unknown=program();unknown.effects[1].class='durable';rejects(unknown,'unknown class',/Effect class/);
  const unmarked=program();delete unmarked.effects[0].operations[0].read_only;rejects(unmarked,'no read_only',/Closed object fields/);
  const text=program();text.effects[0].operations[0].read_only='no';rejects(text,'read_only not a boolean',/read_only/);
  const ordinary=program();ordinary.effects[1].operations[0].read_only=false;rejects(ordinary,'read_only on an ordinary operation',/Closed object fields/);
});
test('the older schemas are closed to the class, to the outcome type and to an unhandled effect at the entry', () => {
  const base=cases.find(c=>c.name==='handler-basic').program;
  assert.ok(check(base));
  const classed=clone(base);classed.effects[0].class='ordinary';rejects(classed,'class under schema /1',/Closed object fields/);
  const typed=clone(base);typed.functions[0].result_type=['Remote','I64'];rejects(typed,'Remote under schema /1',/Type/);
  // There is no option that admits an unhandled effect any more: only a declared class does.
  const open=clone(base);open.functions[0].body=open.functions[0].body[4];open.functions[0].effects=['Ask'];remap(open);
  assert.throws(()=>validatePureCallArtifact(encode(open),['int','0'],{remoteEffects:['Ask']}),e=>e instanceof InvalidPureCallArtifact&&/Entry must handle every user effect/.test(e.message));
});
test('only a remote effect may reach the entry function unhandled', () => {
  const p=program();p.functions[0].body=outer(p);p.functions[0].effects=['Ledger','Note'];remap(p);
  rejects(p,'an ordinary effect left at the entry',/Entry must handle every user effect/);
});
test('no handler discharges a remote effect', () => {
  const p=program(),body=p.functions[0].body;
  body[2]='Ledger';body[3]=[['add',body[3][0][1],['tuple','900',['int','901','0'],['int','902','0']]],['total','903',['int','904','0']]];
  rejects(p,'handle of a remote effect',/A remote effect cannot be handled/);
});
test('a remote perform takes the key first unless the operation is read-only, and yields an outcome', () => {
  const keyless=program();outer(keyless)[2][4]=['int',outer(keyless)[2][4][1],'5'];remap(keyless);rejects(keyless,'keyed operation without a key',/Perform argument/);
  const keyed=program(),unit=inner(keyed)[2][4];inner(keyed)[2][4]=['tuple',unit[1],['int','900','7'],['unit','901']];
  keyed.source_map.push({id:'900',file:'x',line:'0',column:'0'},{id:'901',file:'x',line:'0',column:'0'});rejects(keyed,'read-only operation with a key',/Perform argument/);
  // The result is the outcome, not the operation's value: main's declared I64 cannot be the perform itself.
  // And it cannot be the function's result under any signature: the perform is not a scrutinee, and the type cannot be written.
  const raw=program();raw.functions[0].body=inner(raw)[2];remap(raw);rejects(raw,'outcome used as the value',/A remote outcome must be matched where it is performed/);
  const typed=clone(raw);typed.functions[0].result_type=['Remote','I64'];rejects(typed,'outcome returned',/The outcome type Remote cannot be written/);
});
// Must-use (EFFECTS.md §3, ruling on §12.10 question 11). Each edit takes the read-only perform of program(), the
// scrutinee of the inner match, and puts it, or the outcome type, somewhere else. New nodes get IDs from 900.
function edited(edit) {
  const p=program();let next=900;
  const node=(tag,...args)=>{const id=String(next++);p.source_map.push({id,file:'remote-unit',line:'0',column:'0'});return [tag,id,...args];};
  const binder=()=>String(next++),match=inner(p),perform=match[2];
  edit({p,node,binder,match,perform,arms:()=>match.slice(3),set:e=>{match[2]=e;}});
  return remap(p);
}
test('must-use: a remote perform is the scrutinee of a match, and a hand-made artifact cannot put it anywhere else', () => {
  const unexamined=/A remote outcome must be matched where it is performed/;
  assert.ok(check(edited(()=>{})));
  const wrong={
    'bound by let, then matched':({node,binder,perform,set})=>{const b=binder();set(node('let',b,perform,node('var',b)));},
    'bound by let inside the scrutinee and dropped':({node,binder,perform,set,p})=>{const b=binder();p.functions[0].body=node('let',b,perform,node('int','0'));},
    'the scrutinee is an if that yields it':({node,perform,set})=>{const again=clone(perform);again[1]='990';again[4][1]='991';
      set(node('if',node('bool',true),perform,again));edited.extra=['990','991'];},
    'stored in a tuple':({node,perform,p})=>{p.functions[0].body=node('project',node('tuple',node('int','0'),perform),'0');},
    'returned by a function':({perform,p})=>{p.functions[0].body=perform;},
    'returned by a lambda':({node,binder,perform,p})=>{const b=binder(),u=binder();
      p.functions[0].body=node('let',b,node('lambda',u,'Unit','I64',['Ledger'],[],perform),node('int','0'));},
    'passed to a function':({node,perform,p})=>{p.functions[0].body=node('call','main',perform);},
    'compared':({node,perform,p})=>{const again=clone(perform);again[1]='990';again[4][1]='991';p.functions[0].body=node('prim','eq',perform,again);edited.extra=['990','991'];},
    'emitted':({node,perform,p})=>{p.functions[0].body=node('emit','outcome',perform);},
    'the argument of another perform':({node,perform,p})=>{p.functions[0].body=node('perform','Note','note',perform);},
  };
  for(const [why,edit] of Object.entries(wrong)){
    edited.extra=[];const p=edited(edit);for(const id of edited.extra)p.source_map.push({id,file:'remote-unit',line:'0',column:'0'});
    rejects(p,why,unexamined);
  }
});
test('must-use: the outcome type is written nowhere, so nothing can be declared to hold an outcome', () => {
  const unwritable=/The outcome type Remote cannot be written/,remote=['Remote','I64'];
  const wrong={
    'a function argument':p=>{p.functions[0].argument_type=remote;p.input_schema.type=remote;},
    'a function result':p=>{p.functions[0].result_type=remote;},
    'a component of a tuple type':p=>{p.functions[0].result_type=['Tuple','I64',remote];},
    'the result of a function type':p=>{p.functions[0].result_type=['Arrow','I64',remote,['Ledger']];},
    'a datatype field':p=>{p.datatypes=[{name:'Kept',constructors:[{name:'kept',fields:[remote]}]}];},
    'the argument type of an operation':p=>{p.effects[1].operations[0].argument_type=remote;},
    'the result type of an operation':p=>{p.effects[0].operations[1].result_type=remote;},
  };
  for(const [why,edit] of Object.entries(wrong)){const p=program();edit(p);rejects(p,why,unwritable);}
  // An outcome cannot come in as the input either: the entry's argument type would have to name it.
  const p=program();p.functions[0].argument_type=remote;p.input_schema.type=remote;
  assert.throws(()=>validatePureCallArtifact(encode(p),['data','RemoteResult','not_delivered']),e=>e instanceof InvalidPureCallArtifact&&unwritable.test(e.message));
});
test('all three outcomes must be dealt with: a match on an outcome is exhaustive', () => {
  for(const missing of [3,4,5]){const p=program();outer(p).splice(missing,1);remap(p);rejects(p,`arm ${missing} missing`,/Non-exhaustive or duplicate match arms/);}
  const twice=program();outer(twice)[5]=clone(outer(twice)[4]);outer(twice)[5][2][1]='900';twice.source_map.push({id:'900',file:'x',line:'0',column:'0'});
  remap(twice);rejects(twice,'two arms for one outcome',/Non-exhaustive or duplicate match arms|Source map/);
  const foreign=program();outer(foreign)[5][0]='lost';rejects(foreign,'an arm that is no outcome',/Non-exhaustive or duplicate match arms/);
});
test('the name of the outcome values cannot be declared, and a program cannot construct an outcome', () => {
  const named=program();named.datatypes=[{name:'RemoteResult',constructors:[{name:'reply',fields:['I64']}]}];rejects(named,'RemoteResult declared',/Datatype name/);
  const made=program();made.functions[0].body=['construct',made.functions[0].body[1],'RemoteResult','not_delivered'];remap(made);
  made.functions[0].effects=[];rejects(made,'outcome constructed',/Unknown datatype/);
});
test('the JavaScript machine runs a schema /3 program that performs no remote operation', () => {
  const p=program();p.functions[0].body[4]=['perform',outer(p)[1],'Note','note',['var',outer(p)[2][1],p.functions[0].parameter_id]];
  p.functions[0].effects=[];remap(p);
  const checked=check(p),run=new HandlerMachine(checked.artifact,checked.input).run(200);
  assert.equal(run.execution,'Completed');assert.deepEqual(run.outcome,['Ok',['int','0']]);
});

const BOUND=[['caller','Ledger','peer']];
const operations=()=>remoteOperations(check(program()).artifact,'caller',BOUND);
// The Ledger declaration of the program above, as a peer's program has it; and a digest for each side.
const LEDGER=()=>program().effects[0];
const SIGNED=()=>({Ledger:signatureDigest(LEDGER())});
test('the operations of an image are derived from the declarations and the manifest\'s bindings, and from nothing else', () => {
  assert.deepEqual(operations().map(o=>[o.effect,o.operation,o.peer,o.mode]),[['Ledger','add','peer','keyed'],['Ledger','total','peer','read-only']]);
  const {artifact}=check(program());
  assert.throws(()=>remoteOperations(artifact,'caller',[]),/the manifest binds it to no member/);
  // Another caller's binding is not this caller's.
  assert.throws(()=>remoteOperations(artifact,'caller',[['other','Ledger','peer']]),/the manifest binds it to no member/);
  assert.throws(()=>remoteOperations(artifact,'caller',[...BOUND,['caller','Note','peer']]),/does not declare it as a remote effect/);
  assert.throws(()=>remoteOperations(artifact,'caller',[...BOUND,['caller','Ledger','other']]),/bound twice/);
  assert.throws(()=>remoteOperations(cases[0].program,'caller',[]),/schema tc1-handler-demo\/3/);
  // What a peer serves comes from the peer's own program, which is of another schema.
  assert.throws(()=>servedOperations(artifact),/schema tc1-handler-demo\/4/);
  assert.deepEqual(wireProblems(operations()),[]);
  const wide=operations();wide[1].argument_type='I64';assert.equal(wireProblems(wide).length,1);
  // A request names its operation (wire format 4): a second operation of a mode is no problem.
  const two=operations();two.push({...two[1],operation:'count'});assert.deepEqual(wireProblems(two),[]);
  const long=operations();long[0].operation='a'.repeat(60);assert.equal(wireProblems(long).length,1);
});
test('the digest of a signature covers names, types and read-only markers, and not the order of declaration', () => {
  const digest=signatureDigest(LEDGER());
  assert.match(digest,/^[0-9a-f]{64}$/);
  // The encoding is the canonical one, of exactly this object.
  const expected=createHash('sha256').update(encode({effect:'Ledger',operations:[
    {argument_type:'I64',name:'add',read_only:false,result_type:['Tuple','I64','I64']},
    {argument_type:'Unit',name:'total',read_only:true,result_type:'I64'}],schema:'fenrir.remote-signature/1'})).digest('hex');
  assert.equal(digest,expected);
  const reordered=LEDGER();reordered.operations.reverse();assert.equal(signatureDigest(reordered),digest);
  const edit=change=>{const e=LEDGER();change(e);return signatureDigest(e);};
  for(const other of [edit(e=>{e.operations[1].read_only=false;}),edit(e=>{e.operations[0].argument_type='Unit';}),edit(e=>{e.operations[0].result_type='I64';}),
    edit(e=>{e.operations[1].name='sum';}),edit(e=>{e.name='Book';}),edit(e=>{e.operations.push({name:'entries',argument_type:'Unit',result_type:'I64',read_only:true});})])
    assert.notEqual(other,digest);
  assert.throws(()=>signatureDigest(program().effects[1]),/remote effect/);
  // The two programs of the example include one declarations file, so their digests are one.
  const text=name=>readFileSync('examples/remote/'+name,'utf8');
  for(const name of ['ledger-caller.fen','ledger-peer.fen'])assert.match(text(name),/^\(include "ledger\.decl\.fen"\)$/m);
  assert.match(text('ledger.decl.fen'),/^\(remote-effect Ledger\n  \(add I64 --> \(Tuple I64 I64\)\)\n  \(read-only total Unit --> I64\)\)$/m);
  assert.ok(!/remote-effect/.test(text('ledger-caller.fen').replace(/^\\\\.*$/gm,'')+text('ledger-peer.fen').replace(/^\\\\.*$/gm,'')));
});
test('the declarations the images carry are spelled as the supervisor reads them', () => {
  const serves=operations().map(({effect,operation,mode})=>({effect,operation,mode})),d=SIGNED().Ledger;
  assert.equal(callerDeclaration(operations(),SIGNED()),'FENRIR-REMOTE-DECL/3 connects=peer uses=peer/Ledger.add/keyed,peer/Ledger.total/read-only signatures=Ledger:'+d);
  assert.equal(peerDeclaration(serves,true,true,SIGNED()),'FENRIR-REMOTE-SERVES/2 store=yes writes=yes operations=Ledger.add/keyed,Ledger.total/read-only signatures=Ledger:'+d);
  assert.equal(peerDeclaration(serves,false,false,SIGNED()),'FENRIR-REMOTE-SERVES/2 store=no writes=no operations=Ledger.add/keyed,Ledger.total/read-only signatures=Ledger:'+d);
  const relay=readFileSync('supervisor/src/fenrir_relay.erl','utf8');
  for(const marker of ['FENRIR-REMOTE-DECL/3 ','FENRIR-REMOTE-SERVES/2 '])assert.ok(relay.includes(`<<"\\n${marker}">>`),marker);
  for(const refusal of ['<<"no-store">>','<<"unserved">>','<<"unbound">>','<<"unknown-member">>','<<"signature">>','<<"StoreWrite">>'])assert.ok(relay.includes(refusal),refusal);
  // No marker is written by hand: each line comes from data.h, which the build writes.
  assert.ok(!/FENRIR-REMOTE/.test(readFileSync('backends/solo5/remote/caller.c','utf8')+readFileSync('backends/solo5/remote/peer.c','utf8')));
});
test('assembly refuses a declared remote effect with no manifest connection, and a storeless peer that serves a keyed operation or whose program writes', () => {
  const serves=operations().map(({effect,operation,mode})=>({effect,operation,mode})),edge=[['caller','peer']];
  const caller={name:'caller',kind:'caller',operations:serves,signatures:SIGNED()},peer=(store,writes=true)=>({name:'peer',kind:'peer',store,writes,serves,signatures:SIGNED()});
  assert.deepEqual(assemblyProblems([caller,peer(true)],edge,BOUND),[]);
  assert.deepEqual(assemblyProblems([caller,peer(true)],[],BOUND),[['caller','peer']]);
  assert.deepEqual(assemblyProblems([caller,peer(true)],[['peer','caller']],BOUND),[['caller','peer']]);
  assert.deepEqual(assemblyProblems([caller,peer(false)],edge,BOUND),[['peer','no-store','Ledger.add'],['peer','no-store','StoreWrite']]);
  assert.deepEqual(assemblyProblems([caller,peer(false,false)],edge,BOUND),[['peer','no-store','Ledger.add']]);
  // A peer without a store is allowed for read-only operations, and only for them; and only if its program does not mention the write effect.
  const reads=serves.filter(o=>o.mode==='read-only');
  const reader={name:'caller',kind:'caller',operations:reads,signatures:SIGNED()};
  const meter=writes=>({name:'peer',kind:'peer',store:false,writes,serves:reads,signatures:SIGNED()});
  assert.deepEqual(assemblyProblems([reader,meter(false)],edge,BOUND),[]);
  assert.deepEqual(assemblyProblems([reader,meter(true)],edge,BOUND),[['peer','no-store','StoreWrite']]);
  assert.deepEqual(assemblyProblems([caller,meter(false)],edge,BOUND),[['caller','peer','unserved','Ledger.add']]);
  // A caller that takes an operation for read-only when the peer does not serve it so is refused too.
  const mistaken={name:'caller',kind:'caller',operations:serves.map(o=>({...o,mode:'read-only'})),signatures:SIGNED()};
  assert.deepEqual(assemblyProblems([mistaken,peer(true)],edge,BOUND),[['caller','peer','unserved','Ledger.add']]);
});
test('assembly refuses a caller and a peer whose digests of an effect\'s signature differ', () => {
  const serves=operations().map(({effect,operation,mode})=>({effect,operation,mode})),edge=[['caller','peer']];
  const caller={name:'caller',kind:'caller',operations:serves,signatures:SIGNED()};
  // The peer was built from a declaration with one operation more: it serves all the caller uses, in the right modes.
  const wider=LEDGER();wider.operations.push({name:'entries',argument_type:'Unit',result_type:'I64',read_only:true});
  const other={name:'peer',kind:'peer',store:true,writes:true,serves:[...serves,{effect:'Ledger',operation:'entries',mode:'read-only'}],signatures:{Ledger:signatureDigest(wider)}};
  assert.deepEqual(assemblyProblems([caller,other],edge,BOUND),[['caller','peer','signature','Ledger']]);
  // A member that does not serve the effect at all is unserved, not mismatched.
  const idle={name:'peer',kind:'peer',store:true,writes:false,serves:[],signatures:{}};
  assert.deepEqual(assemblyProblems([caller,idle],edge,BOUND),[['caller','peer','unserved','Ledger.add'],['caller','peer','unserved','Ledger.total']]);
});
test('assembly takes the member of a remote effect from the manifest\'s bindings, and refuses each way a binding can fail with its own message', () => {
  const serves=operations().map(({effect,operation,mode})=>({effect,operation,mode})),edge=[['caller','peer']];
  const caller={name:'caller',kind:'caller',operations:serves,signatures:SIGNED()},peer={name:'peer',kind:'peer',store:true,writes:true,serves,signatures:SIGNED()};
  // No binding: the effect is used and the manifest says nothing of who serves it. Another caller's binding does not count.
  assert.deepEqual(assemblyProblems([caller,peer],edge,[]),[['caller','unbound','Ledger']]);
  assert.deepEqual(assemblyProblems([caller,peer],edge,[['other','Ledger','peer']]),[['caller','unbound','Ledger']]);
  // Bound to a name that is no member of the system.
  assert.deepEqual(assemblyProblems([caller,peer],edge,[['caller','Ledger','ledger']]),[['caller','unknown-member','Ledger','ledger']]);
  // Bound to a member the manifest declares no connection to from the caller: a connection the other way is not one.
  const spare={...peer,name:'spare'};
  assert.deepEqual(assemblyProblems([caller,peer,spare],edge,[['caller','Ledger','spare']]),[['caller','spare']]);
  assert.deepEqual(assemblyProblems([caller,peer],[['peer','caller']],BOUND),[['caller','peer']]);
  // The member an operation goes to is the bound one, whatever else is in the system; a caller serves nothing.
  const idle={name:'spare',kind:'peer',store:true,writes:false,serves:[],signatures:{}};
  assert.deepEqual(assemblyProblems([caller,peer,idle],[['caller','spare']],[['caller','Ledger','spare']]),[['caller','spare','unserved','Ledger.add'],['caller','spare','unserved','Ledger.total']]);
  const second={name:'second',kind:'caller',operations:[],signatures:{}};
  assert.deepEqual(assemblyProblems([caller,second],[['caller','second']],[['caller','Ledger','second']]),[['caller','second','unserved','Ledger.add'],['caller','second','unserved','Ledger.total']]);
});
test('the build reads the system from its manifest: the source of every member, the connections and the bindings; it holds no binding itself', () => {
  assert.equal(MANIFEST,'examples/remote/ledger-system.json');
  const manifest=readManifest(MANIFEST);
  assert.deepEqual(manifest,{schema:'fenrir.system-manifest/2',members:[{name:'caller',kind:'caller',program:'examples/remote/ledger-caller.fen'},
    {name:'peer',kind:'peer',program:'examples/remote/ledger-peer.fen',store:true}],connections:[['caller','peer']],bindings:[['caller','Ledger','peer']]});
  // The second system: a caller that only reads, and a peer with no durable store.
  const rates=readManifest('examples/remote/rates-system.json');
  assert.deepEqual(rates.members,[{name:'caller',kind:'caller',program:'examples/remote/rates-caller.fen'},{name:'peer',kind:'peer',program:'examples/remote/rates-peer.fen',store:false}]);
  assert.ok(!/StoreWrite|StoreRead/.test(readFileSync('examples/remote/rates-peer.fen','utf8').replace(/^\\\\.*$/gm,'')));
  // The peer is a program: it has a serve form, and the hand-written counter is gone from the peer's C.
  assert.match(readFileSync(manifest.members[1].program,'utf8'),/^\(serve Ledger$/m);
  const peer=readFileSync('backends/solo5/remote/peer.c','utf8');
  assert.ok(peer.includes('serve_request(')&&!/applications/.test(peer));
  assert.throws(()=>readFileSync('fixtures/tc1/remote-caller.mjs'));
  // Neither the effect's name nor a member's source is in the build script: both come from the manifest.
  const build=readFileSync('tools/solo5/remote-build.mjs','utf8');
  assert.ok(!/Ledger|ledger-caller|ledger-peer\.fen|BINDINGS/.test(build)&&build.includes("MANIFEST='examples/remote/ledger-system.json'"));
  // The supervisor takes the bindings from the manifest it is given, and the harness from what the build read.
  assert.ok(readFileSync('supervisor/src/fenrir_main.erl','utf8').includes('maps:get(<<"bindings">>, Manifest, [])'));
  assert.ok(readFileSync('harness/tc1-remote-run.shen','utf8').includes('(set fx.*bindings* (fh.field "bindings" Info))'));
  assert.ok(!/"Ledger" "peer"/.test(readFileSync('harness/tc1-remote-run.shen','utf8')));
});
test('a system manifest is closed and well formed, or the build does not start', () => {
  const good=()=>JSON.parse(readFileSync(MANIFEST,'utf8')),bad=(edit,pattern)=>{const m=good();edit(m);assert.throws(()=>checkManifest(m),pattern);};
  assert.ok(checkManifest(good()));
  bad(m=>{delete m.bindings;},/schema fenrir.system-manifest\/2/);
  bad(m=>{m.schema='fenrir.system-manifest/1';},/schema fenrir.system-manifest\/2/);
  bad(m=>{m.extra=1;},/schema fenrir.system-manifest\/2/);
  bad(m=>{m.members[1].kind='store';},/a member is/);
  bad(m=>{delete m.members[0].program;},/a member is/);
  // A peer names its program and says whether it has a durable store.
  bad(m=>{delete m.members[1].program;},/a member is/);
  bad(m=>{delete m.members[1].store;},/a member is/);
  bad(m=>{m.members[1].store='yes';},/whether it has a durable store/);
  bad(m=>{m.members[0].store=false;},/a member is/);
  bad(m=>{m.members[0].program='/etc/passwd';},/relative to the repository/);
  bad(m=>{m.members[1].program='';},/relative to the repository/);
  bad(m=>{m.members[1].name='caller';},/listed twice/);
  bad(m=>{m.members[1].name='Peer';},/member name/);
  bad(m=>{m.connections=[['caller','ledger']];},/does not join two members/);
  bad(m=>{m.bindings=[['Ledger','peer']];},/is not \[caller, Effect, member\]/);
  bad(m=>{m.bindings=[['peer','Ledger','peer']];},/is not for a caller/);
  bad(m=>{m.bindings.push(['caller','Ledger','caller']);},/bound twice/);
  // Well formed, and refused at assembly instead: a binding to no member, and one with no connection behind it.
  for(const edit of [m=>{m.bindings=[['caller','Ledger','ledger']];},m=>{m.connections=[];},m=>{m.bindings=[];}]){const m=good();edit(m);assert.ok(checkManifest(m));}
});
