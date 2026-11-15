import {spawnSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdirSync,copyFileSync} from 'node:fs';
import {resolve} from 'node:path';
import assert from 'node:assert/strict';
import {compileArtifact,writeBuild,proofInstance,sha256} from './compile.mjs';
import {fixture} from './fixtures.mjs';
import {encode} from '../tc0/canonical.mjs';
import {PureCallMachine} from '../../runtime/tc0/pure-call-machine.mjs';
const root=resolve(import.meta.dirname,'../..');
// Fresh directory means stale .vo files or reports cannot satisfy this run.
const out=resolve(root,'build/aarch64',`${Date.now()}-${process.pid}`);mkdirSync(out,{recursive:true});
function command(exe,args,{cwd=out,ok=true}={}) {
 const r=spawnSync(exe,args,{cwd,timeout:120000,maxBuffer:16*1024*1024});
 if(r.error||r.signal)throw new Error(`${exe}: ${r.error||r.signal}`);
 if(ok&&r.status!==0)throw new Error(`${exe} ${args.join(' ')}: ${r.stderr}\n${r.stdout}`);
 return r;
}
const versions={};
for(const [tool,args] of [['coqc',['--version']],['coqchk',['--version']],['aarch64-linux-gnu-as',['--version']],['aarch64-linux-gnu-ld',['--version']],['aarch64-linux-gnu-objcopy',['--version']],['qemu-aarch64',['--version']]]) {
 const r=command(tool,args);versions[tool]=r.stdout.toString().split('\n')[0];
}
copyFileSync(resolve(root,'verification/aarch64/Core.v'),resolve(out,'Core.v'));
const flags=['-Q',out,'FenrirARM'];
const audit=[];
function prove(file){const r=command('coqc',[...flags,file]);audit.push(r.stdout.toString());return r;}
prove('Core.v');
const cases=[[],[['add',0]],[['add',1]],[['add',4095]],[['sub',1]],[['sub',4095]],[['neg']],
 [['add',1],['sub',1]],[['sub',1],['add',1]],[['neg'],['neg']],
 [['add',4095],['neg'],['sub',4095]],Array.from({length:12},(_,i)=>[i%2?'sub':'add',i*37])];
