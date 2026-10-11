// Hand-assembled UNQUALIFIED distinguishing programs for the schema /2 data
// built-ins (Bytes, TrapCode, tuples, datatypes, construct/match/project,
// bytes_length/bytes_index/bytes_concat, eq). Not generated discovery.
// IDs/source-map rows are mechanically allocated; expected results are handwritten.
function fixture(name,datatypes,build,expected,checks={}){
 let next=0n;const locations=[];const fresh=()=>String(next++);
 const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
 const fn=(name,argument_type,result_type,effects,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type,result_type,effects,body:body(parameter_id)};};
 const functions=build({fresh,node,fn});
 const program={contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/2',slice:'TC0-A',module:name,datatypes,effects:[],functions,entry:'main',input_schema:{type:functions[0].argument_type},source_map:locations.map(id=>({id,file:name,line:'0',column:'0'}))};
 return {name,program,expected_outcome:expected,...checks};
}
const int=(node,n)=>node('int',String(n));
const prim=(node,op,...args)=>node('prim',op,...args);
const IntList={name:'IntList',constructors:[{name:'Nil',fields:[]},{name:'Cons',fields:['I64',['Data','IntList']]}]};
const Opt={name:'Opt',constructors:[{name:'None',fields:[]},{name:'Some',fields:['I64']}]};
const Box={name:'Box',constructors:[{name:'Box',fields:[['Arrow','I64','I64',[]]]}]};
const list=(node,...xs)=>xs.reduceRight((tail,x)=>node('construct','IntList','Cons',int(node,x),tail),node('construct','IntList','Nil'));
const traps=['Overflow','DivZero','Bounds','InvalidDuration','TaskLimit','ChildFailed'];
export const cases=[
 // [68 69 ff 00]: length 4, index 2 = 255, last valid index 3 = 0.
 fixture('bytes-concat-length-index',[],({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>{const b=fresh();return node('let',b,prim(node,'bytes_concat',node('bytes','6869'),node('bytes','ff00')),
   prim(node,'add',prim(node,'add',prim(node,'bytes_length',node('var',b)),prim(node,'bytes_index',node('var',b),int(node,2))),prim(node,'bytes_index',node('var',b),int(node,3))));})
 ],['Ok',['int','259']]),
 // Index equal to the length is out of bounds; the trap suppresses the later emit.
 fixture('bytes-index-bounds-suppresses-emit',[],({fn,node,fresh})=>[
  fn('main','I64','I64',['Emit'],()=>prim(node,'add',prim(node,'bytes_index',node('bytes','00'),int(node,1)),node('call','later',int(node,1)))),
  fn('later','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','forbidden',node('var',p)),node('var',p)))
 ],['Trap','Bounds'],{expected_emissions:[]}),
 // Empty bytes have length 0; a negative index traps Bounds.
 fixture('bytes-empty-negative-index',[],({fn,node})=>[
  fn('main','I64','I64',[],()=>node('if',prim(node,'eq',prim(node,'bytes_length',node('bytes','')),int(node,0)),prim(node,'bytes_index',node('bytes','ab'),int(node,-1)),int(node,7)))
 ],['Trap','Bounds']),
 // Tuple fields are collected left to right; projection is static metadata.
 fixture('tuple-left-to-right-project',[],({fn,node,fresh})=>[
  fn('main','I64','I64',['Emit'],()=>{const t=fresh();return node('let',t,node('tuple',node('call','left',int(node,2)),node('call','right',int(node,3)),node('bytes','01')),
   prim(node,'sub',node('project',node('var',t),'1'),node('project',node('var',t),'0')));}),
  fn('left','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','left',node('var',p)),node('var',p))),
  fn('right','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','right',node('var',p)),node('var',p)))
 ],['Ok',['int','1']],{expected_emissions:['left','right']}),
 // Non-tail recursion through match arms over a recursive datatype.
 fixture('recursive-datatype-sum',[IntList],({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>node('call','sum',list(node,1,2,3))),
  fn('sum',['Data','IntList'],'I64',[],p=>{const h=fresh(),t=fresh();return node('match',node('var',p),['Nil',[],int(node,0)],['Cons',[h,t],prim(node,'add',node('var',h),node('call','sum',node('var',t)))]);})
 ],['Ok',['int','6']],{expected_return_frames:'3'}),
 // A call in a match arm is in tail position: no Return frames. Depth peaks at 6
 // in main while collecting the nested list literal (call, tuple, four Cons),
 // not in the loop, whose deepest operand chain is call/tuple/add/project = 4.
 fixture('match-arm-tail-call',[IntList],({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>node('call','count',node('tuple',list(node,5,6,7,8),int(node,0)))),
  fn('count',['Tuple',['Data','IntList'],'I64'],'I64',[],p=>{const h=fresh(),t=fresh();return node('match',node('project',node('var',p),'0'),
   ['Cons',[h,t],node('call','count',node('tuple',node('var',t),prim(node,'add',node('project',node('var',p),'1'),int(node,1))))],
   ['Nil',[],node('project',node('var',p),'1')]);})
 ],['Ok',['int','4']],{expected_return_frames:'0',maximum_depth:'6'}),
 // Structural equality over tuples, bytes and constructors.
 fixture('structural-eq',[Opt],({fn,node})=>{
  const value=n=>node('tuple',node('bytes','01'),node('construct','Opt','Some',int(node,n)));
  return [fn('main','I64','I64',[],()=>node('if',prim(node,'eq',value(5),value(5)),
   node('if',prim(node,'eq',node('construct','Opt','Some',int(node,1)),node('construct','Opt','None')),int(node,1),int(node,2)),int(node,3)))];
 },['Ok',['int','2']]),
 // TrapCode is a closed built-in enum: construct, emit and exhaustively match it.
 fixture('trapcode-enum-result',[],({fn,node,fresh})=>[
  fn('main','I64',['Tuple','I64','TrapCode'],['Emit'],()=>{const c=fresh();return node('let',c,node('construct','TrapCode','Bounds'),
   node('let',fresh(),node('emit','code',node('var',c)),
    node('tuple',node('match',node('var',c),...traps.map((k,i)=>[k,[],int(node,k==='Bounds'?42:i)])),node('var',c))));})
 ],['Ok',['tuple',['int','42'],['data','TrapCode','Bounds']]],{expected_emissions:['code']}),
 // A trap inside a constructor field unwinds through the Collect and match frames.
 fixture('match-scrutinee-trap',[Opt],({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>prim(node,'add',int(node,1),node('match',node('construct','Opt','Some',prim(node,'div',int(node,1),int(node,0))),['None',[],int(node,0)],['Some',[fresh()],int(node,0)])))
 ],['Trap','DivZero']),
 // Datatype fields may hold closures; the descriptor survives construct/match.
 fixture('closure-in-datatype-field',[Box],({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>{const k=fresh(),q=fresh(),f=fresh();return node('let',k,int(node,10),
   node('match',node('construct','Box','Box',node('lambda',q,'I64','I64',[],[],prim(node,'add',node('var',q),node('var',k)))),['Box',[f],node('apply',node('var',f),int(node,5))]));})
 ],['Ok',['int','15']],{expected_descriptor_count:'1'})
];
