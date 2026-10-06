// Finite deterministic development enumeration. Not full TC0-A/exhaustive qualification.
import {encode} from './canonical.mjs';
import {validateArtifact} from './artifact.mjs';
export function* generate({maxCases=100,integers=['-2','-1','0','1','2']}={}) {
  if(!Number.isSafeInteger(maxCases)||maxCases<1) throw new TypeError('Invalid case cap');
  if(!Array.isArray(integers)||!integers.length||integers.length>16) throw new TypeError('Invalid integer domain');
  // Validate the domain even if the requested prefix never visits some values.
  for(const n of integers) {
    if(typeof n!=='string'||! /^(0|-[1-9][0-9]*|[1-9][0-9]*)$/.test(n) || BigInt(n)<-(1n<<63n)||BigInt(n)>=(1n<<63n)) throw new TypeError('Invalid I64 domain');
  }
  const total=4*integers.length**2*2*2;let index=0;
  for(const op of ['add','sub','mul','div']) for(const left of integers) for(const right of integers) for(const emit of [false,true]) for(const trapLeft of [false,true]) {
    if(index>=maxCases) return;
    let next=2n;const locations=[];
    const expr=(tag,...args)=>{const id=String(next++);locations.push(id);return [tag,id,...args];};
    // Allocation order is explicit but not evaluation order; IDs have no arithmetic meaning.
    let lhs=expr('int',left);const rhs=expr('int',right);
    if(trapLeft) lhs=expr('prim','div',lhs,expr('int','0'));
    let operand=rhs;
    if(emit) {
      const binding=String(next++),payload=expr('int',left),observation=expr('emit','rhs',payload);
      operand=expr('let',binding,observation,rhs);
    }
    let body=expr('prim',op,lhs,operand);
    // Redundant typed branch supplies generated structural reduction opportunities.
    if(trapLeft) body=expr('if',expr('bool',true),body,expr('int','0'));
    const artifact={contract_version:'0.2',schema_version:'tc0-a-arithmetic-demo/1',slice:'TC0-A',
      module:'generated_'+index,datatypes:[],effects:[],entry:'main',input_schema:{type:'Unit'},
      functions:[{id:'0',name:'main',parameter_id:'1',argument_type:'Unit',result_type:'I64',effects:emit?['Emit']:[],body}],
      source_map:['0',...locations].map(id=>({id,file:'generated.tc0',line:'1',column:'0'}))};
    validateArtifact(encode(artifact),['unit']);
    yield {index:String(index++),artifact,input:['unit'],enumeration:{total:String(total),cap:String(maxCases),
      truncated:maxCases<total,scope:'Arithmetic pair/op/optional left DivZero/right emission only',qualification:'UNKNOWN'}};
  }
}
