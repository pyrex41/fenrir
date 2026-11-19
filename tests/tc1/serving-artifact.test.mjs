// Artifact schema tc1-handler-demo/4 (slice TC1-P1): a peer's program, which serves a
// remote effect and reaches the peer's store through StoreRead and StoreWrite
// (spec/tc1/EFFECTS.md §8, §12.3, §12.12), and one request run on the JavaScript machine.
import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,TC1_SERVING_SCHEMA,TC1_REMOTE_SCHEMA,mentionsStoreWrite} from '../../tools/tc0/pure-call-artifact.mjs';
import {serveRequest} from '../../runtime/tc1/peer-request.mjs';
import {lowerBatch} from '../../tools/solo5/pure-call/lower.mjs';

const check=p=>validatePureCallArtifact(encode(p),null);
const clone=p=>JSON.parse(JSON.stringify(p));
const rejects=(p,why,pattern)=>assert.throws(()=>check(p),e=>e instanceof InvalidPureCallArtifact&&pattern.test(e.message),why);

// A hand-assembled peer program:
//   remote effect Ledger { add : I64 -> (I64, I64); read-only total : Unit -> I64 }
//   effect Note { note : I64 -> I64 }
//   bump(p)        = perform(StoreWrite, put, (0, perform(StoreRead, get, 0) + p))
//   Ledger.add(p)  = let _ = bump(project(p,1)) in (0, perform(StoreRead, get, 0))
//   Ledger.total(u) = handle Note { note(x) => x } in perform(Note, note, perform(StoreRead, get, 0))
// `mutate` is given the node builder and may replace the body of total.
function program(total) {
  let next=0;const locations=[];
  const fresh=()=>String(next++),node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const int=n=>node('int',String(n)),get=k=>node('perform','StoreRead','get',int(k)),put=(k,v)=>node('perform','StoreWrite','put',node('tuple',int(k),v));
  const fn=(name,argument_type,result_type,effects,make)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type,result_type,effects,body:make(parameter_id)};};
  const pair=['Tuple','I64','I64'],x=fresh(),drop=fresh();
  const functions=[
    fn('bump','I64','Unit',['StoreRead','StoreWrite'],p=>put(0,node('prim','add',get(0),node('var',p)))),
    fn('Ledger.add',pair,pair,['StoreRead','StoreWrite'],p=>node('let',drop,node('call','bump',node('project',node('var',p),'1')),node('tuple',int(0),get(0)))),
    total?total({node,int,get,put,fn,fresh}):fn('Ledger.total','Unit','I64',['StoreRead'],()=>node('handle','Note',[['note',x,node('var',x)]],node('perform','Note','note',get(0))))];
  return {contract_version:'tc1-draft-1',schema_version:TC1_SERVING_SCHEMA,slice:'TC1-P1',module:'serving-unit',datatypes:[],
    effects:[{name:'Ledger',class:'remote',operations:[{name:'add',argument_type:'I64',result_type:pair,read_only:false},
                                                         {name:'total',argument_type:'Unit',result_type:'I64',read_only:true}]},
             {name:'Note',class:'ordinary',operations:[{name:'note',argument_type:'I64',result_type:'I64'}]}],
    functions,serves:[{effect:'Ledger',operations:[{name:'add',function:'Ledger.add'},{name:'total',function:'Ledger.total'}]}],
    source_map:locations.map(id=>({id,file:'serving-unit',line:'0',column:'0'}))};
}

test('a peer program is admitted: served functions, store effects, no entry and no input', () => {
  const {artifact,input}=check(program());
  assert.equal(artifact.schema_version,'tc1-handler-demo/4');
  assert.equal(input,null);
  assert.equal(mentionsStoreWrite(artifact),true);
  // Whatever is given as an input is not looked at: there is no entry to give it to.
  assert.doesNotThrow(()=>validatePureCallArtifact(encode(program()),['int','0']));
});

test('Solo5 lowers remote peer operation indices without a durable input or reply descriptor', () => {
  const {function_index,header}=lowerBatch([{program:program(),input:['unit']}]);
  assert.deepEqual(function_index,[{bump:0,'Ledger.add':1,'Ledger.total':2}]);
  assert.doesNotMatch(header,/PC_INPUT_VALUE|struct pc_datatype/);
  assert.match(header,/,"StoreWrite","put",/);
});

