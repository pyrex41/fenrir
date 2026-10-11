import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit,TRAP_CODES} from '../../tools/tc0/pure-call-artifact.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
import {cases} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
const clone=x=>JSON.parse(JSON.stringify(x));
const check=(a,input=['int','0'],caps)=>validatePureCallArtifact(encode(a),input,caps);
const run=(a,input)=>{const v=check(a,input);return new PureCallMachine(v.artifact,v.input).run();};
const program=name=>clone(cases.find(c=>c.name===name).program);
// One-function schema /2 artifact whose body is supplied with every node ID mapped.
function single(body,{argument_type='I64',result_type='I64',datatypes=[]}={}){
 const ids=new Set(['0']);const walk=e=>{if(Array.isArray(e)){if(typeof e[0]==='string'&&typeof e[1]==='string'&&/^\d+$/.test(e[1])&&e[0]!=='Data'&&e[0]!=='Tuple'&&e[0]!=='Arrow')ids.add(e[1]);e.forEach(walk);}};walk(body);
 for(const binder of collectBinders(body))ids.delete(binder);
 return {contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/2',slice:'TC0-A',module:'unit',datatypes,effects:[],functions:[{id:'0',name:'main',parameter_id:'1',argument_type,result_type,effects:[],body}],entry:'main',input_schema:{type:argument_type},source_map:[...ids].map(id=>({id,file:'unit',line:'0',column:'0'}))};
}
function collectBinders(e,out=new Set()){if(!Array.isArray(e))return out;if(e[0]==='let'||e[0]==='lambda')out.add(e[2]);if(e[0]==='match')for(const arm of e.slice(3))for(const b of arm[1])out.add(b);e.forEach(x=>collectBinders(x,out));return out;}
const Opt={name:'Opt',constructors:[{name:'None',fields:[]},{name:'Some',fields:['I64']}]};

for(const c of cases)test('data hand '+c.name,()=>{
 const r=run(c.program);assert.equal(r.execution,'Completed');assert.deepEqual(r.outcome,c.expected_outcome);
 if(c.expected_return_frames!==undefined)assert.equal(r.steps.filter(s=>s.site.rule==='ReturnReturn').length,Number(c.expected_return_frames));
 if(c.maximum_depth!==undefined)assert.ok(Math.max(...r.steps.map(s=>Number(s.depth)))<=Number(c.maximum_depth));
 if(c.expected_descriptor_count!==undefined)assert.equal(r.descriptors.length,Number(c.expected_descriptor_count));
 if(c.expected_emissions!==undefined)assert.deepEqual(r.events.filter(e=>e.kind==='Emit').map(e=>e.label),c.expected_emissions);
});

test('schema /1 stays closed: data tags, primitives and declarations rejected',()=>{
 for(const name of ['bytes-concat-length-index','tuple-left-to-right-project','recursive-datatype-sum','structural-eq','trapcode-enum-result']){const a=program(name);a.schema_version='tc0-a-pure-call-demo/1';assert.throws(()=>check(a),InvalidPureCallArtifact,name);}
 const a=single(['prim','2','eq',['int','3','1'],['int','4','1']],{result_type:'Bool'});check(a);a.schema_version='tc0-a-pure-call-demo/1';assert.throws(()=>check(a),InvalidPureCallArtifact);
});

test('bytes literals are canonical lowercase even-length hex under a size cap',()=>{
 for(const hex of ['','00','ff7f'])check(single(['prim','2','bytes_length',['bytes','3',hex]]));
 for(const hex of ['0','FF','0x00','zz'])assert.throws(()=>check(single(['prim','2','bytes_length',['bytes','3',hex]])),InvalidPureCallArtifact,hex);
 assert.throws(()=>check(single(['prim','2','bytes_length',['bytes','3','00'.repeat(4)]]),['int','0'],{maxBytes:3}),PureCallValidationLimit);
});

test('byte primitive and eq signatures are checked',()=>{
 for(const body of [
  ['prim','2','bytes_length',['int','3','1']],
  ['prim','2','bytes_index',['bytes','3','00'],['bytes','4','00']],
  ['prim','2','bytes_concat',['bytes','3','00']],
  ['prim','2','eq',['int','3','1'],['bool','4',true]],
  ['prim','2','eq',['lambda','3','4','I64','I64',[],[],['var','5','4']],['lambda','6','7','I64','I64',[],[],['var','8','7']]]
 ])assert.throws(()=>check(single(body,{result_type:body[2]==='eq'?'Bool':'I64'})),InvalidPureCallArtifact,JSON.stringify(body));
});

test('bytes primitives: exact length, octet index and Bounds at both edges',()=>{
 const index=i=>run(single(['prim','2','bytes_index',['bytes','3','00ff'],['int','4',String(i)]])).outcome;
 assert.deepEqual(index(0),['Ok',['int','0']]);assert.deepEqual(index(1),['Ok',['int','255']]);
 for(const i of [2,-1,'9223372036854775807','-9223372036854775808'])assert.deepEqual(index(i),['Trap','Bounds']);
 assert.deepEqual(run(single(['prim','2','bytes_concat',['bytes','3',''],['bytes','4','ab']],{result_type:'Bytes'})).outcome,['Ok',['bytes','ab']]);
});

test('tuples: arity 1-8 and statically checked projection index',()=>{
 const tuple=n=>['tuple','2',...Array.from({length:n},(_,i)=>['int',String(10+i),String(i)])];
 check(single(['project','30',tuple(8),'7']));
 assert.throws(()=>check(single(['project','30',tuple(9),'0'])),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['project','30',['tuple','2'],'0'])),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['project','30',tuple(2),'2'])),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['project','30',tuple(2),'-1'])),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['project','30',['int','3','1'],'0'])),InvalidPureCallArtifact);
});

