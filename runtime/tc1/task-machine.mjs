// Independent UNQUALIFIED implementation of TC1 slice C1: structured tasks and bounded
// channels. Contract: spec/tc1/CONCURRENCY.md. Written from that text, not from the
// Shen model. No model, oracle or validator imports.
//
// Each task is a Thread: the TC1 handler machine (runtime/tc1/handler-machine.mjs),
// reused by inheritance for every step that is not one of C1's, on the thread's own
// control, environment and frames. The TaskMachine owns what is shared: the task
// table, scopes, channels, pending awaits and the three ID counters. step(id) runs one
// step of task `id`; the schedule is the caller's.
//
// Injected defects, for the harness to detect (never enabled by default):
//   staleWaiter        a cancellation request leaves the blocked receiver or sender registered
//   waiterNotWoken     stabilization commits an item to a waiting receiver but leaves it Blocked
//   waiterWokenTwice   stabilization serves a receiver without removing its registration
//   eagerCancel        a pending cancellation is delivered at any step of normal control
//   lifoChannel        receive takes the newest queued value instead of the oldest
//   noSiblingCancel    a child's trap latches its scope but requests no sibling cancellation
//   capacityOffByOne   a channel holds one value more than its capacity
//   lostWakeupClose    a first close does not commit End to waiting receivers
//   lostWakeupAwait    a terminating task does not commit its outcome to pending awaits
import {HandlerMachine} from './handler-machine.mjs';

export class ScheduleError extends Error {}
const RUNTIME=new Set(['spawn','await','cancel','yield','channel','send','receive','close']);
const TRAP_NAME={DivZero:'DivZero',Overflow:'Overflow',Bounds:'Bounds',ChildFailed:'ChildFailed'};
const numeric=(a,b)=>BigInt(a)<BigInt(b)?-1:BigInt(a)>BigInt(b)?1:0;

// The bindings an expression uses that `bound` does not bind.
function freeIn(e,bound,out) {
  const [tag,,...x]=e;
  const all=es=>{for(const c of es)freeIn(c,bound,out);};
  if(tag==='var'){if(!bound.has(x[0]))out.add(x[0]);}
  else if(['unit','bool','int','bytes','yield','channel','discontinue'].includes(tag)){}
  else if(tag==='let'){freeIn(x[1],bound,out);freeIn(x[2],new Set([...bound,x[0]]),out);}
  else if(tag==='lambda')freeIn(x[5],new Set([...bound,x[0]]),out);
  else if(tag==='match'){freeIn(x[0],bound,out);for(const [,binders,body] of x.slice(1))freeIn(body,new Set([...bound,...binders]),out);}
  else if(tag==='handle'){for(const clause of x[1])freeIn(clause.at(-1),new Set([...bound,...clause.slice(1,-1)]),out);freeIn(x[2],bound,out);}
  else if(tag==='prim')all(x.slice(1));
  else if(tag==='construct')all(x.slice(2));
  else if(tag==='call'||tag==='emit'||tag==='resume')freeIn(x[1],bound,out);
  else if(tag==='perform')freeIn(x[2],bound,out);
  else if(tag==='project')freeIn(x[0],bound,out);
  else all(x); // tuple, if, apply and C1's scope, spawn, await, cancel, send, receive, close
  return out;
}

// One task's local machine. The parent class steps pure control; this class only adds
// the dispatch of C1's strict forms and the routing of their Ready step to the machine.
class Thread extends HandlerMachine {
  constructor(machine,artifact,input) {
    super(artifact,input);this.machine=machine;
    // The parent class finds the lambdas under the forms it knows; C1's forms hold more.
    const walk=e=>{if(!Array.isArray(e))return;if(e[0]==='lambda'&&typeof e[1]==='string'&&e.length===8)this.codes.set(e[1],{parameter:e[2],body:e[7]});for(const x of e)walk(x);};
    for(const f of artifact.functions)walk(f.body);
  }
  dispatch(expr,tail) {
    const [tag,node,...x]=expr;
    if(tag==='lambda') {
      // Captures in increasing binding-ID order, found by a walk that knows C1's forms.
      const ids=[...freeIn(x[5],new Set([x[0]]),new Set())].sort(numeric);
      return this.produce({code_id:node,captures:ids.map(id=>{if(!this.env.has(id))throw new Error('Missing capture');return [id,this.env.get(id)];}),capture_support:[]});
    }
    if(!RUNTIME.has(tag))return super.dispatch(expr,tail);
    // Operands left to right; yield and channel have none, so they are Ready at once.
    const pending=tag==='channel'||tag==='yield'?[]:x,metadata=tag==='channel'?x[1]:null;
    if(!pending.length){this.control={kind:'Ready',node,operation:tag,metadata,values:[],tail};return;}
    this.frames.push({kind:'Collect',node,operation:tag,metadata,pending,values:[],env:this.env,tail});
    this.enter(pending[0],false);
  }
}

