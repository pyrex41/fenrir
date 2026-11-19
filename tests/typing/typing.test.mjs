import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,mkdtempSync,readFileSync,rmSync,writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validateFrontendArtifact,validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {cases as calls} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as data} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlers,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';

const root=resolve(import.meta.dirname,'../..');
const jit=process.env.FENRIR_SHEN_JIT??spawnSync('sh',['-c','. ./harness/jit.sh; printf %s "$jit"','harness/x'],{cwd:root,encoding:'utf8'}).stdout;
const bin=join(jit,'bin/shen-jit');
const options={skip:!existsSync(bin)&&'Set FENRIR_SHEN_JIT to a Shen/JIT install prefix'};
const zero=['int','0'];
const text=p=>encode(p).toString();
const canonical=p=>JSON.parse(text(p));
const acceptedJob='host/service/artifacts/accepted-job.json';

function runCases(t,cases) {
  const dir=mkdtempSync(join(tmpdir(),'fenrir-typing-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const file=join(dir,'cases.jsonl');
  writeFileSync(file,cases.map(c=>JSON.stringify(c)).join('\n')+'\n');
  const r=spawnSync(bin,['script',join(root,'tests/typing/cases.shen'),join(jit,'lib'),root,file],{cwd:root,encoding:'utf8',input:'',timeout:60_000});
  assert.equal(r.status,0,r.error??r.stderr+r.stdout.slice(-2000));
  assert.deepEqual(JSON.parse(r.stdout.trim().split('\n').at(-1)),{cases:String(cases.length),failures:[]});
}

const program={contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/1',slice:'TC0-A',module:'hand',datatypes:[],effects:[],
  functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:'I64',effects:[],body:['prim','2','add',['var','3','1'],['int','4','1']]}],
  entry:'main',input_schema:{type:'I64'},source_map:['0','2','3','4'].map(id=>({id,file:'hand',line:'0',column:'0'}))};
const proof=(p,body,input=zero,plain=[])=>['Program',['well-typed',canonical(p),input],[
  ...plain,['Function',['function',canonical(p.functions[0])],[body]],
  ['P-Base',['plain',[],'I64'],[]],['P-Base',['plain',[],'I64'],[]]]];
const g=[['1','I64']];
const v=['T-Var',['expr',g,['var','3','1'],'I64',[],[]],[]];
const sound=['T-Prim',['expr',g,program.functions[0].body,'I64',[],[]],[
  v,['T-Int',['expr',g,['int','4','1'],'I64',[],[]],[]]]];
const badInt={...program,functions:[{...program.functions[0],body:['bool','2',true]}],source_map:program.source_map.slice(0,2)};
const d1={...program,contract_version:'tc1-draft-1',schema_version:'tc1-durable-demo/1',slice:'TC1-D1',
  effects:[{name:'Store',class:'durable',operations:[{name:'put',argument_type:'I64',result_type:'I64'}]}],
  functions:[{...program.functions[0],effects:['Store'],body:['perform','2','Store','put',['var','3','1']]}],
  source_map:program.source_map.slice(0,3)};
const perform=effects=>['T-Perform',['expr',g,d1.functions[0].body,'I64',effects,[]],[v]];
const opPremises=Array.from({length:2},()=>['P-Base',['plain',[],'I64'],[]]);
const caseOf=(name,p,expect,more={})=>({name,text:text(p),expect,...more});

test('bounded agreement and derivation round trips: all old hand fixtures and accepted-job',options,t=>{
  const cases=[...calls,...data,...handlers,...resumptionCases].map(({name,program})=>caseOf(name,program,'accept'));
  const bytes=readFileSync(join(root,acceptedJob));
  const {artifact,input}=validateFrontendArtifact(bytes);
  assert.equal(input[0],'data');
  assert.equal(input[1],'Command');
  cases.push(caseOf('service: typed probe',artifact,'accept',{input}),caseOf('service: wrong input',artifact,'reject'));
  for(const c of cases.filter(c=>c.expect==='accept'))validatePureCallArtifact(Buffer.from(c.text),c.input??zero);
  for(const c of cases.filter(c=>c.expect==='accept')) {
    const p=JSON.parse(c.text);
    p.source_map.pop();
    assert.throws(()=>validatePureCallArtifact(encode(p),c.input??zero),/Source map incomplete/);
    cases.push(caseOf(c.name+': missing source map row',p,'reject',{input:c.input??zero}));
  }
  runCases(t,cases);
});