test('datatype declarations are closed, unique and well-typed',()=>{
 const body=['construct','2','Opt','None'],base={result_type:['Data','Opt'],datatypes:[Opt]};check(single(body,base));
 for(const datatypes of [
  [Opt,Opt],
  [{name:'Opt',constructors:[]}],
  [{name:'Opt',constructors:[{name:'None',fields:[]},{name:'None',fields:[]}]}],
  [{name:'I64',constructors:[{name:'X',fields:[]}]}],
  [{name:'Opt',constructors:[{name:'None',fields:[],extra:'1'}]}],
  [{name:'Opt',constructors:[{name:'None',fields:[['Data','Missing']]}]}],
  [{name:'bad-name',constructors:[{name:'None',fields:[]}]}]
 ])assert.throws(()=>check(single(body,{...base,datatypes})),InvalidPureCallArtifact,JSON.stringify(datatypes));
});

test('construct checks constructor name, field count and field types',()=>{
 const base={result_type:['Data','Opt'],datatypes:[Opt]};
 check(single(['construct','2','Opt','Some',['int','3','1']],base));
 for(const body of [['construct','2','Opt','Some'],['construct','2','Opt','Some',['bool','3',true]],['construct','2','Opt','Other'],['construct','2','Nope','None'],['construct','2','Opt','None',['int','3','1']]])
  assert.throws(()=>check(single(body,base)),InvalidPureCallArtifact,JSON.stringify(body));
 check(single(['construct','2','TrapCode','Overflow'],{result_type:'TrapCode'}));
 assert.throws(()=>check(single(['construct','2','TrapCode','UnhandledEffect'],{result_type:'TrapCode'})),InvalidPureCallArtifact);
});

