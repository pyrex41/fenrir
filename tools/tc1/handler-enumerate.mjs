// Exhaustive-small TC1 handler scope, UNQUALIFIED development enumeration.
// Enumerates EVERY expression of grammar H below with at most `maxNodes` AST nodes, as
// the body of `main : I64 -> I64`, in a fixed order. The scope claim is exactly
// "all of H up to the bound", nothing wider. Contract: spec/tc1/EFFECTS.md.
//
// H (sizes count AST nodes of main's body, as the validator counts them; clauses and
// binders are not nodes). An expression is generated in a context: S, the effects that
// have a handler in scope and may therefore be performed; V, the I64 binders in scope;
// and, inside a clause that names its resumption, the innermost such resumption k.
//
//   E ::= 0 | v                                      v in V
//       | tick(E)
//       | deep(E)                                    only if Ask is in S
//       | perform(X, E)                              only if X is in S
//       | div(E, E)
//       | let v = E in E[V+v]
//       | if(B, E, E)
//       | handle(X, C, E[S+X])                       X in {Ask, Bid}
//   B ::= true | false | lt(E, E)
//   C ::= x => E[V+x]                                tail-resumptive clause
//       | (x, k) => R[V+x]                           clause with an explicit resumption
//   R ::= resume(k, E) | let u = discontinue(k) in E
//       | tick(R) | deep(R) | perform(X, R)          same side conditions as in E
//       | div(R, E) | div(E, R)
//       | let v = R in E[V+v] | let v = E in R[V+v]
//       | if(B, R, R)
//       | handle(X, C, R[S+X])
//
// E uses no resumption. R uses the innermost resumption k exactly once on every path,
// which is the one-shot rule of EFFECTS.md §7: one operand of a strict form or one side
// of a let carries the use, both branches of an if carry it, a condition never does, and
// a clause never uses the resumption of an enclosing clause (C always starts afresh).
// The body of a handle inside a clause may carry the enclosing k: the resume then
// happens under a new handler. u has type Unit and is not in V.
//
// A clause is generated in the S of its handle node, not S+X: the selected handler is
// inactive while its clause runs, so a perform of X in the clause needs a handler
// further out (forwarding). main starts with S and V empty, so every enumerated program
// handles every user effect it performs, as the validator requires of an entry function.
//
// Effects: Ask { ask : I64 -> I64 } and Bid { bid : I64 -> I64 }; perform(X, e) performs
// the one operation of X. Two helper functions give the grammar one-node forms for what
// would otherwise not fit in the bound:
//   tick(q) = let u = emit("tick", q) in add(q, 1)       : I64 -> I64 ! {Emit}
//     makes evaluation order and intermediate values observable, and gives values
//     other than 0 (the only literal).
//   deep(q) = if(lt(0, q), handle(Ask, ask(x) => q, deep(sub(q, 1))), perform(Ask, ask, q))
//                                                        : I64 -> I64 ! {Ask}
//     a recursive function that handles Ask around its own recursive call and performs
//     Ask at the bottom. It puts call frames and a handler of another activation inside
//     the suspended segment, and it is the only form in which one binder (q) has
//     different values at a handler and at the perform it answers, which is what
//     distinguishes a clause run in its handler's bindings from one run in the perform
//     site's.
// The only trap is DivZero, from div; the only literal is 0. An artifact declares only
// the effects and helpers its body uses, and takes schema tc1-handler-demo/1 unless a
// clause names its resumption (then /2).
//
// Not in H, so not covered by this scope: effects with more than one operation, Unit
// or other non-I64 operation types, closures, a resumption used in a condition, and
// programs of more than `maxNodes` nodes (for example, resume on one path and
// discontinue on the other needs 10).
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

export const EFFECTS=Object.freeze({
  Ask:{name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]},
  Bid:{name:'Bid',operations:[{name:'bid',argument_type:'I64',result_type:'I64'}]}});
const OPERATION={Ask:'ask',Bid:'bid'};
// AST nodes of each helper's body, to check an enumerated size against the validator's count.
const HELPER_NODES={tick:6,deep:12};
// S is a bit set: bit 0 Ask, bit 1 Bid.
const BIT={Ask:1,Bid:2};

