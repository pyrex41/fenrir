#!/usr/bin/env node
// Trusted local development peer, NOT an isolated candidate adapter or evaluator.
import { readFileSync } from 'node:fs';
import { validateArtifact } from './artifact.mjs';
import { ExpressionMachine } from '../../runtime/tc0/expression-machine.mjs';
const [file, flag] = process.argv.slice(2);
try {
  if (!file || (flag && flag !== '--reverse-operands') || process.argv.length > 4) throw new Error('Usage: run-expression.mjs artifact [--reverse-operands]');
  const graph=validateArtifact(readFileSync(file),['unit']);
  const fn=graph.artifact.functions[0];
  const machine=new ExpressionMachine(fn.body,fn.parameter_id,graph.input,{reverseOperands:flag === '--reverse-operands'});
  console.log(JSON.stringify({scope:'Unqualified arithmetic demo; local trusted process only',qualification:'UNKNOWN',...machine.run(200)}));
} catch(error) {console.error(error.name+': '+error.message);process.exitCode=2;}
