#!/usr/bin/env node
// Development check for models/tc0/portable/i64.shen: every operation over a
// boundary product V x V is compared with exact results computed here with
// BigInt. Run it once per Shen port; agreement between ports is not the test.
// Usage: node tools/tc0/check-portable-i64.mjs SHEN_EXECUTABLE [...more]
import {spawnSync} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';

const root=resolve(import.meta.dirname,'../..');
const MIN=-(1n<<63n),MAX=(1n<<63n)-1n;
export const VALUES=[MIN,MIN+1n,MIN+2n,-(1n<<62n),-(1n<<61n)-1n,-(1n<<61n),-(1n<<53n)-1n,-(1n<<53n),-3037000500n,-3037000499n,
  -4294967296n,-10n,-9n,-2n,-1n,0n,1n,2n,9n,10n,99n,100n,4294967296n,3037000499n,3037000500n,(1n<<53n),(1n<<53n)+1n,
  (1n<<61n)-1n,(1n<<61n),(1n<<62n),MAX-2n,MAX-1n,MAX];
const fits=n=>n>=MIN&&n<=MAX;
const checked=n=>fits(n)?`[ok ${n}]`:'[trap overflow]';
export function expected(op,a,b) {
  if(op==='add')return checked(a+b);
  if(op==='sub')return checked(a-b);
  if(op==='mul')return checked(a*b);
  if(op==='neg')return checked(-a);
  if(op==='div')return b===0n?'[trap div-zero]':checked(a/b); // BigInt division truncates toward zero
  if(op==='compare')return String(a<b?-1:a>b?1:0);
  throw new Error('Unknown operation');
}
export function cases() {
  const rows=[];
  for(const a of VALUES){rows.push(['neg',a,null]);for(const b of VALUES)for(const op of ['add','sub','mul','div','compare'])rows.push([op,a,b]);}
  return rows;
}
function check(executable) {
  const rows=cases(),dir=resolve(root,'build/tc0/portable-i64',`${Date.now()}-${process.pid}`);
  mkdirSync(dir,{recursive:true});
  const lines=[`(load "${resolve(root,'models/tc0/portable/i64.shen')}")`,'(output "FG-BEGIN~%")'];
  for(const [op,a,b] of rows)
    lines.push(op==='compare'?`(output "~A~%" (tc0.i64.compare "${a}" "${b}"))`
      :`(output "~A~%" (tc0.arithmetic ${op} [${[a,b].filter(x=>x!==null).map(x=>`"${x}"`).join(' ')}]))`);
  lines.push('(output "FG-END~%")');
  const script=resolve(dir,'cases.shen');writeFileSync(script,lines.join('\n')+'\n');
  const r=spawnSync(executable,['script',script],{timeout:600000,maxBuffer:64*1024*1024,env:{}});
  if(r.error||r.signal||r.status!==0)return {executable,status:'development-fail',reason:`Shen run failed: ${r.error?.message||r.signal||r.stderr.toString().slice(-300)}`};
  const out=r.stdout.toString().split('\n'),begin=out.indexOf('FG-BEGIN'),end=out.indexOf('FG-END');
  const got=begin<0||end<0?[]:out.slice(begin+1,end),failures=[];
  if(got.length!==rows.length)return {executable,status:'development-fail',reason:`${got.length} results for ${rows.length} cases`};
  rows.forEach(([op,a,b],i)=>{const want=expected(op,a,b);if(got[i]!==want&&failures.length<10)failures.push({op,a:String(a),b:b===null?null:String(b),want,got:got[i]});});
  const tally={};for(const line of got){const k=line.startsWith('[ok')?'ok':line.startsWith('[trap')?line:'compare';tally[k]=(tally[k]||0)+1;}
  return {executable,status:failures.length?'development-fail':'development-pass',cases:String(rows.length),tally,failures};
}
if(process.argv[1]&&resolve(process.argv[1])===import.meta.filename) {
  const ports=process.argv.slice(2);
  if(!ports.length)throw new Error('Usage: check-portable-i64.mjs SHEN_EXECUTABLE [...]');
  const reports=ports.map(p=>check(resolve(p)));
  console.log(JSON.stringify({schema:'fenrir.portable-i64-development/1',qualification:'UNKNOWN',values:String(VALUES.length),reports},null,2));
  if(reports.some(r=>r.status!=='development-pass'))process.exitCode=1;
}
