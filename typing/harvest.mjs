// Harvest every (artifact, input) a validator test file hands to the validator, for the
// typing differential (typing/families.mjs). UNQUALIFIED development transport.
// The test file is imported with node:test replaced by a stub that runs each test body
// at once, and with tools/tc0/pure-call-artifact.mjs wrapped so that each call of
// validatePureCallArtifact is recorded before the real validator runs. So the programs
// are exactly those the test file builds, accepted ones and rejected ones alike; the
// tests' own assertions are not judged here.
import {register} from 'node:module';

const stub=`export default function test(name,options,fn){const body=typeof options==='function'?options:fn;
 try{const r=body();if(r&&typeof r.then==='function')r.catch(()=>{});}catch(e){(globalThis.__harvestFailures??=[]).push(name);}}
export const test2=test;`;
const wrapper=real=>`import * as real from ${JSON.stringify(real)};export * from ${JSON.stringify(real)};
export function validatePureCallArtifact(bytes,input,options){(globalThis.__harvest??=[]).push({text:Buffer.from(bytes).toString('utf8'),input,options:options??null});
 return real.validatePureCallArtifact(bytes,input,options);}`;
const hooks=`
export async function resolve(specifier,context,next){
  if(specifier==='node:test')return {url:'data:text/javascript,'+encodeURIComponent(${JSON.stringify(stub)}),shortCircuit:true};
  const r=await next(specifier,context);
  if(r.url.endsWith('/tools/tc0/pure-call-artifact.mjs')&&!(context.parentURL??'').startsWith('data:')&&(context.parentURL??'').includes('/tests/'))
    return {url:'data:text/javascript,'+encodeURIComponent((${wrapper.toString()})(r.url+'?real')),shortCircuit:true};
  return r;
}`;
let registered=false;
export async function harvest(testFile) {
  if(!registered){register('data:text/javascript,'+encodeURIComponent(hooks));registered=true;}
  globalThis.__harvest=[];
  await import(testFile);
  return globalThis.__harvest.filter(c=>c.options===null||Object.keys(c.options).length===0).map(({text,input})=>({text,input}));
}
