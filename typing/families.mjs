// Batch peer of typing/run.shen, UNQUALIFIED development transport. Writes every
// program family of the repository that the typing differential covers, one JSON line
// per program, with the JavaScript validator's verdict on the exact bytes the Shen side
// will read. Nothing is compared here: typing/run.shen compares.
//
//   node typing/families.mjs OUTDIR [ELABORATED_DIR]
//
// OUTDIR must exist and be empty. Writes OUTDIR/families.jsonl:
//   {family, name, expect, text, js: {status, message, class}}
// expect is "valid" for the repository's valid families, "invalid" for its invalid ones,
// and "mutant" for single-point mutants (typing/mutate.mjs), whose verdict is not known
// in advance. text is the artifact's bytes as the validators read them. js.class maps
// the validator's message onto the check or rule of spec/tc1/TYPING.md (CLASSES below).
// ELABORATED_DIR holds frontend-elaborated artifacts (*.json), written by typing/run.shen.
import {readdirSync,readFileSync,writeFileSync} from 'node:fs';
import {resolve,basename} from 'node:path';
import {encode,EncodingError,EncodingLimit} from '../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from '../tools/tc0/pure-call-artifact.mjs';
import {cases as callHand} from '../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlerCases,resumptionCases} from '../fixtures/tc1/handler-hand-cases.mjs';
import {generatePureCalls} from '../tools/tc0/pure-call-generate.mjs';
import {generatePureData} from '../tools/tc0/pure-data-generate.mjs';
import {enumeratePureData} from '../tools/tc0/pure-data-enumerate.mjs';
import {generateInvalidPureData} from '../tools/tc0/pure-data-invalid.mjs';
import {enumerateHandlers} from '../tools/tc1/handler-enumerate.mjs';
import {exactArithmeticCases} from '../tools/solo5/freerun-pure-call.mjs';
import {mutants,resync} from './mutate.mjs';
import {harvest} from './harvest.mjs';
import {cases as durableHand} from '../fixtures/tc1/durable-hand-cases.mjs';
import {cases as taskHand} from '../fixtures/tc1/task-hand-cases.mjs';
import {enumerateTasks} from '../tools/tc1/task-enumerate.mjs';

// The input the frontend validates a durable artifact with (frontend/validate.mjs): the
// least value of the entry's argument type; 0 for every other schema.
function least(t,datatypes,depth=0) {
  if(depth>16)return null;
  if(t==='Unit')return ['unit'];if(t==='Bool')return ['bool',false];if(t==='I64')return ['int','0'];
  if(t==='Bytes')return ['bytes',''];if(t==='TrapCode')return ['data','TrapCode','Overflow'];
  if(Array.isArray(t)&&t[0]==='Tuple'){const vs=t.slice(1).map(x=>least(x,datatypes,depth+1));return vs.includes(null)?null:['tuple',...vs];}
  if(Array.isArray(t)&&t[0]==='Data')for(const c of datatypes.find(d=>d.name===t[1])?.constructors??[]){
    const vs=c.fields.map(f=>least(f,datatypes,depth+1));if(!vs.includes(null))return ['data',t[1],c.name,...vs];}
  return null;
}
export function frontendInput(text) {
  try{const a=JSON.parse(text);if(a?.schema_version==='tc1-durable-demo/1')return least(a.input_schema?.type,a.datatypes??[])??INPUT;}catch{}
  return INPUT;
}
import {probes} from './probes.mjs';

