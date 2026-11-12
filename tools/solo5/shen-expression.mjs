// Drive the Shen expression model (models/tc0/expression-machine.shen) over a
// batch of TC0-A arithmetic-demo artifacts and normalize its samples to the
// step shape the candidates emit. Transport and normalization only: no
// transition logic lives here. Mirrors tools/check-tc0-expression.py.
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';

const root=resolve(import.meta.dirname,'../..');
const OPS=new Set(['add','sub','mul','div','neg','lt','le','gt','ge','not']);

export function shenExpression(e) {
  const [tag,node,...args]=e;let rest;
  if(!/^(0|[1-9][0-9]*)$/.test(node))throw new Error('Invalid ID');
  if(tag==='int'){if(!/^(0|-?[1-9][0-9]*)$/.test(args[0]))throw new Error('Invalid integer');rest=args[0];}
  else if(tag==='var'){if(!/^(0|[1-9][0-9]*)$/.test(args[0]))throw new Error('Invalid binding');rest=args[0];}
  else if(tag==='bool')rest=args[0]?'true':'false';
  else if(tag==='unit')rest='';
  else if(tag==='let'){if(!/^(0|[1-9][0-9]*)$/.test(args[0]))throw new Error('Invalid binding');rest=`${args[0]} ${shenExpression(args[1])} ${shenExpression(args[2])}`;}
  else if(tag==='if')rest=args.map(shenExpression).join(' ');
  else if(tag==='emit') {
    if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(args[0]))throw new Error('Label outside demonstrated Shen transport scope');
    rest=`"${args[0]}" ${shenExpression(args[1])}`;
  } else if(tag==='prim') {
    if(!OPS.has(args[0]))throw new Error('Unsupported primitive');
    rest=`${args[0]} ${args.slice(1).map(shenExpression).join(' ')}`;
  } else throw new Error('Unsupported expression');
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

const pick=(table,key)=>{if(!Object.hasOwn(table,key))throw new Error('Unexpected model token '+key);return table[key];};
function value(v) {
  if(v.length===1&&v[0]==='unit')return ['unit'];
  if(v.length===2&&v[0]==='int')return ['int',v[1]];
  if(v.length===2&&v[0]==='bool'&&(v[1]==='true'||v[1]==='false'))return ['bool',v[1]==='true'];
  throw new Error('Unexpected model value');
}
const outcome=o=>o[0]==='ok'?['Ok',value(o[1])]:['Trap',pick({'div-zero':'DivZero',overflow:'Overflow'},o[1])];
function event(e) {
  if(e[0]==='scope-exit')return {kind:'ScopeExit',task:'0',outcome:outcome(e[1]),scope:'0'};
  if(e[0]==='task-termination')return {kind:'TaskTermination',task:'0',outcome:outcome(e[1])};
  if(e[0]==='invoke')return {kind:'Invoke',task:'0',node:e[1],label:e[2],value:value(e[3]),operation:'emit'};
  if(e[0]==='emit')return {kind:'Emit',task:'0',node:e[1],label:e[2],value:value(e[3])};
  if(e[0]==='commit')return {kind:'Commit',task:'0',node:e[1],operation:'emit',value:value(e[2])};
  throw new Error('Unknown model event');
}
const RULES={dispatch:'Dispatch',ready:'Ready','collect-return':'CollectReturn','let-return':'LetReturn','if-return':'IfReturn',
  'unwind-frame':'UnwindFrame',value:'Value',unwind:'Unwind',join:'Join',terminate:'Terminate'};
const SITES={'root-join-entry':'RootJoinEntry',join:'Join',terminate:'Terminate'};
const AFTER={eval:'Eval',evaluate:'Eval',value:'Value',ready:'Ready',unwind:'Unwind',join:'Join',terminate:'Terminate',terminal:'Terminal'};
export function normalize(sample,epoch) {
  if(sample.length!==5||sample[0]!=='sample')throw new Error('Expected sample');
  const [,site,after,depth,events]=sample;
  const where=site[0]==='node'?{node:site[1]}:site[0]==='machine'?{machine:pick(SITES,site[1])}:null;
  if(!where)throw new Error('Unexpected model site');
  return {epoch:String(epoch),site:{...where,rule:pick(RULES,site[2])},after:pick(AFTER,after),depth,events:events.map(event)};
}

// One Shen process for the whole batch. Returns [{execution, steps}] in input order.
export function shenTraces(executable,functions,fuel) {
  const command=['eval','-l',resolve(root,'models/tc0/arithmetic.shen'),'-l',resolve(root,'models/tc0/expression-machine.shen'),
    '-l',resolve(root,'tools/solo5/shen-trace.shen')];
  for(const fn of functions)
    command.push('-e',`(fg.trace [state [eval ${shenExpression(fn.body)}] [[${fn.parameter_id} [unit]]] []] ${fuel})`);
  const r=spawnSync(executable,command,{timeout:120000,maxBuffer:64*1024*1024,env:{}});
  if(r.error||r.signal||r.status!==0)throw new Error(`Shen model run failed: ${r.error?.message||r.signal||r.stderr}`);
  const traces=[];let steps=[];
  for(const line of r.stdout.toString().split('\n')) {
    if(line.startsWith('[sample '))steps.push(normalize(parseList(line),steps.length));
    else if(line.startsWith('[fg-end ')) {
      const end=parseList(line)[1];
      traces.push({execution:pick({completed:'Completed','budget-exhausted':'BudgetExhausted'},end),steps});steps=[];
    }
  }
  if(steps.length||traces.length!==functions.length)throw new Error('Wrong Shen trace count');
  return traces;
}