export class TaskMachine {
  constructor(artifact,input,options={}) {
    if(artifact?.schema_version!=='tc1-task-demo/1'||artifact.slice!=='TC1-C1')throw new TypeError('TC1-C1 artifact required');
    this.options={...options};this.artifact=artifact;this.input=input;
    this.tasks=new Map();this.scopes=new Map();this.channels=new Map();this.awaits=[];
    this.counters={task:1n,scope:1n,channel:0n};this.epoch=0n;this.events=[];this.becameRunnable=[];
    const root=new Thread(this,artifact,input);
    // The root's implicit scope 0 is the bottom frame of its continuation.
    root.frames.unshift({kind:'Scope',node:null,scope:'0'});
    this.addTask('0',root,null);this.addScope('0','0');
  }

  addTask(id,thread,owningScope){this.tasks.set(id,{id,thread,status:'Runnable',cancel:'None',owningScope,outcome:null});}
  addScope(id,owner){this.scopes.set(id,{id,owner,phase:'Open',reason:null,children:[],failed:false,failures:[],joinWaiting:false});}
  fresh(space){const id=String(this.counters[space]);this.counters[space]++;return id;}
  runnable(){return [...this.tasks.values()].filter(t=>t.status==='Runnable').map(t=>t.id).sort(numeric);}
  root(){return this.tasks.get('0');}
  terminal(){return this.root().status==='Terminal';}
  makeRunnable(task){task.status='Runnable';this.becameRunnable.push(task.id);}

  // ---------- one step ----------
  step(id) {
    const task=this.tasks.get(id);
    if(!task||task.status!=='Runnable')throw new ScheduleError(`Task ${id} is not Runnable`);
    const th=task.thread,c=th.control,top=th.frames.at(-1),events=[];this.becameRunnable=[];
    let site,point=true;
    const normal=['Eval','Value','Ready'].includes(c.kind);
    if(this.options.eagerCancel&&task.cancel==='Requested'&&normal&&!(top?.kind==='Scope'&&c.kind==='Value')) {
      site=th.site();this.deliver(task,events);point=false;
    }
    else if(c.kind==='Start') {
      site={machine:'TaskStart',rule:'TaskStart'};
      if(task.cancel==='Requested')this.deliver(task,events);
      else {
        const code=th.codes.get(c.closure.code_id);
        th.env=th.bind(new Map(c.closure.captures),code.parameter,['unit']);th.enter(code.body,true);
      }
    }
    else if(c.kind==='Eval'&&c.expr[0]==='scope') {
      site={node:c.expr[1],rule:'Dispatch'};
      if(task.cancel==='Requested')this.deliver(task,events);
      else {
        const scope=this.fresh('scope');this.addScope(scope,id);
        th.frames.push({kind:'Scope',node:c.expr[1],scope});th.enter(c.expr[2],true);
        events.push({kind:'ScopeEnter',task:id,scope});
      }
    }
    else if(c.kind==='Ready'&&RUNTIME.has(c.operation)) {
      site={node:c.node,rule:'Ready'};
      if(task.cancel==='Requested')this.deliver(task,events);
      else this.operation(task,c,events);
    }
    else if(c.kind==='Pending'||c.kind==='Wait') {
      site={node:c.node,rule:'Wake'};
      if(task.cancel==='Requested')this.deliver(task,events);
      else if(c.kind==='Pending')th.produce(c.value);
      else throw new Error('Wait without a cancellation request');
    }
    else if(top?.kind==='Scope'&&c.kind==='Value') {
      site=this.scopeSite(top,'ScopeClose');point=false;
      const s=this.scopes.get(top.scope);s.phase='Joining';s.reason={kind:'Normal',value:c.value};th.control={kind:'Join'};
    }
    else if(top?.kind==='Scope'&&(c.kind==='Unwind'||c.kind==='Abandon')) {
      site=this.scopeSite(top,'ScopeAbort');
      const s=this.scopes.get(top.scope);s.phase='Joining';
      s.reason=c.kind==='Abandon'?{kind:'Abandon'}:c.code==='Cancelled'?{kind:'Cancelled'}:{kind:'Trap',code:c.code};
      this.requestEach(id,s.children,events);th.control={kind:'Join'};
    }
    else if(c.kind==='Join') {site=this.scopeSite(top,'Join');this.join(task,top,events);}
    else if(!th.frames.length&&(c.kind==='Value'||c.kind==='Unwind')) {
      site={machine:'Terminate',rule:'Terminate'};
      this.terminate(task,c.kind==='Value'?['Ok',c.value]:c.code==='Cancelled'?['Cancelled']:['Trap',c.code],events);
    }
    else {
      // A step of the handler machine. Only emit has events there; C1 keeps Emit alone.
      point=false;
      const record=th.step();site=record.site;
      for(const e of record.events)if(e.kind==='Emit')events.push({kind:'Emit',task:id,label:e.label,value:e.value});
    }
    this.events.push(...events);
    return {epoch:String(this.epoch++),task:id,site,after:th.control.kind,depth:String(th.frames.length),events,point,runnable:this.runnable()};
  }

