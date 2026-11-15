#!/usr/bin/env node
// Differential check of an edit to the artifact validator (tools/tc0/pure-call-artifact.mjs)
// on the existing corpora: every program of every schema older than the edit, plus
// mutations of them, must get exactly the same verdict from the old and the new
// validator: the same accepted result (canonical codes and node count), or a rejection
// of the same class with the same message. Development evidence only.
//
//   node tools/tc1/validator-differential.mjs OLD-VALIDATOR.mjs
//
// OLD-VALIDATOR.mjs is a copy of the validator before the edit (for example
// `git show REV:tools/tc0/pure-call-artifact.mjs`). It is imported from a scratch
// directory next to a copy of the current canonical.mjs, which the edit did not touch.
import {copyFileSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {encode} from '../tc0/canonical.mjs';
import * as current from '../tc0/pure-call-artifact.mjs';
import {cases as callHand} from '../../fixtures/tc0/pure-call-hand-cases.mjs';
import {cases as dataHand} from '../../fixtures/tc0/pure-data-hand-cases.mjs';
import {cases as handlerHand,resumptionCases} from '../../fixtures/tc1/handler-hand-cases.mjs';
import {cases as taskHand} from '../../fixtures/tc1/task-hand-cases.mjs';
import {enumeratePureData} from '../tc0/pure-data-enumerate.mjs';
import {generatePureCalls} from '../tc0/pure-call-generate.mjs';
import {generatePureData} from '../tc0/pure-data-generate.mjs';
import {enumerateHandlers} from './handler-enumerate.mjs';
import {generateHandlers} from './handler-generate.mjs';
import {enumerateTasks} from './task-enumerate.mjs';

const root=resolve(import.meta.dirname,'../..');
const [oldPath]=process.argv.slice(2);
if(!oldPath)throw new Error('Usage: validator-differential.mjs OLD-VALIDATOR.mjs');
const scratch=resolve(root,'build/validator-differential',`${Date.now()}-${process.pid}`);
mkdirSync(scratch,{recursive:true});
copyFileSync(resolve(root,'tools/tc0/canonical.mjs'),resolve(scratch,'canonical.mjs'));
copyFileSync(resolve(oldPath),resolve(scratch,'old-validator.mjs'));
const old=await import(pathToFileURL(resolve(scratch,'old-validator.mjs')).href);

const clone=x=>JSON.parse(JSON.stringify(x));
function verdict(v,program,input) {
  try{const r=v.validatePureCallArtifact(encode(program),input);return JSON.stringify({ok:true,codes:r.codes,nodes:r.node_count});}
  catch(e){return JSON.stringify({ok:false,error:e.constructor.name,message:e.message});}
}
// Mutations aimed at what the edit touches: effect declarations, effect sets of the
// entry, the identity fields. Each applies where it can and is skipped otherwise.
const mutations={
  'effect-class-field':p=>{if(!p.effects?.length)return null;p.effects[0].class='durable';return p;},
  'effect-class-ordinary':p=>{if(!p.effects?.length)return null;p.effects[0].class='ordinary';return p;},
  'entry-declares-user-effect':p=>{if(!p.effects?.length)return null;const f=p.functions.find(f=>f.name===p.entry);f.effects=[...new Set([...f.effects,p.effects[0].name])].sort();return p;},
  'slice-d1':p=>{p.slice='TC1-D1';return p;},
  'schema-durable-under-old-slice':p=>{p.schema_version='tc1-durable-demo/1';return p;},
  'entry-input-not-i64':p=>{p.input_schema={type:'Unit'};return p;},
};
const corpora={
  'tc0-call-hand':callHand.map(c=>c.program),
  'tc0-data-hand':dataHand.map(c=>c.program),
  'tc0-call-generated':generatePureCalls(32).cases.map(c=>c.program),
  'tc0-data-generated':generatePureData(24).cases.map(c=>c.program),
  'tc0-data-exhaustive-5':enumeratePureData(5,{maxCases:8000}).cases.map(c=>c.program),
  'tc1-handler-hand':[...handlerHand,...resumptionCases].map(c=>c.program),
  'tc1-handler-exhaustive-7':enumerateHandlers(7).cases.map(c=>c.program),
  'tc1-handler-generated':generateHandlers().cases.map(c=>c.program),
  'tc1-task-hand':taskHand.map(c=>c.program),
  'tc1-task-exhaustive':enumerateTasks().cases.map(c=>c.program),
};
const input=['int','0'];
const report={schema:'fenrir.validator-differential/1',evidence:'development',corpora:{},mutations:{},differences:[]};
let total=0,same=0,accepted=0;
for(const [name,programs] of Object.entries(corpora)){
  let n=0,ok=0;
  for(const [i,program] of programs.entries()){
    const variants=[['as-is',clone(program)],...Object.entries(mutations).map(([m,f])=>[m,f(clone(program))]).filter(([,p])=>p)];
    for(const [m,p] of variants){
      const a=verdict(old,p,input),b=verdict(current,p,input);
      total++;n++;report.mutations[m]=(report.mutations[m]??0)+1;
      if(a===b){same++;if(m==='as-is'&&JSON.parse(a).ok)ok++;}
      else if(report.differences.length<20)report.differences.push({corpus:name,index:i,variant:m,old:JSON.parse(a),new:JSON.parse(b)});
    }
  }
  accepted+=ok;report.corpora[name]={programs:programs.length,verdicts:n,accepted_as_is:ok};
}
Object.assign(report,{verdicts:total,identical:same,accepted_as_is:accepted,status:same===total?'identical':'DIFFERENT'});
console.log(JSON.stringify(report));
process.exitCode=same===total?0:1;
