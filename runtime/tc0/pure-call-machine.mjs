// Independent UNQUALIFIED integrated candidate. No oracle/validator imports.
function children(e){const [t,,...x]=e;if(t==='let')return [x[1],x[2]];if(t==='lambda')return [x[5]];if(t==='if'||t==='apply')return x;if(t==='prim')return x.slice(1);if(t==='call'||t==='emit')return [x[1]];return [];}
function free(e,bound=new Set(),out=new Set()){
 const [t,,...x]=e;if(t==='var'){if(!bound.has(x[0]))out.add(x[0]);}
 else if(t==='let'){free(x[1],bound,out);free(x[2],new Set([...bound,x[0]]),out);}
 else if(t==='lambda')free(x[5],new Set([...bound,x[0]]),out);
 else for(const child of children(e))free(child,bound,out);return out;
}
export class PureCallMachine {
 constructor(artifact,input,{reverseOperands=false}={}){
  this.artifact=artifact;this.input=input;this.functions=new Map(artifact.functions.map(f=>[f.name,f]));this.codes=new Map();this.frames=[];this.epoch=0n;this.terminal=null;this.events=[];this.descriptors=[];this.reverseOperands=reverseOperands;
  const collect=e=>{if(e[0]==='lambda')this.codes.set(e[1],{parameter:e[2],body:e[7]});for(const c of children(e))collect(c);};
  for(const f of artifact.functions){this.codes.set(f.id,{parameter:f.parameter_id,body:f.body});collect(f.body);}
  const entry=this.functions.get(artifact.entry);this.env=new Map([[entry.parameter_id,input]]);this.control={kind:'Eval',expr:entry.body,tail:true};
 }
 site(){const c=this.control;if(c.kind==='Eval')return {node:c.expr[1],rule:'Dispatch'};if(c.kind==='Ready')return {node:c.node,rule:'Ready'};if(c.kind==='Value'&&this.frames.length)return {node:this.frames.at(-1).node,rule:this.frames.at(-1).kind+'Return'};if(c.kind==='Unwind'&&this.frames.length)return {node:this.frames.at(-1).node,rule:'UnwindFrame'};return {machine:c.kind==='Value'||c.kind==='Unwind'?'RootJoinEntry':c.kind,rule:c.kind};}
 step(){
  if(this.terminal)throw new Error('Already terminal');const c=this.control,site=this.site(),events=[];
  const value=v=>{this.control={kind:'Value',value:v};},enter=(expr,tail)=>{this.control={kind:'Eval',expr,tail};};
  if(c.kind==='Eval'){
   const [t,node,...x]=c.expr;
   if(['int','bool','unit'].includes(t))value([t,...x]);
   else if(t==='var'){if(!this.env.has(x[0]))throw new Error('Unknown binding');value(this.env.get(x[0]));}
   else if(t==='lambda'){const captures=[...free(x[5],new Set([x[0]]))].sort((a,b)=>BigInt(a)<BigInt(b)?-1:1).map(k=>{if(!this.env.has(k))throw new Error('Missing capture');return [k,this.env.get(k)];});const d={code_id:node,captures,capture_support:[]};this.descriptors.push(d);value(d);}
   else if(t==='let'){this.frames.push({kind:'Let',node,binding:x[0],body:x[2],env:this.env,tail:c.tail});enter(x[1],false);}
   else if(t==='if'){this.frames.push({kind:'If',node,yes:x[1],no:x[2],env:this.env,tail:c.tail});enter(x[0],false);}
   else if(['prim','apply','call','emit'].includes(t)){
    let operands=t==='prim'?x.slice(1):t==='apply'?x:[x[1]];if(this.reverseOperands)operands=[...operands].reverse();
    const f={kind:'Collect',node,operation:t==='prim'?x[0]:t,metadata:t==='call'||t==='emit'?x[0]:null,remaining:operands.slice(1),values:[],env:this.env,tail:c.tail};
    if(operands.length){this.frames.push(f);enter(operands[0],false);}else this.control={kind:'Ready',node,operation:f.operation,metadata:f.metadata,values:[],tail:c.tail};
   }else throw new Error('Unsupported expression');
  }else if(c.kind==='Value'){
   if(!this.frames.length)this.control={kind:'Join',outcome:['Ok',c.value]};
   else {const f=this.frames.pop();this.env=f.env;
    if(f.kind==='Let'){this.env=new Map(this.env);this.env.set(f.binding,c.value);enter(f.body,f.tail);}
    else if(f.kind==='If')enter(c.value[1]?f.yes:f.no,f.tail);
    else if(f.kind==='Return')value(c.value);
    else {const values=[...f.values,c.value];if(f.remaining.length){this.frames.push({...f,values,remaining:f.remaining.slice(1)});enter(f.remaining[0],false);}else this.control={kind:'Ready',node:f.node,operation:f.operation,metadata:f.metadata,values:this.reverseOperands?[...values].reverse():values,tail:f.tail};}
   }
  }else if(c.kind==='Ready'){
   if(c.operation==='call'||c.operation==='apply'){
    let code,captures,arg;if(c.operation==='call'){const f=this.functions.get(c.metadata);code=this.codes.get(f.id);captures=[];arg=c.values[0];}else {const d=c.values[0];if(!d||!Array.isArray(d.capture_support)||d.capture_support.length)throw new Error('Descriptor');code=this.codes.get(d.code_id);captures=d.captures;arg=c.values[1];}
    if(!code)throw new Error('Unknown code');if(!c.tail)this.frames.push({kind:'Return',node:c.node,env:this.env});this.env=new Map(captures);this.env.set(code.parameter,arg);enter(code.body,true);
   }else if(c.operation==='emit'){
    const identity={task:'0',node:c.node};events.push({kind:'Invoke',...identity,operation:'emit',label:c.metadata,value:c.values[0]},{kind:'Emit',...identity,label:c.metadata,value:c.values[0]},{kind:'Commit',...identity,operation:'emit',value:['unit']});value(['unit']);
   }else if(c.operation==='not')value(['bool',!c.values[0][1]]);
   else {const [a,b]=c.values.map(v=>BigInt(v[1]));let n;if(c.operation==='div'&&b===0n)this.control={kind:'Unwind',code:'DivZero'};else {
    switch(c.operation){case 'add':n=a+b;break;case 'sub':n=a-b;break;case 'mul':n=a*b;break;case 'div':n=a/b;break;case 'neg':n=-a;break;case 'lt':n=a<b;break;case 'le':n=a<=b;break;case 'gt':n=a>b;break;case 'ge':n=a>=b;break;default:throw new Error('Primitive');}
    if(typeof n==='boolean')value(['bool',n]);else if(n<-(1n<<63n)||n>=(1n<<63n))this.control={kind:'Unwind',code:'Overflow'};else value(['int',String(n)]);
   }}
  }else if(c.kind==='Unwind'){if(this.frames.length)this.env=this.frames.pop().env;else this.control={kind:'Join',outcome:['Trap',c.code]};}
  else if(c.kind==='Join'){events.push({kind:'ScopeExit',task:'0',scope:'0',outcome:c.outcome});this.control={kind:'Terminate',outcome:c.outcome};}
  else if(c.kind==='Terminate'){events.push({kind:'TaskTermination',task:'0',outcome:c.outcome});this.terminal=c.outcome;this.control={kind:'Terminal'};}
  else throw new Error('Control');
  this.events.push(...events);return {epoch:String(this.epoch++),site,after:this.control.kind,depth:String(this.frames.length),events};
 }
 run(fuel=200){if(!Number.isSafeInteger(fuel)||fuel<0)throw new TypeError('Fuel');const steps=[];while(!this.terminal&&steps.length<fuel)steps.push(this.step());return {execution:this.terminal?'Completed':'BudgetExhausted',outcome:this.terminal,steps,events:[...this.events],descriptors:this.descriptors};}
}
