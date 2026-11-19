// Independent UNQUALIFIED implementation of TC1-D1: the TC1 handler machine plus
// durable effects that the host discharges. Contract: spec/tc1/DURABLE.md.
// No model, oracle or validator imports. It reuses the JavaScript handler machine
// (runtime/tc1/handler-machine.mjs) by extension; every step that is not a host
// request or a host reply is that machine's step.
//
// The host drives a run: run(fuel, host) with host an array of replies (in order) or
// a function from a request {seq, effect, operation, value} to a reply. A reply is a
// JSON value in the artifact's value encoding; it is checked against the operation's
// result type before the program sees it (DURABLE.md section 5).
//
// Injected defects, for the harness to detect (never enabled by default):
//   doubleReply        the continuation is resumed with the reply a second time when the
//                      program would otherwise finish
//   lateRequestRecord  the HostRequest observation is recorded after the next events
//                      that follow the reply (it moves past later emits)
//   earlyRequest       the request is observed when the perform is dispatched, before its
//                      argument is evaluated (the argument is filled in afterwards)
//   hostFirst          a durable perform goes to the host even when a user handler for
//                      its effect is active
//   staleHandler       a residual perform is routed to the last removed user handler of
//                      its effect, as if it were still installed outermost
//   uncheckedReply     replies are not type-checked at the boundary
//   seqReuse           every request carries sequence number 0
import {HandlerMachine} from './handler-machine.mjs';

const TRAP_CODES=new Set(['Overflow','DivZero','Bounds','InvalidDuration','TaskLimit','ChildFailed']);
const I64_MIN=-(1n<<63n),I64_MAX=(1n<<63n)-1n;
const DEFECTS=['doubleReply','lateRequestRecord','earlyRequest','hostFirst','staleHandler','uncheckedReply','seqReuse'];

export class DurableMachine extends HandlerMachine {
  constructor(artifact,input,options={}) {
    const defects={},base={};
    for(const [k,v] of Object.entries(options))(DEFECTS.includes(k)?defects:base)[k]=v;
    super(artifact,input,base);
    this.defects=defects;
    // Result type of every operation of every durable effect.
    this.durable=new Map(artifact.effects.filter(e=>e.class==='durable').map(e=>[e.name,new Map(e.operations.map(o=>[o.name,o.result_type]))]));
    this.datatypes=new Map(artifact.datatypes.map(d=>[d.name,d]));
    this.requests=0;this.removed=new Map();this.held=null;this.snapshot=null;this.early=null;
  }

  // A perform of a durable effect is a host request when no active handler for the
  // effect is in the frames (DURABLE.md section 3). Inactive handlers are held inside
  // clause frames and resumptions, not in the frame list.
  residual(effect) {
    if(!this.durable.has(effect))return false;
    if(this.defects.hostFirst)return true;
    return !this.frames.some(f=>f.kind==='Handle'&&f.effect===effect);
  }

  ready(c,events) {
    if(c.operation!=='perform'||!this.residual(c.metadata[0]))return super.ready(c,events);
    const [effect,operation]=c.metadata;
    if(this.defects.staleHandler&&this.removed.has(effect)){this.frames.unshift(this.removed.get(effect));return this.perform(c);}
    const seq=String(this.defects.seqReuse?0:this.requests++);
    const request={kind:'HostRequest',task:'0',node:c.node,seq,effect,operation,value:c.values[0]};
    this.control={kind:'HostWait',node:c.node,effect,operation,seq,request};
    if(this.early){Object.assign(this.early,{seq,value:c.values[0]});this.early=null;}
    else if(this.defects.lateRequestRecord)this.held=request;
    else events.push(request);
  }

  returnTo(frame,value,events) {
    if(frame.kind==='Handle'&&this.durable.has(frame.effect))this.removed.set(frame.effect,frame);
    return super.returnTo(frame,value,events);
  }

  site() {
    return this.control.kind==='HostWait'?{node:this.control.node,rule:'HostReply'}:super.site();
  }

