// Identity helper for standalone trusted-local closure development replay.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {hash,stateHash} from './closure-replay.mjs';
const digest=b=>createHash('sha256').update(b).digest('hex');
const source=p=>digest(readFileSync(new URL('../../'+p,import.meta.url)));
export function closureHeader(machine,program,input,reference,oracleIdentity,{run_id='closure-development',steps='200'}={}) {
 return {schema:'closure-demo-tape/1',profile:'pure-closure-demo/1',run_id,program_hash:hash(program),input_hash:hash(input),
  reference_hash:hash(reference),oracle_hash:hash(oracleIdentity),catalog_hash:source('spec/tc0/pure-closure-demo.json'),
  candidate_hash:source('runtime/tc0/closure-machine.mjs'),
  adapter_hash:hash(['tools/tc0/closure-replay.mjs','tools/tc0/closure-replay-header.mjs','tools/tc0/closure-artifact.mjs','tools/tc0/canonical.mjs'].map(source)),
  toolchain_hash:digest(readFileSync(process.execPath)),environment_hash:hash({node:process.version,platform:process.platform,arch:process.arch,mode:'trusted-local-development'}),
  initial_state_hash:stateHash(machine),bounds:{steps}};
}
