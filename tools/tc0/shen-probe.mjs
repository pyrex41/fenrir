// Shared transport for the TC0 development checkers: process running, Shen
// term translation, Shen output parsing and normalization, and the batch
// oracle wrapper. Transport and normalization only: no transition logic and no
// verdicts live here. Replaces the library halves of the former
// tools/check-tc0-expression.py and tools/check-tc0-pure-call.py.
import {spawnSync} from 'node:child_process';
import {existsSync, readFileSync, realpathSync} from 'node:fs';
import {resolve, relative, isAbsolute, extname} from 'node:path';
import {digest} from './digest-cache.mjs';

export {digest};
export const ROOT=resolve(import.meta.dirname,'../..');
export const REFERENCE_STEPS=200;
export const MODEL_FILES=['models/tc0/arithmetic.shen','models/tc0/pure-call-machine.shen','models/tc0/pure-call-oracle.shen'].map(p=>resolve(ROOT,p));

// Run one process to completion. Nonzero exit, a signal or a timeout throws.
// timeout is in seconds, as in the former Python helper.
export function synchronous(argv,{timeout=30,stdin=null,cwd=ROOT,maxBuffer=512*1024*1024}={}) {
  const r=spawnSync(String(argv[0]),argv.slice(1).map(String),{cwd,timeout:timeout*1000,killSignal:'SIGKILL',maxBuffer,
    input:stdin===null?undefined:stdin,stdio:[stdin===null?'ignore':'pipe','pipe','pipe']});
  if(r.error)throw new Error(`Process failed: ${r.error.message}`);
  if(r.signal)throw new Error(`Process killed by ${r.signal}`);
  if(r.status!==0)throw new Error(`Process exit ${r.status}: ${r.stderr.toString().slice(-2000)}`);
  return {stdout:r.stdout.toString(),stderr:r.stderr.toString()};
}

// Development reports go to a .json file below build/.
export function outputPath(path,{fresh=false}={}) {
  const dest=resolve(path),inside=relative(resolve(ROOT,'build'),dest);
  if(inside===''||inside.startsWith('..')||isAbsolute(inside)||extname(dest)!=='.json')throw new Error('Output must be a .json file below build/');
  if(fresh&&existsSync(dest))throw new Error('Fresh output JSON below build required');
  return dest;
}

// ---------- Arithmetic-demo expressions (models/tc0/expression-machine.shen) ----------

const ID=/^(0|[1-9][0-9]*)$/,SAFE=/^[A-Za-z_][A-Za-z0-9_]*$/;
const EXPRESSION_OPS=new Set(['add','sub','mul','div','neg','lt','le','gt','ge','not']);
export function shenExpr(e) {
  const [tag,node,...args]=e;let rest;
  if(tag==='int'||tag==='var')rest=args[0];
  else if(tag==='bool')rest=args[0]?'true':'false';
  else if(tag==='unit')rest='';
  else if(tag==='let')rest=`${args[0]} ${shenExpr(args[1])} ${shenExpr(args[2])}`;
  else if(tag==='if')rest=args.map(shenExpr).join(' ');
  else if(tag==='emit') {
    if(!SAFE.test(args[0]))throw new Error('Label outside demonstrated Shen transport scope');
    rest=`${JSON.stringify(args[0])} ${shenExpr(args[1])}`;
  } else if(tag==='prim') {
    if(!EXPRESSION_OPS.has(args[0]))throw new Error('Unsupported primitive');
    rest=`${args[0]} ${args.slice(1).map(shenExpr).join(' ')}`;
  } else throw new Error('Unsupported expression');
  if(typeof node!=='string'||!ID.test(node))throw new Error('Invalid ID');
  return `[${tag} ${node}${rest?' '+rest:''}]`;
}

export function parseList(line) {
  const tokens=line.match(/"(?:[^"\\]|\\.)*"|\[|\]|[^\s\[\]]+/g)||[];let index=0;
  const parse=depth=>{
    if(depth>128||index>=tokens.length)throw new Error('Invalid Shen list framing');
    const token=tokens[index++];
    if(token==='[') {
      const values=[];
      while(index<tokens.length&&tokens[index]!==']')values.push(parse(depth+1));
      if(index>=tokens.length)throw new Error('Unclosed Shen list');
      index++;return values;
    }
    if(token===']')throw new Error('Unexpected closing bracket');
    return token.startsWith('"')?JSON.parse(token):token;
  };
  const value=parse(0);
  if(index!==tokens.length)throw new Error('Extra Shen output');
  return value;
}

