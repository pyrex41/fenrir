import {createHash} from 'node:crypto';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';
import {encode} from '../tc0/canonical.mjs';
export const PROFILE='fenrir-aarch64-checked-unary/1';
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export class UnsupportedProfile extends Error {}
const reject = message => {throw new UnsupportedProfile(message);};

// Run the existing closed validator first. Admission is independent of the
// runtime input: zero is only a well-typed witness for its input argument.
export function compileArtifact(bytes) {
 const {artifact:a}=validatePureCallArtifact(bytes,['int','0']);
 if(a.functions.length!==1||a.datatypes.length||a.effects.length)reject('One function, no declarations');
 const f=a.functions[0];
 if(f.name!==a.entry||f.argument_type!=='I64'||f.result_type!=='I64'||f.effects.length)reject('Pure I64 entry required');
 function project(e) {
  if(e[0]==='var'&&e[2]===f.parameter_id)return {kind:'input'};
  if(e[0]!=='prim')reject(`Unsupported expression ${e[0]}`);
  const op=e[2];
  if(op==='neg')return {kind:'neg',inner:project(e[3])};
  if(!['add','sub'].includes(op)||e[4][0]!=='int')reject('Only neg and add/sub with literal right operand');
  const k=BigInt(e[4][2]);if(k<0n||k>4095n)reject('Immediate outside 0..4095');
  return {kind:op,k:Number(k),inner:project(e[3])};
 }
 const source=project(f.body),ops=[];
 function lower(e){if(e.kind==='input')return;lower(e.inner);ops.push(e);}
 lower(source);
 const words=ops.flatMap(op=>[
  op.kind==='neg'?0xeb0003e0:(op.kind==='add'?0xb1000000:0xf1000000)+op.k*1024,
  0x54000067,0xd2800021,0xd65f03c0,
 ]).concat([0xd2800001,0xd65f03c0]);
 const binary=Buffer.alloc(words.length*4);words.forEach((w,i)=>binary.writeUInt32LE(w,i*4));
 const manifest={profile:PROFILE,artifact_sha256:sha256(encode(a)),binary_sha256:sha256(binary),
  binary_bytes:binary.length,operations:ops.length,
  scope:'Function only; handwritten instruction model; no Sail/ARM correspondence proof',
  open_obligations:['json-projection','authoritative-isa-refinement','loader-and-call-abi','native-runtime','process-lifecycle']};
 return {artifact:a,source,words,binary,manifest};
}
function coqExpr(e){return e.kind==='input'?'Input':`(Apply ${e.kind==='neg'?'Neg':`(${e.kind==='add'?'Add':'Sub'} ${e.k})`} ${coqExpr(e.inner)})`;}
export function proofInstance(result){
 const {source,binary,manifest}=result;
 return `From Coq Require Import ZArith List Lia.\nFrom FenrirARM Require Import Core.\nImport ListNotations.\nOpen Scope Z_scope.\n(* Canonical artifact SHA256: ${manifest.artifact_sha256}\n   Exact code SHA256: ${manifest.binary_sha256}\n   JSON -> source projection is not yet verified. *)\nDefinition source : expr := ${coqExpr(source)}.\nDefinition image : list Z := [${[...binary].join(';')}].\nLemma image_identity : words_of_bytes image = Some (compile (lower source)).\nProof. vm_compute. reflexivity. Qed.\nLemma source_admitted : Forall admissible (lower source).\nProof. repeat constructor; cbn; lia. Qed.\nTheorem exact_image_correct : forall code x v tag,\n words_of_bytes image = Some code -> fits x = true ->\n run (4 * length (lower source) + 2)%nat code (State x v tag) = Some (eval_expr source x).\nProof. intros code x v tag H Hx. rewrite image_identity in H. injection H as H. subst code.\n apply expression_binary_correct. exact source_admitted. exact Hx. Qed.\nPrint Assumptions exact_image_correct.\n`;
}
export function writeBuild(result,dir){mkdirSync(dir,{recursive:true});
 writeFileSync(resolve(dir,'code.bin'),result.binary);
 writeFileSync(resolve(dir,'Instance.v'),proofInstance(result));
 writeFileSync(resolve(dir,'manifest.json'),JSON.stringify(result.manifest,null,2)+'\n');
}
if(process.argv[1]&&import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
 if(process.argv.length!==4)throw new Error('Usage: node tools/aarch64/compile.mjs ARTIFACT OUTPUT_DIR');
 writeBuild(compileArtifact(readFileSync(process.argv[2])),process.argv[3]);
}