// Templates carry no IDs. Binders are named by depth ('$v0', '$v1', ...); resume and
// discontinue name no resumption, since it is always the innermost one. Forms:
//   ['int','0'] ['var',v] ['call','tick'|'deep',e] ['perform',X,op,e] ['prim','div'|'lt',a,b]
//   ['let',v,init,body] ['if',c,a,b] ['bool',b] ['handle',X,['tail'|'explicit',x,clause],body]
//   ['resume',e] and ['drop',e], which stands for let u = discontinue(k) in e.
function enumerate(maxNodes) {
  const memo=new Map();
  // All templates of `kind` ('E', 'R' or 'B') with exactly n nodes in context (S, v),
  // v being the number of binders in scope.
  function gen(kind,n,S,v) {
    const key=`${kind}/${n}/${S}/${v}`;
    if(memo.has(key))return memo.get(key);
    const out=[];memo.set(key,out);
    if(n<1)return out;
    // One row per way of giving the child generators sizes that sum to `total`.
    const product=(total,children,build)=>{
      const fill=(i,left,row)=>{
        if(i===children.length-1){for(const c of gen(...children[i](left)))out.push(build(...row,c));return;}
        for(let size=1;size<=left-(children.length-1-i);size++)for(const c of gen(...children[i](size)))fill(i+1,left-size,[...row,c]);
      };
      if(total>=children.length)fill(0,total,[]);
    };
    const E=(S2=S,v2=v)=>size=>['E',size,S2,v2],R=(S2=S,v2=v)=>size=>['R',size,S2,v2],B=size=>['B',size,S,v];
    // The strict one-operand forms available here: tick always, deep and perform by S.
    const unary=[a=>['call','tick',a],...(S&BIT.Ask?[a=>['call','deep',a]]:[]),
      ...Object.keys(BIT).filter(X=>S&BIT[X]).map(X=>a=>['perform',X,OPERATION[X],a])];
    const binder='$v'+v;
    // handle(X, C, body): the clause is generated in S, the body in S+X.
    const handles=body=>{
      for(const X of Object.keys(BIT)) {
        product(n-1,[E(S,v+1),body(S|BIT[X])],(c,b)=>['handle',X,['tail',binder,c],b]);
        product(n-1,[R(S,v+1),body(S|BIT[X])],(c,b)=>['handle',X,['explicit',binder,c],b]);
      }
    };
    if(kind==='B') {
      if(n===1)out.push(['bool',true],['bool',false]);
      product(n-1,[E(),E()],(a,b)=>['prim','lt',a,b]);
    } else if(kind==='E') {
      if(n===1){out.push(['int','0']);for(let d=0;d<v;d++)out.push(['var','$v'+d]);}
      for(const form of unary)product(n-1,[E()],form);
      product(n-1,[E(),E()],(a,b)=>['prim','div',a,b]);
      product(n-1,[E(),E(S,v+1)],(a,b)=>['let',binder,a,b]);
      product(n-1,[B,E(),E()],(c,a,b)=>['if',c,a,b]);
      handles(S2=>E(S2));
    } else {
      product(n-1,[E()],a=>['resume',a]);
      // let u = discontinue(k) in E: two nodes besides E.
      product(n-2,[E()],a=>['drop',a]);
      for(const form of unary)product(n-1,[R()],form);
      product(n-1,[R(),E()],(a,b)=>['prim','div',a,b]);
      product(n-1,[E(),R()],(a,b)=>['prim','div',a,b]);
      product(n-1,[R(),E(S,v+1)],(a,b)=>['let',binder,a,b]);
      product(n-1,[E(),R(S,v+1)],(a,b)=>['let',binder,a,b]);
      product(n-1,[B,R(),R()],(c,a,b)=>['if',c,a,b]);
      handles(S2=>R(S2));
    }
    return out;
  }
  const rows=[];
  for(let n=1;n<=maxNodes;n++)for(const body of gen('E',n,0,0))rows.push({nodes:n,body});
  return rows;
}

