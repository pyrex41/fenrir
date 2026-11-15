// Hand-assembled UNQUALIFIED programs for TC1 slice C1, contract spec/tc1/CONCURRENCY.md.
// IDs and source-map rows are allocated mechanically. Every expectation below was
// written from the contract text BEFORE either machine (models/tc1/task-machine.shen,
// runtime/tc1/task-machine.mjs) existed or ran; per-schedule expectations were derived
// by hand, step by step, from sections 5-10. Expectations the machines later
// contradicted are recorded in CONTRADICTIONS at the end of this file, with which side
// was wrong. None was edited silently.
//
// A fixture is {name, program, schedules, all, per_schedule}:
//   schedules     the schedules it is run under. A schedule is a policy the batch runner
//                 turns into an explicit list of choices (task IDs, one per step), which
//                 is what both machines then run under:
//                   lowest | highest           the lowest / highest Runnable task ID (reference)
//                   random:N                   seeded uniform choice among Runnable tasks (reference)
//                   fifo                       the production FIFO policy (section 9)
//                   prandom:N                  seeded uniform choice among production-enabled tasks
//                   script                     {script:[{task, until}], then}: run `task` until a step
//                                              emits an event matching `until`, then the next item;
//                                              afterwards the policy `then` (reference)
//   all           expectations that hold under every schedule run
//   per_schedule  expectations for one named schedule
// Expectation keys (checked by harness/tc1-tasks.shen):
//   execution            "Completed" or "Deadlock"
//   outcome              the root outcome, ["Ok",v] or ["Trap",code]
//   terminations         {task: outcome} for tasks that must terminate so
//   terminations_one_of  {task: [outcome...]}
//   emissions            {task: [[label, value]...]}: the task's Emit events in order
//   emissions_one_of     {task: [[[label, value]...]...]}
//   task_kinds           {task: [kind...]}: kinds of the events whose task is that task
//   channel_kinds        {channel: ["Kind:task"...]}: the channel's sequence
//   order                [[P,Q]...]: the first event matching P precedes the first matching Q
//   absent_before        [[P,Q]...]: no event matching P precedes the first event matching Q
//                        (holds vacuously when nothing matches Q)
//   absent               [P...]: no event matches P
//   wait_graph           the deadlock wait graph
// A pattern P matches an event when every field of P is equal in the event.
function fixture(name,build,spec) {
  let next=0n;const locations=[];const fresh=()=>String(next++);
  const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const fn=(fname,argument_type,result_type,effects,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name:fname,parameter_id,argument_type,result_type,effects,body:body(parameter_id)};};
  const functions=build(helpers(node,fresh,fn));
  const program={contract_version:'tc1-draft-1',schema_version:'tc1-task-demo/1',slice:'TC1-C1',module:name,datatypes:[],effects:spec.effects??[],functions,entry:'main',
    input_schema:{type:functions[0].argument_type},source_map:locations.map(id=>({id,file:name,line:'0',column:'0'}))};
  return {name,program,schedules:[...DEFAULT_SCHEDULES,...(spec.schedules??[])],all:spec.all??{},per_schedule:spec.per_schedule??{}};
}
export const DEFAULT_SCHEDULES=Object.freeze(['lowest','highest','fifo','random:1','random:2','random:3','prandom:1','prandom:2'].map(policy=>({name:policy,policy})));
const order=names=>[...names].sort((a,b)=>Buffer.compare(Buffer.from(a),Buffer.from(b)));
function helpers(node,fresh,fn) {
  const h={node,fresh,fn};
  h.int=n=>node('int',String(n));
  h.v=id=>node('var',id);
  // let _ = a in let _ = b in ... in last
  h.seq=(...es)=>es.length===1?es[0]:node('let',fresh(),es[0],h.seq(...es.slice(1)));
  h.lam=(result,effects,body)=>node('lambda',fresh(),'Unit',result,order(effects),[],body);
  h.emit=(label,e)=>node('emit',label,e);
  h.channel=(capacity,type='I64')=>node('channel',type,String(capacity));
  h.send=(c,e)=>node('send',c,e);
  h.receive=c=>node('receive',c);
  // match(receive(c), Item(x) => item(x), End => end)
  h.onReceive=(c,item,end)=>{const x=fresh();return node('match',h.receive(c),['Item',[x],item(x)],['End',[],end]);};
  // match(await(t), Ok(v) => ok(v), Cancelled => cancelled, Failed(c) => failed(c))
  h.onAwait=(t,ok,cancelled,failed)=>{const x=fresh(),c=fresh();return node('match',node('await',t),['Ok',[x],ok(x)],['Cancelled',[],cancelled],['Failed',[c],failed(c)]);};
  h.let=(init,body)=>{const id=fresh();return node('let',id,init,body(id));};
  h.div=(a,b)=>node('prim','div',a,b);
  h.add=(a,b)=>node('prim','add',a,b);
  return h;
}
const int=n=>['int',String(n)];
const ok=n=>['Ok',int(n)];
const trap=code=>['Trap',code];
const CANCELLED=['Cancelled'];
const got=(...ns)=>ns.map(n=>['got',int(n)]);

