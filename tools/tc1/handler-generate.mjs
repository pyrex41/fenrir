// Generated TC1 handler family G, UNQUALIFIED development discovery scope: finite,
// deterministic, NOT exhaustive. Contract: spec/tc1/EFFECTS.md.
//
// Program i of the family is drawn from grammar G below by a 32-bit PRNG (mulberry32)
// seeded with SEED_BASE + i, so the family is fixed by this file alone: the same index
// gives the same program on every run and host. Nothing here runs a machine: no program
// is selected, kept or dropped by how the model or the implementation behaves on it.
// Every drawn program must pass the validator (effect sets, the one-shot rule, types);
// a rejection is a generator defect and stops generation, it is never skipped.
//
// G goes beyond grammar H of handler-enumerate.mjs. It is typed (I64, Unit, Bool,
// Opt = None | Some(I64), Unit -> I64 closures) and generated in a context: S, the
// effects with a handler in scope; V, the I64 binders; F, the closure binders with their
// effect sets; and inside an explicit clause, its resumption k (used exactly once on
// every path) and the type k is resumed with.
//
//   Effects  Ask  { ask : I64 -> I64 }
//            Cell { get : Unit -> I64; put : I64 -> Unit }      multi-operation, Unit types
//   I ::= n | v | add/sub/mul(I, I) | div(I, D)                 D often the literal 0: traps
//       | let v = I in I | let _ = emit(l, I) in I | if(Cond, I, I) | tick(I)
//       | perform(Ask, ask, I)            Ask in S
//       | perform(Cell, get, ()) | let _ = perform(Cell, put, I) in I        Cell in S
//       | deep(n)                         Ask in S; the recursive helper of grammar H
//       | handle(Ask, ask-clause, I[S+Ask]) | handle(Cell, get-clause put-clause, I[S+Cell])
//       | let f = W(lambda(_: Unit) -> I64 ! fx. I[S=fx, F=none]) in I[F+f]
//       | apply(f, ())                    f in F, fx(f) within S
//       | match (if(Cond, Some(I), None)) { Some(y) => I[V+y]; None => I }
//   W ::= the lambda itself | handle(X, tail clauses, W)    X in fx: made under a handler
//   U ::= () | let _ = emit(l, I) in () | perform(Cell, put, I) | if(Cond, U, U)
//   Cond ::= true | false | lt(I, I)
//   clause for op : A -> B, generated in the S of its handle node (the selected handler
//   is inactive in its clause, so a perform of the same effect there forwards outward):
//       op(x) => I or U, by B             tail-resumptive
//       op(x, k) => R                     explicit; only on handles of type I64
//   R ::= resume(k, I or U by B) | let _ = discontinue(k) in I
//       | let r = R in I[V+r]             the clause continues after resume returns
//       | let v = I in R | let _ = emit(l, I) in R | add(R, I) | add(I, R) | div(R, D)
//       | if(Cond, R, R) | handle(X, clauses, R[S+X])            resumed under a new handler
//
// The entry main : I64 -> I64 ! {Emit} starts with S, V, F empty, so every perform is
// handled inside the program. Helpers: tick(q) = let _ = emit("tick", q) in add(q, 1)
// and deep(q), exactly as in handler-enumerate.mjs. Integer literals are small, so
// Overflow is possible only by repeated multiplication; deep is only called on 0..2.
// Each program draws a node budget in [MIN_BUDGET, MAX_BUDGET]; the budget bounds the
// choice of productions, not the exact size.
import {encode} from '../tc0/canonical.mjs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

export const FAMILY_SIZE=2048;
const SEED_BASE=0x7c1a0000,MIN_BUDGET=10,MAX_BUDGET=48;
export const EFFECTS=Object.freeze({
  Ask:{name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]},
  Cell:{name:'Cell',operations:[{name:'get',argument_type:'Unit',result_type:'I64'},{name:'put',argument_type:'I64',result_type:'Unit'}]}});
