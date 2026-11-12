// Build the Yggdrasil-shaken pure-call oracle, development tier, NOT qualification.
// Shakes models/tc0/pure-call-oracle.shen (with its loaded model files) to an
// eval-free KLambda slice, compiles it to an SBCL executable, and admits it only
// if its observations are identical to the host Shen running the same driver on
// every hand case. The stamp binds the artifact to the exact model sources, so a
// model edit makes it stale and the checkers refuse it until it is rebuilt.
//
// Usage: node tools/tc0/build-shaken-oracle.mjs --yggdrasil CLI --shen-cl DIR [--uncompressed]
//   CLI      a built pyrex41/yggdrasil command
//   DIR      a built shen-cl checkout (bin/sbcl/shen): stage-1 host and lisp builder
//   sbcl must be on PATH (e.g. nix shell nixpkgs#sbcl -c node ...).
//   Parity uses the host Shen at build/toolchain/shen-scheme.
// Exit 0 = built and admitted, 1 = build or parity failed, 2 = prerequisite missing.
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync,readFileSync,writeFileSync,rmSync,renameSync,mkdirSync,realpathSync} from 'node:fs';
import {dirname,relative,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const sources=['models/tc0/arithmetic.shen','models/tc0/pure-call-machine.shen','models/tc0/pure-call-oracle.shen'];
const out=resolve(root,'build/toolchain/tc0-pure-call-oracle');
const tmp=resolve(root,`build/toolchain/.tc0-pure-call-oracle.${process.pid}`);
const parityDir=resolve(root,'build/tc0/shaken-oracle');
const digest=p=>createHash('sha256').update(readFileSync(p)).digest('hex');

function blocked(m){console.error('BLOCKED: '+m);process.exit(2);}
function fail(m){console.error('FAIL: '+m);rmSync(tmp,{recursive:true,force:true});process.exit(1);}
function arg(name){const i=process.argv.indexOf(name);return i>0?process.argv[i+1]:undefined;}
function run(argv,opts={}){
  const r=spawnSync(argv[0],argv.slice(1),{cwd:root,encoding:'utf8',maxBuffer:64<<20,timeout:600000,...opts});
  if(r.error?.code==='ENOENT')blocked(`${argv[0]} not found`);
  return r;
}

const cliArg=arg('--yggdrasil'),shenClArg=arg('--shen-cl');
if(!cliArg||!shenClArg)blocked('usage: --yggdrasil CLI --shen-cl DIR');
if(!existsSync(cliArg))blocked(`no yggdrasil CLI at ${cliArg}`);
const cli=realpathSync(cliArg),shenCl=realpathSync(shenClArg),host=resolve(shenCl,'bin/sbcl/shen');
if(!existsSync(host))blocked(`no built shen-cl at ${host}`);
if(run(['sbcl','--version']).status!==0)blocked('sbcl is not on PATH');
const paritySh=resolve(root,'build/toolchain/shen-scheme');
if(!existsSync(paritySh))blocked(`no host Shen at ${paritySh} for parity`);

rmSync(tmp,{recursive:true,force:true});
// The stage-1 host compiles each source to a .kl beside it; remove only those it creates.
const strayKl=sources.map(p=>resolve(root,p).replace(/\.shen$/,'.kl')).filter(p=>!existsSync(p));
process.on('exit',()=>{for(const p of strayKl)rmSync(p,{force:true});});
const env={...process.env,YGGDRASIL_HOST:host,YGGDRASIL_SHEN_CL_DIR:shenCl,LISP_IMPL:'sbcl'};
const built=run([cli,'build',resolve(root,'models/tc0/pure-call-oracle.shen'),tmp,'--target','lisp'],{env});
if(built.status!==0)fail('yggdrasil build exited '+built.status+'\n'+built.stderr.slice(-2000));
const manifestPath=resolve(tmp,'yggdrasil.manifest.txt'),app=resolve(tmp,'app-lisp');
if(!existsSync(manifestPath)||!existsSync(app))fail('build produced no manifest or app-lisp');
// The nixpkgs SBCL core alone is ~120 MB, and every check SHA-256s the artifact
// several times. Re-save the staged image compressed (~12 MB): ~0.3 s slower to
// start, far cheaper to hash. Yggdrasil's lisp builder has no compression switch,
// so patch its generated driver, and refuse rather than guess if it changed shape.
let compressed=false;
if(!process.argv.includes('--uncompressed')){
  const save="  :save-runtime-options t\n  :toplevel #'yggdrasil-toplevel)";
  const driver=readFileSync(resolve(tmp,'driver.lsp'),'utf8');
  if(driver.split(save).length!==2)fail('unexpected Yggdrasil lisp driver; rebuild with --uncompressed or update this script');
  writeFileSync(resolve(tmp,'driver-compressed.lsp'),driver.replace(save,"  :save-runtime-options t\n  :compression t\n  :toplevel #'yggdrasil-toplevel)"));
  const r=run(['sbcl','--non-interactive','--no-userinit','--no-sysinit','--load','driver-compressed.lsp'],{cwd:tmp});
  if(r.status!==0)fail('compressed re-save failed\n'+r.stderr.slice(-2000));
  compressed=true;
}
const manifest=readFileSync(manifestPath,'utf8');
for(const line of ['needs-eval=false','cannot-reach=eval','read-data=true'])
  if(!manifest.split('\n').includes(line))fail(`manifest lacks ${line}; the oracle must stay eval-free`);

const gitHead=dir=>{const r=run(['git','-C',dir,'rev-parse','HEAD']);return r.status===0?r.stdout.trim():null;};
const stamp={
  schema:'fenrir.shaken-oracle.v1',
  sources:Object.fromEntries(sources.map(p=>[p,digest(resolve(root,p))])),
  artifact_sha256:digest(app),manifest_sha256:digest(manifestPath),
  manifest_facts:Object.fromEntries(manifest.split('\n').filter(l=>/^(kernel-version|needs-eval|cannot-reach|read-data|init-order|computed-names)=/.test(l)).map(l=>l.split(/=(.*)/s).slice(0,2))),
  compressed,
  toolchain:{yggdrasil_cli_sha256:digest(cli),shen_cl_commit:gitHead(shenCl),shen_cl_host_sha256:digest(host),sbcl:run(['sbcl','--version']).stdout.trim()},
};
writeFileSync(resolve(tmp,'oracle-stamp.json'),JSON.stringify(stamp,null,2)+'\n');

// Parity: same driver, host Shen vs shaken artifact, every hand case, raw observations.
mkdirSync(parityDir,{recursive:true});
const reports={};
for(const [kind,flag,value] of [['host','--shen-executable',paritySh],['artifact','--oracle-artifact',tmp]]){
  const path=resolve(parityDir,`parity-${kind}.json`);rmSync(path,{force:true});
  const r=run(['python3','-I',resolve(root,'tools/check-tc0-pure-call.py'),flag,value,'--output',path]);
  if(r.status!==0)fail(`${kind} oracle run failed\n`+r.stderr.slice(-2000));
  reports[kind]=JSON.parse(readFileSync(path,'utf8'));
}
const observed=c=>c.shen_stdout.split('\n').filter(l=>/^(\[sample |\[closure |terminal$)/.test(l));
const [a,b]=[reports.host.cases,reports.artifact.cases];
if(a.length!==b.length||!a.length)fail('parity case count mismatch');
for(let i=0;i<a.length;i++){
  if(a[i].name!==b[i].name||JSON.stringify(observed(a[i]))!==JSON.stringify(observed(b[i]))||JSON.stringify(a[i].model_steps)!==JSON.stringify(b[i].model_steps))
    fail(`parity mismatch on ${a[i].name}`);
}
stamp.parity={host:realpathSync(paritySh),cases:a.map(c=>c.name),identical:true};
writeFileSync(resolve(tmp,'oracle-stamp.json'),JSON.stringify(stamp,null,2)+'\n');
// The artifact report's stamp hash is now stale; it served parity only.

rmSync(out,{recursive:true,force:true});renameSync(tmp,out);
console.log(JSON.stringify({qualification:'UNKNOWN',artifact:relative(root,out),parity_cases:a.length,
  manifest:stamp.manifest_facts}));