const pick=(table,key)=>{if(typeof key!=='string'||!Object.hasOwn(table,key))throw new Error('Unexpected model token '+JSON.stringify(key));return table[key];};
export function scalarValue(v) {
  if(Array.isArray(v)&&v.length===1&&v[0]==='unit')return ['unit'];
  if(Array.isArray(v)&&v.length===2&&v[0]==='int')return ['int',v[1]];
  if(Array.isArray(v)&&v.length===2&&v[0]==='bool'&&(v[1]==='true'||v[1]==='false'))return ['bool',v[1]==='true'];
  throw new Error('Unexpected model value');
}
const EXPRESSION_TRAPS={'div-zero':'DivZero',overflow:'Overflow'};
const expressionOutcome=o=>o[0]==='ok'?['Ok',scalarValue(o[1])]:['Trap',pick(EXPRESSION_TRAPS,o[1])];
// Key order matches the former Python dict construction so serialized reports are unchanged.
function expressionEvent(e) {
  if(e[0]==='scope-exit')return {kind:'ScopeExit',task:'0',outcome:expressionOutcome(e[1]),scope:'0'};
  if(e[0]==='task-termination')return {kind:'TaskTermination',task:'0',outcome:expressionOutcome(e[1])};
  if(e[0]==='invoke')return {kind:'Invoke',task:'0',node:e[1],label:e[2],value:scalarValue(e[3]),operation:'emit'};
  if(e[0]==='emit')return {kind:'Emit',task:'0',node:e[1],label:e[2],value:scalarValue(e[3])};
  if(e[0]==='commit')return {kind:'Commit',task:'0',node:e[1],operation:'emit',value:scalarValue(e[2])};
  throw new Error('Unknown model event');
}
const RULES={dispatch:'Dispatch',ready:'Ready','collect-return':'CollectReturn','let-return':'LetReturn','if-return':'IfReturn',
  'unwind-frame':'UnwindFrame',value:'Value',unwind:'Unwind',join:'Join',terminate:'Terminate'};
const MACHINE_SITES={'root-join-entry':'RootJoinEntry',join:'Join',terminate:'Terminate'};
const AFTER={eval:'Eval',evaluate:'Eval',value:'Value',ready:'Ready',unwind:'Unwind',join:'Join',terminate:'Terminate',terminal:'Terminal'};
function normalizeWith(sample,epoch,decodeEvent,extraRules) {
  if(!Array.isArray(sample)||sample.length!==5||sample[0]!=='sample')throw new Error('Expected sample');
  const [,site,after,depth,events]=sample;
  const rule=extraRules&&site[0]==='node'&&Object.hasOwn(extraRules,site[2])?extraRules[site[2]]:pick(RULES,site[2]);
  const where=site[0]==='node'?{node:site[1]}:{[site[0]]:pick(MACHINE_SITES,site[1])};
  return {epoch:String(epoch),site:{...where,rule},after:pick(AFTER,after),depth,events:events.map(decodeEvent)};
}
export const normalizeExpression=(sample,epoch)=>normalizeWith(sample,epoch,expressionEvent,null);

// ---------- Pure-call programs (models/tc0/pure-call-machine.shen) ----------

