// Hand-assembled UNQUALIFIED distinguishing programs, not generated discovery.
// IDs/source-map rows are mechanically allocated; expected results are handwritten.
function fixture(name,build,expected,checks={}){
 let next=0n;const locations=[];const fresh=()=>String(next++);
 const node=(tag,...args)=>{const id=fresh();locations.push(id);return [tag,id,...args];};
 const fn=(name,argument_type,result_type,effects,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type,result_type,effects,body:body(parameter_id)};};
 const functions=build({fresh,node,fn});
 const program={contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/1',slice:'TC0-A',module:name,datatypes:[],effects:[],functions,entry:'main',input_schema:{type:functions[0].argument_type},source_map:locations.map(id=>({id,file:name,line:'0',column:'0'}))};
 return {name,program,expected_outcome:expected,...checks};
}
const int=(node,n)=>node('int',String(n));
export const cases=[
 fixture('mutual-tail-countdown',({fn,node})=>[
  fn('main','I64','I64',[],()=>node('call','even',int(node,4))),
  fn('even','I64','I64',[],p=>node('if',node('prim','le',node('var',p),int(node,0)),int(node,10),node('call','odd',node('prim','sub',node('var',p),int(node,1))))),
  fn('odd','I64','I64',[],p=>node('if',node('prim','le',node('var',p),int(node,0)),int(node,20),node('call','even',node('prim','sub',node('var',p),int(node,1)))))
 ],['Ok',['int','10']],{expected_return_frames:'0',maximum_depth:'2'}),
 fixture('non-tail-recursive-sum',({fn,node})=>[
  fn('main','I64','I64',[],()=>node('call','sum',int(node,3))),
  fn('sum','I64','I64',[],p=>node('if',node('prim','le',node('var',p),int(node,0)),int(node,0),node('prim','add',node('var',p),node('call','sum',node('prim','sub',node('var',p),int(node,1))))))
 ],['Ok',['int','6']],{expected_return_frames:'3'}),
 fixture('returned-closure-alias',({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>{const f=fresh(),alias=fresh();return node('let',f,node('call','make',int(node,7)),node('let',alias,node('var',f),node('prim','add',node('apply',node('var',f),int(node,2)),node('apply',node('var',alias),int(node,3)))));}),
  fn('make','I64',['Arrow','I64','I64',[]],[],p=>{const q=fresh();return node('lambda',q,'I64','I64',[],[],node('prim','add',node('var',p),node('var',q)));})
 ],['Ok',['int','19']],{expected_descriptor_count:'1'}),
 fixture('higher-order-captured-closure',({fn,node,fresh})=>[
  fn('main','I64','I64',[],()=>{const f=fresh(),g=fresh(),q=fresh(),r=fresh();return node('let',f,node('lambda',q,'I64','I64',[],[],node('prim','add',node('var',q),int(node,4))),node('let',g,node('lambda',r,'I64','I64',[],[],node('apply',node('var',f),node('var',r))),node('call','use',node('var',g))));}),
  fn('use',['Arrow','I64','I64',[]],'I64',[],p=>node('apply',node('var',p),int(node,5)))
 ],['Ok',['int','9']],{expected_descriptor_count:'2'}),
 fixture('named-emit-order',({fn,node,fresh})=>[
  fn('main','I64','I64',['Emit'],()=>node('prim','add',node('call','left',int(node,2)),node('call','right',int(node,3)))),
  fn('left','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','left',node('var',p)),node('var',p))),
  fn('right','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','right',node('var',p)),node('var',p)))
 ],['Ok',['int','5']],{expected_emissions:['left','right']}),
 fixture('left-call-trap-suppresses-emit',({fn,node,fresh})=>[
  fn('main','I64','I64',['Emit'],()=>node('prim','add',node('call','bad',int(node,0)),node('call','later',int(node,1)))),
  fn('bad','I64','I64',[],()=>node('prim','div',int(node,1),int(node,0))),
  fn('later','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','forbidden',node('var',p)),node('var',p)))
 ],['Trap','DivZero'],{expected_emissions:[]}),
 fixture('named-overflow-unwind',({fn,node})=>[
  fn('main','I64','I64',[],()=>node('prim','add',node('call','inc',int(node,'9223372036854775807')),int(node,0))),
  fn('inc','I64','I64',[],p=>node('prim','add',node('var',p),int(node,1)))
 ],['Trap','Overflow']),
 fixture('effectful-closure-unit-bool-unary',({fn,node,fresh})=>[
  fn('main','I64','I64',['Emit'],()=>{const f=fresh(),q=fresh(),ignored=fresh();return node('let',f,node('lambda',q,'I64','Unit',['Emit'],[],node('let',fresh(),node('emit','closure',node('var',q)),node('unit'))),node('let',ignored,node('if',node('prim','not',node('bool',false)),node('apply',node('var',f),int(node,3)),node('emit','unselected',int(node,99))),node('prim','neg',int(node,-9))));})
 ],['Ok',['int','9']],{expected_descriptor_count:'1',expected_emissions:['closure']})
];
