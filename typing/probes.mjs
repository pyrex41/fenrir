// Hand-written boundary probes for the typing differential, UNQUALIFIED development
// family (typing/run.shen). Each probe sits at an edge of a rule of spec/tc1/TYPING.md
// or of a structural check, and says what the contract text makes of it (`contract`:
// "valid" or "invalid"), written from the text before either validator ran. The
// differential reports each validator's verdict against that, so a disagreement says
// which side departs from the contract.
const SCHEMAS={
  'tc0-1':['0.2','tc0-a-pure-call-demo/1','TC0-A'],'tc0-2':['0.2','tc0-a-pure-call-demo/2','TC0-A'],
  'h1':['tc1-draft-1','tc1-handler-demo/1','TC1-H1'],'h2':['tc1-draft-1','tc1-handler-demo/2','TC1-H2'],
  'd1':['tc1-draft-1','tc1-durable-demo/1','TC1-D1'],'c1':['tc1-draft-1','tc1-task-demo/1','TC1-C1']};
// A program whose IDs and source map are allocated mechanically, as the fixtures do.
function program(name,schema,{datatypes=[],effects=[],functions,inputType}) {
  let next=0n;const locations=[],fresh=()=>String(next++);
  const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
  const fs=functions.map(([fname,argument_type,result_type,effectSet,body])=>{
    const id=fresh(),parameter_id=fresh();locations.push(id);
    return {id,name:fname,parameter_id,argument_type,result_type,effects:effectSet,body:body({node,fresh,p:parameter_id})};
  });
  const [contract_version,schema_version,slice]=SCHEMAS[schema];
  return {contract_version,schema_version,slice,module:name,datatypes,effects,functions:fs,entry:'main',
    input_schema:{type:inputType??fs[0].argument_type},source_map:locations.map(id=>({id,file:name,line:'0',column:'0'}))};
}
const Ask={name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]};
const Bid={name:'Bid',operations:[{name:'bid',argument_type:'I64',result_type:'I64'}]};
const int=(node,n)=>node('int',String(n));
const main=(res,eff,body)=>['main','I64',res,eff,body];
const nest=(depth,t)=>depth===0?t:['Tuple',nest(depth-1,t)];
// handle Ask { ask(x,k) => clause(x,k) } in perform Ask 1, at handle type T.
const resuming=(clause)=>({node,fresh})=>{const x=fresh(),k=fresh();return node('handle','Ask',[['ask',x,k,clause({node,fresh,x,k})]],node('perform','Ask','ask',int(node,1)));};

