// Hand-assembled UNQUALIFIED programs for TC1 slice H1 (tail-resumptive handlers),
// contract spec/tc1/EFFECTS.md. IDs and source-map rows are allocated mechanically;
// every expectation is handwritten from the contract, before either machine ran:
// outcomes, the order of performed operations, emission order, and for two cases
// the complete step staging [after, depth].
function fixture(name,effects,build,expected,checks={}) {
  let next=0n;const locations=[];const fresh=()=>String(next++);
  const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const fn=(name,argument_type,result_type,effectSet,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type,result_type,effects:effectSet,body:body(parameter_id)};};
  const functions=build({fresh,node,fn});
  const program={contract_version:'tc1-draft-1',schema_version:'tc1-handler-demo/1',slice:'TC1-H1',module:name,datatypes:[],effects,functions,entry:'main',
    input_schema:{type:functions[0].argument_type},source_map:locations.map(id=>({id,file:name,line:'0',column:'0'}))};
  return {name,program,expected_outcome:expected,...checks};
}
const Ask={name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]};
const Tell={name:'Tell',operations:[{name:'tell',argument_type:'I64',result_type:'Unit'}]};
const Cell={name:'Cell',operations:[{name:'get',argument_type:'Unit',result_type:'I64'},{name:'put',argument_type:'I64',result_type:'Unit'}]};
const int=(node,n)=>node('int',String(n));
const ok=n=>['Ok',['int',String(n)]];
// handle Ask with one clause ask(x) => clause(x)
const ask=(node,fresh,clause,body)=>{const x=fresh();return node('handle','Ask',[['ask',x,clause(x)]],body);};
const performAsk=(node,n)=>node('perform','Ask','ask',int(node,n));