test('match must be exhaustive with no duplicate arms; binders are typed and scoped',()=>{
 const scrutinee=['construct','2','Opt','None'],base={datatypes:[Opt]};
 const none=['None',[],['int','3','0']],some=['Some',['4'],['var','5','4']];
 check(single(['match','6',scrutinee,none,some],base));check(single(['match','6',scrutinee,some,none],base));
 for(const arms of [[none],[none,none],[none,some,some],[none,['Some',[],['int','5','0']]],[none,['Some',['4','7'],['int','5','0']]],[none,['Other',[],['int','5','0']]]])
  assert.throws(()=>check(single(['match','6',scrutinee,...arms],base)),InvalidPureCallArtifact,JSON.stringify(arms));
 assert.throws(()=>check(single(['match','6',scrutinee,none,['Some',['4'],['bool','5',true]]],base)),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['match','6',['int','2','1'],none,some],base)),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['let','9','14',['match','6',scrutinee,none,some],['var','8','4']],base)),/Unknown binding/);
 const all=TRAP_CODES.map((k,i)=>[k,[],['int',String(20+i),'0']]);
 check(single(['match','6',['construct','2','TrapCode','Bounds'],...all]));
 assert.throws(()=>check(single(['match','6',['construct','2','TrapCode','Bounds'],...all.slice(1)])),InvalidPureCallArtifact);
});

test('serializable entry/emit exclude functions inside tuples and datatypes',()=>{
 const Box={name:'Box',constructors:[{name:'Box',fields:[['Arrow','I64','I64',[]]]}]};
 assert.throws(()=>check(single(['tuple','2',['lambda','3','4','I64','I64',[],[],['var','5','4']]],{result_type:['Tuple',['Arrow','I64','I64',[]]]})),InvalidPureCallArtifact);
 assert.throws(()=>check(single(['construct','2','Box','Box',['lambda','3','4','I64','I64',[],[],['var','5','4']]],{result_type:['Data','Box'],datatypes:[Box]})),InvalidPureCallArtifact);
 const Rec={name:'Rec',constructors:[{name:'Leaf',fields:[]},{name:'Node',fields:[['Data','Rec'],'Bytes']}]};
 check(single(['construct','2','Rec','Leaf'],{result_type:['Data','Rec'],datatypes:[Rec]}));
});

test('typed entry inputs: bytes, tuples, datatypes and TrapCode values are checked',()=>{
 const List={name:'List',constructors:[{name:'Nil',fields:[]},{name:'Cons',fields:['Bytes',['Data','List']]}]};
 const type=['Tuple',['Data','List'],'TrapCode'],a=single(['var','2','1'],{argument_type:type,result_type:type,datatypes:[List]});
 const input=['tuple',['data','List','Cons',['bytes','ab'],['data','List','Nil']],['data','TrapCode','DivZero']];
 assert.deepEqual(run(a,input).outcome,['Ok',input]);
 for(const bad of [['tuple',['data','List','Nil']],['tuple',['data','List','Cons',['bytes','AB'],['data','List','Nil']],['data','TrapCode','DivZero']],['tuple',['data','List','Nil'],['data','TrapCode','Nope']],['tuple',['data','Other','Nil'],['data','TrapCode','DivZero']]])
  assert.throws(()=>check(a,bad),InvalidPureCallArtifact,JSON.stringify(bad));
});

test('match selects one arm with fields bound in declaration order; unselected arms never run',()=>{
 const Pair={name:'Pair',constructors:[{name:'Pair',fields:['I64','I64']},{name:'Other',fields:[]}]};
 const a=single(['match','2',['construct','3','Pair','Pair',['int','4','7'],['int','5','2']],['Other',[],['prim','6','div',['int','7','1'],['int','8','0']]],['Pair',['9','10'],['prim','11','sub',['var','12','9'],['var','13','10']]]],{datatypes:[Pair]});
 const r=run(a);assert.deepEqual(r.outcome,['Ok',['int','5']]);assert.equal(r.steps.filter(s=>s.site.rule==='MatchReturn').length,1);
});