// The validator's messages, each mapped to the TYPING.md structural check (S-...),
// cap (L-...) or typing rule it corresponds to. The coarse class is the part before
// the colon; the differential compares coarse classes.
export const CLASSES={
  'Identity':'structure:S-Identity',
  'Effect declarations unsupported':'structure:S-Features','Declarations unsupported':'structure:S-Features',
  'Closed object fields':'structure:S-Shape','Array required':'structure:S-Shape','String required':'structure:S-Shape',
  'Identifier':'structure:S-Shape','Unsigned ID':'structure:S-Shape','Expression':'structure:S-Shape','Arity':'structure:S-Shape',
  'Unsupported tag':'structure:S-Shape','Primitive':'structure:S-Shape','Tuple arity':'structure:S-Shape','Match arm':'structure:S-Shape',
  'Handler clause':'structure:S-Shape','Empty capture support required':'structure:S-Shape',
  'Datatype count':'structure:S-Declarations','Datatype name':'structure:S-Declarations','Constructor count':'structure:S-Declarations',
  'Duplicate constructor':'structure:S-Declarations','Field count':'structure:S-Declarations','Effect count':'structure:S-Declarations',
  'Effect name':'structure:S-Declarations','Operation count':'structure:S-Declarations','Duplicate operation':'structure:S-Declarations',
  'Function count':'structure:S-Declarations','Duplicate function name':'structure:S-Declarations',
  'Duplicate ID':'structure:S-Unique-IDs',
  'Source map location':'structure:S-Source-Map','Source map incomplete':'structure:S-Source-Map',
  'AST cap':'limit:L-Nodes','Type depth':'limit:L-Type-Depth','Value cap':'limit:L-Values','Bytes cap':'limit:L-Bytes',
  // typing: the rule whose premise or side condition fails
  'Effect set':'typing:WF-Effects','Effect set order':'typing:WF-Effects','Type':'typing:WF-Type',
  'Operation types must be serializable':'typing:Program','Entry':'typing:Program','Entry must handle every user effect':'typing:Program',
  'Serializable entry':'typing:Program','Input schema':'typing:Program','Value type/range':'typing:T-Int/Value','Bytes hex':'typing:T-Bytes/Value',
  'Function signature':'typing:Function','Named function captures':'typing:Function',
  'Unknown binding':'typing:T-Var','A resumption is not a value':'typing:T-Var','If types':'typing:T-If',
  'A resumption must be used on every path':'typing:T-If/T-Match','Equality type':'typing:T-Eq','Primitive type':'typing:T-Prim',
  'Projection':'typing:T-Project','Unknown datatype':'typing:T-Construct','Constructor':'typing:T-Construct',
  'Constructor field type':'typing:T-Construct','Match scrutinee type':'typing:T-Match','Non-exhaustive or duplicate match arms':'typing:T-Match',
  'Match binders':'typing:T-Match','Match arm types':'typing:T-Match','Emit serializable':'typing:T-Emit','Lambda signature':'typing:T-Lambda',
  'Apply type':'typing:T-Apply','Unknown function':'typing:T-Call','Call argument':'typing:T-Call','Unknown effect operation':'typing:T-Perform',
  'Perform argument':'typing:T-Perform','Unknown effect':'typing:T-Handle','Handler clauses':'typing:T-Handle',
  'Handler clause type':'typing:T-Handle','A resumption must be used exactly once on every path':'typing:T-Handle',
  'Unknown resumption':'typing:T-Resume/T-Discontinue','Resume argument':'typing:T-Resume',
  // schema tc1-durable-demo/1 (spec/tc1/DURABLE.md)
  'Effect class':'structure:S-Declarations',
  // schema tc1-task-demo/1 (spec/tc1/CONCURRENCY.md)
  'A scope result must be serializable':'typing:T-Scope',
  'A task result must be serializable':'typing:T-Spawn',
  'Spawn needs a function from Unit':'typing:T-Spawn',
  'Task handle required':'typing:T-Await/T-Cancel',
  'Channel handle required':'typing:T-Send/T-Receive/T-Close',
  'Channel capacity':'typing:T-Channel',
  'Channel elements must be serializable':'typing:T-Channel',
  'Send value type':'typing:T-Send',
};

const INPUT=['int','0'];
export function jsVerdict(bytes,input=INPUT) {
  try {validatePureCallArtifact(bytes,input);return {status:'valid'};}
  catch(e) {
    if(e instanceof PureCallValidationLimit||e instanceof EncodingLimit)return {status:'limit',message:e.message,class:CLASSES[e.message]??'limit:L-Encoding'};
    if(e instanceof EncodingError)return {status:'invalid',message:e.message,class:'structure:S-Transport'};
    if(e instanceof InvalidPureCallArtifact)return {status:'invalid',message:e.message,class:CLASSES[e.message]??'unmapped'};
    throw e;
  }
}