export const cases=[
  // The value a clause returns is the result of the perform, and the body continues.
  fixture('handler-basic',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    ask(node,fresh,x=>node('prim','add',node('var',x),int(node,1)),node('prim','add',performAsk(node,41),int(node,100))))],ok(142),
   {expected_performs:['Ask.ask'],
    // handle entry; add collects; perform collects 41; perform suspends [handler, add] into one
    // clause frame; the clause computes 42; resume restores both frames; add finishes; handler exits.
    expected_staging:[['Eval','1'],['Eval','2'],['Eval','3'],['Value','3'],['Ready','2'],['Eval','1'],['Eval','2'],['Value','2'],['Eval','2'],['Value','2'],['Ready','1'],['Value','1'],
      ['Value','2'],['Eval','2'],['Value','2'],['Ready','1'],['Value','1'],['Value','0'],['Join','0'],['Terminate','0'],['Terminal','0']]}),
  // A trap in a clause aborts: the suspended segment is unwound, never resumed.
  fixture('clause-trap-aborts',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    ask(node,fresh,x=>node('prim','div',node('var',x),int(node,0)),node('prim','add',performAsk(node,1),int(node,5))))],['Trap','DivZero'],
   {expected_performs:['Ask.ask'],
    // as above up to the clause; div traps; unwinding discards the clause frame (exposing the
    // two suspended frames), then the add frame, then the handler frame.
    expected_staging:[['Eval','1'],['Eval','2'],['Eval','3'],['Value','3'],['Ready','2'],['Eval','1'],['Eval','2'],['Value','2'],['Eval','2'],['Value','2'],['Ready','1'],['Unwind','1'],
      ['Unwind','2'],['Unwind','1'],['Unwind','0'],['Join','0'],['Terminate','0'],['Terminal','0']]}),
  // Effects of the clause happen before effects of the resumed body.
  fixture('body-continues-after-resume',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',['Emit'],()=>{
    const a=fresh(),u1=fresh(),u2=fresh();
    return ask(node,fresh,x=>node('let',u1,node('emit','clause',node('var',x)),node('var',x)),
      node('let',a,performAsk(node,7),node('let',u2,node('emit','after',node('var',a)),node('var',a))));})],ok(7),
   {expected_performs:['Ask.ask'],expected_emissions:['clause','after']}),
  // Handler selection is dynamic: a closure made under one handler and applied under
  // another uses the handler active where it is applied.
  fixture('closure-uses-handler-at-application',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const f=fresh(),u=fresh();
    return node('let',f,ask(node,fresh,()=>int(node,1),node('lambda',u,'Unit','I64',['Ask'],[],performAsk(node,0))),
      ask(node,fresh,()=>int(node,2),node('apply',node('var',f),node('unit'))));})],ok(2),
   {expected_performs:['Ask.ask'],expected_descriptor_count:'1'}),
  // In a clause the selected handler is inactive: the same effect forwards outward.
  fixture('same-effect-forwards-outward',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    ask(node,fresh,x=>node('prim','mul',node('var',x),int(node,2)),
      ask(node,fresh,x=>node('perform','Ask','ask',node('prim','add',node('var',x),int(node,1))),performAsk(node,5))))],ok(12),
   {expected_performs:['Ask.ask','Ask.ask']}),
  // A handler for another effect between the perform and its handler is passed over.
  fixture('outer-effect-across-inner-handler',[Ask,Tell],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const t=fresh();
    return ask(node,fresh,()=>int(node,100),node('handle','Tell',[['tell',t,node('unit')]],node('prim','add',performAsk(node,0),int(node,1))));})],ok(101),
   {expected_performs:['Ask.ask']}),
  // A trap in the body unwinds through the handler like any other frame.
  fixture('body-trap-under-handler',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    ask(node,fresh,x=>node('var',x),node('prim','div',int(node,1),int(node,0))))],['Trap','DivZero'],{expected_performs:[]}),
  // A handler is gone once its body returns.
  fixture('sequential-handlers',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    node('prim','add',ask(node,fresh,()=>int(node,10),performAsk(node,0)),ask(node,fresh,()=>int(node,20),performAsk(node,0))))],ok(30),
   {expected_performs:['Ask.ask','Ask.ask']}),
  // A clause runs in the bindings of its handle node, not of the perform site. f(2) installs a
  // handler answering 2 and calls f(1), which installs one answering 1 and calls f(0), which
  // performs: the innermost handler answers with ITS p, 1, although p is 0 at the perform site.
  fixture('clause-sees-definition-bindings',[Ask],({fresh,node,fn})=>[
    fn('main','I64','I64',[],()=>ask(node,fresh,()=>int(node,99),node('call','f',int(node,2)))),
    fn('f','I64','I64',['Ask'],p=>node('if',node('prim','le',node('var',p),int(node,0)),performAsk(node,0),
      ask(node,fresh,()=>node('var',p),node('call','f',node('prim','sub',node('var',p),int(node,1))))))],ok(1),
   {expected_performs:['Ask.ask']}),
  // One handler, two operations, each with its own clause.
  fixture('two-operations',[Cell],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const g=fresh(),p=fresh(),a=fresh(),u=fresh();
    return node('handle','Cell',[['get',g,int(node,5)],['put',p,node('unit')]],
      node('let',a,node('perform','Cell','get',node('unit')),node('let',u,node('perform','Cell','put',node('var',a)),node('prim','add',node('var',a),int(node,1)))));})],ok(6),
   {expected_performs:['Cell.get','Cell.put']}),
  // Tail calls under a handler do not grow the continuation: the handler frame, the if
  // frame of the current activation... no: each tail call replaces its activation, so the
  // deepest point is handler, if, and one operand collection.
  fixture('tail-calls-under-handler',[Ask],({fresh,node,fn})=>[
    fn('main','I64','I64',[],()=>ask(node,fresh,()=>int(node,7),node('call','loop',int(node,5)))),
    fn('loop','I64','I64',['Ask'],n=>node('if',node('prim','le',node('var',n),int(node,0)),performAsk(node,0),
      node('call','loop',node('prim','sub',node('var',n),int(node,1)))))],ok(7),
   {expected_performs:['Ask.ask'],expected_return_frames:'0',maximum_depth:'3'})
];
