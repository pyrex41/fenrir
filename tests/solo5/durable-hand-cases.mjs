// Hand-assembled UNQUALIFIED programs for TC1-D1 durable effects, contract
// spec/tc1/DURABLE.md. IDs and source-map rows are allocated mechanically. Every
// expectation was written from the contract text, before either machine (or the
// Solo5 guest) had run any program of this slice:
//   input                 the entry input (DURABLE.md section 10)
//   replies               the host's replies, in order, as JSON values
//   expected_execution    Completed | AwaitingHost | HostViolation (section 7)
//   expected_outcome      the outcome, for a Completed run
//   expected_observations the observations in order (section 6):
//                         ["emit", label, value] and ["request", seq, "Effect.op", value]
//   expected_performs     handled performs (user handlers), from the step records
//   expected_staging      for two cases, the complete [after, depth] staging
// Contradictions between an expectation and the machines, and which side was wrong,
// are recorded in CONTRADICTIONS at the end.
function fixture(name,effects,build,checks) {
  let next=0n;const locations=[];const fresh=()=>String(next++);
  const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const fn=(name,argument_type,result_type,effectSet,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type,result_type,effects:effectSet,body:body(parameter_id)};};
  const {datatypes=[],...rest}=checks;
  const functions=build({fresh,node,fn});
  const program={contract_version:'tc1-draft-1',schema_version:'tc1-durable-demo/1',slice:'TC1-D1',module:name,datatypes,effects,functions,entry:'main',
    input_schema:{type:functions[0].argument_type},source_map:locations.map(id=>({id,file:name,line:'0',column:'0'}))};
  return {name,program,input:['int','0'],replies:[],expected_execution:'Completed',...rest};
}
const Store={name:'Store',class:'durable',operations:[{name:'put',argument_type:'I64',result_type:'I64'}]};
const Ask={name:'Ask',class:'ordinary',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]};
const Tx={name:'Tx',class:'ordinary',operations:[{name:'begin',argument_type:'Unit',result_type:'Unit'}]};
const Kv={name:'Kv',class:'durable',operations:[{name:'get',argument_type:'I64',result_type:['Data','Answer']}]};
const Answer={name:'Answer',constructors:[{name:'Found',fields:['I64']},{name:'Busy',fields:[]}]};
const Req={name:'Req',constructors:[{name:'Req',fields:['I64','I64']}]};
const int=(node,n)=>node('int',String(n));
const I=n=>['int',String(n)];
const ok=n=>['Ok',I(n)];
const put=(node,arg)=>node('perform','Store','put',arg);
const emitThen=(node,fresh,label,value,body)=>node('let',fresh(),node('emit',label,value),body);

