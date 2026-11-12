#!/usr/bin/env node
// Owner-reviewed, registered TC0-A gate evaluator (02 §14 TC0-GATE).
// Port of the former tools/check-tc0-a-gate.py: same rows, acceptance rules,
// verdict precedence and report schema.
//
// Runs trusted-local under the G1 scope and waivers recorded in
// campaigns/tc0/G1_EVALUATOR_REVIEW.md; registration does not establish isolation.
//
// Runs every row of spec/tc0/tc0-a-requirements.json freshly against the current
// committed source, into a new run directory under build/tc0/gate/, and aggregates:
// any required FAIL -> FAIL; else any BLOCKED -> BLOCKED; else any UNKNOWN -> UNKNOWN;
// else PASS. All row reasons are reported whatever the aggregate.
//
// The manifest also maps the workflow controller's six required claims to rows: a
// claim is credited only when every row it names, and every claim prerequisite, PASS.
//
// Authority: the verdict is a qualification verdict only when the manifest is
// owner-reviewed AND .pi/fenrir-workflow.json registers this script as
// `tc0-a-qualification`; otherwise `qualification` stays UNKNOWN. Waivers (such as
// accepted instruction-only repairer isolation) are listed in every report.
//
// Under the workflow controller (FENRIR_CHECK_NONCE set) stdout carries exactly one
// fenrir.check.v1 report; logs go to stderr. Exit: PASS 0, FAIL 1, UNKNOWN/BLOCKED 2.
//
// Child checkers and tools run under this process's own Node (process.execPath),
// where the Python evaluator used its own interpreter and the node on PATH.
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {accessSync, constants, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync, unlinkSync, writeFileSync} from 'node:fs';
import {constants as osConstants} from 'node:os';
import {basename, delimiter, dirname, relative, resolve} from 'node:path';

const ROOT=resolve(import.meta.dirname,'..');
const SELF='tools/check-tc0-a-gate.mjs';
const NODE=process.execPath;
const at=p=>resolve(ROOT,p);
const now=()=>performance.now()/1000;
const round2=x=>Math.round(x*100)/100;

class Row {
  constructor(status,reasons=[],detail={}) {this.status=status;this.reasons=[...reasons];this.detail=detail;}
}

// Fail-closed field access: a missing field in a child report is an evaluator
// error (the row becomes UNKNOWN), never an `undefined` that reads as agreement.
function field(object,key) {
  if(object===null||typeof object!=='object'||!Object.hasOwn(object,key))throw new Error(`missing field ${JSON.stringify(key)}`);
  return object[key];
}
const isRecord=v=>v!==null&&typeof v==='object'&&!Array.isArray(v);
// Empty reports, lists and strings do not count as present.
const present=v=>!(v===null||v===undefined||v===false||v===0||v===''||(Array.isArray(v)&&v.length===0)||(isRecord(v)&&Object.keys(v).length===0));
const number=v=>{if(typeof v!=='number')throw new Error('expected a number');return v;};
const list=v=>{if(!Array.isArray(v))throw new Error('expected a list');return v;};
const quoted=v=>typeof v==='string'?`'${v}'`:String(v);

function which(name) {
  for(const dir of (process.env.PATH||'').split(delimiter)) {
    if(!dir)continue;
    const candidate=resolve(dir,name);
    try {accessSync(candidate,constants.X_OK);if(statSync(candidate).isFile())return candidate;} catch {}
  }
  return null;
}

// Resolve symlinks as far as the path exists.
function realpathLoose(path) {
  try {return realpathSync(path);} catch {
    const parent=dirname(path);
    return parent===path?path:resolve(realpathLoose(parent),basename(path));
  }
}

// Returns {code, out, err, secs}. A watchdog timeout gives code null. A child
// killed by a signal gives the negated signal number. Failure to start throws.
function run(argv,{timeout=900,cwd=ROOT,input}={}) {
  const started=now();
  const r=spawnSync(String(argv[0]),argv.slice(1).map(String),{cwd,encoding:'utf8',timeout:timeout*1000,killSignal:'SIGKILL',
    detached:true,maxBuffer:1024*1024*1024,input,stdio:[input===undefined?'ignore':'pipe','pipe','pipe']});
  const secs=round2(now()-started);
  if(r.error&&r.error.code==='ETIMEDOUT')return {code:null,out:'',err:'evaluator watchdog',secs};
  if(r.error)throw r.error;
  const code=r.status===null?-(osConstants.signals[r.signal]??1):r.status;
  return {code,out:r.stdout,err:r.stderr,secs};
}
const git=(...args)=>spawnSync('git',args,{cwd:ROOT,encoding:'utf8'}).stdout?.trim()??'';

