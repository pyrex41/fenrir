import test from 'node:test';
import assert from 'node:assert/strict';
import {encode} from '../../tools/tc0/canonical.mjs';
import {validatePureCallArtifact,InvalidPureCallArtifact,PureCallValidationLimit} from '../../tools/tc0/pure-call-artifact.mjs';
function artifact(){return {contract_version:'0.2',schema_version:'tc0-a-pure-call-demo/1',slice:'TC0-A',module:'hand-forward',datatypes:[],effects:[],functions:[
 {id:'0',name:'main',parameter_id:'1',argument_type:'I64',result_type:'I64',effects:[],body:['call','2','inc',['var','3','1']]},
 {id:'4',name:'inc',parameter_id:'5',argument_type:'I64',result_type:'I64',effects:[],body:['prim','6','add',['var','7','5'],['int','8','1']]}
 ],entry:'main',input_schema:{type:'I64'},source_map:['0','2','3','4','6','7','8'].map(id=>({id,file:'hand',line:'0',column:'0'}))};}
const check=a=>validatePureCallArtifact(encode(a),['int','0']);
test('new closed identity admits forward named calls, freezes checked graph',()=>{const r=check(artifact());assert.equal(r.node_count,'5');assert.deepEqual(r.codes.map(c=>c.capture_support),[[],[]]);assert.ok(Object.isFrozen(r.artifact.functions[0].body));});
test('older schemas remain incompatible; no silent widening',()=>{for(const schema of ['tc0-a-arithmetic-demo/1','pure-closure-demo/1']){const a=artifact();a.schema_version=schema;assert.throws(()=>check(a),InvalidPureCallArtifact);}});
test('reject duplicate IDs/names, missing/extra source maps, unknown calls/fields',()=>{for(const mutate of [a=>a.functions[1].id='0',a=>a.functions[1].name='main',a=>a.source_map.pop(),a=>a.source_map.push({id:'1',file:'x',line:'0',column:'0'}),a=>a.functions[0].body[2]='missing',a=>a.extra=true]){const a=artifact();mutate(a);assert.throws(()=>check(a),InvalidPureCallArtifact);}});
test('named bodies cannot see caller bindings; argument/effect checks',()=>{for(const mutate of [a=>a.functions[1].body[3][2]='1',a=>a.functions[1].argument_type='Bool',a=>{a.functions[1].effects=['Emit'];},a=>{a.functions[0].body=['emit','2','x',['var','3','1']];}]){const a=artifact();mutate(a);assert.throws(()=>check(a),InvalidPureCallArtifact);}});
test('validation caps are distinct from invalid syntax',()=>{assert.throws(()=>validatePureCallArtifact(encode(artifact()),['int','0'],{maxNodes:4}),PureCallValidationLimit);});
test('closure signature includes effects and empty support; higher-order result checked',()=>{const a=artifact();a.functions=a.functions.slice(0,1);a.functions[0].body=['apply','2',['lambda','3','4','I64','I64',[],[],['var','5','4']],['var','6','1']];a.source_map=['0','2','3','5','6'].map(id=>({id,file:'hand',line:'0',column:'0'}));const r=check(a);assert.deepEqual(r.codes.find(c=>c.code_id==='3'),{code_id:'3',parameter_id:'4',free_bindings:[],capture_support:[]});a.functions[0].body[2][7]=['9'];assert.throws(()=>check(a),InvalidPureCallArtifact);});
