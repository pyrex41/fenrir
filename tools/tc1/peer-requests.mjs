#!/usr/bin/env node
// Requests served by peer programs, for the three-way comparison of
// harness/tc1-peer-requests.shen (spec/tc1/EFFECTS.md §12.12). UNQUALIFIED development
// transport: nothing is compared here and no model transitions are involved.
//
// A case is (peer program, operation, request input, store). This file elaborates the peer
// programs from their sources (frontend/fenrir.sh emit), validates them, writes the cases,
// runs each on the JavaScript machine (runtime/tc1/peer-request.mjs), with and without its
// injected defect, and builds a Solo5 guest (backends/solo5/remote/check.c) that runs the
// same cases on the C machine with the store code the peer image uses (serve.c).
//   node tools/tc1/peer-requests.mjs --out DIR [--solo5 DIR] [--abi spt|hvt]
// DIR then holds programs.json (the validated artifacts), cases.jsonl (one case a line, with
// the JavaScript runs), check.<abi> and batch.json.
//
// Hand cases carry expectations written from the programs' text and the contract, before
// any machine ran: the outcome, and for an Ok outcome the writes. Generated cases have
// none: the three machines are each other's check there. They come from one fixed seed.
import {createHash} from 'node:crypto';
import {copyFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {toolchain, defaultSolo5, must, SOLO5_COMMIT} from '../solo5/freerun.mjs';
import {elaborate} from '../solo5/remote-build.mjs';
import {lowerBatch} from '../solo5/pure-call/lower.mjs';
import {validatePureCallArtifact, TC1_SERVING_SCHEMA} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
import {serveRequest} from '../../runtime/tc1/peer-request.mjs';

const root=resolve(import.meta.dirname,'../..');
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
export const PROGRAMS=Object.freeze(['examples/remote/ledger-peer.fen','examples/remote/rates-peer.fen','tests/remote/peers/pots.fen']);
export const GENERATED=400,SEED=20261116n,FUEL=2000;
const MAX='9223372036854775807',MIN='-9223372036854775808';
const ok=(...v)=>['Ok',v.length===2?['tuple',['int',String(v[0])],['int',String(v[1])]]:['int',String(v[0])]];
const trap=code=>['Trap',code];

// [program, operation, key or null, argument or null, store, expected outcome, expected writes or null]
// Ledger: cell 0 the total, 1 the number of additions, 2 the key of the latest; add replies (0, new total).
// Pots: cell 0 the balance, 1 the movements, 100+key what the key moved; withdraw traps below zero, after writing.
export const HAND=Object.freeze([
  ['ledger-first-add',0,'Ledger.add','7','5',[],ok(0,5),[['0','5'],['1','1'],['2','7']]],
  ['ledger-second-add',0,'Ledger.add','8','5',[['0','5'],['1','1'],['2','7']],ok(0,10),[['0','10'],['1','2'],['2','8']]],
  ['ledger-add-negative',0,'Ledger.add','1','-5',[['0','3']],ok(0,-2),[['0','-2'],['1','1'],['2','1']]],
  ['ledger-add-zero-negative-key',0,'Ledger.add','-3','0',[],ok(0,0),[['0','0'],['1','1'],['2','-3']]],
  ['ledger-add-overflows',0,'Ledger.add','9','1',[['0',MAX],['1','4']],trap('Overflow'),null],
  ['ledger-add-underflows',0,'Ledger.add','9','-1',[['0',MIN]],trap('Overflow'),null],
  ['ledger-add-to-the-limit',0,'Ledger.add','2',MAX,[],ok(0,MAX),[['0',MAX],['1','1'],['2','2']]],
  ['ledger-count-overflows-after-the-total-is-written',0,'Ledger.add','2','1',[['0','1'],['1',MAX]],trap('Overflow'),null],
  ['ledger-total-of-nothing',0,'Ledger.total',null,null,[],ok(0),[]],
  ['ledger-total',0,'Ledger.total',null,null,[['0','10'],['1','2'],['2','8']],ok(10),[]],
  ['ledger-total-with-other-cells-only',0,'Ledger.total',null,null,[['5','1'],['-1','9']],ok(0),[]],
  ['rates-base',1,'Rates.base',null,null,[],ok(250),[]],
  ['rates-cap',1,'Rates.cap',null,null,[],ok(300),[]],
  ['rates-cap-ignores-a-store',1,'Rates.cap',null,null,[['0','9']],ok(300),[]],
  ['pots-deposit',2,'Pots.deposit','1','5',[],ok(0,5),[['0','5'],['1','1'],['101','5']]],
  ['pots-withdraw',2,'Pots.withdraw','2','5',[['0','5'],['1','1'],['101','5']],ok(0,0),[['0','0'],['1','2'],['102','-5']]],
  ['pots-withdraw-too-much-traps-after-writing',2,'Pots.withdraw','2','9',[['0','5'],['1','1'],['101','5']],trap('DivZero'),null],
  ['pots-deposit-key-overflows-after-three-writes',2,'Pots.deposit',MAX,'1',[],trap('Overflow'),null],
  ['pots-deposit-on-own-cell',2,'Pots.deposit','-100','4',[['0','1']],ok(0,4),[['0','4'],['1','1']]],
  ['pots-balance',2,'Pots.balance',null,null,[['0','-7']],ok(-7),[]],
  ['pots-audit-under-a-handler',2,'Pots.audit',null,null,[['0','5'],['1','1']],ok(6),[]],
  ['pots-audit-overflows',2,'Pots.audit',null,null,[['0',MAX],['1','1']],trap('Overflow'),null]]);

// A 64-bit linear congruential generator (Knuth's MMIX constants), as supervisor/src/fenrir_run.erl has.
function generator(seed){let x=seed;return n=>{x=(x*6364136223846793005n+1442695040888963407n)&0xffffffffffffffffn;return Number((x>>33n)%BigInt(n));};}
const BOUNDARY=['0','1','-1','5','6','100',MAX,MIN,'9223372036854775806','-9223372036854775807','4611686018427387904'];
const KEYS=['0','1','2','7','8','-1','100','101','102','107','-100',MAX];
export function generated(programs,count=GENERATED,seed=SEED) {
  const next=generator(seed),pick=list=>list[next(list.length)],small=()=>String(next(41)-20);
  const cases=[];
  for(let i=0;i<count;i++){
    const program=next(programs.length),served=programs[program].serves.flatMap(s=>s.operations.map((x,k)=>({name:`${s.effect}.${x.name}`,
      keyed:!programs[program].effects.find(e=>e.name===s.effect).operations[k].read_only})));
    const operation=pick(served),cells=new Map();
    for(let k=next(5);k>0;k--)cells.set(next(3)?pick(KEYS):small(),next(3)?small():pick(BOUNDARY));
    cases.push([`generated-${i}`,program,operation.name,operation.keyed?(next(4)?pick(KEYS):small()):null,operation.keyed?(next(3)?small():pick(BOUNDARY)):null,
      [...cells].sort((a,b)=>BigInt(a[0])<BigInt(b[0])?-1:1),null,null]);
  }
  return cases;
}

export function build(tools,dir) {
  mkdirSync(dir,{recursive:true});
  const programs=PROGRAMS.map((source,i)=>{
    const {artifact}=validatePureCallArtifact(elaborate(source,resolve(dir,`program-${i}.json`)),null);
    if(artifact.schema_version!==TC1_SERVING_SCHEMA)throw new Error(`${source} does not serve an effect`);
    return artifact;
  });
  const functionOf=(artifact,operation)=>{const [effect,name]=operation.split('.');return artifact.serves.find(s=>s.effect===effect).operations.find(x=>x.name===name).function;};
  const all=[...HAND,...generated(programs)];
  if(new Set(all.map(c=>c[0])).size!==all.length)throw new Error('Case names must be unique');
  const lowered=lowerBatch(programs.map(program=>({program,input:['unit']})));
  const int=n=>{const v=BigInt(n);return v===-(1n<<63n)?'(-INT64_C(9223372036854775807)-1)':v<0n?`(-INT64_C(${-v}))`:`INT64_C(${v})`;};
  const lines=[],rows=[],tables=[];
  all.forEach(([name,program,operation,key,argument,store,outcome,writes],i)=>{
    const artifact=programs[program],fn=functionOf(artifact,operation),keyed=key!==null;
    const input=keyed?['tuple',['int',key],['int',argument]]:['unit'];
    const run=options=>{const r=serveRequest(artifact,fn,input,new Map(store),{...options,fuel:FUEL});return {execution:r.execution,trace:r.trace,writes:r.writes};};
    lines.push(encode({name,program:String(program),operation,keyed,input,store,expected:outcome?{outcome,writes:writes??[]}:null,
      js:run({}),js_stale_reads:run({staleReads:true})}).toString());
    if(store.length)tables.push(`static const struct serve_cell cells${i}[]={${store.map(([k,v])=>`{${int(k)},${int(v)}}`).join(',')}};`);
    rows.push(`{${program},${lowered.function_index[program][fn]},${keyed?1:0},${keyed?int(key):'0'},${keyed?int(argument):'0'},${store.length},${store.length?`cells${i}`:'0'}}`);
  });
  writeFileSync(resolve(dir,'programs.json'),JSON.stringify(programs));
  writeFileSync(resolve(dir,'cases.jsonl'),lines.join('\n')+'\n');
  writeFileSync(resolve(dir,'data.h'),lowered.header+
    `struct serve_case { unsigned program,function; int keyed; int64_t key,argument; unsigned cell_count; const struct serve_cell *cells; };\n`+
    tables.join('\n')+`\nstatic const struct serve_case serve_cases[]={\n${rows.join(',\n')}\n};\nstatic const unsigned serve_case_count=${rows.length};\n`);
  writeFileSync(resolve(dir,'manifest.json'),'{"type":"solo5.manifest","version":1,"devices":[]}\n');
  const machine=resolve(root,'backends/solo5/pure-call'),remote=resolve(root,'backends/solo5/remote');
  for(const file of ['machine.c','machine.h','format.c'])copyFileSync(resolve(machine,file),resolve(dir,file));
  for(const file of ['wire.c','wire.h','support.c','support.h','serve.c','serve.h','check.c'])copyFileSync(resolve(remote,file),resolve(dir,file));
  const FLAGS=['-O1','-Wall','-Wextra','-Werror',`-DPEER_FUEL=${FUEL}`,'-I.'];
  for(const unit of ['machine','format'])must(tools.cc,['-std=c11',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  for(const unit of ['wire','support','serve','check'])must(tools.cc,['-std=c99',...FLAGS,'-c',unit+'.c','-o',unit+'.o'],{cwd:dir,timeout:600000});
  must(tools.elftool,['gen-manifest','manifest.json','manifest.c'],{cwd:dir});
  must(tools.cc,['-c','manifest.c','-o','manifest.o'],{cwd:dir});
  must(tools.ld,['-z','solo5-abi='+tools.abi,'manifest.o','check.o','serve.o','support.o','wire.o','machine.o','format.o','-o','check.'+tools.abi],{cwd:dir});
  const guest=resolve(dir,'check.'+tools.abi);
  const info={guest,guest_sha256:sha(readFileSync(guest)),tender:tools.tender,abi:tools.abi,tender_sha256:tools.tender_sha256,solo5_commit:SOLO5_COMMIT,
    batch_sha256:lowered.batch_sha256,programs:resolve(dir,'programs.json'),sources:[...PROGRAMS],cases:resolve(dir,'cases.jsonl'),
    count:String(all.length),hand:String(HAND.length),generated:String(all.length-HAND.length),seed:String(SEED),fuel:String(FUEL)};
  writeFileSync(resolve(dir,'batch.json'),JSON.stringify(info)+'\n');
  return info;
}

function main() {
  const args=process.argv.slice(2);
  const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
  const tools=toolchain(resolve(option('--solo5',defaultSolo5())),option('--abi','spt'));
  const out=resolve(option('--out',resolve(root,'build/solo5/peer-requests',`${Date.now()}-${process.pid}`)));
  build(tools,out);
  console.log(out);
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename)main();
