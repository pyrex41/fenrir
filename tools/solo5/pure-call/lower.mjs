// Artifact admission and data-only lowering of a BATCH of TC0-A pure-call
// programs to a C header for backends/solo5/pure-call. No machine or oracle
// transition imports. Static syntax facts only: node tables, child indices,
// callee indices, and each lambda's free bindings in numeric order.
// TC1-D1 (schema tc1-durable-demo/1, spec/tc1/DURABLE.md) adds, for that schema only: a
// durable flag and the result type descriptor on each perform of a durable effect, the
// datatype table, and the entry input as a canonical JSON value with its type. Rows of
// every older schema keep their existing fields and zero the added fields.
// TC1-C1 (schema tc1-task-demo/1, spec/tc1/CONCURRENCY.md) adds the nine task forms as
// node tags (scope, spawn, await, cancel, yield, channel, send, receive, close; a
// channel's capacity in `integer`, its element type dropped: it is metadata). Task
// programs are lowered only for the v3 control guest (lowerBatch with {tasks:true}); the
// free-running guest has no scheduler input and refuses them here.
import {createHash} from 'node:crypto';
import {validatePureCallArtifact} from '../../tc0/pure-call-artifact.mjs';
import {encode} from '../../tc0/canonical.mjs';

export class UnsupportedGuestProgram extends Error {}
const reject=message=>{throw new UnsupportedGuestProgram(message);};
const TAGS=['unit','bool','int','bytes','var','let','if','lambda','apply','call','prim','emit','tuple','project','construct','match',
  'handle','perform','resume','discontinue',
  'scope','spawn','await','cancel','yield','channel','send','receive','close'];
const OPS=['none','add','sub','mul','div','neg','lt','le','gt','ge','not','eq','bytes_length','bytes_index','bytes_concat'];
const MAX_ID=(1n<<64n)-1n,MAX_OPERANDS=16;
const id=value=>{if(!/^(0|[1-9][0-9]*)$/.test(value)||BigInt(value)>MAX_ID)reject('ID outside the guest adapter range');return `UINT64_C(${value})`;};
const name=value=>{if(typeof value!=='string'||!/^[A-Za-z_][A-Za-z0-9_-]{0,63}$/.test(value))reject('Name or label outside the guest adapter alphabet');return JSON.stringify(value);};
const int64=value=>{const n=BigInt(value);if(n<-(1n<<63n)||n>=(1n<<63n))reject('Integer outside I64');
  return n===-(1n<<63n)?'(-INT64_C(9223372036854775807)-1)':n<0n?`(-INT64_C(${-n}))`:`INT64_C(${n})`;};

// Free bindings of a lambda body, excluding its parameter.
function free(e,bound,out) {
  const [tag,,...x]=e;
  if(tag==='var'){if(!bound.has(x[0]))out.add(x[0]);}
  else if(tag==='let'){free(x[1],bound,out);free(x[2],new Set([...bound,x[0]]),out);}
  else if(tag==='lambda')free(x[5],new Set([...bound,x[0]]),out);
  else if(tag==='match'){free(x[0],bound,out);for(const [,binders,body] of x.slice(1))free(body,new Set([...bound,...binders]),out);}
  else if(tag==='handle'){for(const clause of x[1])free(clause.at(-1),new Set([...bound,...clause.slice(1,-1)]),out);free(x[2],bound,out);}
  else for(const child of operands(e))free(child,bound,out);
  return out;
}
function operands(e) {
  const [tag,,...x]=e;
  if(tag==='if'||tag==='apply'||tag==='tuple')return x;
  if(tag==='prim')return x.slice(1);
  if(tag==='construct')return x.slice(2);
  if(tag==='call'||tag==='emit')return [x[1]];
  if(tag==='project')return [x[0]];
  if(tag==='perform')return [x[2]];
  if(tag==='resume')return [x[1]];
  if(['scope','spawn','await','cancel','receive','close'].includes(tag))return [x[0]];
  if(tag==='send')return [x[0],x[1]];
  return [];
}

