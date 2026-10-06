// New development fixtures only: mathematical hand outcomes are not an oracle
// implementation. Existing artifact validator remains the admission authority.
import {mkdirSync,writeFileSync,realpathSync} from 'node:fs';
import {resolve,relative} from 'node:path';
import {fileURLToPath} from 'node:url';
import {encode} from '../../tc0/canonical.mjs';
import {lower,dataHeader} from './lower.mjs';
const root=fileURLToPath(new URL('../../..',import.meta.url));
const dest=resolve(process.argv[2]??'');
if(process.argv.length!==3||!relative(resolve(root,'build/solo5'),dest)||relative(resolve(root,'build/solo5'),dest).startsWith('..'))throw Error('fresh build/solo5 directory required');
// Resolve parent to exclude symlink escape before creating output.
if(relative(realpathSync(resolve(root,'build/solo5')),realpathSync(resolve(dest,'..'))).startsWith('..'))throw Error('output escape');
mkdirSync(dest);
const manifest=[];
let next=2;
const int=n=>['int',String(next++),String(n)];
const bool=b=>['bool',String(next++),b];
const variable=id=>['var',String(next++),String(id)];
const prim=(op,...args)=>['prim',String(next++),op,...args];
const emit=(label,v)=>['emit',String(next++),label,v];
const bind=(id,init,body)=>['let',String(next++),String(id),init,body];
const branch=(cond,yes,no)=>['if',String(next++),cond,yes,no];
const ok=v=>['Ok',v], trap=code=>['Trap',code];
function add(name,make,outcome,emits=[],argumentType='Unit',input=['unit'],fuel=200,execution='Completed',rules=null){
 next=2;const body=make();const ids=[];
 function walk(e){ids.push(e[1]);for(const a of e.slice(2))if(Array.isArray(a))walk(a);}walk(body);
 const artifact={contract_version:'0.2',datatypes:[],effects:[],entry:'main',functions:[{argument_type:argumentType,body,effects:emits.length?['Emit']:[],id:'0',name:'main',parameter_id:'1',result_type:body[0]==='bool'||body[0]==='prim'&&body[2]==='not'?'Bool':'I64'}],input_schema:{type:argumentType},module:name,schema_version:'tc0-a-arithmetic-demo/1',slice:'TC0-A',source_map:['0',...ids].map(id=>({column:'0',file:name+'.tc0',id,line:'1'}))};
 // Trapping left operand suppresses RHS emit but the static effect remains.
 if(name==='left_trap')artifact.functions[0].effects=['Emit'];
 const bytes=encode(artifact),data=lower(bytes,input);
 writeFileSync(resolve(dest,name+'.artifact.json'),bytes,{flag:'wx'});writeFileSync(resolve(dest,name+'.input.json'),encode(input),{flag:'wx'});writeFileSync(resolve(dest,name+'.h'),dataHeader(data),{flag:'wx'});
 manifest.push({name,fuel:String(fuel),execution,outcome,emits,rules});
}
add('exact_2p53',()=>prim('add',int('9007199254740993'),int(1)),ok(['int','9007199254740994']));
add('wide_mul',()=>prim('mul',int('3037000500'),int('3037000500')),trap('Overflow'));
add('min_neg',()=>prim('neg',int('-9223372036854775808')),trap('Overflow'));
add('min_div',()=>prim('div',int('-9223372036854775808'),int(-1)),trap('Overflow'));
add('negative_div',()=>prim('div',int(-7),int(3)),ok(['int','-2']));
add('max_add',()=>prim('add',int('9223372036854775807'),int(1)),trap('Overflow'));
// Source-level shadowing resolves distinct binder identities (20 then 21);
// reusing identity20 is rejected by the unchanged validator, not admitted.
add('shadow',()=>bind(20,int(7),bind(21,int(9),variable(21))),ok(['int','9']));
add('selected_if',()=>branch(variable(1),bind(20,emit('yes',int(7)),int(3)),bind(21,emit('no',int(8)),int(4))),ok(['int','3']),['yes'],'Bool',['bool',true]);
add('emit_order',()=>prim('add',bind(20,emit('left',int(7)),int(1)),bind(21,emit('right',int(8)),int(2))),ok(['int','3']),['left','right']);
add('left_trap',()=>prim('add',prim('div',int(1),int(0)),bind(20,emit('rhs',int(7)),int(2))),trap('DivZero'));
add('bool_not',()=>prim('not',bool(true)),ok(['bool',false]));
// Literal hand trace: Dispatch->Value, root Value->Join, Join->Terminate,
// Terminate->Terminal. Budget3 stops before termination; budget4 completes.
add('last_step',()=>int(7),ok(['int','7']),[],'Unit',['unit'],4,'Completed',['Dispatch','Value','Join','Terminate']);
add('budget_edge',()=>int(7),null,[],'Unit',['unit'],3,'BudgetExhausted',['Dispatch','Value','Join']);
writeFileSync(resolve(dest,'manifest.json'),JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({qualification:'UNKNOWN',hand_cases:manifest.length,directory:dest}));