  step() {
    const c=this.control;
    if(c.kind==='HostWait')throw new Error('Awaiting the host');
    if(this.defects.doubleReply&&this.snapshot&&c.kind==='Value'&&!this.frames.length) {
      // The second resumption of the same continuation with the same reply.
      const s=this.snapshot;this.snapshot=null;
      this.frames=[...s.frames];this.env=s.env;this.control={kind:'Value',value:s.value};
      return this.record({node:s.node,rule:'HostReply'},[{kind:'HostReply',task:'0',node:s.node,seq:s.seq,value:s.value}]);
    }
    let early=null;
    if(this.defects.earlyRequest&&c.kind==='Eval'&&c.expr[0]==='perform'&&this.residual(c.expr[2]))
      early={kind:'HostRequest',task:'0',node:c.expr[1],seq:null,effect:c.expr[2],operation:c.expr[3],value:null};
    const record=super.step();
    if(early){record.events.unshift(early);this.events.push(early);this.early=early;}
    if(this.held&&this.control.kind!=='HostWait'&&record.events.length&&record.site.rule!=='HostReply'){record.events.push(this.held);this.events.push(this.held);this.held=null;}
    return record;
  }

  record(site,events) {
    this.events.push(...events);
    return {epoch:String(this.epoch++),site,after:this.control.kind,depth:String(this.frames.length),events};
  }

  // The host's reply to the pending request: the HostReply step, or {violation} when the
  // reply is not a value of the operation's result type (no step is taken).
  reply(value) {
    const c=this.control;
    if(c.kind!=='HostWait')throw new Error('No request is pending');
    const type=this.durable.get(c.effect).get(c.operation);
    const wrong=this.defects.uncheckedReply?null:this.illTyped(value,type,[]);
    if(wrong)return {violation:wrong};
    if(this.defects.doubleReply)this.snapshot={frames:[...this.frames],env:this.env,value,node:c.node,seq:c.seq};
    this.control={kind:'Value',value};
    return this.record({node:c.node,rule:'HostReply'},[{kind:'HostReply',task:'0',node:c.node,seq:c.seq,value}]);
  }

  // null when v is a value of type t (DURABLE.md section 5), else the path to the first
  // ill-typed component.
  illTyped(v,t,path) {
    const bad=()=>path.length?path:['root'];
    if(!Array.isArray(v)||typeof v[0]!=='string')return bad();
    if(t==='Unit')return v.length===1&&v[0]==='unit'?null:bad();
    if(t==='Bool')return v.length===2&&v[0]==='bool'&&typeof v[1]==='boolean'?null:bad();
    if(t==='I64'){
      if(v.length!==2||v[0]!=='int'||typeof v[1]!=='string'||!/^(0|-?[1-9][0-9]*)$/.test(v[1]))return bad();
      const n=BigInt(v[1]);return n>=I64_MIN&&n<=I64_MAX?null:bad();
    }
    if(t==='Bytes')return v.length===2&&v[0]==='bytes'&&typeof v[1]==='string'&&/^(?:[0-9a-f]{2})*$/.test(v[1])?null:bad();
    if(t==='TrapCode')return v.length===3&&v[0]==='data'&&v[1]==='TrapCode'&&TRAP_CODES.has(v[2])?null:bad();
    if(Array.isArray(t)&&t[0]==='Tuple') {
      if(v[0]!=='tuple'||v.length!==t.length)return bad();
      for(let i=1;i<t.length;i++){const w=this.illTyped(v[i],t[i],[...path,i-1]);if(w)return w;}
      return null;
    }
    if(Array.isArray(t)&&t[0]==='Data') {
      const d=this.datatypes.get(t[1]),c=d&&v[0]==='data'&&v[1]===t[1]?d.constructors.find(c=>c.name===v[2]):null;
      if(!c||v.length!==3+c.fields.length)return bad();
      for(let i=0;i<c.fields.length;i++){const w=this.illTyped(v[3+i],c.fields[i],[...path,i]);if(w)return w;}
      return null;
    }
    return bad();
  }

  // {execution, outcome, steps, events, violation}: execution Completed, BudgetExhausted,
  // AwaitingHost (the host gave no reply) or HostViolation.
  run(fuel=200,host=[]) {
    if(!Number.isSafeInteger(fuel)||fuel<0)throw new TypeError('Fuel');
    const steps=[],replies=Array.isArray(host)?[...host]:null;let execution=null,violation=null;
    while(!this.terminal&&steps.length<fuel){
      if(this.control.kind!=='HostWait'){steps.push(this.step());continue;}
      const {seq,effect,operation,request}=this.control;
      if(replies&&!replies.length){execution='AwaitingHost';break;}
      const r=this.reply(replies?replies.shift():host({seq,effect,operation,value:request.value}));
      if(r.violation){execution='HostViolation';violation=r.violation;break;}
      steps.push(r);
    }
    execution??=this.terminal?'Completed':'BudgetExhausted';
    return {execution,outcome:this.terminal,steps,events:[...this.events],descriptors:this.descriptors,violation};
  }
}