const lines=text=>text.trim().split(/\r\n|\r|\n/);
function lastJson(text) {
  for(const line of lines(text).reverse()) {
    try {return JSON.parse(line);} catch {}
  }
  return null;
}
// The last stderr line names the failure. A Node child that dies on an uncaught
// error ends its stderr with the stack and a "Node.js vX" trailer, so there the
// error line itself is reported (reason text only; no status depends on it).
function lastLine(err,code) {
  if(!err.trim())return `exit ${code}`;
  const all=lines(err),last=all.at(-1);
  if(/^Node\.js v\d/.test(last)) {
    const thrown=all.findLast(l=>/^(?:Uncaught )?[A-Za-z]*Error(?: \[[^\]]*\])?: /.test(l));
    if(thrown)return thrown;
  }
  return last;
}

class Gate {
  constructor(out,shen) {
    this.out=out;this.shen=shen;this.node=NODE;
    this.memo={};this.waivers=[];this.head=undefined;
  }
  path(name) {return resolve(this.out,name);}

  needShen() {
    return this.shen&&existsSync(this.shen)?null:new Row('BLOCKED',['No Shen executable at build/toolchain/shen-scheme']);
  }

  sourceIdentity() {
    const dirty=git('status','--porcelain'),head=git('rev-parse','HEAD');
    this.head=head;
    if(dirty)return new Row('UNKNOWN',['Worktree has uncommitted changes; evidence would not be source-bound'],{head});
    return new Row('PASS',[],{head});
  }

  toolchainPinned() {
    if(!which('nix'))return new Row('BLOCKED',['nix unavailable; cannot resolve the pinned toolchain']);
    const {code,out,err,secs}=run(['nix','build','--no-link','--print-out-paths','.#shen-scheme'],{timeout:1800});
    if(code!==0)return new Row('BLOCKED',['nix build .#shen-scheme failed: '+err.slice(-300)]);
    if(!out.trim())throw new Error('nix build printed no output path');
    const pinned=lines(out).at(-1)+'/bin/shen-scheme';
    const actual=realpathLoose(at('build/toolchain/shen-scheme'));
    if(actual!==pinned)return new Row('UNKNOWN',[`build/toolchain/shen-scheme is ${actual}, not the pinned ${pinned}`]);
    return new Row('PASS',[],{shen:pinned,seconds:secs});
  }

