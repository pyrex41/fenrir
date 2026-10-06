// Artifact admission and data-only lowering; no machine/oracle transition imports.
import { constants, openSync, fstatSync, readSync, closeSync, writeFileSync, existsSync, realpathSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateArtifact } from '../../tc0/artifact.mjs';
import { decode, encode } from '../../tc0/canonical.mjs';
import { createHash } from 'node:crypto';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
// Cap file bytes before decoding, including non-regular or changing inputs.
// Canonical/semantic admission remains the unchanged TC0 validator's job.
export const maxAdmissionBytes=4*1024*1024;
export function readAdmissionFile(path) {
  const fd=openSync(path,constants.O_RDONLY|constants.O_NONBLOCK);
  try {
    if(!fstatSync(fd).isFile())throw new Error('NativeAdmissionRegularFileRequired');
    const bytes=Buffer.alloc(maxAdmissionBytes+1);
    let used=0;
    while(used<bytes.length) {
      const n=readSync(fd,bytes,used,bytes.length-used,null);
      if(n===0)break;
      used+=n;
    }
    if(used>maxAdmissionBytes)throw new Error('NativeAdmissionByteLimit');
    return bytes.subarray(0,used);
  } finally { closeSync(fd); }
}
const maxId=(1n<<64n)-1n;
const tags=['unit','bool','int','var','let','if','prim','emit'];
const ops=['add','sub','mul','div','neg','lt','le','gt','ge','not'];
export function lower(bytes,input) {
  const graph=validateArtifact(bytes,input,{maxNodes:100,maxDepth:32});
  const fn=graph.artifact.functions[0], rows=[];
  function id(value) {
    if (BigInt(value)>maxId) throw new Error('Unsupported native adapter ID range');
    return value;
  }
  id(fn.id);id(fn.parameter_id);
  function visit(e) {
    const [tag,node,...args]=e,index=rows.length;
    const row={tag,id:id(node),binding:'0',op:'none',literal:['unit'],label:'',children:[]};
    rows.push(row);
    if(tag==='int')row.literal=['int',args[0]];
    if(tag==='bool')row.literal=['bool',args[0]];
    if(tag==='var')row.binding=id(args[0]);
    if(tag==='let'){row.binding=id(args[0]);row.children=[visit(args[1]),visit(args[2])];}
    if(tag==='if')row.children=args.map(visit);
    if(tag==='prim'){row.op=args[0];row.children=args.slice(1).map(visit);}
    if(tag==='emit'){
      if(!/^[A-Za-z_][A-Za-z0-9_]{0,63}$/.test(args[0]))throw new Error('Unsupported native/Shen adapter label');
      row.label=args[0];row.children=[visit(args[1])];
    }
    return index;
  }
  const root=visit(fn.body);
  return {schema:'fenrir.solo5.native-arithmetic-lowering/1',artifact_sha256:hash(encode(graph.artifact)),
    input_sha256:hash(encode(graph.input)),parameter:id(fn.parameter_id),input:graph.input,root,rows};
}
function literal(v) {
  if(v[0]==='unit')return '{0,0}';
  if(v[0]==='bool')return `{1,${v[1]?'1':'0'}}`;
  const n=BigInt(v[1]);
  return `{2,${n===-(1n<<63n)?'(-INT64_C(9223372036854775807)-1)':n<0n?`(-INT64_C(${-n}))`:`INT64_C(${n})`}}`;
}
export function dataHeader(data) {
  const rows=data.rows.map(r=>`{${tags.indexOf(r.tag)},UINT64_C(${r.id}),UINT64_C(${r.binding}),${ops.indexOf(r.op)},${literal(r.literal)},${JSON.stringify(r.label)},${r.children.length},{${[...r.children,...Array(3-r.children.length).fill(-1)].join(',')}}}`).join(',\n');
  return `/* Validated artifact DATA ONLY, not precomputed transitions. */\n#define NA_ARTIFACT_SHA256 "${data.artifact_sha256}"\n#define NA_INPUT_SHA256 "${data.input_sha256}"\nstatic const struct na_node na_nodes[]={\n${rows}\n};\nstatic const unsigned na_node_count=${data.rows.length};\nstatic const unsigned na_root=${data.root};\nstatic const uint64_t na_parameter=UINT64_C(${data.parameter});\nstatic const struct na_value na_input=${literal(data.input)};\n`;
}
if(process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [artifactFile,inputFile,outputFile]=process.argv.slice(2);
  if(!outputFile || process.argv.length!==5)throw new Error('Usage: lower.mjs artifact.json input.json fresh-build-data.h');
  const root=fileURLToPath(new URL('../../..',import.meta.url)),output=resolve(outputFile);
  const inside=relative(resolve(root,'build/solo5'),output);
  if(inside.startsWith('..') || inside==='' || existsSync(output))throw new Error('Fresh build/solo5 output required');
  const data=lower(readAdmissionFile(artifactFile),decode(readAdmissionFile(inputFile)));
  writeFileSync(output,dataHeader(data),{flag:'wx'});
  console.log(JSON.stringify({qualification:'UNKNOWN',artifact_sha256:data.artifact_sha256,input_sha256:data.input_sha256,nodes:String(data.rows.length)}));
}