test('eq is structural across nested values and distinguishes constructors and lengths',()=>{
 const eq=(x,y)=>run(single(['prim','2','eq',x,y],{result_type:'Bool',datatypes:[Opt]})).outcome[1][1];
 assert.equal(eq(['bytes','3','0102'],['bytes','4','0102']),true);
 assert.equal(eq(['bytes','3','01'],['bytes','4','0102']),false);
 assert.equal(eq(['construct','3','Opt','Some',['int','4','1']],['construct','5','Opt','Some',['int','6','2']]),false);
 assert.equal(eq(['tuple','3',['unit','4'],['construct','5','TrapCode','Bounds']],['tuple','6',['unit','7'],['construct','8','TrapCode','Bounds']]),true);
 assert.equal(eq(['tuple','3',['unit','4'],['construct','5','TrapCode','Bounds']],['tuple','6',['unit','7'],['construct','8','TrapCode','Overflow']]),false);
});

test('reverse-operands mutant is distinguished on tuple and constructor collection',()=>{
 const reversed=name=>{const v=check(program(name));return new PureCallMachine(v.artifact,v.input,{reverseOperands:true}).run();};
 const r=reversed('tuple-left-to-right-project');assert.deepEqual(r.outcome,['Ok',['int','1']]);assert.deepEqual(r.events.filter(e=>e.kind==='Emit').map(e=>e.label),['right','left']);
});

test('typed reductions reach into match arms and tuples and stay valid',async()=>{
 const {pureCallReductions}=await import('../../tools/tc0/pure-call-reduce.mjs');
 for(const name of ['recursive-datatype-sum','match-arm-tail-call','tuple-left-to-right-project','trapcode-enum-result']){
  const proposals=pureCallReductions(program(name));
  for(const p of proposals)check(p.program);
 }
 const a=single(['match','6',['construct','2','Opt','Some',['int','3','4']],['None',[],['int','7','0']],['Some',['4'],['prim','8','add',['var','5','4'],['int','9','0']]]],{datatypes:[Opt]});
 const inside=pureCallReductions(a).find(p=>p.rule==='add-zero');
 assert.deepEqual(inside.path,['0','4','2']);check(inside.program);assert.deepEqual(run(inside.program).outcome,['Ok',['int','4']]);
 assert.ok(!inside.program.source_map.some(r=>['8','9'].includes(r.id)),'source map drops removed arm nodes');
});

test('data hand cases record and replay Exact; reversed tuple collection diverges',async()=>{
 const {pureCallHeader}=await import('../../tools/tc0/pure-call-replay-header.mjs');
 const {recordPureCall,replayPureCall}=await import('../../tools/tc0/pure-call-replay.mjs');
 const setup=(c,reverseOperands=false)=>{const v=check(c.program),machine=()=>new PureCallMachine(v.artifact,v.input,{reverseOperands});
  const reference=new PureCallMachine(v.artifact,v.input).run().steps,m=machine(),header=pureCallHeader(m,v.artifact,v.input,reference,{unit_mock:true});
  return {machine,reference,header,bundle:recordPureCall(m,reference,header)};};
 for(const c of cases){const s=setup(c),r=replayPureCall(s.machine(),s.reference,s.header,s.bundle);assert.equal(r.replay,'Exact',c.name);assert.equal(r.conformance,'Admitted',c.name);}
 const s=setup(cases.find(c=>c.name==='tuple-left-to-right-project'),true);assert.equal(s.bundle.footer.kind,'Divergence');
 assert.equal(replayPureCall(s.machine(),s.reference,s.header,s.bundle).conformance,'Diverged');
});

test('wrap-overflow mutant replaces each Overflow trap with the two\'s-complement result',()=>{
 const wrapped=name=>{const v=check(program(name));return new PureCallMachine(v.artifact,v.input,{wrapOverflow:true}).run().outcome;};
 assert.deepEqual(wrapped('div-min-by-minus-one'),['Ok',['int','-9223372036854775808']]);
 assert.deepEqual(wrapped('mul-exact-square-then-overflow'),['Ok',['int',String(BigInt.asIntN(64,3037000499n*3037000499n*2n))]]);
 assert.deepEqual(wrapped('gt-ge-mul-around-2-53'),['Ok',['int','43']]);
});