export const cases=[
  // Two tasks, one channel of capacity 2: a producer sends 1 then 2, a consumer receives
  // twice and emits each item. FIFO order on the channel under every schedule.
  fixture('two-tasks-one-channel',({fn,let:L,channel,lam,seq,send,int,v,onReceive,emit,node})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(2),c=>L(node('spawn',lam('I64',['Channel'],seq(send(v(c),int(1)),send(v(c),int(2)),int(0)))),()=>
      L(node('spawn',lam('I64',['Channel','Emit'],seq(onReceive(v(c),x=>emit('got',v(x)),emit('end',int(0))),onReceive(v(c),x=>emit('got',v(x)),emit('end',int(0))),int(0)))),()=>int(0)))))],
   {all:{execution:'Completed',outcome:ok(0),terminations:{'1':ok(0),'2':ok(0)},emissions:{'0':[],'1':[],'2':got(1,2)}},
    per_schedule:{
      // Root runs until its implicit join blocks; then the producer fills the queue and
      // terminates; then the consumer drains it.
      lowest:{channel_kinds:{'0':['Channel:0','Send:1','Sent:1','Send:1','Sent:1','Receive:2','Received:2','Receive:2','Received:2']},
        task_kinds:{'0':['Channel','Spawn','Spawn','ScopeExit','Termination'],'1':['Send','Sent','Send','Sent','ScopeExit','Termination']}}}}),

  // A receive on an empty channel blocks; the later send commits the item to the waiting
  // receiver in the sender's step, and the receiver consumes it on its Wake step.
  fixture('blocking-receive-on-empty',({fn,let:L,channel,lam,seq,send,int,v,onReceive,emit,node})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel','Emit'],seq(onReceive(v(c),x=>emit('got',v(x)),emit('end',int(0))),int(0)))),()=>
      L(node('spawn',lam('I64',['Channel'],seq(send(v(c),int(5)),int(0)))),()=>int(0)))))],
   {all:{execution:'Completed',outcome:ok(0),emissions:{'1':got(5)}},
    per_schedule:{lowest:{channel_kinds:{'0':['Channel:0','Receive:1','ReceiveWait:1','Send:2','Sent:2','Received:1']},
      task_kinds:{'1':['Receive','ReceiveWait','Received','Emit','ScopeExit','Termination'],'2':['Send','Sent','ScopeExit','Termination']},
      order:[[{kind:'ReceiveWait',task:'1'},{kind:'Send',task:'2'}]]}}}),

  // A send on a full channel (capacity 1) blocks until a receive makes room; the receive
  // admits the waiting sender's value in its own step.
  fixture('blocking-send-on-full',({fn,let:L,channel,lam,seq,send,int,v,onReceive,emit,node})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel'],seq(send(v(c),int(1)),send(v(c),int(2)),send(v(c),int(3)),int(0)))),()=>
      L(node('spawn',lam('I64',['Channel','Emit'],seq(...[1,2,3].map(()=>onReceive(v(c),x=>emit('got',v(x)),emit('end',int(0)))),int(0)))),()=>int(0)))))],
   {all:{execution:'Completed',outcome:ok(0),emissions:{'2':got(1,2,3)},terminations:{'1':ok(0),'2':ok(0)}},
    per_schedule:{lowest:{task_kinds:{'1':['Send','Sent','Send','SendWait','Sent','Send','SendWait','Sent','ScopeExit','Termination']},
      channel_kinds:{'0':['Channel:0','Send:1','Sent:1','Send:1','SendWait:1','Receive:2','Received:2','Sent:1','Send:1','SendWait:1','Receive:2','Received:2','Sent:1','Receive:2','Received:2']}}}}),

  // await returns the child's outcome, and may be repeated without consuming it.
  fixture('await-child-outcome',({fn,let:L,lam,seq,int,v,emit,node,onAwait,add})=>[fn('main','I64','I64',['Emit','Task'],()=>
    L(node('spawn',lam('I64',['Emit'],seq(emit('child',int(7)),int(7)))),t=>
      onAwait(v(t),a=>onAwait(v(t),b=>add(v(a),v(b)),int(0),()=>int(0)),int(0),()=>int(0))))],
   {all:{execution:'Completed',outcome:ok(14),terminations:{'1':ok(7)},emissions:{'1':[['child',int(7)]]}},
    per_schedule:{
      lowest:{task_kinds:{'0':['Spawn','Await','AwaitWait','Awaited','Await','Awaited','ScopeExit','Termination'],'1':['Emit','ScopeExit','Termination']},
        order:[[{kind:'Termination',task:'1'},{kind:'Awaited',task:'0'}]]},
      highest:{task_kinds:{'0':['Spawn','Await','Awaited','Await','Awaited','ScopeExit','Termination']}}}}),

  // Observing Failed does not acknowledge the failure: the scope still exits ChildFailed.
  fixture('await-failed-child-still-fails-scope',({fn,let:L,lam,seq,int,v,emit,node,onAwait,div})=>[fn('main','I64','I64',['Emit','Task'],()=>
    L(node('spawn',lam('I64',[],div(int(1),int(0)))),t=>onAwait(v(t),()=>int(0),int(1),c=>seq(emit('failed',v(c)),int(2)))))],
   {all:{execution:'Completed',outcome:trap('ChildFailed'),terminations:{'1':trap('DivZero')},emissions:{'0':[['failed',['data','TrapCode','DivZero']]]},
    order:[[{kind:'ScopeFailure',task:'1',scope:'0',code:'DivZero'},{kind:'Termination',task:'0'}]]}}),

  // Cancellation is delivered only at a scheduling point. The child emits a and b with no
  // scheduling point between them, then yields. A request made between a and b (the
  // script) is delivered at the yield: the child emits a and b, never a alone.
  fixture('cancel-delivered-at-scheduling-point',({fn,let:L,lam,seq,int,v,emit,node,onAwait})=>[fn('main','I64','I64',['Emit','Task'],()=>
    L(node('spawn',lam('I64',['Emit','Task'],seq(emit('a',int(0)),emit('b',int(0)),node('yield'),emit('c',int(0)),int(0)))),t=>
      seq(node('cancel',v(t)),onAwait(v(t),()=>int(0),int(1),()=>int(2)))))],
   {schedules:[{name:'cancel-mid-stretch',policy:'script',script:[{task:'0',until:{kind:'Spawn'}},{task:'1',until:{kind:'Emit',label:'a'}},{task:'0',until:{kind:'CancelRequest'}}],then:'lowest'}],
    all:{execution:'Completed',emissions_one_of:{'1':[[],[['a',int(0)],['b',int(0)]],[['a',int(0)],['b',int(0)],['c',int(0)]]]},
      absent:[{kind:'CancelEffective',task:'0'}]},
    per_schedule:{
      'cancel-mid-stretch':{outcome:ok(1),emissions:{'1':[['a',int(0)],['b',int(0)]]},task_kinds:{'1':['Emit','Emit','CancelEffective','ScopeExit','Termination']},
        order:[[{kind:'CancelRequest',task:'0',target:'1',new_request:true},{kind:'Emit',task:'1',label:'b'}]]},
      // Root cancels before the child first runs: TaskStart delivers it; no user code runs.
      lowest:{outcome:ok(1),emissions:{'1':[]},task_kinds:{'1':['CancelEffective','ScopeExit','Termination']}},
      // The child runs to completion before root's request, which then finds it Terminal.
      highest:{outcome:ok(0),emissions:{'1':[['a',int(0)],['b',int(0)],['c',int(0)]]},
        task_kinds:{'0':['Spawn','CancelRequest','Await','Awaited','ScopeExit','Termination']}},
      // FIFO: child TaskStart, then root's cancel, then the child's stretch to its yield.
      fifo:{outcome:ok(1),emissions:{'1':[['a',int(0)],['b',int(0)]]}}}}),

  // A child trap is latched into its scope in the child's terminal step, and its siblings
  // are requested cancelled in that step; the parent body continues.
  fixture('child-trap-cancels-sibling',({fn,let:L,channel,lam,seq,int,v,emit,node,onReceive,div})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Task'],seq(node('yield'),div(int(1),int(0))))),()=>
      L(node('spawn',lam('I64',['Channel','Emit'],seq(emit('b0',int(0)),onReceive(v(c),x=>v(x),int(0)),emit('b1',int(0)),int(0)))),()=>
        seq(emit('root',int(0)),int(0))))))],
   {schedules:[{name:'sibling-blocked',policy:'script',script:[{task:'0',until:{kind:'Emit',label:'root'}},{task:'2',until:{kind:'ReceiveWait'}}],then:'lowest'}],
    all:{execution:'Completed',outcome:trap('ChildFailed'),terminations:{'1':trap('DivZero')},absent:[{kind:'Emit',label:'b1'}],
      absent_before:[[{kind:'CancelRequest',target:'2'},{kind:'Termination',task:'1'}]]},
    per_schedule:{
      lowest:{terminations:{'2':CANCELLED},emissions:{'0':[['root',int(0)]],'2':[]},
        task_kinds:{'1':['Yield','ScopeExit','Termination','ScopeFailure','CancelRequest'],'2':['CancelEffective','ScopeExit','Termination']},
        order:[[{kind:'Emit',task:'0',label:'root'},{kind:'Termination',task:'1'}]]},
      'sibling-blocked':{terminations:{'2':CANCELLED},emissions:{'2':[['b0',int(0)]]},
        task_kinds:{'2':['Emit','Receive','ReceiveWait','ReceiveRemoved','CancelEffective','ScopeExit','Termination']}},
      // Highest: A runs to its trap before root spawns B; the spawn of B then traps ChildFailed.
      highest:{absent:[{kind:'Spawn',child:'2'},{kind:'Emit',label:'root'}]}}}),

  // TC0-C-FAILURE-AFTER-DESCENDANT-JOIN. A (1) and B (2) share root's scope; A spawns a
  // descendant D (3) and traps. A requests D's cancellation and joins it while the
  // schedule runs B, which emits. Only after A is terminal does root's scope latch A's
  // failure and request B's cancellation; no earlier request reaches B.
  fixture('failure-after-descendant-join',({fn,let:L,channel,lam,seq,int,v,emit,node,onReceive,div})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel','Task'],L(node('spawn',lam('I64',['Channel'],onReceive(v(c),x=>v(x),int(0)))),()=>div(int(1),int(0))))),()=>
      L(node('spawn',lam('I64',['Channel','Emit'],seq(emit('b',int(0)),onReceive(v(c),x=>v(x),int(0))))),()=>int(0)))))],
   {all:{execution:'Completed',outcome:trap('ChildFailed'),terminations:{'1':trap('DivZero')},
      absent_before:[[{kind:'ScopeFailure'},{kind:'ScopeExit',task:'1'}]]},
    // B is task 2 only where root spawns B before A spawns D (see CONTRADICTIONS).
    per_schedule:{fifo:{absent_before:[[{kind:'CancelRequest',target:'2'},{kind:'Termination',task:'1'}]]},
     lowest:{absent_before:[[{kind:'CancelRequest',target:'2'},{kind:'Termination',task:'1'}]],terminations:{'2':CANCELLED,'3':CANCELLED},emissions:{'2':[['b',int(0)]]},
      task_kinds:{'1':['Spawn','CancelRequest','ScopeExit','Termination','ScopeFailure','CancelRequest'],
        '2':['Emit','Receive','ReceiveWait','ReceiveRemoved','CancelEffective','ScopeExit','Termination'],'3':['CancelEffective','ScopeExit','Termination']},
      order:[[{kind:'CancelRequest',task:'1',target:'3'},{kind:'Emit',task:'2',label:'b'}],[{kind:'Emit',task:'2',label:'b'},{kind:'Termination',task:'3'}],
        [{kind:'Termination',task:'3'},{kind:'ScopeExit',task:'1'}],[{kind:'Termination',task:'1'},{kind:'ScopeFailure',task:'1',scope:'0'}],
        [{kind:'ScopeFailure',task:'1'},{kind:'CancelRequest',task:'1',target:'2'}]]}}}),

  // A handler installed in the parent answers a perform in the child: spawn copies the
  // active handlers into the child (section 5).
  fixture('copied-handler-in-child',({fn,let:L,lam,int,v,node,onAwait,add,fresh})=>{
    const x=fresh();
    return [fn('main','I64','I64',['Task'],()=>node('handle','Ask',[['ask',x,add(v(x),int(100))]],
      L(node('spawn',lam('I64',['Ask'],node('perform','Ask','ask',int(1)))),t=>onAwait(v(t),r=>v(r),int(0),()=>int(0)))))];},
   {effects:[{name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]}],
    all:{execution:'Completed',outcome:ok(101),terminations:{'1':ok(101)}}}),

  // The copy is the child's own: the parent leaves its handler before the child performs
  // (root returns the handle out of the handle expression, which is not a scope), and the
  // clause still runs, in the child.
  fixture('copied-handler-outlives-parent-handler',({fn,let:L,lam,seq,int,v,node,onAwait,add,fresh,emit})=>{
    const x=fresh();
    return [fn('main','I64','I64',['Emit','Task'],()=>
      L(node('handle','Ask',[['ask',x,seq(emit('clause',v(x)),add(v(x),int(100)))]],node('spawn',lam('I64',['Ask','Task'],seq(node('yield'),node('perform','Ask','ask',int(2)))))),t=>
        onAwait(v(t),r=>v(r),int(0),()=>int(0))))];},
   {effects:[{name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]}],
    all:{execution:'Completed',outcome:ok(102),emissions:{'0':[],'1':[['clause',int(2)]]}}}),

  // Root awaits a child that waits on a channel nobody sends to: Deadlock, with its wait graph.
  fixture('deadlock-receive-and-await',({fn,let:L,channel,lam,int,v,node,onReceive,onAwait})=>[fn('main','I64','I64',['Channel','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel'],onReceive(v(c),x=>v(x),int(0)))),t=>onAwait(v(t),r=>v(r),int(0),()=>int(0)))))],
   {all:{execution:'Deadlock',wait_graph:[{task:'0',await:'1'},{task:'1',receive:'0'}]}}),

  // First close commits End to every waiting receiver, in registration order.
  fixture('close-wakes-receivers',({fn,let:L,channel,lam,seq,int,v,node,onReceive,emit})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel','Emit'],seq(onReceive(v(c),x=>emit('got',v(x)),emit('end',int(0))),int(0)))),()=>
      L(node('spawn',lam('I64',['Channel','Emit'],seq(onReceive(v(c),x=>emit('got',v(x)),emit('end',int(0))),int(0)))),()=>seq(node('close',v(c)),int(0))))))],
   {schedules:[{name:'receivers-wait',policy:'script',script:[{task:'0',until:{kind:'Spawn',child:'2'}},{task:'1',until:{kind:'ReceiveWait'}},{task:'2',until:{kind:'ReceiveWait'}}],then:'lowest'}],
    all:{execution:'Completed',outcome:ok(0),emissions:{'1':[['end',int(0)]],'2':[['end',int(0)]]}},
    per_schedule:{
      'receivers-wait':{channel_kinds:{'0':['Channel:0','Receive:1','ReceiveWait:1','Receive:2','ReceiveWait:2','Close:0','End:1','End:2']}},
      lowest:{channel_kinds:{'0':['Channel:0','Close:0','Receive:1','End:1','Receive:2','End:2']}}}}),

  // Core section 15, "cancel blocked receiver then await then send": the cancelled
  // receiver's registration is removed, so the later send is not consumed by it.
  fixture('cancel-blocked-receiver-no-stale-consumption',({fn,let:L,channel,lam,seq,int,v,node,onReceive,onAwait,send})=>[fn('main','I64','I64',['Channel','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel'],onReceive(v(c),x=>v(x),int(0)))),t=>
      seq(node('cancel',v(t)),onAwait(v(t),()=>int(0),int(0),()=>int(0)),send(v(c),int(5)),onReceive(v(c),x=>v(x),int(0))))))],
   {schedules:[{name:'receiver-blocked',policy:'script',script:[{task:'0',until:{kind:'Spawn'}},{task:'1',until:{kind:'ReceiveWait'}}],then:'lowest'}],
    all:{execution:'Completed',outcome:ok(5),terminations:{'1':CANCELLED}},
    per_schedule:{'receiver-blocked':{task_kinds:{'1':['Receive','ReceiveWait','ReceiveRemoved','CancelEffective','ScopeExit','Termination']},
      channel_kinds:{'0':['Channel:0','Receive:1','ReceiveWait:1','ReceiveRemoved:1','Send:0','Sent:0','Receive:0','Received:0']}}}}),

  // Core section 15, "receive commit before cancel": the item is committed to the waiting
  // receiver; a cancellation requested before the receiver consumes it is delivered at
  // its Wake step, and the item stays consumed.
  fixture('receive-commit-before-cancel',({fn,let:L,channel,lam,seq,int,v,node,onReceive,send,emit,fresh})=>[fn('main','I64','I64',['Channel','Emit','Task'],()=>
    L(channel(1),c=>L(node('spawn',lam('I64',['Channel','Emit'],onReceive(v(c),x=>seq(emit('got',v(x)),v(x)),int(0)))),t=>
      seq(send(v(c),int(5)),node('cancel',v(t)),L(node('await',v(t)),r=>seq(node('close',v(c)),onReceive(v(c),x=>emit('left',v(x)),emit('empty',int(0))),
        (()=>{const y=fresh(),f=fresh();return node('match',v(r),['Ok',[y],v(y)],['Cancelled',[],int(100)],['Failed',[f],int(200)]);})()))))))],
   {all:{execution:'Completed'},
    schedules:[{name:'receiver-woken',policy:'script',script:[{task:'0',until:{kind:'Spawn'}},{task:'1',until:{kind:'ReceiveWait'}},{task:'0',until:{kind:'CancelRequest'}}],then:'lowest'}],
    per_schedule:{
      'receiver-woken':{outcome:ok(100),emissions:{'0':[['empty',int(0)]],'1':[]},terminations:{'1':CANCELLED},
        task_kinds:{'1':['Receive','ReceiveWait','Received','CancelEffective','ScopeExit','Termination']}},
      lowest:{outcome:ok(100),emissions:{'0':[['left',int(5)]],'1':[]}},
      highest:{outcome:ok(5),emissions:{'0':[['empty',int(0)]],'1':[['got',int(5)]]}}}}),

  // Spawning into a failure-latched scope traps ChildFailed and allocates nothing (core section 8).
  fixture('spawn-into-failed-scope',({fn,let:L,lam,seq,int,v,node,div})=>[fn('main','I64','I64',['Task'],()=>
    node('scope',L(node('spawn',lam('I64',[],div(int(1),int(0)))),a=>seq(node('await',v(a)),node('spawn',lam('I64',[],int(0))),int(0)))))],
   // The explicit scope is scope 1; the first child is task 1. Task 2 is never allocated.
   {all:{execution:'Completed',outcome:trap('ChildFailed'),terminations:{'1':trap('DivZero')},absent:[{kind:'Spawn',child:'2'}],
    order:[[{kind:'ScopeFailure',task:'1',scope:'1'},{kind:'ScopeExit',task:'0',scope:'1'}]]}}),

  // A body trap takes precedence over a child's trap: the scope exits with the body's code.
  fixture('body-trap-precedence',({fn,let:L,lam,seq,int,v,node,div,add})=>[fn('main','I64','I64',['Task'],()=>
    node('scope',L(node('spawn',lam('I64',[],add(int('9223372036854775807'),int(1)))),()=>seq(node('yield'),div(int(1),int(0))))))],
   {schedules:[{name:'child-first',policy:'script',script:[{task:'0',until:{kind:'Yield'}},{task:'1',until:{kind:'Termination'}}],then:'lowest'}],
    all:{execution:'Completed',outcome:trap('DivZero'),terminations_one_of:{'1':[trap('Overflow'),CANCELLED]}},
    per_schedule:{'child-first':{terminations:{'1':trap('Overflow')},
      order:[[{kind:'ScopeFailure',task:'1',code:'Overflow'},{kind:'ScopeExit',task:'0',scope:'1'}]]},
      lowest:{terminations:{'1':CANCELLED}}}}),

  // Cancellation requested while the child's body is returning is delivered at its
  // implicit scope's Join, which then exits Cancelled.
  fixture('cancel-delivered-at-join',({fn,let:L,lam,seq,int,v,node,onAwait,emit})=>[fn('main','I64','I64',['Emit','Task'],()=>
    L(node('spawn',lam('I64',['Emit'],seq(emit('x',int(0)),int(1)))),t=>seq(node('cancel',v(t)),onAwait(v(t),r=>v(r),int(10),()=>int(20)))))],
   {schedules:[{name:'cancel-after-emit',policy:'script',script:[{task:'0',until:{kind:'Spawn'}},{task:'1',until:{kind:'Emit'}},{task:'0',until:{kind:'CancelRequest'}}],then:'lowest'}],
    all:{execution:'Completed'},
    per_schedule:{'cancel-after-emit':{outcome:ok(10),terminations:{'1':CANCELLED},task_kinds:{'1':['Emit','CancelEffective','ScopeExit','Termination']}},
      highest:{outcome:ok(1)}}}),

  // An explicitly cancelled child does not fail a normal scope (core section 8).
  fixture('explicit-cancel-does-not-fail-scope',({fn,let:L,channel,lam,seq,int,v,node,onReceive})=>[fn('main','I64','I64',['Channel','Task'],()=>
    L(channel(1),c=>node('scope',L(node('spawn',lam('I64',['Channel'],onReceive(v(c),x=>v(x),int(0)))),t=>seq(node('cancel',v(t)),int(7))))))],
   {all:{execution:'Completed',outcome:ok(7),terminations:{'1':CANCELLED},absent:[{kind:'ScopeFailure'}]}})
];

// Expectations the machines contradicted when they first ran, and which side was wrong.
export const CONTRADICTIONS=[
  {fixture:'failure-after-descendant-join',expectation:"all schedules: no CancelRequest with target '2' before Termination of task 1",
   observed:"under highest, random:1-3 and prandom:1 both machines give task ID 2 to A's descendant D, not to B: A spawns D before root spawns B",
   wrong:'the fixture',
   why:'Task IDs come from one counter in global spawn order (CONCURRENCY.md sections 4 and 13 item 4), so which task is 2 depends on the schedule. The expectation assumed the IDs of the lowest-ID schedule. It now holds for lowest and fifo, where B is task 2; for every schedule the fixture keeps: no ScopeFailure before A\'s ScopeExit.'}];
