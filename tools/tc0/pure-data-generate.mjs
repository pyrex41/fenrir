// Finite deterministic valid schema /2 family, UNQUALIFIED discovery scope (not exhaustive ASTs).
// Every case uses bytes literals, bytes_concat/bytes_index, tuples, project,
// a declared datatype with construct and match, structural eq, emit and named calls:
//
//   main(_): padding( let t = (left(a), right(b), bytes_concat(01, ff))
//                     let s = Shape.<ctor>(t.0, t.1)
//                     if eq(t.2, 01ff) then add(area(s), bytes_index(t.2, 1)) else 0 )
//   area(s): match s with the three arms listed in <order>
//
// Expected outcomes are computed here from the configuration parameters, not by
// running a candidate. Arm order is "declared" or "rotated"; rotation is what
// distinguishes an arm-by-position mutant, and declared order is its equivalent case.
import {encode} from './canonical.mjs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
const Shape={name:'Shape',constructors:['Sq','Rect','Tri'].map(name=>({name,fields:['I64','I64']}))};
const area={Sq:(x)=>x*x,Rect:(x,y)=>x*y,Tri:(x,y)=>Math.trunc(x*y/2)};
export function generatePureData(maxCases=24){
 if(!Number.isSafeInteger(maxCases)||maxCases<1||maxCases>24)throw new TypeError('Case cap1..24');
 const rows=[];
 // Stable order: arm order declared..rotated, padding 3..0, constructor Sq..Tri.
 for(const order of ['declared','rotated'])for(const padding of [3,2,1,0])for(const ctor of ['Sq','Rect','Tri']){
  let next=0n;const locations=[],fresh=()=>String(next++),node=(t,...a)=>{const id=fresh();locations.push(id);return [t,id,...a];};
  const lit=n=>node('int',String(n)),prim=(op,...a)=>node('prim',op,...a);
  const fn=(name,arg,result,effects,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type:arg,result_type:result,effects,body:body(parameter_id)};};
  const a=3+padding,b=4;
  const functions=[
   fn('main','I64','I64',['Emit'],()=>{const t=fresh(),s=fresh(),v=x=>node('var',x);
    let body=node('let',t,node('tuple',node('call','left',lit(a)),node('call','right',lit(b)),prim('bytes_concat',node('bytes','01'),node('bytes','ff'))),
     node('let',s,node('construct','Shape',ctor,node('project',v(t),'0'),node('project',v(t),'1')),
      node('if',prim('eq',node('project',v(t),'2'),node('bytes','01ff')),prim('add',node('call','area',v(s)),prim('bytes_index',node('project',v(t),'2'),lit(1))),lit(0))));
    for(let i=0;i<padding;i++)body=node('let',fresh(),lit(0),node('if',node('bool',true),body,lit(0)));return body;}),
   fn('area',['Data','Shape'],'I64',[],p=>{
    const arm=name=>{const x=fresh(),y=fresh(),v=k=>node('var',k);return [name,[x,y],name==='Sq'?prim('mul',v(x),v(x)):name==='Rect'?prim('mul',v(x),v(y)):prim('div',prim('mul',v(x),v(y)),lit(2))];};
    const names=order==='declared'?['Sq','Rect','Tri']:['Rect','Tri','Sq'];
    return node('match',node('var',p),...names.map(arm));}),
   fn('left','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','left',node('var',p)),node('var',p))),
   fn('right','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','right',node('var',p)),node('var',p)))
  ];
  const name='generated-data-'+String(rows.length),program={contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/2',slice:'TC0-A',module:name,datatypes:[Shape],effects:[],functions,entry:'main',input_schema:{type:'I64'},source_map:locations.map(id=>({id,file:'generated-pure-data',line:'0',column:'0'}))};
  validatePureCallArtifact(encode(program),['int','0']);
  // The arm-by-position mutant evaluates the arm at the constructor's declared index.
  const names=order==='declared'?['Sq','Rect','Tri']:['Rect','Tri','Sq'],positional=names[Shape.constructors.findIndex(c=>c.name===ctor)];
  rows.push({name,program,expected_outcome:['Ok',['int',String(area[ctor](a,b)+255)]],expected_emissions:['left','right'],
   arm_by_position_outcome:['Ok',['int',String(area[positional](a,b)+255)]],parameters:{order,padding:String(padding),constructor:ctor}});
 }
 return {schema:'pure-data-generated-family/1',scope:'24 configurations of one closed typed schema /2 family, NOT exhaustive language exploration',enumeration_order:['order declared..rotated','padding3..0','constructor Sq..Tri'],family_size:'24',selected_count:String(maxCases),truncated:maxCases<24,cases:rows.slice(0,maxCases)};
}