export const cases=[
  // One host request: the perform's argument is collected, the machine stops in HostWait
  // with the request, and the reply is the value of the perform.
  fixture('single-request',[Store],({node,fn})=>[fn('main','I64','I64',['Store'],()=>
    node('prim','add',put(node,int(node,41)),int(node,1)))],
   {replies:[I(1)],expected_outcome:ok(2),expected_observations:[['request','0','Store.put',I(41)]],
    // add collects; perform collects 41; Ready perform: HostWait at the same depth (1, add's
    // collect frame); HostReply: Value at depth 1; add collects 1; add; join, terminate.
    expected_staging:[['Eval','1'],['Eval','2'],['Value','2'],['Ready','1'],['HostWait','1'],['Value','1'],['Eval','1'],['Value','1'],
      ['Ready','0'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]}),
  // A host request is an observation, ordered with the emits around it.
  fixture('emits-around-request',[Store],({fresh,node,fn})=>[fn('main','I64','I64',['Emit','Store'],()=>{
    const r=fresh();
    return emitThen(node,fresh,'before',int(node,1),node('let',r,put(node,int(node,2)),emitThen(node,fresh,'after',node('var',r),node('var',r))));})],
   {replies:[I(7)],expected_outcome:ok(7),
    expected_observations:[['emit','before',I(1)],['request','0','Store.put',I(2)],['emit','after',I(7)]]}),
  // perform is strict: an emit inside the argument happens before the request.
  fixture('argument-emits-first',[Store],({fresh,node,fn})=>[fn('main','I64','I64',['Emit','Store'],()=>
    put(node,emitThen(node,fresh,'argument',int(node,5),int(node,5))))],
   {replies:[I(3)],expected_outcome:ok(3),expected_observations:[['emit','argument',I(5)],['request','0','Store.put',I(5)]]}),
  // Two requests: sequence numbers 0 and 1, the second's argument computed from the first reply.
  fixture('two-requests-in-order',[Store],({fresh,node,fn})=>[fn('main','I64','I64',['Store'],()=>{
    const a=fresh(),b=fresh();
    return node('let',a,put(node,int(node,1)),node('let',b,put(node,node('prim','add',node('var',a),int(node,1))),
      node('prim','add',node('prim','mul',node('var',a),int(node,100)),node('var',b))));})],
   {replies:[I(10),I(20)],expected_outcome:ok(1020),
    expected_observations:[['request','0','Store.put',I(1)],['request','1','Store.put',I(11)]]}),
  // A user handler for a durable effect intercepts it: nothing crosses the boundary.
  fixture('user-handler-intercepts',[Store],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const x=fresh();
    return node('handle','Store',[['put',x,node('prim','add',node('var',x),int(node,100))]],put(node,int(node,1)));})],
   {expected_outcome:ok(101),expected_observations:[],expected_performs:['Store.put']}),
  // In a clause its handler is inactive: the clause's own perform of the same durable effect
  // has no active handler and goes to the host.
  fixture('clause-forwards-to-host',[Store],({fresh,node,fn})=>[fn('main','I64','I64',['Store'],()=>{
    const x=fresh();
    return node('handle','Store',[['put',x,put(node,node('prim','add',node('var',x),int(node,1)))]],put(node,int(node,1)));})],
   {replies:[I(7)],expected_outcome:ok(7),expected_observations:[['request','0','Store.put',I(2)]],expected_performs:['Store.put'],
    // handle; perform collects 1; Ready: the clause frame replaces [handler] (depth 1); the
    // clause's perform: add collects x and 1 (depth 3 at most); the inner Ready perform is
    // residual: HostWait at depth 1 (the clause frame); HostReply; clause return restores the
    // handler (depth 1); handle return; join, terminate.
    expected_staging:[['Eval','1'],['Eval','2'],['Value','2'],['Ready','1'],['Eval','1'],['Eval','2'],['Eval','3'],['Value','3'],['Eval','3'],['Value','3'],
      ['Ready','2'],['Value','2'],['Ready','1'],['HostWait','1'],['Value','1'],['Value','1'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]}),
  // A handler whose body has returned is gone: a later perform goes to the host.
  fixture('removed-handler-not-used',[Store],({fresh,node,fn})=>[fn('main','I64','I64',['Store'],()=>{
    const x=fresh(),a=fresh();
    return node('let',a,node('handle','Store',[['put',x,int(node,0)]],int(node,5)),put(node,node('var',a)));})],
   {replies:[I(9)],expected_outcome:ok(9),expected_observations:[['request','0','Store.put',I(5)]],expected_performs:[]}),
  // A reply of the wrong type is the host's contract violation: no step, no outcome.
  fixture('ill-typed-reply',[Store],({fresh,node,fn})=>[fn('main','I64','I64',['Emit','Store'],()=>{
    const r=fresh();
    return node('let',r,put(node,int(node,1)),emitThen(node,fresh,'after',node('var',r),node('var',r)));})],
   {replies:[['bool',true]],expected_execution:'HostViolation',expected_observations:[['request','0','Store.put',I(1)]]}),
  // An I64 in a non-canonical spelling is not a value of type I64 either.
  fixture('non-canonical-reply',[Store],({node,fn})=>[fn('main','I64','I64',['Store'],()=>put(node,int(node,1)))],
   {replies:[['int','007']],expected_execution:'HostViolation',expected_observations:[['request','0','Store.put',I(1)]]}),
  // No reply: the run waits; it has no outcome.
  fixture('awaiting-host',[Store],({node,fn})=>[fn('main','I64','I64',['Store'],()=>put(node,int(node,1)))],
   {replies:[],expected_execution:'AwaitingHost',expected_observations:[['request','0','Store.put',I(1)]]}),
  // A trap after a well-typed reply is the program's own outcome.
  fixture('trap-after-reply',[Store],({node,fn})=>[fn('main','I64','I64',['Store'],()=>
    node('prim','div',int(node,10),put(node,int(node,1))))],
   {replies:[I(0)],expected_outcome:['Trap','DivZero'],expected_observations:[['request','0','Store.put',I(1)]]}),
  // A datatype reply is typed against its declaration: Busy has no field.
  fixture('datatype-reply',[Kv],({fresh,node,fn})=>[fn('main','I64','I64',['Kv'],()=>{
    const v=fresh();
    return node('match',node('perform','Kv','get',int(node,3)),['Found',[v],node('var',v)],['Busy',[],int(node,-1)]);})],
   {datatypes:[Answer],replies:[['data','Answer','Busy']],expected_outcome:ok(-1),expected_observations:[['request','0','Kv.get',I(3)]]}),
  fixture('datatype-reply-wrong-arity',[Kv],({fresh,node,fn})=>[fn('main','I64','I64',['Kv'],()=>{
    const v=fresh();
    return node('match',node('perform','Kv','get',int(node,3)),['Found',[v],node('var',v)],['Busy',[],int(node,-1)]);})],
   {datatypes:[Answer],replies:[['data','Answer','Busy',I(1)]],expected_execution:'HostViolation',expected_observations:[['request','0','Kv.get',I(3)]]}),
  // An explicit clause of an ordinary effect resumes the body, then makes a host request
  // with what the body produced: the request comes after the body's emit.
  fixture('request-after-resume',[Tx,Store],({fresh,node,fn})=>[fn('main','I64','I64',['Emit','Store'],()=>{
    const u=fresh(),k=fresh(),r=fresh(),w=fresh();
    return node('handle','Tx',[['begin',u,k,node('let',r,node('resume',k,node('unit')),node('let',w,put(node,node('var',r)),node('var',r)))]],
      node('let',fresh(),node('perform','Tx','begin',node('unit')),emitThen(node,fresh,'body',int(node,5),int(node,5))));})],
   {replies:[I(1)],expected_outcome:ok(5),expected_observations:[['emit','body',I(5)],['request','0','Store.put',I(5)]],expected_performs:['Tx.begin']}),
  // A handled ordinary perform in the argument of a durable one: only the durable one is seen.
  fixture('handled-inside-request-argument',[Ask,Store],({fresh,node,fn})=>[fn('main','I64','I64',['Store'],()=>{
    const x=fresh();
    return node('handle','Ask',[['ask',x,node('prim','mul',node('var',x),int(node,2))]],put(node,node('perform','Ask','ask',int(node,3))));})],
   {replies:[I(1)],expected_outcome:ok(1),expected_observations:[['request','0','Store.put',I(6)]],expected_performs:['Ask.ask']}),
  // The entry takes a request value (DURABLE.md section 10).
  fixture('structured-input',[Store],({fresh,node,fn})=>[fn('main',['Data','Req'],'I64',['Store'],p=>{
    const a=fresh(),b=fresh();
    return node('match',node('var',p),['Req',[a,b],node('prim','add',put(node,node('var',a)),node('var',b))]);})],
   {datatypes:[Req],input:['data','Req','Req',I(3),I(4)],replies:[I(10)],expected_outcome:ok(14),expected_observations:[['request','0','Store.put',I(3)]]}),
];

// Contradictions found when the machines first ran, and which side was wrong.
export const CONTRADICTIONS=[
  {case:'datatype-reply-wrong-arity',
   found:'the Shen model accepted the reply (Busy with one field) as well typed and then failed inside tc1.select; the JavaScript implementation reported HostViolation as expected',
   wrong:'the model: its type check treated a constructor with no fields as unknown and reported the empty path, which means "well typed" (DURABLE.md section 5 is clear); fixed in models/tc1/durable-machine.shen, no expectation changed'},
];