  scopeSite(frame,rule){return frame.node===null?{machine:'TaskScope',rule}:{node:frame.node,rule};}

  // ---------- cancellation (section 6) ----------
  deliver(task,events){task.cancel='Delivered';events.push({kind:'CancelEffective',task:task.id});task.thread.control={kind:'Unwind',code:'Cancelled'};}

  request(requester,targetId,events) {
    const t=this.tasks.get(targetId);
    if(t.status==='Terminal'||t.cancel!=='None'){events.push({kind:'CancelRequest',task:requester,target:targetId,new_request:false});return;}
    t.cancel='Requested';events.push({kind:'CancelRequest',task:requester,target:targetId,new_request:true});
    if(t.status!=='Blocked')return;
    const c=t.thread.control;
    if(c.kind==='Wait') {
      const w=c.waiting;
      if(w.receive!==undefined||w.send!==undefined) {
        const ch=this.channels.get(w.receive??w.send),list=w.receive!==undefined?ch.receivers:ch.senders;
        if(!this.options.staleWaiter){const i=list.findIndex(r=>r.task===targetId);list.splice(i,1);}
        events.push({kind:w.receive!==undefined?'ReceiveRemoved':'SendRemoved',task:targetId,channel:ch.id});
        this.stabilize(ch,events);
      } else {
        this.awaits.splice(this.awaits.findIndex(a=>a.waiter===targetId),1);
        events.push({kind:'AwaitRemoved',task:targetId,target:w.await});
      }
    } else this.scopes.get(t.thread.frames.at(-1).scope).joinWaiting=false; // Join
    this.makeRunnable(t);
  }
  requestEach(requester,ids,events){for(const x of ids)if(this.tasks.get(x).status!=='Terminal')this.request(requester,x,events);}

  // ---------- operations (section 5) ----------
  block(task,node,waiting){task.status='Blocked';task.thread.control={kind:'Wait',node,waiting};}
  commit(waiterId,value) {
    const w=this.tasks.get(waiterId);if(w.status!=='Blocked')return;
    w.thread.control={kind:'Pending',node:w.thread.control.node,value};this.makeRunnable(w);
  }

