// Source-bound identity helper; trusted-local DEVELOPMENT, not evaluator authority.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {hash,stateHash} from './pure-call-replay.mjs';
const digest=b=>createHash('sha256').update(b).digest('hex');
const source=p=>digest(readFileSync(new URL('../../'+p,import.meta.url)));
export function pureCallHeader(machine,program,input,reference,oracleIdentity,{run_id='pure-call-development',steps='200'}={}){
 return {schema:'pure-call-demo-tape/1',profile:'pure-call-demo-step/1',run_id,program_hash:hash(program),input_hash:hash(input),reference_hash:hash(reference),oracle_hash:hash(oracleIdentity),catalog_hash:source('spec/tc0/pure-call-demo.json'),candidate_hash:hash({source:source('runtime/tc0/pure-call-machine.mjs'),reverse_operands:machine.reverseOperands}),adapter_hash:hash(['tools/tc0/pure-call-replay.mjs','tools/tc0/pure-call-replay-header.mjs','tools/tc0/pure-call-artifact.mjs','tools/tc0/canonical.mjs'].map(source)),toolchain_hash:digest(readFileSync(process.execPath)),environment_hash:hash({node:process.version,platform:process.platform,arch:process.arch,mode:'trusted-local-development'}),initial_state_hash:stateHash(machine),bounds:{steps}};
}