  unitSuite() {
    const tests=readdirSync(at('tests/tc0')).filter(n=>n.endsWith('.test.mjs')).map(n=>'tests/tc0/'+n).sort();
    const {code,out,secs}=run([this.node,'--test',...tests]);
    const count=(pattern,missing)=>(out.match(pattern)||[0,missing])[1];
    const fails=Number(count(/^# fail (\d+)/m,'1')),skips=Number(count(/^# skipped (\d+)/m,'0'));
    if(fails||(code!==0&&code!==null&&!fails))return new Row('FAIL',[fails?`${fails} failing tests`:`test runner exit ${code}`],{seconds:secs});
    if(code===null)return new Row('UNKNOWN',['Test runner timed out']);
    if(skips)return new Row('UNKNOWN',[`${skips} skipped tests are missing evidence`],{seconds:secs});
    return new Row('PASS',[],{tests:String(tests.length),passed:count(/^# pass (\d+)/m,'?'),seconds:secs});
  }

  handAgreementAndReplay() {
    const blocked=this.needShen();if(blocked)return blocked;
    const hand=this.path('hand.json');
    const {code,out,err,secs}=run([this.node,at('tools/check-tc0-pure-call.mjs'),'--shen-executable',this.shen,'--sandbox','--output',hand]);
    if(code!==0) {
      const disagreement=err.includes('disagreement')||err.includes('mismatch');
      return new Row(disagreement?'FAIL':'UNKNOWN',[lastLine(err,code)]);
    }
    this.memo.hand=hand;
    const replay=run([this.node,at('tools/tc0/check-pure-call-replay.mjs'),hand,this.path('hand-replay.json')]);
    if(replay.code!==0)return new Row(replay.err.includes('disagreement')?'FAIL':'UNKNOWN',[lastLine(replay.err,replay.code)]);
    const summary=lastJson(out);
    return new Row('PASS',[],{cases:String(isRecord(summary)?summary.independent_case_agreement??'None':'None'),seconds:round2(secs+replay.secs)});
  }

  exactArithmetic(shaken=false) {
    const blocked=this.needShen();if(blocked)return blocked;
    const oracle=shaken?['--oracle-artifact',at('build/toolchain/tc0-pure-call-oracle')]:['--shen-executable',this.shen];
    const {code,out,err,secs}=run([this.node,at('tools/check-tc0-exact-arithmetic.mjs'),...oracle,'--output',this.path(shaken?'arith-shaken.json':'arith.json')]);
    const summary=lastJson(out);
    if(code===0&&present(summary))return new Row('PASS',[],{cases:String(field(summary,'cases')),seconds:secs});
    if(code===1&&present(summary))
      return new Row('FAIL',list(field(summary,'ledger')).filter(l=>field(l,'failure_count')!=='0').map(l=>`${field(l,'port')}: ${field(l,'failure_count')} inexact`));
    return new Row('UNKNOWN',[lastLine(err,code)]);
  }

  exactArithmeticShaken() {
    const row=this.exactArithmetic(true);
    return row.status!=='UNKNOWN'?row:new Row('DEFERRED',['Optional second port unavailable or stale: '+row.reasons.join('; ')]);
  }

  exhaustiveSmall() {
    const blocked=this.needShen();if(blocked)return blocked;
    const report=this.path('exhaustive-5.json');
    const {code,err,secs}=run([this.node,at('tools/check-tc0-pure-data-exhaustive.mjs'),'--shen-executable',this.shen,'--sandbox','--max-nodes','5','--output',report]);
    if(!existsSync(report))return new Row('UNKNOWN',[lastLine(err,code)]);
    const r=JSON.parse(readFileSync(report,'utf8'));
    this.memo.exhaustive=r;
    this.memo.exhaustivePath=report;
    const disagreements=field(r,'disagreements');
    if(present(disagreements))return new Row('FAIL',[`${list(disagreements).length} programs disagree with Shen, first ${field(disagreements[0],'name')}`]);
    return new Row('PASS',[],{programs:field(field(r,'enumeration'),'count'),seconds:secs});
  }

  mutant(name) {
    const r=this.memo.exhaustive;
    if(!present(r))return new Row('UNKNOWN',['No exhaustive report in this run']);
    const s=field(field(r,'mutants'),name);
    const killed=number(field(s,'killed')),survived=field(s,'survived'),crashed=field(s,'crashed');
    if(killed>0)return new Row('PASS',[],{killed:String(killed),survived:String(survived),crashed:String(crashed)});
    return new Row('FAIL',[`Mutant ${name} survived every program (${crashed} crashes are not kills)`]);
  }

  catalogCoverage() {
    if(!('hand' in this.memo)||!('exhaustivePath' in this.memo))return new Row('UNKNOWN',['Needs this run\'s hand and exhaustive reports']);
    const {code,out,err}=run([this.node,at('tools/tc0/check-pure-call-coverage.mjs'),this.memo.hand,this.memo.exhaustivePath,this.path('coverage.json')]);
    const s=lastJson(out);
    if(code!==0||!present(s))return new Row('UNKNOWN',[lastLine(err,code)]);
    const unknown=field(s,'unknown_observed'),missing=field(s,'missing');
    if(present(unknown))return new Row('FAIL',['Steps outside the catalog: '+list(unknown).slice(0,5).join(', ')]);
    if(present(missing))return new Row('UNKNOWN',[`${list(missing).length} catalog transitions uncovered: `+missing.slice(0,5).join(', ')]);
    return new Row('PASS',[],{covered:`${field(s,'covered')}/${field(s,'catalog_keys')}`});
  }

  discoveryReductionReplay() {
    const blocked=this.needShen();if(blocked)return blocked;
    const detail={},reasons=[];let status='PASS';
    for(const mutant of ['arm-by-position','reverse-operands']) {
      const report=this.path(`s2-${mutant}.json`);
      const {code,out,err,secs}=run([this.node,at('tools/check-tc0-pure-call-reduction.mjs'),'--shen-executable',this.shen,'--family','pure-data',
        '--mutant',mutant,'--max-cases','24','--wall-seconds','300','--output',report]);
      if(code!==0) {
        reasons.push(`${mutant}: `+lastLine(err,code));
        status=err.includes('No expected discrepancy discovered')||err.includes('disagreement')?'FAIL':(status==='PASS'?'UNKNOWN':status);
        continue;
      }
      const s=lastJson(out);
      const replay=run([this.node,at('tools/tc0/check-pure-call-failure-replay.mjs'),report,this.path(`s2-${mutant}-replay.json`)]);
      if(replay.code!==0) {
        reasons.push(`${mutant} replay: `+lastLine(replay.err,replay.code));
        status='FAIL';
        continue;
      }
      detail[mutant]={discovered_index:field(s,'discovered_index'),
        nodes:`${field(field(s,'original_metric'),'nodes')}->${field(field(s,'minimized_metric'),'nodes')}`,seconds:secs};
      if(mutant==='arm-by-position')this.memo.s2Arm=report;
    }
    return new Row(status,reasons,detail);
  }

  candidateBoundary() {
    const {code,out,err,secs}=run([this.node,at('tools/tc0/check-sandbox.mjs'),this.path('sandbox.json')]);
    if(code===2)return new Row('BLOCKED',[err.trim()]);
    if(code===0)return new Row('PASS',[],{seconds:secs});
    const s=lastJson(out);
    if(!present(s))return new Row('FAIL',[`exit ${code}`]);
    const rows=isRecord(s)&&Object.hasOwn(s,'rows')?list(s.rows):[];
    return new Row('FAIL',[`probes not enforced: [${rows.filter(r=>!present(r[1])).map(r=>quoted(r[0])).join(', ')}]`]);
  }

  requirementLedger() {
    const {code,out}=run([this.node,at('tools/tc0/check-requirement-ledger.mjs')]);
    const s=lastJson(out);
    if(code===0)return new Row('PASS',[],{summary:field(s,'summary')});
    return new Row('FAIL',isRecord(s)&&Object.hasOwn(s,'problems')?list(s.problems):[`exit ${code}`]);
  }

  independentRepairFresh() {
    const blocked=this.needShen();if(blocked)return blocked;
    if(!('s2Arm' in this.memo))return new Row('UNKNOWN',['Needs this run\'s arm-by-position reduction report']);
    const s3=this.path('s3');
    const prepared=run([this.node,at('tools/tc0/s3-prepare.mjs'),this.memo.s2Arm,s3]);
    if(prepared.code!==0)return new Row('UNKNOWN',['Packet preparation failed: '+lastLine(prepared.err,prepared.code)]);
    const repair=resolve(s3,'repair');
    if(existsSync(repair))throw new Error('Repair directory already exists: '+repair);
    cpSync(resolve(s3,'workspace'),repair,{recursive:true,dereference:true,errorOnExist:true,force:false});
    const patch=readFileSync(at('campaigns/tc0/s3/independent-repair-1.patch'),'utf8');
    const applied=spawnSync('patch',['-p1','--forward','--batch','-d',repair],{input:patch,encoding:'utf8'});
    if(applied.error)throw applied.error;
    if(applied.status!==0)return new Row('UNKNOWN',['Retained independent patch no longer applies to this source; repair evidence is stale']);
    for(const entry of readdirSync(repair,{recursive:true,withFileTypes:true}))
      if(entry.name.endsWith('.orig'))unlinkSync(resolve(entry.parentPath,entry.name));
    const {code,out,err,secs}=run([this.node,at('tools/check-tc0-s3-repair.mjs'),'--packet',resolve(s3,'packet'),'--workspace',repair,
      '--shen-executable',this.shen,'--output',this.path('s3-evaluation.json')]);
    const s=lastJson(out);
    if(present(s)&&!isRecord(s))throw new Error('S3 evaluator summary is not an object');
    if(present(s)&&s.verdict==='DEVELOPMENT-PASS')return new Row('PASS',[],{steps:field(s,'steps'),seconds:secs});
    if(present(s))return new Row('FAIL',['S3 evaluator: '+Object.entries(field(s,'steps')).filter(([,v])=>v!=='PASS').map(([k])=>k).join(', ')]);
    return new Row('UNKNOWN',[lastLine(err,code)]);
  }

  repairIsolation(path) {
    const p=at(path);
    if(!existsSync(p))return new Row('UNKNOWN',[`No isolation record at ${path}`]);
    const a=JSON.parse(readFileSync(p,'utf8'));
    if(!isRecord(a))throw new Error('Isolation record is not an object');
    const patch=at(typeof a.patch==='string'?a.patch:'');
    const isFile=existsSync(patch)&&statSync(patch).isFile();
    if(!isFile||createHash('sha256').update(readFileSync(patch)).digest('hex')!==a.patch_sha256)
      return new Row('UNKNOWN',[`${path} does not match the retained patch`]);
    if(!present(a.accepted_by))return new Row('UNKNOWN',[`${path} names no reviewer`]);
    if(a.isolation==='enforced')return new Row('PASS',[],{isolation:'enforced',accepted_by:a.accepted_by});
    if(a.isolation==='instruction-only'&&a.decision==='owner-waiver') {
      const waiver=`Repair isolation: instruction-only accepted by ${a.accepted_by} on ${a.accepted_on??'None'}; revisit: ${a.revisit??'None'}`;
      this.waivers.push(waiver);
      return new Row('PASS',[],{isolation:'instruction-only',waiver});
    }
    return new Row('UNKNOWN',[`${path} records neither enforced isolation nor an owner waiver`]);
  }

  check(name) {
    if(name.startsWith('mutant:'))return this.mutant(name.slice('mutant:'.length));
    if(name.startsWith('repair-isolation:'))return this.repairIsolation(name.slice('repair-isolation:'.length));
    const checks={source_identity:()=>this.sourceIdentity(),toolchain_pinned:()=>this.toolchainPinned(),unit_suite:()=>this.unitSuite(),
      hand_agreement_and_replay:()=>this.handAgreementAndReplay(),exact_arithmetic:()=>this.exactArithmetic(),
      exact_arithmetic_shaken:()=>this.exactArithmeticShaken(),exhaustive_small:()=>this.exhaustiveSmall(),
      catalog_coverage:()=>this.catalogCoverage(),discovery_reduction_replay:()=>this.discoveryReductionReplay(),
      candidate_boundary:()=>this.candidateBoundary(),requirement_ledger:()=>this.requirementLedger(),
      independent_repair_fresh:()=>this.independentRepairFresh()};
    const key=name.replaceAll('-','_');
    if(!Object.hasOwn(checks,key))throw new Error(`No check named ${name}`);
    return checks[key]();
  }
}

function parseArgs(argv) {
  let manifest=at('spec/tc0/tc0-a-requirements.json');
  for(let i=0;i<argv.length;i++) {
    if(argv[i]==='--manifest'&&i+1<argv.length)manifest=argv[++i];
    else if(argv[i].startsWith('--manifest='))manifest=argv[i].slice('--manifest='.length);
    else {console.error('usage: check-tc0-a-gate.mjs [--manifest MANIFEST]');process.exit(2);}
  }
  return {manifest};
}

function main() {
  const args=parseArgs(process.argv.slice(2));
  const manifestPath=resolve(args.manifest);
  const manifest=JSON.parse(readFileSync(manifestPath,'utf8'));
  const ledger=new Set(JSON.parse(readFileSync(at(field(manifest,'ledger')),'utf8')).rows.map(r=>field(r,'id')));
  const unknownRefs=[...new Set(field(manifest,'rows').flatMap(r=>field(r,'ledger')).filter(l=>!ledger.has(l)))].sort();
  if(field(manifest,'schema')!=='tc0-a-requirement-manifest/1'||unknownRefs.length) {
    console.error('Manifest invalid; unknown ledger rows: '+unknownRefs.join(', '));
    process.exit(1);
  }
  const stamp=new Date().toISOString().replace(/[-:]/g,'').replace(/\.\d+Z$/,'Z');
  const out=at(`build/tc0/gate/${git('rev-parse','--short=12','HEAD')}-${stamp}`);
  mkdirSync(dirname(out),{recursive:true});
  mkdirSync(out);
  const shen=at('build/toolchain/shen-scheme');
  const gate=new Gate(out,existsSync(shen)?shen:null);
  const rows=[],started=now();
  for(const spec of manifest.rows) {
    const t=now();let row;
    try {
      row=gate.check(field(spec,'check'));
    } catch(e) { // evaluator fault: never a pass
      row=new Row('UNKNOWN',[`Evaluator error: ${e?.name??'Error'}: ${e?.message??e}`]);
    }
    rows.push({id:field(spec,'id'),required:field(spec,'required'),status:row.status,reasons:row.reasons,detail:row.detail,seconds:round2(now()-t)});
    console.error(`${spec.id}: ${row.status}${row.reasons.length?' - '+row.reasons.join('; '):''}`);
  }
  const required=rows.filter(r=>present(r.required));
  let verdict=['FAIL','BLOCKED','UNKNOWN'].find(s=>required.some(r=>r.status===s))??'PASS';
  // Deliberate fix over the Python evaluator (owner-reviewed PR #6): read HEAD
  // directly and compare it with the head recorded when the source-identity row
  // ran. The Python called source_identity() here, which overwrote the recorded
  // head first and so compared HEAD with itself. If the source-identity row never
  // ran there is no recorded head, and the result is UNKNOWN.
  const headNow=git('rev-parse','HEAD');
  if(headNow!==gate.head||git('status','--porcelain')) {
    verdict=verdict==='PASS'?'UNKNOWN':verdict;
    rows.push({id:'source-drift',required:true,status:'UNKNOWN',reasons:['Source changed during evaluation'],detail:{},seconds:0});
  }
  const status=Object.fromEntries(rows.map(r=>[r.id,r.status]));
  const prerequisites=field(manifest,'claim_prerequisites');
  const claims=Object.entries(field(manifest,'claims')).filter(([,ids])=>[...ids,...prerequisites].every(i=>status[i]==='PASS')).map(([c])=>c).sort();
  const config=JSON.parse(readFileSync(at('.pi/fenrir-workflow.json'),'utf8'));
  const command=config.checks?.['tc0-a-qualification']?.command??[];
  const registered=manifest.status==='owner-reviewed'&&Array.isArray(command)&&command.includes(SELF);
  const report={schema:'tc0-a-gate-run/2',authority:registered?'owner-reviewed, registered':'UNREGISTERED',
    qualification:registered?verdict:'UNKNOWN',verdict,claims,waivers:gate.waivers,
    head:gate.head??null,manifest:relative(ROOT,manifestPath),evaluator:SELF,
    aggregation:field(manifest,'aggregation'),seconds:round2(now()-started),rows};
  writeFileSync(resolve(out,'gate.json'),JSON.stringify(report,null,1)+'\n');
  const evidence=['gate.json','hand.json','hand-replay.json','arith.json','exhaustive-5.json','coverage.json',
    's2-arm-by-position.json','s2-arm-by-position-replay.json','s2-reverse-operands.json','s2-reverse-operands-replay.json',
    'sandbox.json','s3-evaluation.json'].map(n=>resolve(out,n)).filter(p=>existsSync(p)&&statSync(p).isFile()).map(p=>relative(ROOT,p));
  const summary=(`TC0-A gate at ${report.head===null?'None':report.head}: ${verdict}; ${required.filter(r=>r.status==='PASS').length}/${required.length} required rows PASS; `+
    `claims ${claims.join(', ')||'none'}`+(gate.waivers.length?`; waivers: ${gate.waivers.join(' | ')}`:'')+
    rows.filter(r=>r.status!=='PASS'&&present(r.required)).map(r=>`; ${r.id}: ${r.status} (${r.reasons.join('; ')})`).join('')).slice(0,7900);
  if(process.env.FENRIR_CHECK_NONCE) {
    console.log(JSON.stringify({schema:'fenrir.check.v1',nonce:process.env.FENRIR_CHECK_NONCE,checkId:process.env.FENRIR_CHECK_ID??null,
      sourceHash:process.env.FENRIR_SOURCE_SHA256??null,configHash:process.env.FENRIR_CONFIG_SHA256??null,
      verdict:registered?verdict:'UNKNOWN',cleanup:'confirmed',claims:registered?claims:[],evidence,summary}));
  } else {
    console.log(JSON.stringify({authority:report.authority,qualification:report.qualification,verdict,claims,
      waivers:gate.waivers,rows:status,report:resolve(out,'gate.json')}));
  }
  process.exitCode={PASS:0,FAIL:1}[verdict]??2;
}

main();
