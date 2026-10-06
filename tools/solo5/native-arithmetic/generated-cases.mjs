// Finite typed DATA enumeration and structural reduction proposals, no candidate
// execution, oracle transitions or expected samples. Go runs builds/model/native.
import {mkdirSync,readFileSync,writeFileSync,realpathSync} from 'node:fs';
import {resolve,relative} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {encode,decode} from '../../tc0/canonical.mjs';
import {lower,dataHeader} from './lower.mjs';
const root=fileURLToPath(new URL('../../..',import.meta.url));
const [mode,directory,original]=process.argv.slice(2),dest=resolve(directory??'');
const base=realpathSync(resolve(root,'build/solo5')),parent=realpathSync(resolve(dest,'..'));
if(!['generate','reduce'].includes(mode)||relative(base,dest).startsWith('..')||relative(base,parent).startsWith('..')||dest===base)throw Error('Fresh local output required');
mkdirSync(dest);const manifest=[];
function save(name,body,hasEmit){
 const ids=[];function walk(e){ids.push(e[1]);for(const v of e.slice(2))if(Array.isArray(v))walk(v);}walk(body);
 const artifact={contract_version:'0.2',datatypes:[],effects:[],entry:'main',functions:[{argument_type:'Unit',body,effects:hasEmit?['Emit']:[],id:'0',name:'main',parameter_id:'1',result_type:'I64'}],input_schema:{type:'Unit'},module:name,schema_version:'tc0-a-arithmetic-demo/1',slice:'TC0-A',source_map:['0',...ids].map(id=>({column:'0',file:name+'.tc0',id,line:'1'}))};
 const bytes=encode(artifact),input=['unit'];writeFileSync(resolve(dest,name+'.artifact.json'),bytes,{flag:'wx'});writeFileSync(resolve(dest,name+'.input.json'),encode(input),{flag:'wx'});const data=lower(bytes,input);writeFileSync(resolve(dest,name+'.h'),dataHeader(data),{flag:'wx'});manifest.push({name,nodes:String(data.rows.length),artifact_sha256:data.artifact_sha256,input_sha256:data.input_sha256});
}
if(mode==='generate'){
 const ops=['add','sub','mul','div'],values=['-7','0','1','3'];
 for(let op=0;op<4;op++)for(let v=0;v<4;v++){
  const left=values[v],right=values[(v+3)%4];
  const body=['prim','2',ops[op],['let','3','100',['emit','4','g_left',['int','5',left]],['int','6',left]],['let','7','101',['emit','8','g_right',['int','9',right]],['int','10',right]]];
  save('case_'+String(op*4+v).padStart(2,'0'),body,true);
 }
}else{
 const a=decode(readFileSync(resolve(original))),body=a.functions[0].body;
 if(body[0]!=='prim'||body.length!==5||body[3][0]!=='let'||body[4][0]!=='let')throw Error('Unsupported bounded reducer shape');
 const first=structuredClone(body);first[3]=structuredClone(body[3][4]);save('attempt_1',first,true);
 const second=structuredClone(first);second[4]=structuredClone(body[4][4]);save('attempt_2',second,false);
 // A valid smaller artifact must be rechecked; dropping the primitive should
 // lose this operand-order failure and therefore be retained as a rejection.
 save('attempt_3',structuredClone(second[3]),false);
}
const generatorHash=createHash('sha256').update(readFileSync(fileURLToPath(import.meta.url))).digest('hex');
writeFileSync(resolve(dest,'manifest.json'),JSON.stringify({schema:'fenrir.solo5.native-arithmetic-generated-data/1',qualification:'UNKNOWN',mode,generator_sha256:generatorHash,bounds:{cases:'16',nodes:'100',steps:'200',reduction_attempts:'3'},cases:manifest},null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({qualification:'UNKNOWN',mode,cases:manifest.length,directory:dest}));
