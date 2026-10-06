// Finite deterministic valid family, UNQUALIFIED discovery scope (not exhaustive ASTs).
import {encode} from './canonical.mjs';
import {validatePureCallArtifact} from './pure-call-artifact.mjs';
export function generatePureCalls(maxCases=32){
 if(!Number.isSafeInteger(maxCases)||maxCases<1||maxCases>32)throw new TypeError('Case cap1..32');
 const rows=[];
 // Stable order: padding3..0, captured0..1, argument-1..2.
 for(const padding of [3,2,1,0])for(const captured of [0,1])for(const argument of [-1,0,1,2]){
  let next=0n;const locations=[],fresh=()=>String(next++),node=(t,...a)=>{const id=fresh();locations.push(id);return [t,id,...a];};
  const lit=n=>node('int',String(n));
  const fn=(name,arg,result,effects,body)=>{const id=fresh(),parameter_id=fresh();locations.push(id);return {id,name,parameter_id,argument_type:arg,result_type:result,effects,body:body(parameter_id)};};
  const functions=[
   fn('main','I64','I64',['Emit'],()=>{const f=fresh();let body=node('let',f,node('call','make',lit(captured)),node('prim','add',node('call','left',lit(1)),node('apply',node('var',f),node('prim','add',lit(argument),lit(0)))));for(let i=0;i<padding;i++)body=node('let',fresh(),lit(0),node('if',node('bool',true),body,lit(0)));return body;}),
   fn('make','I64',['Arrow','I64','I64',['Emit']],[],p=>{const q=fresh();return node('lambda',q,'I64','I64',['Emit'],[],node('let',fresh(),node('emit','right',node('var',q)),node('prim','add',node('var',p),node('var',q))));}),
   fn('left','I64','I64',['Emit'],p=>node('let',fresh(),node('emit','left',node('var',p)),node('var',p)))
  ];
  const name='generated-'+String(rows.length),program={contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/1',slice:'TC0-A',module:name,datatypes:[],effects:[],functions,entry:'main',input_schema:{type:'I64'},source_map:locations.map(id=>({id,file:'generated-pure-call',line:'0',column:'0'}))};
  validatePureCallArtifact(encode(program),['int','0']);
  rows.push({name,program,expected_outcome:['Ok',['int',String(1+captured+argument)]],expected_emissions:['left','right'],parameters:{padding:String(padding),captured:String(captured),argument:String(argument)}});
 }
 return {schema:'pure-call-generated-family/1',scope:'32 configurations of one closed typed family, NOT exhaustive language exploration',enumeration_order:['padding3..0','captured0..1','argument-1..2'],family_size:'32',selected_count:String(maxCases),truncated:maxCases<32,cases:rows.slice(0,maxCases)};
}