  operation(task,c,events) {
    const th=task.thread,id=task.id,v=c.values,op=c.operation;
    if(op==='spawn') {
      const owning=th.frames.findLast(f=>f.kind==='Scope').scope,s=this.scopes.get(owning);
      if(s.failed)return th.trap('ChildFailed');
      const child=this.fresh('task'),implicit=this.fresh('scope');
      const ct=new Thread(this,this.artifact,this.input);
      // Copies of the active handler frames, in order, above the child's implicit scope.
      ct.frames=[{kind:'Scope',node:null,scope:implicit},...th.frames.filter(f=>f.kind==='Handle')];
      ct.env=new Map();ct.control={kind:'Start',closure:v[0]};
      s.children.push(child);this.addTask(child,ct,owning);this.addScope(implicit,child);this.becameRunnable.push(child);
      events.push({kind:'Spawn',task:id,child,scope:owning,child_scope:implicit});
      return th.produce({task:child});
    }
    if(op==='await') {
      const target=this.tasks.get(v[0].task);events.push({kind:'Await',task:id,target:target.id});
      if(target.status==='Terminal'){events.push({kind:'Awaited',task:id,target:target.id,outcome:outcomeValue(target.outcome)});return th.produce(outcomeValue(target.outcome));}
      this.awaits.push({waiter:id,target:target.id});events.push({kind:'AwaitWait',task:id,target:target.id});
      return this.block(task,c.node,{await:target.id});
    }
    if(op==='cancel'){this.request(id,v[0].task,events);return th.produce(['unit']);}
    if(op==='yield'){events.push({kind:'Yield',task:id});return th.produce(['unit']);}
    if(op==='channel') {
      const ch=this.fresh('channel');this.channels.set(ch,{id:ch,capacity:BigInt(c.metadata),queue:[],closed:false,senders:[],receivers:[]});
      events.push({kind:'Channel',task:id,channel:ch,capacity:c.metadata});return th.produce({channel:ch});
    }
    const ch=this.channels.get(v[0].channel);
    if(op==='send') {
      events.push({kind:'Send',task:id,channel:ch.id,value:v[1]});
      if(ch.closed){events.push({kind:'SendClosed',task:id,channel:ch.id});return th.produce(['data','SendResult','Closed']);}
      if(this.hasRoom(ch)){ch.queue.push(v[1]);events.push({kind:'Sent',task:id,channel:ch.id});this.stabilize(ch,events);return th.produce(['data','SendResult','Sent']);}
      ch.senders.push({task:id,value:v[1]});events.push({kind:'SendWait',task:id,channel:ch.id});
      return this.block(task,c.node,{send:ch.id});
    }
    if(op==='receive') {
      events.push({kind:'Receive',task:id,channel:ch.id});
      if(ch.queue.length){const x=this.take(ch);events.push({kind:'Received',task:id,channel:ch.id,value:x});this.stabilize(ch,events);return th.produce(['data','ReceiveResult','Item',x]);}
      if(ch.closed){events.push({kind:'End',task:id,channel:ch.id});return th.produce(['data','ReceiveResult','End']);}
      ch.receivers.push({task:id});events.push({kind:'ReceiveWait',task:id,channel:ch.id});
      return this.block(task,c.node,{receive:ch.id});
    }
    // close
    events.push({kind:'Close',task:id,channel:ch.id,first:!ch.closed});
    if(!ch.closed) {
      ch.closed=true;
      for(const s of ch.senders.splice(0)){this.commit(s.task,['data','SendResult','Closed']);events.push({kind:'SendClosed',task:s.task,channel:ch.id});}
      this.stabilize(ch,events);
      if(!ch.queue.length&&!this.options.lostWakeupClose)for(const r of ch.receivers.splice(0)){this.commit(r.task,['data','ReceiveResult','End']);events.push({kind:'End',task:r.task,channel:ch.id});}
    }
    th.produce(['unit']);
  }

  hasRoom(ch){return BigInt(ch.queue.length)<ch.capacity+(this.options.capacityOffByOne?1n:0n);}
  take(ch){return this.options.lifoChannel?ch.queue.pop():ch.queue.shift();}

  // Serve receivers while values are queued, then admit senders while there is room; repeat.
  stabilize(ch,events) {
    for(;;) {
      if(ch.receivers.length&&ch.queue.length) {
        const r=this.options.waiterWokenTwice?ch.receivers[0]:ch.receivers.shift(),x=this.take(ch);
        if(this.options.waiterWokenTwice&&this.tasks.get(r.task).status!=='Blocked')ch.receivers.shift();
        if(this.options.waiterNotWoken){const w=this.tasks.get(r.task);w.thread.control={kind:'Pending',node:w.thread.control.node,value:['data','ReceiveResult','Item',x]};}
        else this.commit(r.task,['data','ReceiveResult','Item',x]);
        events.push({kind:'Received',task:r.task,channel:ch.id,value:x});continue;
      }
      if(!ch.closed&&ch.senders.length&&this.hasRoom(ch)) {
        const s=ch.senders.shift();ch.queue.push(s.value);this.commit(s.task,['data','SendResult','Sent']);
        events.push({kind:'Sent',task:s.task,channel:ch.id});continue;
      }
      return;
    }
  }