// The rejections of tests/tc1/handler-artifact.test.mjs, rebuilt here as programs.
function handlerTestRejections() {
  const clone=p=>JSON.parse(JSON.stringify(p)),out=[];
  const base=handlerCases.find(c=>c.name==='handler-basic').program,handle=p=>p.functions[0].body;
  const add=(name,p)=>out.push({name,program:p});
  {const p=clone(base);handle(p)[3]=[];add('missing-clause',p);}
  {const p=clone(base);handle(p)[3].push(clone(handle(p)[3][0]));add('duplicate-clause',p);}
  {const p=clone(base);handle(p)[3][0][0]='tell';add('clause-undeclared-operation',p);}
  {const p=clone(base);p.effects=[];add('handle-undeclared-effect',p);}
  {const p=clone(base);p.effects[0].name='Emit';add('reserved-effect-name',p);}
  {const p=clone(base);p.effects.push(clone(p.effects[0]));add('duplicate-effect',p);}
  {const p=clone(base);p.functions[0].body=handle(p)[4];
   p.source_map=p.source_map.filter(r=>JSON.stringify(p.functions[0].body).includes(`"${r.id}"`)||r.id===p.functions[0].id);
   add('unhandled-effect-at-entry',p);const q=clone(p);q.functions[0].effects=['Ask'];add('entry-declares-user-effect',q);}
  const f=handlerCases.find(c=>c.name==='clause-sees-definition-bindings').program;
  {const p=clone(f);p.functions[1].effects=['Ask','Ask'];add('effect-set-duplicate',p);}
  {const p=clone(f);p.functions[1].effects=['Emit','Ask'];add('effect-set-order',p);}
  {const p=clone(f);p.functions[1].effects=['Nope'];add('effect-set-undeclared',p);}
  {const p=clone(f);p.functions[1].effects=[];add('effect-set-missing',p);}
  {const p=clone(f);p.functions[1].effects=['Ask','Emit'];add('caller-misses-callee-emit',p);}
  {const p=clone(base),perform=handle(p)[4][3];perform[4]=['unit',perform[4][1]];add('perform-argument-type',p);}
  {const p=clone(base),clause=handle(p)[3][0];clause[2]=['unit',clause[2][1]];
   p.source_map=p.source_map.filter(r=>JSON.stringify(p.functions).includes(`"${r.id}"`));add('clause-result-type',p);}
  {const p=clone(base);p.effects[0].operations[0].result_type=['Arrow','I64','I64',[]];add('arrow-operation-type',p);}
  {const p=clone(base);p.contract_version='0.2';p.schema_version='tc0-a-pure-call-demo/2';p.slice='TC0-A';add('tc0-effect-declarations',p);
   const q=clone(p);q.effects=[];add('tc0-handle',q);}
  const h2=resumptionCases.find(c=>c.name==='clause-continues-after-resume').program,clauseOf=p=>handle(p)[3][0];
  const remap=p=>{p.source_map=p.source_map.filter(r=>JSON.stringify(p.functions).includes(`"${r.id}"`));return p;};
  let next=5000;const id=()=>String(next++);
  const located=(p,...ids)=>{for(const i of ids)p.source_map.push({id:i,file:'t',line:'0',column:'0'});return p;};
  {const p=clone(h2),c=clauseOf(p),a=id();c[3]=['int',a,'0'];add('resumption-unused',located(remap(p),a));}
  {const p=clone(h2),c=clauseOf(p),k=c[2],a=id(),b=id(),d=id(),e=id(),g=id();
   c[3]=['prim',a,'add',['resume',b,k,['int',d,'1']],['resume',e,k,['int',g,'2']]];add('resumption-twice',located(remap(p),a,b,d,e,g));}
  {const p=clone(h2),c=clauseOf(p),k=c[2],a=id(),b=id(),d=id(),e=id(),g=id();
   c[3]=['if',a,['bool',b,true],['resume',d,k,['int',e,'1']],['int',g,'0']];add('resumption-one-path',located(remap(p),a,b,d,e,g));}
  {const p=clone(h2),c=clauseOf(p),a=id();c[3]=['var',a,c[2]];add('resumption-as-value',located(remap(p),a));}
  {const p=clone(h2),c=clauseOf(p),k=c[2],l=id(),u=id(),r=id(),n=id(),ap=id(),un=id();
   c[3]=['apply',ap,['lambda',l,u,'Unit','I64',[],[],['resume',r,k,['int',n,'1']]],['unit',un]];add('resumption-captured',located(remap(p),l,r,n,ap,un));}
  {const p=clone(h2),c=clauseOf(p),k=c[2],a=id(),b=id();c[3]=['resume',a,k,['unit',b]];add('resume-argument-type',located(remap(p),a,b));}
  {const p=clone(h2),c=clauseOf(p),k=c[2],h=id(),x=id(),r=id(),n=id(),pf=id(),pa=id();
   c[3]=['handle',h,'Ask',[['ask',x,['resume',r,k,['int',n,'1']]]],['perform',pf,'Ask','ask',['int',pa,'0']]];
   add('outer-resumption-in-inner-clause',located(remap(p),h,r,n,pf,pa));}
  {const p=clone(h2);p.schema_version='tc1-handler-demo/1';p.slice='TC1-H1';add('h2-forms-under-h1',p);}
  return out;
}