test('read-only is checked on the peer: the implementation of a read-only operation cannot write the store', () => {
  // total writes directly, and says so in its effect set.
  rejects(program(({fn,get,put,node,fresh,int})=>{const d=fresh();return fn('Ledger.total','Unit','I64',['StoreRead','StoreWrite'],()=>node('let',d,put(0,int(1)),get(0)));}),
    'a direct write',/read-only operation cannot write the store/);
  // total writes and does not say so: its signature is then wrong.
  rejects(program(({fn,get,put,node,fresh,int})=>{const d=fresh();return fn('Ledger.total','Unit','I64',['StoreRead'],()=>node('let',d,put(0,int(1)),get(0)));}),
    'an undeclared write',/Function signature/);
  // total calls a function that writes: the callee's effect set reaches it.
  rejects(program(({fn,get,node,fresh,int})=>{const d=fresh();return fn('Ledger.total','Unit','I64',['StoreRead','StoreWrite'],()=>node('let',d,node('call','bump',int(1)),get(0)));}),
    'a write through a call',/read-only operation cannot write the store/);
  rejects(program(({fn,get,node,fresh,int})=>{const d=fresh();return fn('Ledger.total','Unit','I64',['StoreRead'],()=>node('let',d,node('call','bump',int(1)),get(0)));}),
    'a write through a call, undeclared',/Function signature/);
  // total applies a function value whose type carries the write.
  rejects(program(({fn,get,put,node,fresh,int})=>{const d=fresh(),v=fresh();
    const writer=node('lambda',v,'I64','Unit',['StoreWrite'],[],put(0,node('var',v)));
    return fn('Ledger.total','Unit','I64',['StoreRead','StoreWrite'],()=>node('let',d,node('apply',writer,int(1)),get(0)));}),
    'a write through a closure',/read-only operation cannot write the store/);
  // The marker is what is checked: the same body under an operation that is not read-only is fine.
  const loose=program(({fn,get,put,node,fresh,int})=>{const d=fresh();return fn('Ledger.total','Unit','I64',['StoreRead','StoreWrite'],()=>node('let',d,put(0,int(1)),get(0)));});
  loose.effects[0].operations[1].read_only=false;loose.functions[2].argument_type=['Tuple','I64','Unit'];
  assert.doesNotThrow(()=>check(loose));
});

test('what a serving artifact must and must not have', () => {
  const p=program();
  let q=clone(p);q.entry='Ledger.add';rejects(q,'an entry',/Closed object fields/);
  q=clone(p);delete q.serves;rejects(q,'no serves',/Closed object fields/);
  q=clone(p);q.serves=[];rejects(q,'nothing served',/Serves/);
  q=clone(p);q.serves[0].operations.pop();rejects(q,'an operation without its function',/Served operations/);
  q=clone(p);q.serves[0].operations.reverse();rejects(q,'operations out of the declared order',/Served operations/);
  q=clone(p);q.serves[0].operations[1].function='Ledger.add';rejects(q,'one function for two operations',/Served function/);
  q=clone(p);q.serves[0].operations[1].function='nowhere';rejects(q,'an unknown function',/Served function/);
  q=clone(p);q.serves.push(clone(q.serves[0]));rejects(q,'an effect served twice',/Served effect/);
  q=clone(p);q.serves[0].effect='Note';rejects(q,'an ordinary effect served',/Served effect/);
  // The function of an operation that is not read-only takes the request key first.
  q=clone(p);q.effects[0].operations[0].argument_type='Unit';rejects(q,'a served function of another type',/Served function type/);
  q=clone(p);q.effects[0].operations[1].result_type='Unit';rejects(q,'a served function of another result',/Served function type/);
  // The store effects are the runtime's: not declared, not handled.
  q=clone(p);q.effects.push({name:'StoreWrite',class:'ordinary',operations:[{name:'put',argument_type:'I64',result_type:'Unit'}]});rejects(q,'the store declared',/Effect name/);
  rejects(program(({fn,get,node,fresh,int})=>{const c=fresh();return fn('Ledger.total','Unit','I64',[],()=>node('handle','StoreRead',[['get',c,int(0)]],get(0)));}),'the store handled',/Unknown effect/);
  rejects(program(({fn,node,int})=>fn('Ledger.total','Unit','I64',['StoreRead'],()=>node('perform','StoreRead','put',int(0)))),'an operation the store has not',/Unknown effect operation/);
  rejects(program(({fn,node})=>fn('Ledger.total','Unit','I64',['StoreRead'],()=>node('perform','StoreRead','get',node('unit')))),'a wrong argument',/Perform argument/);
  // A served operation leaves nothing but Emit and the store to the runtime.
  rejects(program(({fn,node,int})=>fn('Ledger.total','Unit','I64',['Note'],()=>node('perform','Note','note',int(0)))),'an ordinary effect left unhandled',/must handle every user effect/);
  // A peer does not call onward: no remote perform in a serving program.
  rejects(program(({fn,node,int,fresh})=>{const n=fresh();return fn('Ledger.total','Unit','I64',['Ledger'],()=>
    node('match',node('perform','Ledger','total',node('unit')),['reply',[n],node('var',n)],['not_delivered',[],int(0)],['timed_out',[],int(0)]));}),'a remote perform',/performs no remote operation/);
  // Under the older schemas the store effects do not exist.
  q=clone(p);q.schema_version=TC1_REMOTE_SCHEMA;q.slice='TC1-R1';delete q.serves;q.entry='bump';q.input_schema={type:'I64'};
  assert.throws(()=>validatePureCallArtifact(encode(q),['int','0']),/Effect set/);
});