// TC1-D1 type descriptors (backends/solo5/pure-call/machine.h).
function descriptor(t,datatypes) {
  if(typeof t==='string'){const d={Unit:'U',Bool:'B',I64:'I',Bytes:'Y',TrapCode:'K'}[t];if(!d)reject('Type outside the guest adapter');return d;}
  if(t[0]==='Tuple'){
    if(t.length<2||t.length>9)reject('Tuple arity outside the guest adapter');
    return 'T'+(t.length-1)+t.slice(1).map(x=>descriptor(x,datatypes)).join('');
  }
  if(t[0]==='Data'){const i=datatypes.findIndex(d=>d.name===t[1]);if(i<0)reject('Unknown datatype');return `D${i};`;}
  return reject('Type outside the guest adapter');
}

export function lowerProgram(program,input,prefix,{durable=false,tasks=false}={}) {
  // Select the adapter before validation. The shared validator must still admit
  // every artifact and bound input, including in the dedicated durable lane.
  if(durable!==(program?.schema_version==='tc1-durable-demo/1'))
    reject(durable?'Expected a TC1-D1 durable artifact':'TC1-D1 requires a controlled v2 guest');
  if(tasks!==(program?.schema_version==='tc1-task-demo/1'))
    reject(tasks?'Expected a TC1-C1 task artifact':'Task programs need the v3 control guest (a scheduler input)');
  const {artifact,input:checkedInput}=validatePureCallArtifact(encode(program),input);
  const functions=artifact.functions,index=new Map(functions.map((f,i)=>[f.name,i]));
  const durableEffects=new Map(artifact.effects.filter(e=>e.class==='durable').map(e=>[e.name,e]));
  const rows=[],aux=[];
  const list=(kind,at,type,items)=>{if(!items.length)return '0';const symbol=`${prefix}_${kind}${at}`;aux.push(`static const ${type} ${symbol}[]={${items.join(',')}};`);return symbol;};
  function visit(e) {
    const [tag,node,...x]=e,at=rows.length;
    if(!TAGS.includes(tag))reject('Unsupported expression '+tag);
    const row={tag,id:id(node),op:'none',binding:'0',integer:'0',text:'0',text2:'0',index:'0',children:[],arms:[],free:[],type:'0'};
    rows.push(row);
    if(tag==='int')row.integer=int64(x[0]);
    else if(tag==='bool')row.integer=x[0]?'1':'0';
    else if(tag==='bytes'){if(!/^([0-9a-f]{2})*$/.test(x[0]))reject('Bytes literal');row.text=JSON.stringify(x[0]);}
    else if(tag==='var')row.binding=id(x[0]);
    else if(tag==='let'){row.binding=id(x[0]);row.children=[visit(x[1]),visit(x[2])];}
    else if(tag==='lambda') {
      row.binding=id(x[0]);
      row.free=[...free(x[5],new Set([x[0]]),new Set())].sort((a,b)=>BigInt(a)<BigInt(b)?-1:1).map(id);
      row.children=[visit(x[5])];
    } else if(tag==='match') {
      row.children=[visit(x[0])];
      row.arms=x.slice(1).map(([constructor,binders,body],k)=>{
        const symbol=list(`b${at}_`,k,'uint64_t',binders.map(id));
        return `{${name(constructor)},${binders.length},${symbol},${visit(body)}}`;
      });
    } else if(tag==='handle') {
      // Clauses lower as arms: the operation name, then the argument binder and, when the
      // clause names one, the resumption binder.
      row.text=name(x[0]);
      row.arms=x[1].map((clause,k)=>{
        const binders=clause.slice(1,-1),symbol=list(`b${at}_`,k,'uint64_t',binders.map(id));
        return `{${name(clause[0])},${binders.length},${symbol},${visit(clause.at(-1))}}`;
      });
      row.children=[visit(x[2])];
    } else {
      if(tag==='perform'){row.text=name(x[0]);row.text2=name(x[1]);
        if(durable&&durableEffects.has(x[0])){
          row.integer='1';
          row.type=JSON.stringify(descriptor(durableEffects.get(x[0]).operations.find(o=>o.name===x[1]).result_type,artifact.datatypes));
        }}
      if(tag==='resume'||tag==='discontinue')row.binding=id(x[0]);
      if(tag==='prim'){if(!OPS.includes(x[0])||x[0]==='none')reject('Unsupported primitive');row.op=x[0];}
      if(tag==='call'){if(!index.has(x[0]))reject('Unknown function');row.index=String(index.get(x[0]));}
      if(tag==='emit')row.text=name(x[0]);
      if(tag==='channel')row.integer=int64(x[1]);
      if(tag==='project')row.index=String(BigInt(x[1]));
      if(tag==='construct'){row.text=name(x[0]);row.text2=name(x[1]);}
      row.children=operands(e).map(visit);
      if(row.children.length>MAX_OPERANDS)reject('Too many operands for the guest adapter');
    }
    return at;
  }
  const bodies=functions.map(f=>({parameter:id(f.parameter_id),body:visit(f.body)}));
  const nodes=rows.map((r,at)=>`{${TAGS.indexOf(r.tag)},${r.id},${OPS.indexOf(r.op)},${r.binding},${r.integer},${r.text},${r.text2},${r.index},`+
    `${r.children.length},${list('c',at,'int',r.children.map(String))},${r.arms.length},${list('a',at,'struct pc_arm',r.arms)},${r.free.length},${list('f',at,'uint64_t',r.free)}`+
    `,${r.type}}`);
  // A serving peer starts at the function selected by pc_start, not at an entry.
  const entry=artifact.entry===undefined?0:index.get(artifact.entry);
  let row;
  if(durable) {
    // TC1-D1: the datatype table, and the input as a canonical JSON value of the entry type.
    const tables=artifact.datatypes.map((d,k)=>{
      const ctors=d.constructors.map((c,j)=>`{${name(c.name)},${c.fields.length},${list(`t${k}_`,j,'char *const',c.fields.map(f=>JSON.stringify(descriptor(f,artifact.datatypes))))}}`);
      return `{${name(d.name)},${d.constructors.length},${list('d',k,'struct pc_constructor',ctors)}}`;
    });
    const value=encode(checkedInput).toString('utf8');
    if(!/^[\x20-\x7e]*$/.test(value))reject('Input outside the guest adapter alphabet');
    row=`{${prefix}_nodes,${rows.length},${prefix}_functions,${functions.length},${entry},PC_INPUT_VALUE,0,${JSON.stringify(value)},`+
      `${JSON.stringify(descriptor(functions[entry].argument_type,artifact.datatypes))},${list('dt','','struct pc_datatype',tables)},${tables.length}}`;
  } else {
    const inputTags={unit:0,bool:1,int:2};
    if(!Object.hasOwn(inputTags,input[0]))reject('Only unit, bool and int entry inputs are lowered');
    const inputInteger=input[0]==='int'?int64(input[1]):input[0]==='bool'?(input[1]?'1':'0'):'0';
    row=`{${prefix}_nodes,${rows.length},${prefix}_functions,${functions.length},${entry},${inputTags[input[0]]},${inputInteger},0,0,0,0}`;
  }
  const text=[...aux,`static const struct pc_node ${prefix}_nodes[]={\n${nodes.join(',\n')}\n};`,
    `static const struct pc_function ${prefix}_functions[]={${bodies.map(b=>`{${b.parameter},${b.body}}`).join(',')}};`].join('\n');
  return {text,row,artifact_sha256:createHash('sha256').update(encode(artifact)).digest('hex'),nodes:rows.length,
    input_sha256:createHash('sha256').update(encode(durable?checkedInput:input)).digest('hex'),function_index:Object.fromEntries(index)};
}

