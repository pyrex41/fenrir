// Exhaustive-small TC1-C1 scope, UNQUALIFIED development enumeration. Contract:
// spec/tc1/CONCURRENCY.md. Enumerates EVERY program of grammar G below, in a fixed order.
// The scope claim is exactly "all of G", nothing wider.
//
// G. A program is main : I64 -> I64 with the body
//
//   let c0 = channel(I64, K) in
//   [let c1 = channel(I64, 1) in]                        family "two-channel" only
//   let t1 = spawn(() => A1; 0) in
//   [let t2 = spawn(() => A2; 0) in]                     when A2 is not absent
//   R; 0
//
// where "X; Y" is let _ = X in Y, and:
//   K  in {1, 2}                                         capacity of c0
//   A1 a sequence of 1 or 2 actions of child 1, from   send0 recv0 emit yield trap close0
//   A2 absent, or 1 action of child 2, from            send0 recv0 emit cancel1 await1
//   R  0 or 1 action of the root, from                 send0 recv0 cancel1 await1 close0
// Family "two-channel" (K = 1 only, and c1 exists): child 1 and root as above with send1
// and recv1 (on c1) added to child 1's and the root's alphabets, A2 absent.
// Actions: send0 = send(c0, v); recv0 = receive(c0); send1, recv1 the same on c1;
// emit = emit("e", v); yield; trap = div(1, 0); close0 = close(c0);
// cancel1 = cancel(t1); await1 = await(t1). The value v is 10*task + position (child 1:
// 11, 12; child 2: 21; root: 31), so every value sent or emitted names its origin.
// Each task's function declares exactly the effects its actions need.
//
// The family sizes, from the grammar: one-channel 2 * (6 + 36) * 6 * 6 = 3,024;
// two-channel (8 + 64) * 8 = 576. harness/tc1-task-explore.shen derives the same numbers
// from the alphabets and checks the batch against them.
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

export const ALPHABETS=Object.freeze({
  child1:['send0','recv0','emit','yield','trap','close0'],
  child2:['send0','recv0','emit','cancel1','await1'],
  root:['send0','recv0','cancel1','await1','close0'],
  child1Two:['send0','recv0','emit','yield','trap','close0','send1','recv1'],
  rootTwo:['send0','recv0','cancel1','await1','close0','send1','recv1']});

const sequences=(alphabet,lengths)=>lengths.flatMap(n=>{
  let out=[[]];for(let i=0;i<n;i++)out=out.flatMap(s=>alphabet.map(a=>[...s,a]));return out;});

// Every template of G, in order.
export function templates() {
  const rows=[];
  for(const K of ['1','2'])for(const a1 of sequences(ALPHABETS.child1,[1,2]))for(const a2 of [null,...sequences(ALPHABETS.child2,[1])])for(const r of sequences(ALPHABETS.root,[0,1]))
    rows.push({family:'one-channel',capacity:K,child1:a1,child2:a2,root:r});
  for(const a1 of sequences(ALPHABETS.child1Two,[1,2]))for(const r of sequences(ALPHABETS.rootTwo,[0,1]))
    rows.push({family:'two-channel',capacity:'1',child1:a1,child2:null,root:r});
  return rows;
}

const order=names=>[...new Set(names)].sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b)));
const effectOf=a=>a.endsWith('0')||a.endsWith('1')&&!['cancel1','await1'].includes(a)?['Channel']:a==='emit'?['Emit']:['yield','cancel1','await1'].includes(a)?['Task']:[];

export function artifact(t,name) {
  let next=0n;const fresh=()=>String(next++),locations=[];
  const node=(tag,...rest)=>{const id=fresh();locations.push(id);return [tag,id,...rest];};
  const id=fresh(),parameter_id=fresh();locations.push(id);
  const vars={};
  const v=x=>node('var',vars[x]);
  const action=(a,value)=>{
    if(a==='send0')return node('send',v('c0'),node('int',value));
    if(a==='send1')return node('send',v('c1'),node('int',value));
    if(a==='recv0')return node('receive',v('c0'));
    if(a==='recv1')return node('receive',v('c1'));
    if(a==='emit')return node('emit','e',node('int',value));
    if(a==='yield')return node('yield');
    if(a==='trap')return node('prim','div',node('int','1'),node('int','0'));
    if(a==='close0')return node('close',v('c0'));
    if(a==='cancel1')return node('cancel',v('t1'));
    if(a==='await1')return node('await',v('t1'));
    throw new Error('Unknown action '+a);
  };
  const seq=(actions,task)=>{const go=i=>i===actions.length?node('int','0'):node('let',fresh(),action(actions[i],String(10*task+i+1)),go(i+1));return go(0);};
  const lam=(actions,task)=>node('lambda',fresh(),'Unit','I64',order(actions.flatMap(effectOf)),[],seq(actions,task));
  const bind=(name,init,body)=>{const n=node('let','?',init,null);vars[name]=fresh();n[2]=vars[name];n[4]=body();return n;};
  const body=bind('c0',node('channel','I64',t.capacity),()=>{
    const rest=()=>bind('t1',node('spawn',lam(t.child1,1)),()=>t.child2?bind('t2',node('spawn',lam(t.child2,2)),()=>seq(t.root,3)):seq(t.root,3));
    return t.family==='two-channel'?bind('c1',node('channel','I64','1'),rest):rest();
  });
  const all=[...t.child1,...(t.child2??[]),...t.root];
  const effects=order(['Channel','Task',...(all.includes('emit')?['Emit']:[])]);
  return {contract_version:'tc1-draft-1',schema_version:'tc1-task-demo/1',slice:'TC1-C1',module:name,datatypes:[],effects:[],
    functions:[{id,name:'main',parameter_id,argument_type:'I64',result_type:'I64',effects,body}],entry:'main',input_schema:{type:'I64'},
    source_map:locations.map(id=>({id,file:'tc1-task-exhaustive-small',line:'0',column:'0'}))};
}

// Every enumerated program must be valid: a rejection is an enumerator defect and stops
// the enumeration; it is never skipped.
export function enumerateTasks({family=null}={}) {
  const cases=templates().filter(t=>!family||t.family===family).map((t,i)=>{
    const name=`tc1-task-small-${t.family}-${i}`,program=artifact(t,name);
    try{validatePureCallArtifact(encode(program),['int','0']);}
    catch(e){throw new Error(`Enumerated program ${name} is rejected by the validator (${e.message}): ${JSON.stringify(t)}`);}
    return {name,program,template:t};
  });
  const by={};for(const c of cases)by[c.template.family]=String(1+Number(by[c.template.family]??0));
  return {schema:'tc1-task-exhaustive-small/1',grammar:'tools/tc1/task-enumerate.mjs header grammar G',count:String(cases.length),counts_by_family:by,truncated:false,cases};
}