test('whether a program mentions the write effect at all, for a peer without a store', () => {
  const quiet=program();quiet.functions=quiet.functions.slice(2);
  quiet.effects[0].operations=[quiet.effects[0].operations[1]];quiet.serves[0].operations=[quiet.serves[0].operations[1]];
  const used=new Set();const walk=e=>{if(Array.isArray(e)){if(typeof e[1]==='string'&&/^\d+$/.test(e[1]))used.add(e[1]);e.forEach(walk);}};
  walk(quiet.functions[0].body);used.add(quiet.functions[0].id);
  quiet.source_map=quiet.source_map.filter(r=>used.has(r.id));
  assert.equal(mentionsStoreWrite(check(quiet).artifact),false);
  assert.equal(mentionsStoreWrite(check(program()).artifact),true);
});

test('one request on the JavaScript machine: reads see the request\'s own writes, an absent cell reads 0, a trap leaves writes uncommitted', () => {
  const {artifact}=check(program());
  const key=['int','7'],request=amount=>['tuple',key,['int',String(amount)]];
  // An empty store: get(0) is 0, the write is buffered, and the reply reads it back.
  let r=serveRequest(artifact,'Ledger.add',request(5),new Map());
  assert.equal(r.execution,'Completed');
  assert.deepEqual(r.outcome,['Ok',['tuple',['int','0'],['int','5']]]);
  assert.deepEqual(r.writes,[['0','5']]);
  assert.deepEqual(r.trace.filter(t=>t.store),[{store:'get',key:'0',value:'0'},{store:'put',key:'0',value:'5'},{store:'get',key:'0',value:'5'}]);
  // The store's value is read, and the given map is not changed: nothing is committed here.
  const store=new Map([['0','10'],['3','1']]);
  r=serveRequest(artifact,'Ledger.add',request(-4),store);
  assert.deepEqual(r.outcome,['Ok',['tuple',['int','0'],['int','6']]]);
  assert.deepEqual([...store],[['0','10'],['3','1']]);
  // A store perform takes no machine step: the epochs of the step records are consecutive.
  assert.deepEqual(r.trace.filter(t=>!t.store).map(t=>t.epoch),r.trace.filter(t=>!t.store).map((_,i)=>String(i)));
  // The read-only operation, under a handler frame for another effect.
  r=serveRequest(artifact,'Ledger.total',['unit'],store);
  assert.deepEqual(r.outcome,['Ok',['int','10']]);assert.deepEqual(r.writes,[]);
  // Overflow traps: the outcome is the trap, and whatever was buffered is not a reply's.
  r=serveRequest(artifact,'Ledger.add',request(1),new Map([['0','9223372036854775807']]));
  assert.deepEqual(r.outcome,['Trap','Overflow']);assert.deepEqual(r.writes,[]);
  // The injected defect: a read that does not see this request's write.
  r=serveRequest(artifact,'Ledger.add',request(5),new Map(),{staleReads:true});
  assert.deepEqual(r.outcome,['Ok',['tuple',['int','0'],['int','0']]]);
});
