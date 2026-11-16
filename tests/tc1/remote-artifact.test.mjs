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
import {remoteOperations,wireProblems,callerDeclaration,peerDeclaration,assemblyProblems,SOURCE,BINDINGS} from '../../tools/solo5/remote-build.mjs';

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
  const raw=program();raw.functions[0].body=inner(raw)[2];remap(raw);rejects(raw,'outcome used as the value',/Function signature/);
  const typed=clone(raw);typed.functions[0].result_type=['Remote','I64'];assert.ok(check(typed));
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
  made.functions[0].result_type=['Remote','I64'];made.functions[0].effects=[];rejects(made,'outcome constructed',/Unknown datatype/);
});
test('the JavaScript machine runs a schema /3 program that performs no remote operation', () => {
  const p=program();p.functions[0].body[4]=['perform',outer(p)[1],'Note','note',['var',outer(p)[2][1],p.functions[0].parameter_id]];
  p.functions[0].effects=[];remap(p);
  const checked=check(p),run=new HandlerMachine(checked.artifact,checked.input).run(200);
  assert.equal(run.execution,'Completed');assert.deepEqual(run.outcome,['Ok',['int','0']]);
});

const operations=()=>remoteOperations(check(program()).artifact,[['Ledger','peer']]);
test('the operations of an image are derived from the declarations and the binding, and from nothing else', () => {
  assert.deepEqual(operations().map(o=>[o.effect,o.operation,o.peer,o.mode]),[['Ledger','add','peer','keyed'],['Ledger','total','peer','read-only']]);
  const {artifact}=check(program());
  assert.throws(()=>remoteOperations(artifact,[]),/binds it to no member/);
  assert.throws(()=>remoteOperations(artifact,[['Ledger','peer'],['Note','peer']]),/does not declare as a remote effect/);
  assert.throws(()=>remoteOperations(artifact,[['Ledger','peer'],['Ledger','other']]),/bound twice/);
  assert.throws(()=>remoteOperations(cases[0].program,[]),/schema tc1-handler-demo\/3/);
  assert.deepEqual(wireProblems(operations()),[]);
  const wide=operations();wide[1].argument_type='I64';assert.equal(wireProblems(wide).length,1);
  const two=operations();two.push({...two[1],operation:'count'});assert.equal(wireProblems(two).length,2);
});
test('the declarations the images carry are spelled as the supervisor reads them', () => {
  assert.equal(callerDeclaration(operations()),'FENRIR-REMOTE-DECL/2 connects=peer uses=peer/Ledger.add/keyed,peer/Ledger.total/read-only');
  assert.equal(peerDeclaration(operations(),'peer',true),'FENRIR-REMOTE-SERVES/1 store=yes operations=Ledger.add/keyed,Ledger.total/read-only');
  assert.equal(peerDeclaration(operations(),'peer',false),'FENRIR-REMOTE-SERVES/1 store=no operations=Ledger.add/keyed,Ledger.total/read-only');
  const relay=readFileSync('supervisor/src/fenrir_relay.erl','utf8');
  for(const marker of ['FENRIR-REMOTE-DECL/2 ','FENRIR-REMOTE-SERVES/1 '])assert.ok(relay.includes(`<<"\\n${marker}">>`),marker);
  for(const refusal of ['<<"no-store">>','<<"unserved">>'])assert.ok(relay.includes(refusal),refusal);
  // The hand-written marker is gone: the caller's line comes from data.h, the peer's from the build's command line.
  assert.ok(!/FENRIR-REMOTE/.test(readFileSync('backends/solo5/remote/caller.c','utf8')+readFileSync('backends/solo5/remote/peer.c','utf8')));
});
test('assembly refuses a declared remote effect with no manifest connection, and a storeless peer that serves a keyed operation', () => {
  const serves=operations().map(({effect,operation,mode})=>({effect,operation,mode}));
  const caller={name:'caller',kind:'caller',operations:operations()},peer=store=>({name:'peer',kind:'peer',store,serves});
  assert.deepEqual(assemblyProblems([caller,peer(true)],[['caller','peer']]),[]);
  assert.deepEqual(assemblyProblems([caller,peer(true)],[]),[['caller','peer']]);
  assert.deepEqual(assemblyProblems([caller,peer(true)],[['peer','caller']]),[['caller','peer']]);
  assert.deepEqual(assemblyProblems([caller,peer(false)],[['caller','peer']]),[['peer','no-store','Ledger.add']]);
  // A peer without a store is allowed for read-only operations, and only for them.
  const reader={name:'caller',kind:'caller',operations:operations().filter(o=>o.mode==='read-only')};
  const meter={name:'peer',kind:'peer',store:false,serves:serves.filter(o=>o.mode==='read-only')};
  assert.deepEqual(assemblyProblems([reader,meter],[['caller','peer']]),[]);
  assert.deepEqual(assemblyProblems([caller,meter],[['caller','peer']]),[['caller','peer','unserved','Ledger.add']]);
  // A caller that takes an operation for read-only when the peer does not serve it so is refused too.
  const mistaken={name:'caller',kind:'caller',operations:operations().map(o=>({...o,mode:'read-only'}))};
  assert.deepEqual(assemblyProblems([mistaken,peer(true)],[['caller','peer']]),[['caller','peer','unserved','Ledger.add']]);
});
test('the build names a source file as the caller program, and no fixture stands in for it', () => {
  assert.equal(SOURCE,'examples/remote/ledger-caller.fen');
  assert.deepEqual(BINDINGS,[['Ledger','peer']]);
  const source=readFileSync(SOURCE,'utf8');
  assert.match(source,/^\(remote-effect Ledger\n  \(add I64 --> \(Tuple I64 I64\)\)\n  \(read-only total Unit --> I64\)\)$/m);
  assert.throws(()=>readFileSync('fixtures/tc1/remote-caller.mjs'));
});