  // ---------- scopes, joins, termination (section 7) ----------
  join(task,frame,events) {
    const th=task.thread,s=this.scopes.get(frame.scope);
    if(task.cancel==='Requested'&&s.reason.kind==='Normal') {
      task.cancel='Delivered';events.push({kind:'CancelEffective',task:task.id});
      s.reason={kind:'Cancelled'};this.requestEach(task.id,s.children,events);return;
    }
    if(!s.children.every(x=>this.tasks.get(x).status==='Terminal')){s.joinWaiting=true;task.status='Blocked';return;}
    th.frames.pop();s.phase='Exited';s.joinWaiting=false;
    const r=s.reason;let outcome;
    if(r.kind==='Normal'&&!s.failed){outcome=['Ok',r.value];th.produce(r.value);}
    else if(r.kind==='Normal'){outcome=['Trap','ChildFailed'];th.trap('ChildFailed');}
    else if(r.kind==='Trap'){outcome=['Trap',r.code];th.trap(r.code);}
    else if(r.kind==='Cancelled'){outcome=['Cancelled'];th.trap('Cancelled');}
    else {outcome=['Abandoned'];th.control={kind:'Abandon'};}
    events.push({kind:'ScopeExit',task:task.id,scope:s.id,outcome});
  }

  terminate(task,outcome,events) {
    task.status='Terminal';task.outcome=outcome;task.thread.control={kind:'Terminal'};
    events.push({kind:'Termination',task:task.id,outcome});
    const s=task.owningScope===null?null:this.scopes.get(task.owningScope);
    if(s&&outcome[0]==='Trap') {
      s.failed=true;s.failures.push({task:task.id,code:outcome[1]});s.failures.sort((a,b)=>numeric(a.task,b.task));
      events.push({kind:'ScopeFailure',task:task.id,scope:s.id,code:outcome[1]});
      if(!this.options.noSiblingCancel)this.requestEach(task.id,s.children.filter(x=>x!==task.id),events);
    }
    if(!this.options.lostWakeupAwait) {
      const value=outcomeValue(outcome);
      for(const a of this.awaits.filter(a=>a.target===task.id)){this.commit(a.waiter,value);events.push({kind:'Awaited',task:a.waiter,target:task.id,outcome:value});}
      this.awaits=this.awaits.filter(a=>a.target!==task.id);
    }
    if(s&&s.joinWaiting&&s.children.every(x=>this.tasks.get(x).status==='Terminal')){s.joinWaiting=false;this.makeRunnable(this.tasks.get(s.owner));}
  }

  // ---------- footers ----------
  waitGraph() {
    return [...this.tasks.values()].filter(t=>t.status!=='Terminal').sort((a,b)=>numeric(a.id,b.id)).map(t=>{
      const c=t.thread.control;
      if(c.kind==='Wait'){const [k,x]=Object.entries(c.waiting)[0];return {task:t.id,[k]:x};}
      if(c.kind==='Join')return {task:t.id,join:t.thread.frames.at(-1).scope};
      return {task:t.id,running:true};
    });
  }
  footer(){return this.terminal()?{execution:'Completed',outcome:this.root().outcome}:this.runnable().length?null:{execution:'Deadlock',wait_graph:this.waitGraph()};}
}

// A task outcome as the Outcome value await returns.
export function outcomeValue(o){return o[0]==='Ok'?['data','Outcome','Ok',o[1]]:o[0]==='Cancelled'?['data','Outcome','Cancelled']:['data','Outcome','Failed',['data','TrapCode',TRAP_NAME[o[1]]]];}

// Run under an explicit schedule: one task ID per step. Stops at the end of the schedule,
// at a terminal root, at a deadlock or at a choice that is not Runnable (ScheduleDiverged,
// an orderly report, not a crash).
export function runSchedule(artifact,input,choices,options={},fuel=1000) {
  const m=new TaskMachine(artifact,input,options),steps=[];
  for(const id of choices) {
    if(m.footer()||steps.length>=fuel)break;
    if(!m.runnable().includes(id))return {execution:'ScheduleDiverged',at:String(steps.length),steps};
    steps.push(m.step(id));
  }
  const f=m.footer();
  return f?{...f,steps}:{execution:steps.length>=fuel?'BudgetExhausted':'ScheduleIncomplete',steps};
}