const lo=-(1n<<63n),hi=(1n<<63n)-1n;
const inputs=[lo,lo+1n,lo+4094n,lo+4095n,-4096n,-1n,0n,1n,4095n,4096n,(1n<<53n)+1n,hi-4095n,hi-4094n,hi-1n,hi];
// Deterministic full-width samples complement boundary cases; never a proof.
let seed=0xc0ffee1234567890n;for(let i=0;i<32;i++){seed=BigInt.asUintN(64,seed*6364136223846793005n+1442695040888963407n);inputs.push(BigInt.asIntN(64,seed));}
function native(binary,dir) {
 writeFileSync(resolve(dir,'code.bin'),binary);
 const asm=`.global _start
.text
_start:
 adr x19, inputs
 mov x20, #${inputs.length}
 adr x21, outputs
loop:
 ldr x0, [x19], #8
 bl target
 stp x0, x1, [x21], #16
 subs x20, x20, #1
 b.ne loop
 mov x0, #1
 adr x1, outputs
 mov x2, #${inputs.length*16}
 mov x8, #64
 svc #0
 cmp x0, #${inputs.length*16}
 b.ne failed
 mov x0, #0
 b exit
failed:
 mov x0, #1
exit:
 mov x8, #93
 svc #0
.balign 4
target:
.incbin "code.bin"
.data
.balign 8
inputs:
${inputs.map(x=>`.quad ${x}`).join('\n')}
.bss
.balign 8
outputs: .skip ${inputs.length*16}
`;
 writeFileSync(resolve(dir,'runner.s'),asm);
 command('aarch64-linux-gnu-as',['-o','runner.o','runner.s'],{cwd:dir});
 command('aarch64-linux-gnu-ld',['-o','runner','runner.o'],{cwd:dir});
 const r=command('qemu-aarch64',['./runner'],{cwd:dir});
 assert.equal(r.stdout.length,inputs.length*16);
 return inputs.map((_,i)=>{const n=r.stdout.readBigInt64LE(i*16),tag=r.stdout.readBigUInt64LE(i*16+8);
  if(tag===0n)return ['Ok',['int',String(n)]];if(tag===1n)return ['Trap','Overflow'];return ['InvalidStatus',String(tag)];});
}
let nativeCases=0;const receipts=[];
for(const [i,ops] of cases.entries()){
 const dir=resolve(out,`case${i}`);mkdirSync(dir);
 const artifact=fixture(ops),result=compileArtifact(encode(artifact));writeBuild(result,dir);
 writeFileSync(resolve(dir,'artifact.json'),encode(artifact));
 const module=`Case${i}`;writeFileSync(resolve(out,`${module}.v`),proofInstance(result));prove(`${module}.v`);
 // Independent GNU assembler check of the encoder's output.
 const assembly=ops.map(([op,k])=>`${op==='neg'?'negs x0, x0':`${op==='add'?'adds':'subs'} x0, x0, #${k}`}\nb.vc 1f\nmov x1, #1\nret\n1:`).join('\n')+'\nmov x1, #0\nret\n';
 writeFileSync(resolve(dir,'reference.s'),assembly);command('aarch64-linux-gnu-as',['-o','reference.o','reference.s'],{cwd:dir});
 command('aarch64-linux-gnu-objcopy',['-O','binary','-j','.text','reference.o','reference.bin'],{cwd:dir});
 assert.deepEqual(readFileSync(resolve(dir,'reference.bin')),result.binary);
 const observed=native(result.binary,dir);
 const expected=inputs.map(x=>{const r=new PureCallMachine(artifact,['int',String(x)]).run(2000);assert.equal(r.execution,'Completed');return r.outcome;});
 assert.deepEqual(observed,expected);nativeCases+=inputs.length;
 receipts.push({...result.manifest,module});
 console.log(`${module}: universal model proof, byte check, ${inputs.length} QEMU comparisons passed`);
}
// Exact-image proof rejection plus execution divergence for distinct mutations.
const good=compileArtifact(encode(fixture([['add',1],['sub',1]])));
const mutations=[['immediate',0,0xb1000800],['branch-condition',4,0x54000066],['success-status',32,0xd2800041]];
for(const [name,offset,word] of mutations){
 const binary=Buffer.from(good.binary);binary.writeUInt32LE(word,offset);
 const dir=resolve(out,`mutant-${name}`);mkdirSync(dir);
 writeFileSync(resolve(out,'Mutant.v'),proofInstance({...good,binary}));
 const r=command('coqc',[...flags,'Mutant.v'],{ok:false});
 assert.notEqual(r.status,0,'mutated bytes unexpectedly proved');
 assert.match(r.stderr.toString(),/Unable to unify/,'must fail the identity proof, not infrastructure');
 const expected=inputs.map(x=>new PureCallMachine(good.artifact,['int',String(x)]).run(2000).outcome);
 assert.notDeepEqual(native(binary,dir),expected,'mutant survived runtime controls');
}
const checked=command('coqchk',[...flags,'FenrirARM.Core',...receipts.map(r=>`FenrirARM.${r.module}`)]);
writeFileSync(resolve(out,'coqchk.log'),checked.stdout.toString()+checked.stderr.toString());
assert(audit.every(log=>log.includes('Closed under the global context')),'missing axiom audit');
assert(!audit.some(log=>/Axioms:/.test(log)),'unexpected theorem assumptions');
writeFileSync(resolve(out,'assumptions.log'),audit.join('\n'));
const sourceFiles=['verification/aarch64/Core.v','tools/aarch64/compile.mjs','tools/aarch64/check.mjs',
 'tools/aarch64/fixtures.mjs','tools/tc0/canonical.mjs','tools/tc0/pure-call-artifact.mjs','runtime/tc0/pure-call-machine.mjs'];
const sourceInventory=Object.fromEntries(sourceFiles.map(p=>[p,sha256(readFileSync(resolve(root,p)))]));
const report={node:process.version,sourceInventory,profile:'fenrir-aarch64-checked-unary/1',status:'development-pass',versions,nativeCases,proofInstances:receipts.length,
 rejectedMutations:mutations.map(x=>x[0]),core_sha256:sha256(readFileSync(resolve(out,'Core.v'))),receipts,
 claims:{universal_handwritten_model_proof:true,exact_byte_identity:true,coqchk_replay:true,
 authoritative_ARM_refinement:false,full_TC0:false,whole_process:false,Shen_oracle_run:false}};
writeFileSync(resolve(out,'report.json'),JSON.stringify(report,null,2)+'\n');
console.log(`PASS: ${nativeCases} native comparisons; ${receipts.length} proof instances; ${mutations.length} rejected mutants.\n${out}/report.json`);