export function probes() {
  const P=[];const add=(name,contract,why,p,input)=>P.push({name,contract,why,program:p,...input?{input}:{}});
  const raw=(name,contract,why,text)=>P.push({name,contract,why,text});
  // ---------- effect sets in declared types ----------
  add('datatype-field-arrow-with-user-effect','valid','EFFECTS.md §3: an effect set names Emit or declared effects, in any type; a datatype field is a type',
    program('p','h1',{effects:[Ask],datatypes:[{name:'Box',constructors:[{name:'Box',fields:[['Arrow','I64','I64',['Ask']]]}]}],functions:[main('I64',[],({node})=>int(node,0))]}));
  add('datatype-field-arrow-with-emit','valid','Emit is always a legal effect name',
    program('p','h1',{effects:[Ask],datatypes:[{name:'Box',constructors:[{name:'Box',fields:[['Arrow','I64','I64',['Emit']]]}]}],functions:[main('I64',[],({node})=>int(node,0))]}));
  add('datatype-field-arrow-with-undeclared-effect','invalid','an effect set names only Emit or declared effects',
    program('p','h1',{effects:[Ask],datatypes:[{name:'Box',constructors:[{name:'Box',fields:[['Arrow','I64','I64',['Zzz']]]}]}],functions:[main('I64',[],({node})=>int(node,0))]}));
  add('lambda-annotation-arrow-with-user-effect','valid','a lambda parameter of a function type may name a declared effect',
    program('p','h1',{effects:[Ask],functions:[main('I64',[],({node,fresh})=>{const f=fresh();
      return node('apply',node('lambda',f,['Arrow','I64','I64',['Ask']],'I64',[],[],int(node,0)),node('lambda',fresh(),'I64','I64',['Ask'],[],int(node,1)));})]}));
  add('effect-set-byte-order','valid','byte order: Ask (A) before Bid (B) before Emit (E)',
    program('p','h1',{effects:[Ask,Bid],functions:[main('I64',['Emit'],({node,fresh})=>node('handle','Ask',[['ask',fresh(),int(node,0)]],node('handle','Bid',[['bid',fresh(),int(node,0)]],node('call','f',int(node,0))))),
      ['f','I64','I64',['Ask','Bid','Emit'],({node,p})=>node('var',p)]]}));
  add('effect-set-wrong-order','invalid','byte order is required: Bid before Ask is a second spelling',
    program('p','h1',{effects:[Ask,Bid],functions:[main('I64',[],({node})=>int(node,0)),['f','I64','I64',['Bid','Ask'],({node,p})=>node('var',p)]]}));
  add('effect-set-superset-on-uncalled-function','valid','a declared set may be larger than what the body performs',
    program('p','h1',{effects:[Ask],functions:[main('I64',[],({node})=>int(node,0)),['f','I64','I64',['Ask','Emit'],({node,p})=>node('var',p)]]}));
  // ---------- entry ----------
  add('entry-emit-only','valid','the entry may declare Emit',program('p','h1',{effects:[],functions:[main('I64',['Emit'],({node,fresh})=>node('let',fresh(),node('emit','x',int(node,0)),int(node,1)))]}));
  add('entry-input-schema-differs','invalid','input_schema.type is the entry argument type',program('p','tc0-2',{functions:[main('I64',[],({node})=>int(node,0))],inputType:'Bool'}));
  add('entry-result-tuple-of-data','valid','a serializable entry result',program('p','tc0-2',{datatypes:[{name:'Opt',constructors:[{name:'None',fields:[]},{name:'Some',fields:['I64']}]}],
    functions:[main(['Tuple',['Data','Opt']],[],({node})=>node('tuple',node('construct','Opt','None')))]}));
  add('entry-result-recursive-data-with-arrow','invalid','a reachable function field makes a type not serializable',
    program('p','tc0-2',{datatypes:[{name:'L',constructors:[{name:'N',fields:[]},{name:'C',fields:[['Data','M'],['Data','L']]}]},{name:'M',constructors:[{name:'F',fields:[['Arrow','I64','I64',[]]]}]}],
      functions:[main(['Data','L'],[],({node})=>node('construct','L','N'))]}));
  // ---------- literals and caps ----------
  add('int-max','valid','2^63-1 is in range',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,'9223372036854775807'))]}));
  add('int-max-plus-one','invalid','2^63 is out of range',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,'9223372036854775808'))]}));
  add('int-min','valid','-2^63 is in range',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,'-9223372036854775808'))]}));
  add('int-min-minus-one','invalid','-2^63-1 is out of range',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,'-9223372036854775809'))]}));
  add('int-negative-zero','invalid','no negative zero',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,'-0'))]}));
  add('int-leading-zero','invalid','no leading zero',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,'07'))]}));
  add('bytes-256-octets','valid','256 octets is the cap',program('p','tc0-2',{functions:[main('I64',[],({node})=>node('prim','bytes_length',node('bytes','ab'.repeat(256))))]}));
  add('bytes-257-octets','limit','over the 256-octet cap: a limit, not a judgement',program('p','tc0-2',{functions:[main('I64',[],({node})=>node('prim','bytes_length',node('bytes','ab'.repeat(257))))]}));
  add('bytes-uppercase','invalid','lowercase hex only',program('p','tc0-2',{functions:[main('I64',[],({node})=>node('prim','bytes_length',node('bytes','AB')))]}));
  const chain=(node,n)=>n===1?int(node,0):node('prim','neg',chain(node,n-1));
  // A balanced tree of exactly n nodes, so that only the node cap is at issue.
  const tree=(node,n)=>n===1?int(node,1):n===2?node('prim','neg',int(node,1)):node('prim','add',tree(node,Math.floor((n-1)/2)),tree(node,n-1-Math.floor((n-1)/2)));
  add('nodes-200','valid','200 expression nodes is the cap',program('p','tc0-1',{functions:[main('I64',[],({node})=>tree(node,200))]}));
  add('nodes-201','limit','201 nodes: a limit',program('p','tc0-1',{functions:[main('I64',[],({node})=>tree(node,201))]}));
  add('depth-64','valid','depth 64 below the body is the cap',program('p','tc0-1',{functions:[main('I64',[],({node})=>chain(node,65))]}));
  add('depth-65','limit','depth 65: a limit',program('p','tc0-1',{functions:[main('I64',[],({node})=>chain(node,66))]}));
  add('type-depth-16','valid','type nesting 16 is the cap',program('p','tc0-2',{functions:[main('I64',[],({node})=>int(node,0)),['f',nest(16,'I64'),'I64',[],({node})=>int(node,0)]]}));
  add('type-depth-17','limit','type nesting 17: a limit',program('p','tc0-2',{functions:[main('I64',[],({node})=>int(node,0)),['f',nest(17,'I64'),'I64',[],({node})=>int(node,0)]]}));
  add('tuple-eight','valid','tuples have 1 to 8 components',program('p','tc0-2',{functions:[main(['Tuple','I64','I64','I64','I64','I64','I64','I64','I64'],[],({node})=>node('tuple',...Array.from({length:8},()=>int(node,0))))]}));
  add('tuple-type-nine','invalid','a tuple type has at most 8 components',program('p','tc0-2',{functions:[main('I64',[],({node})=>int(node,0)),['f',['Tuple',...Array(9).fill('I64')],'I64',[],({node})=>int(node,0)]]}));
  add('project-last','valid','index 7 of 8',program('p','tc0-2',{functions:[main('I64',[],({node})=>node('project',node('tuple',...Array.from({length:8},()=>int(node,0))),'7'))]}));
  // ---------- one-shot resumptions ----------
  add('resume-in-condition','valid','a use in the condition of an if counts once on every path',
    program('p','h2',{effects:[Ask],functions:[main('I64',[],({node,fresh})=>{const x=fresh(),k=fresh();
      return node('if',node('prim','lt',int(node,0),node('handle','Ask',[['ask',x,k,node('resume',k,node('var',x))]],node('perform','Ask','ask',int(node,1)))),int(node,1),int(node,2));})]}));
  add('resume-in-scrutinee-free-arms','valid','a use in a match scrutinee, none in the arms',
    program('p','h2',{effects:[{name:'Ask',operations:[{name:'ask',argument_type:'I64',result_type:'Bool'}]}],
      datatypes:[{name:'B',constructors:[{name:'T',fields:[]},{name:'F',fields:[]}]}],
      functions:[main('I64',[],({node,fresh})=>{const x=fresh(),k=fresh();
        return node('match',node('handle','Ask',[['ask',x,k,node('match',node('resume',k,node('bool',true)),['T',[],node('construct','B','T')],['F',[],node('construct','B','F')])]],
          node('if',node('perform','Ask','ask',int(node,1)),node('construct','B','T'),node('construct','B','F'))),['T',[],int(node,1)],['F',[],int(node,0)]);})]}));
  add('discontinue-then-resume','invalid','two uses on one path',program('p','h2',{effects:[Ask],functions:[main('I64',[],resuming(({node,fresh,k})=>node('let',fresh(),node('discontinue',k),node('resume',k,int(node,0)))))]}));
  add('discontinue-only','valid','one use by discontinue, the clause continues with a value of the handle type',
    program('p','h2',{effects:[Ask],functions:[main('I64',[],resuming(({node,fresh,k})=>node('let',fresh(),node('discontinue',k),int(node,7))))]}));
  add('discontinue-or-resume','valid','both paths use k once',program('p','h2',{effects:[Ask],functions:[main('I64',[],resuming(({node,fresh,k,x})=>
    node('if',node('prim','lt',node('var',x),int(node,0)),node('let',fresh(),node('discontinue',k),int(node,0)),node('resume',k,node('var',x)))))]}));
  add('resume-in-inner-handle-body','valid','k may be used in the body of an inner handle',program('p','h2',{effects:[Ask,Bid],functions:[main('I64',[],resuming(({node,fresh,k})=>
    {const y=fresh();return node('handle','Bid',[['bid',y,node('var',y)]],node('resume',k,node('perform','Bid','bid',int(node,0))));}))]}));
  add('resume-inside-lambda-in-clause','invalid','a closure cannot mention k',program('p','h2',{effects:[Ask],functions:[main('I64',[],resuming(({node,fresh,k})=>
    node('apply',node('lambda',fresh(),'I64','I64',[],[],node('resume',k,int(node,0))),int(node,0))))]}));
  add('resume-wrong-handle-type','invalid','resume has the type of the handle, here I64, not Bool',program('p','h2',{effects:[Ask],functions:[main('I64',[],resuming(({node,k})=>
    node('if',node('resume',k,int(node,0)),int(node,0),int(node,1))))]}));
  add('tail-clause-under-h2','valid','H2 keeps the tail-resumptive form',program('p','h2',{effects:[Ask],functions:[main('I64',[],({node,fresh})=>{const x=fresh();
    return node('handle','Ask',[['ask',x,node('var',x)]],node('perform','Ask','ask',int(node,1)));})]}));
  // ---------- effects through handlers ----------
  add('clause-forwards-same-effect','valid','a clause may perform the effect it handles; an outer handler answers',
    program('p','h1',{effects:[Ask],functions:[main('I64',[],({node,fresh})=>node('handle','Ask',[['ask',fresh(),int(node,5)]],
      node('handle','Ask',[['ask',fresh(),node('perform','Ask','ask',int(node,0))]],node('perform','Ask','ask',int(node,1)))))]}));
  add('clause-forwards-unhandled','invalid','a forwarded perform with no outer handler reaches the entry',
    program('p','h1',{effects:[Ask],functions:[main('I64',[],({node,fresh})=>node('handle','Ask',[['ask',fresh(),node('perform','Ask','ask',int(node,0))]],node('perform','Ask','ask',int(node,1))))]}));
  add('lambda-effect-subset','valid','a lambda body may perform fewer effects than declared',program('p','h1',{effects:[Ask],functions:[main('I64',['Emit'],({node,fresh})=>
    node('handle','Ask',[['ask',fresh(),int(node,0)]],node('apply',node('lambda',fresh(),'I64','I64',['Ask','Emit'],[],int(node,0)),int(node,1))))]}));
  add('lambda-effect-escapes','invalid','a lambda body may not perform an undeclared effect',program('p','h1',{effects:[Ask],functions:[main('I64',[],({node,fresh})=>
    node('handle','Ask',[['ask',fresh(),int(node,0)]],node('apply',node('lambda',fresh(),'I64','I64',[],[],node('perform','Ask','ask',int(node,0))),int(node,1))))]}));
  // ---------- data ----------
  add('match-arms-out-of-order','valid','arms are matched by constructor name, not position',program('p','tc0-2',{datatypes:[{name:'Opt',constructors:[{name:'None',fields:[]},{name:'Some',fields:['I64']}]}],
    functions:[main('I64',[],({node,fresh})=>{const y=fresh();return node('match',node('construct','Opt','Some',int(node,3)),['Some',[y],node('var',y)],['None',[],int(node,0)]);})]}));
  add('match-trapcode-all','valid','TrapCode has six constructors',program('p','tc0-2',{functions:[main('I64',[],({node})=>node('match',node('construct','TrapCode','Bounds'),
    ...['Overflow','DivZero','Bounds','InvalidDuration','TaskLimit','ChildFailed'].map((c,i)=>[c,[],int(node,i)])))]}));
  add('eq-on-recursive-data','valid','a recursive datatype without functions is equality-compatible',program('p','tc0-2',{datatypes:[{name:'L',constructors:[{name:'N',fields:[]},{name:'C',fields:['I64',['Data','L']]}]}],
    functions:[main('Bool',[],({node})=>node('prim','eq',node('construct','L','N'),node('construct','L','N')))]}));
  add('eq-on-data-with-arrow','invalid','a datatype with a function field is not equality-compatible',program('p','tc0-2',{datatypes:[{name:'F',constructors:[{name:'F',fields:[['Arrow','I64','I64',[]]]},{name:'G',fields:[]}]}],
    functions:[main('Bool',[],({node})=>node('prim','eq',node('construct','F','G'),node('construct','F','G')))]}));
  add('emit-tuple','valid','emit takes any serializable value',program('p','tc0-2',{functions:[main('Unit',['Emit'],({node})=>node('emit','x',node('tuple',int(node,1),node('bool',true))))]}));
  add('constructor-name-in-two-datatypes','valid','constructor names are unique within a datatype only',program('p','tc0-2',{datatypes:[{name:'A',constructors:[{name:'K',fields:[]}]},{name:'B',constructors:[{name:'K',fields:[]}]}],
    functions:[main('I64',[],({node})=>node('match',node('construct','B','K'),['K',[],int(node,0)]))]}));
  add('function-name-not-an-identifier','valid','function names are any string',program('p','tc0-1',{functions:[main('I64',[],({node})=>node('call','f g',int(node,0))),['f g','I64','I64',[],({node,p})=>node('var',p)]]}));
  add('bytes-type-under-schema-1','invalid','Bytes is not a type of schema /1',program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,0)),['f','Bytes','I64',[],({node})=>int(node,0)]]}));
  // ---------- transport ----------
  const base=program('p','tc0-1',{functions:[main('I64',[],({node})=>int(node,0))]});
  const text=JSON.stringify(base);
  raw('transport-whitespace','valid','noncanonical whitespace may be accepted at ingestion',JSON.stringify(base,null,1));
  raw('transport-duplicate-key','invalid','duplicate decoded keys are rejected',text.replace('{"contract_version":"0.2"','{"contract_version":"0.2","contract_version":"0.2"'));
  raw('transport-number-token','invalid','numeric tokens are forbidden',text.replace('"column":"0"','"column":0'));
  raw('transport-bom','invalid','a BOM is rejected','﻿'+text);
  raw('transport-unknown-field','invalid','fields are closed',text.replace('{"contract_version"','{"extra":"1","contract_version"'));
  raw('transport-object-for-array','invalid','datatypes is an array',text.replace('"datatypes":[]','"datatypes":{}'));
  raw('transport-bad-key','invalid','keys match [A-Za-z_][A-Za-z0-9_]*',text.replace('{"contract_version"','{"1x":"1","contract_version"'));
  // ---------- durable effects (DURABLE.md, schema tc1-durable-demo/1) ----------
  const Store={name:'Store',class:'durable',operations:[{name:'put',argument_type:'I64',result_type:'I64'}]};
  const AskO={name:'Ask',class:'ordinary',operations:[{name:'ask',argument_type:'I64',result_type:'I64'}]};
  const put=(node,n)=>node('perform','Store','put',int(node,n));
  add('durable-residual-at-entry','valid','§2: the entry set may contain durable effects',program('p','d1',{effects:[Store],functions:[main('I64',['Store'],({node})=>put(node,1))]}));
  add('durable-ordinary-at-entry','invalid','§2: no ordinary effect at the entry',program('p','d1',{effects:[AskO],functions:[main('I64',['Ask'],({node})=>node('perform','Ask','ask',int(node,1)))]}));
  add('durable-handled-in-program','valid','§3: a user handler may enclose a durable effect',program('p','d1',{effects:[Store],functions:[main('I64',[],({node,fresh})=>{const x=fresh();
    return node('handle','Store',[['put',x,node('var',x)]],put(node,1));})]}));
  add('durable-forwarded-from-clause-to-host','valid','§3: a perform of E in a clause of a handler for E goes out, to the host',program('p','d1',{effects:[Store],functions:[main('I64',['Store'],({node,fresh})=>{const x=fresh();
    return node('handle','Store',[['put',x,node('perform','Store','put',node('var',x))]],put(node,1));})]}));
  add('durable-declared-not-performed','valid','EFFECTS.md §3: a declared set may be larger than the body performs',program('p','d1',{effects:[Store],functions:[main('I64',['Emit','Store'],({node})=>int(node,0))]}));
  add('durable-entry-set-order','invalid','EFFECTS.md §3: byte order, Emit before Store',program('p','d1',{effects:[Store],functions:[main('I64',['Store','Emit'],({node})=>int(node,0))]}));
  add('durable-residual-through-call','valid','§2: the callee leaves Store to the entry, which leaves it to the host',program('p','d1',{effects:[Store],
    functions:[main('I64',['Store'],({node})=>node('call','f',int(node,1))),['f','I64','I64',['Store'],({node,p})=>node('perform','Store','put',node('var',p))]]}));
  add('durable-class-missing','invalid','§1: every declaration of this schema has the class field',program('p','d1',{effects:[{name:'Store',operations:Store.operations}],functions:[main('I64',['Store'],({node})=>put(node,1))]}));
  add('durable-class-runtime','invalid','§1: only ordinary and durable are declarable',program('p','d1',{effects:[{...Store,class:'runtime'}],functions:[main('I64',['Store'],({node})=>put(node,1))]}));
  add('durable-class-under-h2','invalid','§1: older schemas have no class field',program('p','h2',{effects:[{...Store}],functions:[main('I64',[],({node,fresh})=>{const x=fresh();
    return node('handle','Store',[['put',x,node('var',x)]],put(node,1));})]}));
  add('durable-reserved-name','invalid','§1: the runtime names stay reserved',program('p','d1',{effects:[{...Store,name:'Time'}],functions:[main('I64',[],({node})=>int(node,0))]}));
  add('durable-operation-arrow','invalid','§1: operation types stay serializable',program('p','d1',{effects:[{...Store,operations:[{name:'put',argument_type:'I64',result_type:['Arrow','I64','I64',[]]}]}],
    functions:[main('I64',[],({node})=>int(node,0))]}));
  const Req={name:'Req',constructors:[{name:'Req',fields:['I64','Bytes']}]};
  add('durable-entry-takes-request','valid','§2, §10: the entry may take any serializable argument, here a Req',program('p','d1',{effects:[Store],datatypes:[Req],
    functions:[['main',['Data','Req'],'I64',[],({node})=>int(node,0)]]}),['data','Req','Req',['int','5'],['bytes','ab']]);
  add('durable-entry-input-wrong-type','invalid','§10: the input is a value of the entry argument type',program('p','d1',{effects:[Store],datatypes:[Req],
    functions:[['main',['Data','Req'],'I64',[],({node})=>int(node,0)]]}),['int','0']);
  add('durable-entry-takes-function','invalid','§2: the argument is serializable',program('p','d1',{effects:[Store],functions:[['main',['Arrow','I64','I64',[]],'I64',[],({node})=>int(node,0)]],inputType:['Arrow','I64','I64',[]]}));
  add('durable-no-task-forms','invalid','§11: a D1 artifact has no task forms',program('p','d1',{effects:[Store],functions:[main('Unit',[],({node})=>node('yield'))]}));
  add('durable-no-runtime-effects','invalid','§11: Task is not an effect of D1',program('p','d1',{effects:[Store],functions:[main('I64',['Task'],({node})=>int(node,0))]}));
  // ---------- tasks and channels (CONCURRENCY.md, schema tc1-task-demo/1) ----------
  const T=['Channel','Emit','Task'];
  const lam=(node,fresh,body,result='I64',eff=[])=>node('lambda',fresh(),'Unit',result,eff,[],body);
  add('task-scope','valid','§2: scope(b) with b serializable',program('p','c1',{functions:[main('I64',['Task'],({node})=>node('scope',int(node,1)))]}));
  add('task-scope-returns-channel','invalid','§3: a handle may not leave its scope',program('p','c1',{functions:[main(['Channel','I64'],T,({node})=>node('scope',node('channel','I64','1')))]}));
  add('task-scope-returns-closure','invalid','§3: a closure may not leave its scope',program('p','c1',{functions:[main('I64',T,({node,fresh})=>
    node('apply',node('scope',lam(node,fresh,int(node,1))),node('unit')))]}));
  add('task-spawn-await','valid','§2: spawn then await gives Outcome(I64)',program('p','c1',{functions:[main(['Outcome','I64'],['Task'],({node,fresh})=>node('await',node('spawn',lam(node,fresh,int(node,1)))))]}));
  add('task-spawn-not-unit','invalid','§2: spawn needs Unit -> T',program('p','c1',{functions:[main('Unit',['Task'],({node,fresh})=>
    node('cancel',node('spawn',node('lambda',fresh(),'I64','I64',[],[],int(node,1)))))]}));
  add('task-spawn-returns-handle','invalid','§3: a task result is serializable',program('p','c1',{functions:[main('Unit',T,({node,fresh})=>
    node('cancel',node('spawn',lam(node,fresh,node('channel','I64','1'),['Channel','I64'],['Channel']))))]}));
  add('task-spawn-effects-at-site','invalid','§2: spawn performs the effects of f: Emit is undeclared here',program('p','c1',{functions:[main('Unit',['Task'],({node,fresh})=>
    node('cancel',node('spawn',lam(node,fresh,node('emit','x',int(node,1)),'Unit',['Emit']))))]}));
  add('task-await-channel','invalid','§2: await needs Task(T)',program('p','c1',{functions:[main(['Outcome','I64'],T,({node})=>node('await',node('channel','I64','1')))]}));
  add('task-capacity-1','valid','§2: 1 <= c',program('p','c1',{functions:[main('Unit',T,({node})=>node('close',node('channel','I64','1')))]}));
  add('task-capacity-8','valid','§2: c <= the configured maximum, 8 by default',program('p','c1',{functions:[main('Unit',T,({node})=>node('close',node('channel','I64','8')))]}));
  add('task-capacity-0','invalid','§2: 1 <= c',program('p','c1',{functions:[main('Unit',T,({node})=>node('close',node('channel','I64','0')))]}));
  add('task-capacity-9','invalid','§2: above the default maximum',program('p','c1',{functions:[main('Unit',T,({node})=>node('close',node('channel','I64','9')))]}));
  add('task-channel-of-outcomes','valid','§2: an element type serializable when its T is',program('p','c1',{functions:[main('Unit',T,({node})=>node('close',node('channel',['Outcome','I64'],'2')))]}));
  add('task-channel-of-tasks','invalid','§2: handles are not serializable',program('p','c1',{functions:[main('Unit',T,({node})=>node('close',node('channel',['Task','I64'],'2')))]}));
  add('task-send-receive','valid','§2: send T into Channel(T), receive ReceiveResult(T)',program('p','c1',{functions:[main(['ReceiveResult','I64'],['Channel'],({node,fresh})=>{const c=fresh();
    return node('let',c,node('channel','I64','1'),node('let',fresh(),node('send',node('var',c),int(node,3)),node('receive',node('var',c))));})]}));
  add('task-send-wrong-type','invalid','§2: v : T',program('p','c1',{functions:[main('SendResult',['Channel'],({node})=>node('send',node('channel','I64','1'),node('bool',true)))]}));
  add('task-match-outcome','valid','§2: Outcome is matched exhaustively',program('p','c1',{functions:[main('I64',['Task'],({node,fresh})=>{const v=fresh(),c=fresh();
    return node('match',node('await',node('spawn',lam(node,fresh,int(node,1)))),['Ok',[v],node('var',v)],['Cancelled',[],int(node,0)],['Failed',[c],int(node,2)]);})]}));
  add('task-match-outcome-missing-arm','invalid','§2: exhaustive',program('p','c1',{functions:[main('I64',['Task'],({node,fresh})=>{const v=fresh();
    return node('match',node('await',node('spawn',lam(node,fresh,int(node,1)))),['Ok',[v],node('var',v)],['Cancelled',[],int(node,0)]);})]}));
  add('task-match-failed-binds-trapcode','invalid','§2: Failed carries a TrapCode, not an I64',program('p','c1',{functions:[main('I64',['Task'],({node,fresh})=>{const v=fresh(),c=fresh();
    return node('match',node('await',node('spawn',lam(node,fresh,int(node,1)))),['Ok',[v],node('var',v)],['Cancelled',[],int(node,0)],['Failed',[c],node('var',c)]);})]}));
  add('task-construct-outcome','invalid','§2: a program cannot construct Outcome',program('p','c1',{functions:[main('I64',[],({node})=>node('let','99',node('construct','Outcome','Cancelled'),int(node,0)))]}));
  add('task-eq-on-results','valid','§2: SendResult is equality-compatible',program('p','c1',{functions:[main('Bool',['Channel'],({node,fresh})=>{const c=fresh();
    return node('let',c,node('channel','I64','1'),node('prim','eq',node('send',node('var',c),int(node,1)),node('send',node('var',c),int(node,2))));})]}));
  add('task-emit-channel','invalid','§2: a handle is not serializable',program('p','c1',{functions:[main('Unit',T,({node})=>node('emit','x',node('channel','I64','1')))]}));
  add('task-entry-returns-sendresult','valid','§2: SendResult is serializable',program('p','c1',{functions:[main('SendResult',['Channel'],({node})=>node('send',node('channel','I64','1'),int(node,1)))]}));
  add('task-entry-returns-task','invalid','core §2: a serializable entry result',program('p','c1',{functions:[main(['Task','I64'],['Task'],({node,fresh})=>node('spawn',lam(node,fresh,int(node,1))))]}));
  add('task-effect-order','valid','§2: canonical order Channel, Emit, Task',program('p','c1',{functions:[main('I64',['Channel','Emit','Task'],({node})=>int(node,0))]}));
  add('task-effect-order-wrong','invalid','§2: canonical order',program('p','c1',{functions:[main('I64',['Task','Channel'],({node})=>int(node,0))]}));
  add('task-yield-needs-task','invalid','§2: yield has effect Task',program('p','c1',{functions:[main('Unit',[],({node})=>node('yield'))]}));
  add('task-handle-runtime-effect','invalid','§2: Task cannot be handled by a user handler',program('p','c1',{functions:[main('Unit',[],({node,fresh})=>node('handle','Task',[['yield',fresh(),node('unit')]],node('yield')))]}));
  add('task-user-effect-handled-around-spawn','valid','§5: handlers are copied into the child, so the spawn site needs a handler',program('p','c1',{effects:[Ask],
    functions:[main('Unit',['Task'],({node,fresh})=>node('handle','Ask',[['ask',fresh(),int(node,0)]],
      node('cancel',node('spawn',lam(node,fresh,node('perform','Ask','ask',int(node,1)),'I64',['Ask'])))))]}));
  add('task-datatype-field-handle','valid','a datatype field may be a handle type; only serializable positions exclude it',program('p','c1',{datatypes:[{name:'Box',constructors:[{name:'Box',fields:[['Channel','I64']]}]}],
    functions:[main('I64',[],({node})=>int(node,0))]}));
  add('task-forms-under-h2','invalid','older schemas have no task forms',program('p','h2',{functions:[main('Unit',[],({node})=>node('yield'))]}));
  add('task-runtime-effect-under-h2','invalid','older schemas cannot name Task in an effect set',program('p','h2',{functions:[main('I64',['Task'],({node})=>int(node,0))]}));
  return P;
}
