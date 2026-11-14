// Independent UNQUALIFIED implementation of TC1 slice H1: the TC0-A pure-call
// language plus user effects with tail-resumptive handlers (spec/tc1/EFFECTS.md).
// No model, oracle or validator imports. Written separately from
// runtime/tc0/pure-call-machine.mjs; it shares no code with it.
//
// Injected defects, for the harness to detect (never enabled by default):
//   forgottenResume            clause return discards the suspended segment
//   doubleResume               clause return restores the suspended segment twice
//   outermostHandler           perform selects the outermost matching handler
//   dynamicClauseEnvironment   a clause sees the perform site's bindings

const MIN=-(1n<<63n),MAX=(1n<<63n)-1n;

// Operand expressions of a strict form, in evaluation order.
function operands(e) {
  const [tag,,...x]=e;
  if(tag==='prim')return x.slice(1);
  if(tag==='construct')return x.slice(2);
  if(tag==='apply'||tag==='tuple')return x;
  if(tag==='project')return [x[0]];
  if(tag==='call'||tag==='emit')return [x[1]];
  if(tag==='perform')return [x[2]];
  return [];
}

// Free bindings of an expression given the bindings already bound.
function free(e,bound,out) {
  const [tag,,...x]=e;
  if(tag==='var'){if(!bound.has(x[0]))out.add(x[0]);}
  else if(tag==='let'){free(x[1],bound,out);free(x[2],new Set([...bound,x[0]]),out);}
  else if(tag==='if')for(const c of x)free(c,bound,out);
  else if(tag==='lambda')free(x[5],new Set([...bound,x[0]]),out);
  else if(tag==='match'){free(x[0],bound,out);for(const [,binders,body] of x.slice(1))free(body,new Set([...bound,...binders]),out);}
  else if(tag==='handle'){for(const [,binder,body] of x[1])free(body,new Set([...bound,binder]),out);free(x[2],bound,out);}
  else for(const c of operands(e))free(c,bound,out);
  return out;
}

// Every lambda in an expression, keyed by its node ID.
function lambdas(e,codes) {
  const [tag,node,...x]=e;
  if(tag==='lambda'){codes.set(node,{parameter:x[0],body:x[5]});lambdas(x[5],codes);}
  else if(tag==='let'){lambdas(x[1],codes);lambdas(x[2],codes);}
  else if(tag==='if')for(const c of x)lambdas(c,codes);
  else if(tag==='match'){lambdas(x[0],codes);for(const arm of x.slice(1))lambdas(arm[2],codes);}
  else if(tag==='handle'){for(const clause of x[1])lambdas(clause[2],codes);lambdas(x[2],codes);}
  else for(const c of operands(e))lambdas(c,codes);
}

// Structural equality on equality-compatible values (no closures).
function equal(a,b) {
  if(a.length!==b.length)return false;
  return a.every((x,i)=>Array.isArray(x)?Array.isArray(b[i])&&equal(x,b[i]):x===b[i]);
}

export class HandlerMachine {
  constructor(artifact,input,{forgottenResume=false,doubleResume=false,outermostHandler=false,dynamicClauseEnvironment=false}={}) {
    this.options={forgottenResume,doubleResume,outermostHandler,dynamicClauseEnvironment};
    this.functions=new Map(artifact.functions.map(f=>[f.name,f]));
    this.codes=new Map();
    for(const f of artifact.functions){this.codes.set(f.id,{parameter:f.parameter_id,body:f.body});lambdas(f.body,this.codes);}
    const entry=this.functions.get(artifact.entry);
    this.env=new Map([[entry.parameter_id,input]]);
    this.frames=[];            // innermost frame last
    this.control={kind:'Eval',expr:entry.body,tail:true};
    this.epoch=0n;this.terminal=null;this.events=[];this.descriptors=[];
  }

  site() {
    const c=this.control,top=this.frames.at(-1);
    if(c.kind==='Eval')return {node:c.expr[1],rule:'Dispatch'};
    if(c.kind==='Ready')return {node:c.node,rule:'Ready'};
    if(c.kind==='Value'&&top)return {node:top.node,rule:top.kind+'Return'};
    if(c.kind==='Unwind'&&top)return {node:top.node,rule:'UnwindFrame'};
    if(c.kind==='Value'||c.kind==='Unwind')return {machine:'RootJoinEntry',rule:c.kind};
    return {machine:c.kind,rule:c.kind};
  }

  bind(env,id,value){const next=new Map(env);next.set(id,value);return next;}
  produce(value){this.control={kind:'Value',value};}
  enter(expr,tail){this.control={kind:'Eval',expr,tail};}
  trap(code){this.control={kind:'Unwind',code};}

