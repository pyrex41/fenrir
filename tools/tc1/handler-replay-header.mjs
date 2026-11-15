// Source-bound tape header for TC1 handler replay; trusted-local DEVELOPMENT, not
// evaluator authority. Binds the program, input, reference trace, oracle identity, the
// handler transition catalog (spec/tc1/handler-catalog.json), the implementation source
// with its defect switches, the replay adapter sources, the node executable and the
// machine's initial state.
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {hash,stateHash,TAPE_SCHEMA,TAPE_PROFILE} from './handler-replay.mjs';
const digest=b=>createHash('sha256').update(b).digest('hex');
const source=p=>digest(readFileSync(new URL('../../'+p,import.meta.url)));
export const CATALOG='spec/tc1/handler-catalog.json';
export function handlerHeader(machine,program,input,reference,oracleIdentity,{run_id='tc1-handler-development',steps='1000'}={}){
 return {schema:TAPE_SCHEMA,profile:TAPE_PROFILE,run_id,program_hash:hash(program),input_hash:hash(input),reference_hash:hash(reference),
  oracle_hash:hash(oracleIdentity),catalog_hash:source(CATALOG),
  candidate_hash:hash({source:source('runtime/tc1/handler-machine.mjs'),options:machine.options}),
  adapter_hash:hash(['tools/tc1/handler-replay.mjs','tools/tc1/handler-replay-header.mjs','tools/tc0/pure-call-artifact.mjs','tools/tc0/canonical.mjs'].map(source)),
  toolchain_hash:digest(readFileSync(process.execPath)),
  environment_hash:hash({node:process.version,platform:process.platform,arch:process.arch,mode:'trusted-local-development'}),
  initial_state_hash:stateHash(machine),bounds:{steps}};
}
