#!/usr/bin/env node
// Source-bound trusted LOCAL development probe; NOT TC0-A qualification/isolation.
// Port of the former tools/check-tc0-expression.py main; its library half is
// tools/tc0/shen-probe.mjs.
import {mkdirSync, readFileSync, realpathSync, writeFileSync} from 'node:fs';
import {dirname, relative, resolve} from 'node:path';
import {isDeepStrictEqual} from 'node:util';
import {ROOT, digest, synchronous, shenExpr, parseList, normalizeExpression, outputPath, parseArgs} from './tc0/shen-probe.mjs';

function main() {
  const args=parseArgs(process.argv.slice(2),{values:['--shen-executable','--output']});
  if(!args['shen-executable']||!args.output)throw new Error('Usage: check-tc0-expression.mjs --shen-executable SHEN --output build/....json');
  // Follow symlinks: the runtime files are located relative to the real executable.
  const executable=realpathSync(resolve(args['shen-executable']));
  const node=process.execPath;
  const at=p=>resolve(ROOT,p);
  const program=at('fixtures/tc0/left-trap-program.json'),golden=at('fixtures/tc0/left-trap-trace.json');
  const model=at('models/tc0/expression-machine.shen'),arithmetic=at('models/tc0/arithmetic.shen'),peer=at('tools/tc0/run-expression.mjs');
  const sources=[program,golden,model,arithmetic,peer,import.meta.filename,at('tools/tc0/shen-probe.mjs'),at('tools/tc0/artifact.mjs'),
    at('tools/tc0/canonical.mjs'),at('runtime/tc0/expression-machine.mjs')];
  const snapshot=()=>Object.fromEntries(sources.map(p=>[relative(ROOT,p),digest(p)]));
  const before=snapshot();
  // Validate the artifact through the host adapter BEFORE model translation/execution.
  const candidate=JSON.parse(synchronous([node,peer,program]).stdout);
  const artifact=JSON.parse(readFileSync(program,'utf8')),hand=JSON.parse(readFileSync(golden,'utf8'));
  const fn=artifact.functions[0];
  const initial=`[state [eval ${shenExpr(fn.body)}] [[${fn.parameter_id} [unit]]] []]`;
  const count=hand.steps.length;
  const command=[executable,'eval','-l',arithmetic,'-l',model,'-e',`(set tc0.demo.state ${initial})`];
  for(let i=0;i<count;i++)command.push('-e','(tc0.demo.sample (value tc0.demo.state))','-e','(set tc0.demo.state (hd (tl (tc0.demo.step (value tc0.demo.state)))))');
  const {stdout:modelOut,stderr:modelErr}=synchronous(command);
  const samples=modelOut.split('\n').filter(line=>line.startsWith('[sample ')).map(parseList);
  if(samples.length!==count)throw new Error('Wrong model sample count');
  const modelSteps=samples.map((s,i)=>normalizeExpression(s,i));
  const mutant=JSON.parse(synchronous([node,peer,program,'--reverse-operands']).stdout);
  let first=null;
  for(let i=0;i<Math.min(modelSteps.length,mutant.steps.length)&&first===null;i++)if(!isDeepStrictEqual(modelSteps[i],mutant.steps[i]))first=String(i);
  if(!isDeepStrictEqual(before,snapshot()))throw new Error('Source drift during development check');
  const report={scope:'Unqualified arithmetic-demo hand fixture only; trusted local development',
    qualification:'UNKNOWN',sources:before,
    shen_executable_sha256:digest(executable),
    shen_boot_sha256:digest(resolve(executable,'../../lib/shen-scheme/shen.boot')),
    node_executable_sha256:digest(node),model_steps:modelSteps,
    model_matches_hand:isDeepStrictEqual(modelSteps,hand.steps),
    candidate_matches_hand:isDeepStrictEqual(candidate.steps,hand.steps),
    candidate_outcome_matches_hand:isDeepStrictEqual(candidate.outcome,hand.expected_outcome),
    mutant_first_step_divergence:first,
    mutant_emissions:mutant.events.filter(e=>e.kind==='Emit'),
    limitations:['Not full TC0-A; no calls/closures or other constructors',
      'Catalog/event/field shapes unreviewed','No strict tape replay or reduction',
      'No qualified OS isolation or evaluator registration']};
  const destination=outputPath(args.output);
  if(sources.includes(destination))throw new Error('Output overwrites source');
  mkdirSync(dirname(destination),{recursive:true});
  writeFileSync(destination,JSON.stringify(report,null,2)+'\n');
  writeFileSync(destination.replace(/\.json$/,'.shen.stdout'),modelOut);
  writeFileSync(destination.replace(/\.json$/,'.shen.stderr'),modelErr);
  const matched=report.model_matches_hand&&report.candidate_matches_hand&&report.candidate_outcome_matches_hand;
  console.log(JSON.stringify({development_agreement:matched,mutant_first_divergence:first,qualification:'UNKNOWN',report:destination}));
  process.exitCode=matched&&first==='1'&&report.mutant_emissions.length===1?0:1;
}
main();