  dispatch(expr,tail) {
    const [tag,node,...x]=expr;
    if(tag==='unit'||tag==='bool'||tag==='int'||tag==='bytes')return this.produce([tag,...x]);
    if(tag==='var'){if(!this.env.has(x[0]))throw new Error('Unknown binding');return this.produce(this.env.get(x[0]));}
    if(tag==='lambda') {
      const ids=[...free(x[5],new Set([x[0]]),new Set())].sort((a,b)=>BigInt(a)<BigInt(b)?-1:1);
      const closure={code_id:node,captures:ids.map(id=>{if(!this.env.has(id))throw new Error('Missing capture');return [id,this.env.get(id)];}),capture_support:[]};
      this.descriptors.push(closure);return this.produce(closure);
    }
    if(tag==='let'){this.frames.push({kind:'Let',node,binding:x[0],body:x[2],env:this.env,tail});return this.enter(x[1],false);}
    if(tag==='if'){this.frames.push({kind:'If',node,yes:x[1],no:x[2],env:this.env,tail});return this.enter(x[0],false);}
    if(tag==='match'){this.frames.push({kind:'Match',node,arms:x.slice(1),env:this.env,tail});return this.enter(x[0],false);}
    if(tag==='handle') {
      // The handler frame is the body's return destination.
      this.frames.push({kind:'Handle',node,effect:x[0],clauses:x[1],env:this.env});
      return this.enter(x[2],true);
    }
    const strict={prim:x[0],construct:'construct',apply:'apply',tuple:'tuple',project:'project',call:'call',emit:'emit',perform:'perform'};
    if(!Object.hasOwn(strict,tag))throw new Error('Unsupported expression');
    const metadata=tag==='call'||tag==='emit'?x[0]:tag==='project'?x[1]:tag==='construct'?[x[0],x[1]]:tag==='perform'?[x[0],x[1]]:null;
    const pending=operands(expr),frame={kind:'Collect',node,operation:strict[tag],metadata,pending,values:[],env:this.env,tail};
    if(!pending.length){this.control={kind:'Ready',node,operation:frame.operation,metadata,values:[],tail};return;}
    this.frames.push(frame);this.enter(pending[0],false);
  }

  returnTo(frame,value,events) {
    if(frame.kind==='Let'){this.env=this.bind(frame.env,frame.binding,value);return this.enter(frame.body,frame.tail);}
    if(frame.kind==='If'){this.env=frame.env;return this.enter(value[1]?frame.yes:frame.no,frame.tail);}
    if(frame.kind==='Match') {
      const arm=frame.arms.find(arm=>arm[0]===value[2]);if(!arm)throw new Error('No match arm');
      let env=frame.env;arm[1].forEach((binder,i)=>{env=this.bind(env,binder,value[3+i]);});
      this.env=env;return this.enter(arm[2],frame.tail);
    }
    if(frame.kind==='Return'||frame.kind==='Handle'){this.env=frame.env;return this.produce(value);}
    if(frame.kind==='Clause') {
      // Resume: the suspended segment goes back on top of the outer frames and the
      // perform site receives the clause's value.
      if(!this.options.forgottenResume)this.frames.push(...frame.segment);
      if(this.options.doubleResume)this.frames.splice(this.frames.length-frame.segment.length,0,...frame.segment);
      this.env=frame.env;events.push({kind:'Resume',task:'0',node:frame.node,value});return this.produce(value);
    }
    // Collect: store the value and enter the next operand, or become Ready.
    this.env=frame.env;
    const values=[...frame.values,value],pending=frame.pending.slice(1);
    if(pending.length){this.frames.push({...frame,values,pending});return this.enter(pending[0],false);}
    this.control={kind:'Ready',node:frame.node,operation:frame.operation,metadata:frame.metadata,values,tail:frame.tail};
  }

  call(parameter,body,captures,argument,node,tail) {
    if(!tail)this.frames.push({kind:'Return',node,env:this.env});
    this.env=this.bind(new Map(captures),parameter,argument);this.enter(body,true);
  }

  perform(c,events) {
    const [effect,operation]=c.metadata,argument=c.values[0];
    const matches=this.frames.map((f,i)=>f.kind==='Handle'&&f.effect===effect?i:-1).filter(i=>i>=0);
    if(!matches.length)throw new Error('Unhandled effect');
    const at=this.options.outermostHandler?matches[0]:matches.at(-1),handler=this.frames[at];
    const clause=handler.clauses.find(clause=>clause[0]===operation);if(!clause)throw new Error('No clause');
    // Suspend everything from the selected handler up to the perform site.
    const segment=this.frames.splice(at);
    this.frames.push({kind:'Clause',node:c.node,segment,env:this.env});
    events.push({kind:'Perform',task:'0',node:c.node,effect,operation,value:argument});
    this.env=this.bind(this.options.dynamicClauseEnvironment?this.env:handler.env,clause[1],argument);
    this.enter(clause[2],true);
  }

