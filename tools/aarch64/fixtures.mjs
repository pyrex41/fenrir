export function fixture(operations){
 let id=2;const locations=['0'];const fresh=()=>{const x=String(id++);locations.push(x);return x;};
 let body=['var',fresh(),'1'];
 for(const [op,k] of operations)body=op==='neg'?['prim',fresh(),op,body]:['prim',fresh(),op,body,['int',fresh(),String(k)]];
 return {contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/2',slice:'TC0-A',module:'arm-checked',datatypes:[],effects:[],
 functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:'I64',effects:[],body}],entry:'main',input_schema:{type:'I64'},
 source_map:locations.map(id=>({id,file:'arm-checked',line:'0',column:'0'}))};
}
// The twelve operation chains of profile fenrir-aarch64-checked-unary/1 that
// tools/aarch64/check.mjs proves and runs, and the Shen differential reuses.
export const UNARY_CASES=[[],[['add',0]],[['add',1]],[['add',4095]],[['sub',1]],[['sub',4095]],[['neg']],
 [['add',1],['sub',1]],[['sub',1],['add',1]],[['neg'],['neg']],
 [['add',4095],['neg'],['sub',4095]],Array.from({length:12},(_,i)=>[i%2?'sub':'add',i*37])];