export function atom(s) {
  if(typeof s!=='string'||!/^[a-z][a-z0-9_-]*$/.test(s))throw new Error('Name outside demonstrated Shen symbol transport scope');
  return 'fn-'+s;
}
// Datatype/constructor names travel as Shen strings and print bare with ~A.
export function name(s) {
  if(typeof s!=='string'||!SAFE.test(s))throw new Error('Name outside demonstrated Shen string scope');
  return JSON.stringify(s);
}
export function octets(hex) {
  if(typeof hex!=='string'||!/^(?:[0-9a-f]{2})*$/.test(hex))throw new Error('Bytes outside canonical hex');
  return '['+[...Buffer.from(hex,'hex')].join(' ')+']';
}
// codes collects one "[id [parameter body]]" entry per lambda, innermost first.
export function translate(e,codes) {
  const [tag,node,...x]=e;let rest;
  const sub=c=>translate(c,codes);
  if(tag==='bytes')rest=octets(x[0]);
  else if(tag==='tuple'||tag==='apply'||tag==='if')rest=x.map(sub).join(' ');
  else if(tag==='project')rest=`${sub(x[0])} ${String(BigInt(x[1]))}`;
  else if(tag==='construct')rest=[name(x[0]),name(x[1]),...x.slice(2).map(sub)].join(' ');
  else if(tag==='match')rest=`${sub(x[0])} [${x.slice(1).map(([c,b,body])=>`[${name(c)} [${b.join(' ')}] ${sub(body)}]`).join(' ')}]`;
  else if(tag==='lambda'){const body=sub(x[5]);codes.push(`[${node} [${x[0]} ${body}]]`);rest=`${x[0]} ${body}`;}
  else if(tag==='call')rest=`${atom(x[0])} ${sub(x[1])}`;
  else if(tag==='let')rest=`${x[0]} ${sub(x[1])} ${sub(x[2])}`;
  else if(tag==='prim')rest=`${x[0]} ${x.slice(1).map(sub).join(' ')}`;
  else if(tag==='emit') {
    if(!SAFE.test(x[0]))throw new Error('Label outside demonstrated Shen string scope');
    rest=`${JSON.stringify(x[0])} ${sub(x[1])}`;
  } else return shenExpr(e);
  return `[${tag} ${node} ${rest}]`;
}
export function initialValue(v) {
  const [tag,...x]=v;
  if(tag==='int')return `[int ${x[0]}]`;
  if(tag==='bool')return `[bool ${x[0]?'true':'false'}]`;
  if(tag==='unit')return '[unit]';
  if(tag==='bytes')return `[bytes ${octets(x[0])}]`;
  if(tag==='tuple')return `[tuple ${x.map(initialValue).join(' ')}]`;
  if(tag==='data')return `[data ${[name(x[0]),name(x[1]),...x.slice(2).map(initialValue)].join(' ')}]`;
  throw new Error('Unsupported input value');
}
export function initialState(artifact,input=['int','0']) {
  const codes=[];
  for(const f of artifact.functions){const body=translate(f.body,codes);codes.push(`[${f.id} [${f.parameter_id} ${body}]]`);}
  const names='['+artifact.functions.map(f=>`[${atom(f.name)} ${f.id}]`).join(' ')+']';
  const entry=artifact.functions.find(f=>f.name===artifact.entry);
  return `[pure-call-state [evaluate ${translate(entry.body,[])} true] [[${entry.parameter_id} ${initialValue(input)}]] [] [${codes.join(' ')}] ${names}]`;
}

export function modelValue(v) {
  if(Array.isArray(v)&&v.length===4&&v[0]==='closure'&&Array.isArray(v[3])&&v[3].length===0)
    return {code_id:v[1],captures:v[2].map(([k,x])=>[k,modelValue(x)]),capture_support:[]};
  if(Array.isArray(v)&&v.length===2&&v[0]==='bytes'&&Array.isArray(v[1]))
    return ['bytes',Buffer.from(v[1].map(o=>{const n=Number(o);if(!Number.isInteger(n)||n<0||n>255)throw new Error('Octet');return n;})).toString('hex')];
  if(Array.isArray(v)&&v.length>=2&&v[0]==='tuple')return ['tuple',...v.slice(1).map(modelValue)];
  if(Array.isArray(v)&&v.length>=3&&v[0]==='data')return ['data',v[1],v[2],...v.slice(3).map(modelValue)];
  return scalarValue(v);
}
const TRAPS={'div-zero':'DivZero',overflow:'Overflow',bounds:'Bounds'};
export const outcome=o=>o[0]==='ok'?['Ok',modelValue(o[1])]:['Trap',pick(TRAPS,o[1])];
export function event(e) {
  if(e[0]==='scope-exit')return {kind:'ScopeExit',task:'0',outcome:outcome(e[1]),scope:'0'};
  if(e[0]==='task-termination')return {kind:'TaskTermination',task:'0',outcome:outcome(e[1])};
  if(e[0]==='invoke')return {kind:'Invoke',task:'0',node:e[1],label:e[2],value:modelValue(e[3]),operation:'emit'};
  if(e[0]==='emit')return {kind:'Emit',task:'0',node:e[1],label:e[2],value:modelValue(e[3])};
  if(e[0]==='commit')return {kind:'Commit',task:'0',node:e[1],operation:'emit',value:modelValue(e[2])};
  throw new Error('Unknown model event');
}
const PURE_CALL_RULES={'return-return':'ReturnReturn','match-return':'MatchReturn'};
export const normalize=(sample,epoch)=>normalizeWith(sample,epoch,event,PURE_CALL_RULES);