// items: [{program, input}]. Returns the data header, hashes and function indices.
// bindInputs (TC1-D1 batches): the batch identity covers each entry's input as well,
// since one image entry is one (artifact, input) pair.
export function lowerBatch(items,{bindInputs=false,durable=false,tasks=false}={}) {
  if(durable&&tasks)reject('Durable and task batches are separate adapters');
  if(durable&&!bindInputs)reject('Durable batches must bind their inputs');
  const lowered=items.map((item,i)=>lowerProgram(item.program,item.input,`p${i}`,{durable,tasks}));
  const batch=createHash('sha256').update(lowered.map(l=>bindInputs?`${l.artifact_sha256}:${l.input_sha256}`:l.artifact_sha256).join('\n')).digest('hex');
  const header=`/* Validated artifact DATA ONLY, not precomputed transitions. */\n#define PC_BATCH_SHA256 "${batch}"\n`+
    lowered.map(l=>l.text).join('\n')+`\nstatic const struct pc_program pc_programs[]={\n${lowered.map(l=>l.row).join(',\n')}\n};\n`+
    `static const unsigned pc_program_count=${lowered.length};\n`;
  return {header,batch_sha256:batch,artifact_sha256:lowered.map(l=>l.artifact_sha256),
    input_sha256:lowered.map(l=>l.input_sha256),function_index:lowered.map(l=>l.function_index)};
}
