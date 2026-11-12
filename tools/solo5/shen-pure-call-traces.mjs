// Transport only: run a Shen pure-call model over an array of programs and
// return one normalized trace per program. No transition logic and no
// comparison happens here. Development use; not a qualification tool.
//
// Default: the registered model through the Oracle wrapper in
// tools/tc0/shen-probe.mjs, unchanged.
//
// portable: the proposed width-independent model (models/tc0/portable), for
// Shen ports whose integers are narrower than I64 such as Shen/JIT. I64 literals
// and IDs are sent as Shen strings; the output has the same shape, so the
// existing normalization is reused unchanged.
//
// Replaces the former tools/solo5/shen-pure-call-traces.py.
import {existsSync, realpathSync} from 'node:fs';
import {resolve} from 'node:path';
import {Oracle, initialState, decodeCase, synchronous, atom, name, octets, REFERENCE_STEPS, ROOT} from '../tc0/shen-probe.mjs';

function ident(s) {
  if(typeof s!=='string'||!/^(?:0|[1-9][0-9]*)$/.test(s))throw new Error('Invalid ID');
  return '"'+s+'"';
}
function integer(s) {
  if(typeof s!=='string'||!/^(?:0|-?[1-9][0-9]*)$/.test(s))throw new Error('Invalid integer literal');
  return '"'+s+'"';
}
function label(s) {
  if(typeof s!=='string'||!/^[A-Za-z_][A-Za-z0-9_]*$/.test(s))throw new Error('Label outside demonstrated Shen string scope');
  return JSON.stringify(s);
}

// Same shapes as shen-probe translate, with IDs and I64 literals as strings.
export function portableTranslate(e,codes) {
  const [tag,node,...x]=e;let rest;
  const sub=c=>portableTranslate(c,codes);
  if(tag==='unit')rest='';
  else if(tag==='bool')rest=x[0]?'true':'false';
  else if(tag==='int')rest=integer(x[0]);
  else if(tag==='var')rest=ident(x[0]);
  else if(tag==='bytes')rest=octets(x[0]);
  else if(tag==='tuple'||tag==='apply'||tag==='if')rest=x.map(sub).join(' ');
  else if(tag==='project')rest=`${sub(x[0])} ${String(BigInt(x[1]))}`;
  else if(tag==='construct')rest=[name(x[0]),name(x[1]),...x.slice(2).map(sub)].join(' ');
  else if(tag==='match')rest=`${sub(x[0])} [${x.slice(1).map(([c,b,body])=>`[${name(c)} [${b.map(ident).join(' ')}] ${sub(body)}]`).join(' ')}]`;
  else if(tag==='lambda'){const body=sub(x[5]);codes.push(`[${ident(node)} [${ident(x[0])} ${body}]]`);rest=`${ident(x[0])} ${body}`;}
  else if(tag==='call')rest=`${atom(x[0])} ${sub(x[1])}`;
  else if(tag==='let')rest=`${ident(x[0])} ${sub(x[1])} ${sub(x[2])}`;
  else if(tag==='prim') {
    if(typeof x[0]!=='string'||!/^[a-z_]+$/.test(x[0]))throw new Error('Unsupported primitive');
    rest=`${x[0]} ${x.slice(1).map(sub).join(' ')}`;
  } else if(tag==='emit')rest=`${label(x[0])} ${sub(x[1])}`;
  else throw new Error('Unsupported expression');
  return `[${tag} ${ident(node)}${rest?' '+rest:''}]`;
}

export function portableInitialState(artifact,input=['int','0']) {
  const codes=[];
  for(const f of artifact.functions){const body=portableTranslate(f.body,codes);codes.push(`[${ident(f.id)} [${ident(f.parameter_id)} ${body}]]`);}
  const names='['+artifact.functions.map(f=>`[${atom(f.name)} ${ident(f.id)}]`).join(' ')+']';
  const entry=artifact.functions.find(f=>f.name===artifact.entry);
  if(!entry)throw new Error('Entry function missing');
  if(input[0]!=='int')throw new Error('Only int entry inputs are transported');
  return `[pure-call-state [evaluate ${portableTranslate(entry.body,[])} true] [[${ident(entry.parameter_id)} [int ${integer(input[1])}]]] [] [${codes.join(' ')}] ${names}]`;
}

function runPortable(shen,programs) {
  const launcher=resolve(shen);
  if(!existsSync(launcher))throw new Error('Missing '+launcher);
  const driver=resolve(ROOT,'models/tc0/portable/pure-call-oracle.shen');
  const stdin=programs.map(p=>`${REFERENCE_STEPS} ${portableInitialState(p)}\n`).join('')+'end\n';
  const {stdout}=synchronous([realpathSync(launcher),'script',driver],{timeout:Math.max(60,programs.length),stdin,cwd:resolve(ROOT,'models/tc0')});
  const chunks=stdout.split('[case-end]\n');
  if(chunks.length!==programs.length+1)throw new Error(`Oracle returned ${chunks.length-1} cases for ${programs.length}`);
  return chunks.slice(0,-1);
}

// Returns [{execution, steps}], one per program, in order.
export function shenPureCallTraces(shen,programs,{portable=false}={}) {
  const outs=portable?runPortable(shen,programs):new Oracle({shen}).run(programs.map(p=>initialState(p)),{timeout:1}).outs;
  return outs.map(text=>{
    const {completed,steps}=decodeCase(text);
    return {execution:completed?'Completed':'BudgetExhausted',steps};
  });
}