  ready(c,events) {
    const v=c.values,op=c.operation;
    if(op==='call'){const f=this.functions.get(c.metadata),code=this.codes.get(f.id);return this.call(code.parameter,code.body,[],v[0],c.node,c.tail);}
    if(op==='apply'){const code=this.codes.get(v[0].code_id);if(!code)throw new Error('Unknown code');return this.call(code.parameter,code.body,v[0].captures,v[1],c.node,c.tail);}
    if(op==='perform')return this.perform(c,events);
    if(op==='emit') {
      const identity={task:'0',node:c.node};
      events.push({kind:'Invoke',...identity,operation:'emit',label:c.metadata,value:v[0]},{kind:'Emit',...identity,label:c.metadata,value:v[0]},{kind:'Commit',...identity,operation:'emit',value:['unit']});
      return this.produce(['unit']);
    }
    if(op==='tuple')return this.produce(['tuple',...v]);
    if(op==='construct')return this.produce(['data',...c.metadata,...v]);
    if(op==='project')return this.produce(v[0][Number(c.metadata)+1]);
    if(op==='not')return this.produce(['bool',!v[0][1]]);
    if(op==='eq')return this.produce(['bool',equal(v[0],v[1])]);
    if(op==='bytes_length')return this.produce(['int',String(v[0][1].length/2)]);
    if(op==='bytes_concat')return this.produce(['bytes',v[0][1]+v[1][1]]);
    if(op==='bytes_index') {
      const i=BigInt(v[1][1]),hex=v[0][1];
      if(i<0n||i>=BigInt(hex.length/2))return this.trap('Bounds');
      return this.produce(['int',String(parseInt(hex.substr(Number(i)*2,2),16))]);
    }
    const a=BigInt(v[0][1]),b=v.length>1?BigInt(v[1][1]):0n;
    if(op==='lt'||op==='le'||op==='gt'||op==='ge')return this.produce(['bool',op==='lt'?a<b:op==='le'?a<=b:op==='gt'?a>b:a>=b]);
    if(op==='div'&&b===0n)return this.trap('DivZero');
    const n=op==='add'?a+b:op==='sub'?a-b:op==='mul'?a*b:op==='div'?a/b:op==='neg'?-a:null;
    if(n===null)throw new Error('Primitive');
    if(n<MIN||n>MAX)return this.trap('Overflow');
    this.produce(['int',String(n)]);
  }

  step() {
    if(this.terminal)throw new Error('Already terminal');
    const c=this.control,site=this.site(),events=[];
    if(c.kind==='Eval')this.dispatch(c.expr,c.tail);
    else if(c.kind==='Value') {
      if(this.frames.length)this.returnTo(this.frames.pop(),c.value,events);
      else this.control={kind:'Join',outcome:['Ok',c.value]};
    } else if(c.kind==='Ready')this.ready(c,events);
    else if(c.kind==='Unwind') {
      if(!this.frames.length)this.control={kind:'Join',outcome:['Trap',c.code]};
      else {
        // One frame per step. A clause frame gives back its suspended segment to be unwound next.
        const frame=this.frames.pop();
        if(frame.kind==='Clause')this.frames.push(...frame.segment);
        this.env=frame.env;
      }
    } else if(c.kind==='Join'){events.push({kind:'ScopeExit',task:'0',scope:'0',outcome:c.outcome});this.control={kind:'Terminate',outcome:c.outcome};}
    else if(c.kind==='Terminate'){events.push({kind:'TaskTermination',task:'0',outcome:c.outcome});this.terminal=c.outcome;this.control={kind:'Terminal'};}
    else throw new Error('Control');
    this.events.push(...events);
    return {epoch:String(this.epoch++),site,after:this.control.kind,depth:String(this.frames.length),events};
  }

  run(fuel=200) {
    if(!Number.isSafeInteger(fuel)||fuel<0)throw new TypeError('Fuel');
    const steps=[];
    while(!this.terminal&&steps.length<fuel)steps.push(this.step());
    return {execution:this.terminal?'Completed':'BudgetExhausted',outcome:this.terminal,steps,events:[...this.events],descriptors:this.descriptors};
  }
}