const OPT={name:'Opt',constructors:[{name:'None',fields:[]},{name:'Some',fields:['I64']}]};
const LITERALS=['0','1','2','3','5','-2'];

export function mulberry32(seed) {
  let a=seed>>>0;
  return ()=>{a=(a+0x6D2B79F5)>>>0;let t=a;t=Math.imul(t^(t>>>15),t|1);t^=t+Math.imul(t^(t>>>7),t|61);return ((t^(t>>>14))>>>0)/4294967296;};
}

// One program. All IDs come from one counter; every node gets a source-map row.
function draw(index) {
  const random=mulberry32(SEED_BASE+index);
  const pick=xs=>xs[Math.floor(random()*xs.length)];
  const chance=p=>random()<p;
  let next=0n,labels=0;const locations=[],used={tick:false,deep:false,opt:false,Ask:false,Cell:false,explicit:false};
  const fresh=()=>String(next++);
  const node=(tag,...rest)=>{const id=fresh();locations.push(id);return [tag,id,...rest];};
  const lit=n=>node('int',n);
  const unit=()=>node('unit');
  const label=()=>'e'+String(labels++);
  // Split a budget between children, each at least 1.
  const split=(b,parts)=>{const out=[];let left=Math.max(b,parts);for(let i=parts-1;i>0;i--){const take=1+Math.floor(random()*(left-i));out.push(take);left-=take;}out.push(left);return out;};
  const withV=(ctx,v)=>({...ctx,V:[...ctx.V,v]});
  const cond=(ctx,b)=>{
    if(b<3||chance(0.25))return node('bool',chance(0.5));
    const [l,r]=split(b-1,2);return node('prim','lt',I(ctx,l),I(ctx,r));
  };
  const divisor=(ctx,b)=>chance(0.35)?lit('0'):chance(0.5)?lit('2'):I(ctx,b);
  // A clause for one operation of X, generated in ctx (the S of the handle node).
  function clause(X,op,ctx,b,explicit) {
    const x=fresh(),o=EFFECTS[X].operations.find(o=>o.name===op);
    const inner={...ctx,K:null,V:o.argument_type==='I64'?[...ctx.V,x]:ctx.V};
    if(explicit){used.explicit=true;const k=fresh();return [op,x,k,R({...inner,K:k,KT:o.result_type},b)];}
    return [op,x,o.result_type==='I64'?I(inner,b):U(inner,b)];
  }
  function clauses(X,ctx,b,explicitAllowed) {
    const ops=EFFECTS[X].operations,parts=split(b,ops.length);
    return ops.map((o,i)=>clause(X,o.name,ctx,parts[i],explicitAllowed&&chance(0.5)));
  }
  function handle(X,ctx,b,body,explicitAllowed=true) {
    used[X]=true;
    const [c,rest]=split(b-1,2),cs=clauses(X,ctx,c,explicitAllowed);
    return node('handle',X,cs,body({...ctx,S:[...new Set([...ctx.S,X])]},rest));
  }
  function U(ctx,b) {
    const options=['unit','emit'];
    if(ctx.S.includes('Cell'))options.push('put','put');
    if(b>=4)options.push('if');
    const choice=b<=1?'unit':pick(options);
    if(choice==='unit')return unit();
    if(choice==='emit')return node('let',fresh(),node('emit',label(),I(ctx,b-2)),unit());
    if(choice==='put'){used.Cell=true;return node('perform','Cell','put',I(ctx,b-1));}
    const [c,y,n]=split(b-1,3);return node('if',cond(ctx,c),U(ctx,y),U(ctx,n));
  }
  function closure(ctx,b) {
    // Effects of the lambda: a sorted subset of Ask, Cell, plus Emit.
    const fx=['Ask','Cell'].filter(()=>chance(0.6));
    const [lb,wb]=split(b,2);
    const lambda=()=>node('lambda',fresh(),'Unit','I64',[...fx,'Emit'],[],I({S:fx,V:ctx.V,F:[],K:null},lb));
    fx.forEach(X=>{used[X]=true;});
    // Made under a handler for one of its own effects (tail clauses: the handle has an arrow type).
    const wrap=(left)=>{
      if(fx.length&&left>=3&&chance(0.6)){const X=pick(fx);return handle(X,ctx,left,(_,rest)=>wrap(rest),false);}
      return lambda();
    };
    return {value:wrap(wb),fx};
  }
  function I(ctx,b) {
    if(b<=1)return ctx.V.length&&chance(0.6)?node('var',pick(ctx.V)):lit(pick(LITERALS));
    const options=['arith','div','let','emit','if','tick'];
    if(ctx.S.includes('Ask'))options.push('ask','ask','ask','deep');
    if(ctx.S.includes('Cell'))options.push('get','get','put');
    if(b>=4)options.push('handleAsk','handleAsk','handleCell','handleCell');
    if(b>=5)options.push('closure');
    const callable=ctx.F.filter(f=>f.fx.every(X=>ctx.S.includes(X)));
    if(callable.length)options.push('apply','apply','apply');
    if(b>=6)options.push('match');
    const choice=pick(options);
    if(choice==='arith'){const [l,r]=split(b-1,2);return node('prim',pick(['add','sub','mul']),I(ctx,l),I(ctx,r));}
    if(choice==='div'){const [l,r]=split(b-1,2);return node('prim','div',I(ctx,l),divisor(ctx,r));}
    if(choice==='let'){const [i,r]=split(b-1,2),v=fresh();return node('let',v,I(ctx,i),I(withV(ctx,v),r));}
    if(choice==='emit'){const [i,r]=split(b-2,2);return node('let',fresh(),node('emit',label(),I(ctx,i)),I(ctx,r));}
    if(choice==='if'){const [c,y,n]=split(b-1,3);return node('if',cond(ctx,c),I(ctx,y),I(ctx,n));}
    if(choice==='tick'){used.tick=true;return node('call','tick',I(ctx,b-1));}
    if(choice==='ask'){used.Ask=true;return node('perform','Ask','ask',I(ctx,b-1));}
    if(choice==='deep'){used.deep=true;used.Ask=true;return node('call','deep',lit(pick(['0','1','2'])));}
    if(choice==='get'){used.Cell=true;return node('perform','Cell','get',unit());}
    if(choice==='put'){used.Cell=true;const [a,r]=split(b-2,2);return node('let',fresh(),node('perform','Cell','put',I(ctx,a)),I(ctx,r));}
    if(choice==='handleAsk')return handle('Ask',ctx,b,I);
    if(choice==='handleCell')return handle('Cell',ctx,b,I);
    if(choice==='closure') {
      const [c,r]=split(b-1,2),f=fresh(),made=closure(ctx,c);
      return node('let',f,made.value,I({...ctx,F:[...ctx.F,{id:f,fx:made.fx}]},r));
    }
    if(choice==='apply')return node('apply',node('var',pick(callable).id),unit());
    used.opt=true;
    const [c,s,y,n]=split(b-3,4),bound=fresh();
    const scrutinee=node('if',cond(ctx,c),node('construct','Opt','Some',I(ctx,s)),node('construct','Opt','None'));
    return node('match',scrutinee,['Some',[bound],I(withV(ctx,bound),y)],['None',[],I(ctx,n)]);
  }
  function R(ctx,b) {
    const resumeArg=()=>ctx.KT==='Unit'?U({...ctx,K:null},b-1):I({...ctx,K:null},b-1);
    if(b<=2)return node('resume',ctx.K,resumeArg());
    const plain={...ctx,K:null};
    const choice=pick(['resume','resume','drop','continue','continue','pre','emit','add','div','if','handle']);
    if(choice==='resume')return node('resume',ctx.K,resumeArg());
    if(choice==='drop')return node('let',fresh(),node('discontinue',ctx.K),I(plain,b-2));
    if(choice==='continue'){const [r,c]=split(b-1,2),v=fresh();return node('let',v,R(ctx,r),I(withV(plain,v),c));}
    if(choice==='pre'){const [i,r]=split(b-1,2),v=fresh();return node('let',v,I(plain,i),R(withV(ctx,v),r));}
    if(choice==='emit'){const [i,r]=split(b-2,2);return node('let',fresh(),node('emit',label(),I(plain,i)),R(ctx,r));}
    if(choice==='add'){const [l,r]=split(b-1,2);return chance(0.5)?node('prim','add',R(ctx,l),I(plain,r)):node('prim','add',I(plain,l),R(ctx,r));}
    if(choice==='div'){const [l,r]=split(b-1,2);return node('prim','div',R(ctx,l),divisor(plain,r));}
    if(choice==='if'){const [c,y,n]=split(b-1,3);return node('if',cond(plain,c),R(ctx,y),R(ctx,n));}
    // The resume happens under a new handler; its clauses start without k.
    return handle(pick(['Ask','Cell']),ctx,b,(inner,rest)=>R({...inner,K:ctx.K,KT:ctx.KT},rest));
  }
  const main={id:fresh(),name:'main',parameter_id:fresh()};locations.push(main.id);
  const budget=MIN_BUDGET+Math.floor(random()*(MAX_BUDGET-MIN_BUDGET+1));
  // The body starts with a handler half of the time, so most programs perform.
  const top={S:[],V:[],F:[],K:null};
  const body=chance(0.5)?handle(pick(['Ask','Cell']),top,budget,I):I(top,budget);
  const functions=[{...main,argument_type:'I64',result_type:'I64',effects:['Emit'],body}];
  const helper=(name,effects,build)=>{const id=fresh(),parameter_id=fresh();locations.push(id);
    functions.push({id,name,parameter_id,argument_type:'I64',result_type:'I64',effects,body:build(parameter_id)});};
  if(used.tick)helper('tick',['Emit'],q=>node('let',fresh(),node('emit','tick',node('var',q)),node('prim','add',node('var',q),node('int','1'))));
  if(used.deep)helper('deep',['Ask'],q=>{
    const x=fresh();
    return node('if',node('prim','lt',node('int','0'),node('var',q)),
      node('handle','Ask',[['ask',x,node('var',q)]],node('call','deep',node('prim','sub',node('var',q),node('int','1')))),
      node('perform','Ask','ask',node('var',q)));});
  const name='tc1-generated-'+String(index);
  return {contract_version:'tc1-draft-1',schema_version:used.explicit?'tc1-handler-demo/2':'tc1-handler-demo/1',slice:used.explicit?'TC1-H2':'TC1-H1',module:name,
    datatypes:used.opt?[OPT]:[],effects:['Ask','Cell'].filter(X=>used[X]).map(X=>EFFECTS[X]),functions,entry:'main',input_schema:{type:'I64'},
    source_map:locations.map(id=>({id,file:'tc1-generated',line:'0',column:'0'}))};
}

// The first `count` programs of family G, in index order. Not truncated when count is
// FAMILY_SIZE; a smaller count is a prefix and says so.
export function generateHandlers(count=FAMILY_SIZE) {
  if(!Number.isSafeInteger(count)||count<1||count>FAMILY_SIZE)throw new TypeError(`Case count 1..${FAMILY_SIZE}`);
  const cases=[];
  for(let i=0;i<count;i++) {
    const program=draw(i),name=program.module;
    let checked;
    try{checked=validatePureCallArtifact(encode(program),['int','0']);}
    catch(e){throw new Error(`Generated program ${name} is rejected by the validator (${e.message})`);}
    cases.push({name,program,nodes:checked.node_count});
  }
  return {schema:'tc1-handler-generated/1',grammar:'tools/tc1/handler-generate.mjs header grammar G',seed_base:String(SEED_BASE),
    family_size:String(FAMILY_SIZE),count:String(count),truncated:count<FAMILY_SIZE,cases};
}
