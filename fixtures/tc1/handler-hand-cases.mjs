// Hand-assembled UNQUALIFIED programs for TC1 effects, contract spec/tc1/EFFECTS.md:
// `cases` for slice H1 (tail-resumptive handlers), `resumptionCases` for slice H2
// (explicit one-shot resumption). IDs and source-map rows are allocated mechanically;
// every expectation is handwritten from the contract, before either machine ran:
// outcomes, the order of performed operations, emission order, and for three cases
// the complete step staging [after, depth].
function fixture(name,effects,build,expected,checks={},slice='H1') {
  let next=0n;const locations=[];const fresh=()=>String(next++);
  const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const fn=(name,argument_type,result_type,effectSet,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type,result_type,effects:effectSet,body:body(parameter_id)};};
  const functions=build({fresh,node,fn});
  const program={contract_version:'tc1-draft-1',schema_version:slice==='H2'?'tc1-handler-demo/2':'tc1-handler-demo/1',slice:'TC1-'+slice,module:name,datatypes:[],effects,functions,entry:'main',
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
  // Tail calls under a handler do not grow the continuation. Each tail call replaces its
  // activation, so the deepest point is three frames: handler, if, one operand collection.
  fixture('tail-calls-under-handler',[Ask],({fresh,node,fn})=>[
    fn('main','I64','I64',[],()=>ask(node,fresh,()=>int(node,7),node('call','loop',int(node,5)))),
    fn('loop','I64','I64',['Ask'],n=>node('if',node('prim','le',node('var',n),int(node,0)),performAsk(node,0),
      node('call','loop',node('prim','sub',node('var',n),int(node,1)))))],ok(7),
   {expected_performs:['Ask.ask'],expected_return_frames:'0',maximum_depth:'3'})
];

// ---------- Slice H2: explicit one-shot resumption ----------
// handle Ask with one clause ask(x, k) => clause(x, k)
const askK=(node,fresh,clause,body)=>{const x=fresh(),k=fresh();return node('handle','Ask',[['ask',x,k,clause(x,k)]],body);};
const h2=(name,effects,build,expected,checks)=>fixture(name,effects,build,expected,checks,'H2');