test('fixed checker rejects forged derivations and an unsound search result',options,t=>{
  const dropped=structuredClone(sound);dropped[2].pop();
  const swapped=structuredClone(sound);swapped[2].reverse();
  const cases=[
    caseOf('hand proof',program,'accept',{derivation:proof(program,sound)}),
    caseOf('unknown rule',program,'reject',{derivation:proof(program,['T-Add',...sound.slice(1)])}),
    caseOf('missing premise',program,'reject',{derivation:proof(program,dropped)}),
    caseOf('swapped premises',program,'reject',{derivation:proof(program,swapped)}),
    caseOf('transplanted proof',{...program,module:'other'},'reject',{derivation:proof(program,sound)}),
    caseOf('unsound search',badInt,'forgery-rejected',{unsound:true}),
    caseOf('same ill-typed program under normal search',badInt,'reject'),
    caseOf('proof search out of budget',program,'unknown',{low_budget:true}),
    caseOf('durable hand proof',d1,'accept',{derivation:proof(d1,perform(['Store']),zero,opPremises)}),
    caseOf('forgotten durable effect',d1,'reject',{derivation:proof(d1,perform([]),zero,opPremises)}),
    caseOf('ordinary effect cannot be residual',{...d1,effects:[{...d1.effects[0],class:'ordinary'}]},'reject'),
    caseOf('remote class is not valid in D1',{...d1,effects:[{...d1.effects[0],class:'remote'}]},'reject'),
    caseOf('D1 has no task forms',{...d1,functions:[{...d1.functions[0],body:['yield','2']}],source_map:program.source_map.slice(0,2)},'reject'),
    caseOf('D1 input value cap',{...d1,functions:[{...d1.functions[0],argument_type:'Bytes'}],input_schema:{type:'Bytes'}},'limit',{input:['bytes','00'.repeat(257)]}),
  ];
  runCases(t,cases);
});

function fenrir(strict,...args){
  return spawnSync('sh',['frontend/fenrir.sh',...args],{cwd:root,encoding:'utf8',timeout:30_000,
    env:{...process.env,FENRIR_SHEN_JIT:jit,FENRIR_REQUIRE_SHEN_TYPING:strict?'1':'0'}});
}
function status(r,n){assert.equal(r.status,n,r.error??r.stdout+r.stderr);}

test('strict frontend preserves the D1 artifact and refuses unsupported R1/P1 without output',options,t=>{
  const dir=mkdtempSync(join(tmpdir(),'fenrir-typing-'));
  t.after(()=>rmSync(dir,{recursive:true,force:true}));
  const out=join(dir,'out.json');
  status(fenrir(true,'emit','examples/service/accepted-job.fen',out),0);
  assert.deepEqual(readFileSync(out),readFileSync(join(root,acceptedJob)));
  status(fenrir(true,'check','tests/frontend/durable/durable-datatype-field-effect.fen'),0);
  status(fenrir(true,'check','tests/frontend/durable/request-after-resume.fen'),0);
  status(fenrir(true,'run-artifact','fixtures/tc0/pure-call-forward.json'),0);
  const cases=[];
  for(const [source,schema] of [['examples/remote/ledger-caller.fen','tc1-handler-demo/3'],['examples/remote/ledger-peer.fen','tc1-handler-demo/4']]){
    const blocked=join(dir,'blocked.json');
    const strict=fenrir(true,'emit',source,blocked);
    status(strict,2);
    assert.match(strict.stderr,/Shen typing does not support schema/);
    assert.ok(strict.stderr.includes(schema));
    assert.equal(existsSync(blocked),false);
    status(fenrir(false,'emit',source,out),0);
    const artifact=JSON.parse(readFileSync(out,'utf8'));
    assert.equal(artifact.schema_version,schema);
    cases.push(caseOf(schema,artifact,'unsupported'));
    const run=fenrir(true,'run-artifact',out);
    status(run,2);
    assert.match(run.stderr,/Shen typing does not support schema/);
    assert.equal(run.stdout,'');
  }
  for(const [schema,slice] of [['tc1-handler-demo/3','TC1-R1'],['tc1-handler-demo/4','TC1-P1'],['tc1-task-demo/1','TC1-C1'],['future/1','Future']]){
    const p={...program,schema_version:schema,slice,contract_version:'tc1-draft-1'};
    cases.push(caseOf(schema+' with a relabelled proof',p,'reject',{direct:true,derivation:proof(p,sound)}));
    cases.push(caseOf(schema+' with a legacy shape',p,'unsupported'));
  }
  runCases(t,cases);
});
