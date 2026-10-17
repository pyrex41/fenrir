// Independent UNQUALIFIED candidate. No validator or Shen transition imports.
function free(e,bound=new Set(),result=new Set()) {
 const [tag,,...a]=e;
 if(tag==='var') {if(!bound.has(a[0]))result.add(a[0]);}
 else if(tag==='let') {free(a[1],bound,result);free(a[2],new Set([...bound,a[0]]),result);}
 else if(tag==='lambda') free(a[5],new Set([...bound,a[0]]),result);
 else if(tag==='apply'||tag==='add') {free(a[0],bound,result);free(a[1],bound,result);}
 return result;
}
export class ClosureMachine {
 constructor(program,input) {
  this.env=new Map([[program.input_binding,input]]);this.frames=[];this.control={kind:'Eval',expr:program.body,tail:true};
  this.codes=new Map();this.epoch=0n;this.terminal=null;this.descriptors=[];
  const collect=e=>{const [t,id,...a]=e;
   if(t==='lambda') {this.codes.set(id,{parameter:a[0],body:a[5]});collect(a[5]);}
   else if(t==='let'){collect(a[1]);collect(a[2]);}
   else if(t==='apply'||t==='add'){collect(a[0]);collect(a[1]);}};
  collect(program.body);
 }
 step() {
  const c=this.control;if(this.terminal)throw new Error('Already terminal');
  const events=[];const node=c.expr?.[1]??c.node??this.frames.at(-1)?.node;
  const site=node===undefined?{machine:c.kind,rule:c.kind}:{node,rule:c.kind==='Value'?this.frames.at(-1).kind+'Return':c.kind==='Eval'?'Dispatch':c.kind};
  const enter=(e,tail)=>{this.control={kind:'Eval',expr:e,tail};};
  const value=v=>{this.control={kind:'Value',value:v};};
  if(c.kind==='Eval') {
   const [t,id,...a]=c.expr;
   if(t==='int')value(['int',a[0]]);
   else if(t==='var'){if(!this.env.has(a[0]))throw new Error('Unknown binding');value(this.env.get(a[0]));}
   else if(t==='lambda') {
    const captures=[...free(a[5],new Set([a[0]]))].sort((x,y)=>BigInt(x)<BigInt(y)?-1:1).map(k=>{if(!this.env.has(k))throw new Error('Missing capture');return [k,this.env.get(k)];});
    const descriptor={code_id:id,captures,capture_support:[]};this.descriptors.push(descriptor);value(descriptor);
   } else if(t==='let') {this.frames.push({kind:'Let',node:id,binding:a[0],body:a[2],env:this.env,tail:c.tail});enter(a[1],false);}
   else if(t==='apply'||t==='add') {this.frames.push({kind:'Collect',node:id,operation:t,remaining:[a[1]],values:[],env:this.env,tail:c.tail});enter(a[0],false);}
   else throw new Error('Unsupported node');
  } else if(c.kind==='Value') {
   if(!this.frames.length)this.control={kind:'Join',outcome:['Ok',c.value]};
   else {
    const f=this.frames.pop();this.env=f.env;
    if(f.kind==='Let') {this.env=new Map(this.env);this.env.set(f.binding,c.value);enter(f.body,f.tail);}
    else if(f.kind==='Return')value(c.value);
    else {const values=[...f.values,c.value];if(f.remaining.length){this.frames.push({...f,values,remaining:[]});enter(f.remaining[0],false);}
     else this.control={kind:'Ready',node:f.node,operation:f.operation,values,tail:f.tail};}
   }
  } else if(c.kind==='Ready') {
   if(c.operation==='add') {const n=BigInt(c.values[0][1])+BigInt(c.values[1][1]);if(n<-(1n<<63n)||n>=(1n<<63n))this.control={kind:'Unwind',code:'Overflow'};else value(['int',String(n)]);}
   else {
    const [closure,arg]=c.values,code=this.codes.get(closure.code_id);if(!code||closure.capture_support.length)throw new Error('Invalid closure');
    if(!c.tail)this.frames.push({kind:'Return',node:c.node,env:this.env});
    this.env=new Map(closure.captures);this.env.set(code.parameter,arg);enter(code.body,true);
   }
  } else if(c.kind==='Unwind') {if(this.frames.length)this.env=this.frames.pop().env;else this.control={kind:'Join',outcome:['Trap',c.code]};}
  else if(c.kind==='Join') {events.push({kind:'ScopeExit',outcome:c.outcome});this.control={kind:'Terminate',outcome:c.outcome};}
  else if(c.kind==='Terminate') {events.push({kind:'TaskTermination',outcome:c.outcome});this.terminal=c.outcome;this.control={kind:'Terminal'};}
  else throw new Error('Invalid control');
  return {epoch:String(this.epoch++),site,after:this.control.kind,depth:String(this.frames.length),events};
 }
 run(fuel=200) {if(!Number.isSafeInteger(fuel)||fuel<0)throw new Error('Invalid fuel');const steps=[];while(!this.terminal&&steps.length<fuel)steps.push(this.step());return {execution:this.terminal?'Completed':'BudgetExhausted',outcome:this.terminal,steps,descriptors:this.descriptors};}
}