export const resumptionCases=[
  // After resume returns, the clause continues, and its value is the value of the handle.
  // The body gets 2 and yields 12; the clause doubles that.
  h2('clause-continues-after-resume',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const r=fresh();
    return askK(node,fresh,(x,k)=>node('let',r,node('resume',k,node('prim','add',node('var',x),int(node,1))),node('prim','mul',node('var',r),int(node,2))),
      node('prim','add',performAsk(node,1),int(node,10)));})],ok(24),
   {expected_performs:['Ask.ask'],
    // handle; add; perform collects 1; the clause starts over one clause-exit frame; let; resume
    // collects x+1; resume puts back [handler, add] over a resume-return frame (depth 5); the body
    // adds 10; handler exit; resume-return; let binds r; r*2; clause exit.
    expected_staging:[['Eval','1'],['Eval','2'],['Eval','3'],['Value','3'],['Ready','2'],['Eval','1'],['Eval','2'],['Eval','3'],['Eval','4'],['Value','4'],['Eval','4'],['Value','4'],['Ready','3'],['Value','3'],['Ready','2'],
      ['Value','5'],['Eval','5'],['Value','5'],['Ready','4'],['Value','4'],['Value','3'],['Value','2'],['Eval','1'],['Eval','2'],['Value','2'],['Eval','2'],['Value','2'],['Ready','1'],['Value','1'],['Value','0'],
      ['Join','0'],['Terminate','0'],['Terminal','0']]}),
  // A resume in tail position behaves as the tail-resumptive clause does.
  h2('tail-resume-is-tail-resumptive',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    askK(node,fresh,(x,k)=>node('resume',k,node('prim','add',node('var',x),int(node,1))),node('prim','add',performAsk(node,41),int(node,100))))],ok(142),
   {expected_performs:['Ask.ask']}),
  // discontinue abandons the rest of the body: nothing after the perform runs.
  h2('discontinue-abandons-the-body',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',['Emit'],()=>{
    const u=fresh(),a=fresh(),v=fresh();
    return askK(node,fresh,(x,k)=>node('let',u,node('discontinue',k),int(node,7)),
      node('let',a,performAsk(node,1),node('let',v,node('emit','never',node('var',a)),node('var',a))));})],ok(7),
   {expected_performs:['Ask.ask'],expected_emissions:[]}),
  // Effects before the resume, in the resumed body, and after the resume, in that order.
  h2('effects-around-resume',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',['Emit'],()=>{
    const u1=fresh(),r=fresh(),u2=fresh(),a=fresh(),u3=fresh();
    return askK(node,fresh,(x,k)=>node('let',u1,node('emit','before',node('var',x)),node('let',r,node('resume',k,node('var',x)),node('let',u2,node('emit','after',node('var',r)),node('var',r)))),
      node('let',a,performAsk(node,5),node('let',u3,node('emit','body',node('var',a)),node('var',a))));})],ok(5),
   {expected_performs:['Ask.ask'],expected_emissions:['before','body','after']}),
  // Each path of a clause uses its resumption once: resume on one, discontinue on the other.
  h2('resume-on-one-path',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const u=fresh();
    return askK(node,fresh,(x,k)=>node('if',node('prim','gt',node('var',x),int(node,0)),node('resume',k,int(node,1)),node('let',u,node('discontinue',k),int(node,-1))),
      node('prim','add',performAsk(node,3),int(node,10)));})],ok(11),{expected_performs:['Ask.ask']}),
  h2('discontinue-on-the-other-path',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>{
    const u=fresh();
    return askK(node,fresh,(x,k)=>node('if',node('prim','gt',node('var',x),int(node,0)),node('resume',k,int(node,1)),node('let',u,node('discontinue',k),int(node,-1))),
      node('prim','add',performAsk(node,0),int(node,10)));})],ok(-1),{expected_performs:['Ask.ask']}),
  // The handler is active again in the resumed body, so a second perform starts a second
  // clause while the first is still waiting for its resume to return. The body yields 1+2=3;
  // the second clause adds 1, then the first adds 1.
  h2('second-perform-inside-first-resume',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',[],()=>
    askK(node,fresh,(x,k)=>node('prim','add',node('resume',k,node('var',x)),int(node,1)),
      node('prim','add',performAsk(node,1),performAsk(node,2))))],ok(5),{expected_performs:['Ask.ask','Ask.ask']}),
  // A trap after the resume returned: the body's effects have happened.
  h2('trap-after-resume',[Ask],({fresh,node,fn})=>[fn('main','I64','I64',['Emit'],()=>{
    const a=fresh(),u=fresh();
    return askK(node,fresh,(x,k)=>node('prim','div',node('resume',k,node('var',x)),int(node,0)),
      node('let',a,performAsk(node,1),node('let',u,node('emit','body',node('var',a)),node('var',a))));})],['Trap','DivZero'],
   {expected_performs:['Ask.ask'],expected_emissions:['body']}),
  // discontinue discards a segment that itself holds a tail-resumptive clause in progress:
  // the inner (tail-resumptive) clause for Tell performs Ask, whose clause discontinues.
  h2('discontinue-through-a-running-clause',[Ask,Tell],({fresh,node,fn})=>[fn('main','I64','I64',['Emit'],()=>{
    const u=fresh(),t=fresh(),w=fresh(),v=fresh();
    return askK(node,fresh,(x,k)=>node('let',u,node('discontinue',k),int(node,9)),
      node('handle','Tell',[['tell',t,node('let',w,performAsk(node,0),node('unit'))]],
        node('let',v,node('perform','Tell','tell',int(node,1)),node('let',fresh(),node('emit','never',int(node,0)),int(node,3)))));})],ok(9),
   {expected_performs:['Tell.tell','Ask.ask'],expected_emissions:[]})
];

// Frontend round-trip companion. Exercise simultaneous closed and capturing
// functions without changing the enumerated H1/H2 qualification catalogs.
export const closedAndCapturing = fixture('closed-and-capturing-functions', [],
  ({fresh, node, fn}) => {
    const variable = id => node('var', id);
    const literal = n => int(node, n);
    const add = (a, b) => node('prim', 'add', a, b);
    const operation = fn('operation', 'I64', ['Arrow', 'I64', 'I64', []], [], offset => {
      const make = term => {
        const arg = fresh();
        return node('lambda', arg, 'I64', 'I64', [], [], add(variable(arg), term));
      };
      return node('if', node('prim', 'eq', variable(offset), literal(0)),
        make(literal(2)), make(variable(offset)));
    });
    const main = fn('main', 'I64', 'I64', [], input => {
      const closed = fresh(), first = fresh(), second = fresh();
      const call = offset => node('call', 'operation', offset);
      const apply = (id, x) => node('apply', variable(id), x);
      return node('let', closed, call(literal(0)),
        node('let', first, call(add(variable(input), literal(10))),
          node('let', second, call(add(variable(input), literal(30))),
            apply(closed, apply(first, apply(second, literal(0)))))));
    });
    return [operation, main];
  }, ok(42), {}, 'H2');