// Assign node IDs in preorder and binding IDs at binders; build the closed artifact.
function artifact(row,name) {
  let next=0n;const fresh=()=>String(next++),locations=[];
  const node=(tag,...rest)=>{const id=fresh();locations.push(id);return [tag,id,...rest];};
  const main={id:fresh(),name:'main',parameter_id:fresh()};locations.push(main.id);
  const binders=new Map(),resumptions=[];let explicit=false;
  const walk=e=>{
    const [tag,...x]=e,id=fresh();locations.push(id);
    if(tag==='int'||tag==='bool')return [tag,id,...x];
    if(tag==='var')return ['var',id,binders.get(x[0])];
    if(tag==='call')return ['call',id,x[0],walk(x[1])];
    if(tag==='perform')return ['perform',id,x[0],x[1],walk(x[2])];
    if(tag==='prim')return ['prim',id,x[0],...x.slice(1).map(walk)];
    if(tag==='if')return ['if',id,...x.map(walk)];
    if(tag==='let'){const init=walk(x[1]),v=fresh();binders.set(x[0],v);return ['let',id,v,init,walk(x[2])];}
    if(tag==='resume')return ['resume',id,resumptions.at(-1),walk(x[0])];
    if(tag==='drop')return ['let',id,fresh(),node('discontinue',resumptions.at(-1)),walk(x[0])];
    if(tag==='handle') {
      const [form,binder,clauseBody]=x[1],v=fresh();binders.set(binder,v);
      let clause;
      if(form==='explicit'){explicit=true;const k=fresh();resumptions.push(k);clause=[OPERATION[x[0]],v,k,walk(clauseBody)];resumptions.pop();}
      else clause=[OPERATION[x[0]],v,walk(clauseBody)];
      return ['handle',id,x[0],[clause],walk(x[2])];
    }
    throw new Error('Unknown template '+tag);
  };
  const body=walk(row.body),text=JSON.stringify(row.body);
  const functions=[{...main,argument_type:'I64',result_type:'I64',effects:['Emit'],body}];
  const helper=(name,effects,build)=>{const id=fresh(),parameter_id=fresh();locations.push(id);
    functions.push({id,name,parameter_id,argument_type:'I64',result_type:'I64',effects,body:build(parameter_id)});};
  if(text.includes('"tick"'))helper('tick',['Emit'],q=>node('let',fresh(),node('emit','tick',node('var',q)),node('prim','add',node('var',q),node('int','1'))));
  if(text.includes('"deep"'))helper('deep',['Ask'],q=>{
    const x=fresh();
    return node('if',node('prim','lt',node('int','0'),node('var',q)),
      node('handle','Ask',[['ask',x,node('var',q)]],node('call','deep',node('prim','sub',node('var',q),node('int','1')))),
      node('perform','Ask','ask',node('var',q)));});
  // deep performs and handles Ask, so its declaration is needed wherever deep is.
  const effects=Object.keys(EFFECTS).filter(X=>text.includes(`"${X}"`)||(X==='Ask'&&text.includes('"deep"'))).map(X=>EFFECTS[X]);
  return {contract_version:'tc1-draft-1',schema_version:explicit?'tc1-handler-demo/2':'tc1-handler-demo/1',slice:explicit?'TC1-H2':'TC1-H1',module:name,
    datatypes:[],effects,functions,entry:'main',input_schema:{type:'I64'},
    source_map:locations.map(id=>({id,file:'tc1-exhaustive-small',line:'0',column:'0'}))};
}

// Every enumerated program must be valid: a rejection is an enumerator defect and stops
// the enumeration (it is never skipped), as does a node count that differs from the size
// the program was enumerated at.
// The bound stops at 7 (12,693 programs): the scope grows about eightfold per node
// (96,205 programs at 8), and at 7 the Solo5 guest image holding the whole family is
// already 23 MB of the tender's 32 MB.
export function enumerateHandlers(maxNodes=7,{maxCases=20000}={}) {
  if(!Number.isSafeInteger(maxNodes)||maxNodes<1||maxNodes>7)throw new TypeError('Node bound 1..7');
  const rows=enumerate(maxNodes);
  if(rows.length>maxCases)throw new RangeError(`Exhaustive scope has ${rows.length} programs, above the ${maxCases} cap; lower the node bound rather than truncating`);
  const by={};
  const cases=rows.map((row,i)=>{
    const name='tc1-small-'+i,program=artifact(row,name);
    let checked;
    try{checked=validatePureCallArtifact(encode(program),['int','0']);}
    catch(e){throw new Error(`Enumerated program ${name} is rejected by the validator (${e.message}): ${JSON.stringify(row.body)}`);}
    const helpers=program.functions.slice(1).reduce((n,f)=>n+HELPER_NODES[f.name],0);
    if(Number(checked.node_count)-helpers!==row.nodes)throw new Error(`Enumerated program ${name} has ${Number(checked.node_count)-helpers} body nodes, enumerated at ${row.nodes}`);
    by[row.nodes]=String(1+Number(by[row.nodes]??0));
    return {name,program,nodes:String(row.nodes),template:row.body};
  });
  return {schema:'tc1-handler-exhaustive-small/1',grammar:'tools/tc1/handler-enumerate.mjs header grammar H',max_nodes:String(maxNodes),count:String(cases.length),counts_by_nodes:by,truncated:false,cases};
}