export async function families(elaborated) {
  const list=[];
  const add=(family,expect,cases)=>{for(const c of cases)list.push({family,name:c.name,expect,program:c.program,text:c.text,contract:c.contract,input:c.input});};
  add('tc0-hand','valid',[...callHand,...dataHand]);
  add('generated-pure-call','valid',generatePureCalls(32).cases);
  add('generated-pure-data','valid',generatePureData(24).cases);
  add('exact-arithmetic','valid',exactArithmeticCases());
  add('exhaustive-5','valid',enumeratePureData(5).cases);
  add('tc1-hand','valid',[...handlerCases,...resumptionCases]);
  add('tc1-exhaustive-7','valid',enumerateHandlers(7).cases);
  add('durable-hand','valid',durableHand);
  add('task-hand','valid',taskHand);
  add('task-grammar-G','valid',enumerateTasks().cases);
  if(elaborated)add('frontend','valid',readdirSync(elaborated).filter(f=>f.endsWith('.json')).sort()
    .map(f=>{const text=readFileSync(resolve(elaborated,f),'utf8');return {name:basename(f,'.json'),text,input:frontendInput(text)};}));
  add('pure-data-invalid','invalid',generateInvalidPureData().cases);
  add('handler-test-rejections','invalid',handlerTestRejections());
  // The same invalid programs with the source map made to cover exactly their nodes: the
  // test mutations leave stale rows, a second fault the two validators find in a
  // different order. Without it each has one fault, and the classes should agree.
  add('invalid-resynced','invalid',[...generateInvalidPureData().cases.filter(c=>!c.name.includes('source-map')),...handlerTestRejections()]
    .map(c=>({name:c.name,program:resync(JSON.parse(JSON.stringify(c.program)))})));
  // Every program the durable and task validator tests hand to the validator, with its
  // input: their accepted programs and their rejections alike (typing/harvest.mjs).
  for(const [family,file] of [['durable-artifact-tests','tests/tc1/durable-artifact.test.mjs'],['task-artifact-tests','tests/tc1/task-artifact.test.mjs']])
    add(family,'test',(await harvest(resolve(import.meta.dirname,'..',file))).map((c,i)=>({name:`${family}-${i}`,...c})));
  add('mutants','mutant',mutants());
  add('probes','probe',probes());
  return list;
}

if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename) {
  const [directory,elaborated]=process.argv.slice(2);
  if(!directory||process.argv.length>4)throw new Error('Usage: node typing/families.mjs OUTDIR [ELABORATED_DIR]');
  const lines=(await families(elaborated)).map(c=>{
    const text=c.text??encode(c.program).toString('utf8'),input=c.input??INPUT;
    return JSON.stringify({family:c.family,name:c.name,expect:c.expect,text,input,js:jsVerdict(Buffer.from(text,'utf8'),input),...c.contract?{contract:c.contract}:{}});
  });
  writeFileSync(resolve(directory,'families.jsonl'),lines.join('\n')+'\n',{flag:'wx'});
  console.log(JSON.stringify({programs:String(lines.length),output:resolve(directory,'families.jsonl')}));
}