// Split one case's oracle output into its normalized steps and closure descriptors.
export function decodeCase(text) {
  const lines=text.split('\n');
  while(lines.length&&lines.at(-1)==='')lines.pop();
  const completed=lines.length>0&&lines.at(-1).trim()==='terminal';
  const steps=lines.filter(l=>l.startsWith('[sample ')).map((l,i)=>normalize(parseList(l),i));
  const descriptors=lines.filter(l=>l.startsWith('[closure ')).map(l=>modelValue(parseList(l)));
  return {completed,steps,descriptors,lines};
}

// Runs models/tc0/pure-call-oracle.shen over a batch of initial states. Exactly one
// of: a host Shen launcher (runs the driver source), or a Yggdrasil-shaken artifact
// directory built by tools/tc0/build-shaken-oracle.mjs, admitted only while its
// stamp matches the current model sources.
export class Oracle {
  constructor({shen=null,artifact=null}={}) {
    if((shen===null)===(artifact===null))throw new Error('Exactly one oracle: host Shen executable or shaken artifact');
    // Follow symlinks, as the former Python wrapper did: runtime files sit beside the real executable.
    const must=p=>{const r=resolve(p);if(!existsSync(r))throw new Error('Missing '+r);return realpathSync(r);};
    this.shen=shen===null?null:must(shen);
    this.artifact=artifact===null?null:must(artifact);
    if(this.artifact) {
      const stamp=JSON.parse(readFileSync(resolve(this.artifact,'oracle-stamp.json'),'utf8'));
      const current=Object.fromEntries(MODEL_FILES.map(p=>[relative(ROOT,p),digest(p)]));
      const same=(a,b)=>a&&typeof a==='object'&&Object.keys(a).length===Object.keys(b).length&&Object.keys(b).every(k=>a[k]===b[k]);
      if(stamp.schema!=='fenrir.shaken-oracle.v1'||!same(stamp.sources,current))
        throw new Error('Shaken oracle is stale or foreign; rebuild with tools/tc0/build-shaken-oracle.mjs');
      if(digest(resolve(this.artifact,'app-lisp'))!==stamp.artifact_sha256||digest(resolve(this.artifact,'yggdrasil.manifest.txt'))!==stamp.manifest_sha256)
        throw new Error('Shaken oracle artifact does not match its stamp');
    }
  }
  identityPaths() {
    if(this.shen)return [this.shen,resolve(this.shen,'../../lib/shen-scheme/shen.boot')];
    return ['app-lisp','yggdrasil.manifest.txt','oracle-stamp.json'].map(f=>resolve(this.artifact,f));
  }
  describe() {
    return this.shen?{kind:'host-shen',executable:this.shen}:{kind:'yggdrasil-shaken',artifact:this.artifact};
  }
  // Returns {outs: one output chunk per initial state, stderr}. timeout is seconds per case.
  run(initials,{timeout=30}={}) {
    const argv=this.shen?[this.shen,'script',resolve(ROOT,'models/tc0/pure-call-oracle.shen')]:[resolve(this.artifact,'app-lisp')];
    const stdin=initials.map(i=>`${REFERENCE_STEPS} ${i}\n`).join('')+'end\n';
    const {stdout,stderr}=synchronous(argv,{timeout:timeout*Math.max(1,initials.length),stdin,cwd:resolve(ROOT,'models/tc0')});
    const chunks=stdout.split('[case-end]\n');
    if(chunks.length!==initials.length+1)throw new Error(`Oracle returned ${chunks.length-1} cases for ${initials.length}`);
    return {outs:chunks.slice(0,-1),stderr};
  }
}

// Minimal flag parser for the checkers: --name value, and bare boolean flags listed in `booleans`.
export function parseArgs(argv,{values=[],booleans=[]}) {
  const out={};
  for(let i=0;i<argv.length;i++) {
    const flag=argv[i];
    if(booleans.includes(flag))out[flag.slice(2)]=true;
    else if(values.includes(flag)&&i+1<argv.length)out[flag.slice(2)]=argv[++i];
    else throw new Error('Unknown or incomplete argument '+flag);
  }
  return out;
}
