// Writes the programs of the three AArch64 profiles for the Shen differential
// (harness/aarch64-differential.shen): one JSON line per program with the
// artifact (what the Shen model runs) and the Rocq term the lane's projection
// produces from it (what Rocq evaluates). No outcomes are computed here.
// Usage: node tools/aarch64/differential-programs.mjs OUTPUT.jsonl
import {writeFileSync} from 'node:fs';
import {encode} from '../tc0/canonical.mjs';
import {compileArtifact, coqExpr} from './compile.mjs';
import {fixture, UNARY_CASES} from './fixtures.mjs';
import {projectArtifact, rocqExpr} from './expr.mjs';
import {cases} from './expr-fixtures.mjs';
import {VALUES} from '../tc0/check-i64.mjs';
import {projectProgram, rocqProgram} from './call.mjs';
import {callCases} from './call-fixtures.mjs';

const rows = [];
UNARY_CASES.forEach((ops, i) => {
  const a = fixture(ops), r = compileArtifact(encode(a));
  rows.push({name: `unary-${i}`, profile: 'unary', result_type: 'I64', rocq: coqExpr(r.source), artifact: a});
});
for (const c of cases()) {
  const p = projectArtifact(encode(c.artifact));
  rows.push({name: c.name, profile: 'expr', result_type: p.resultType, rocq: rocqExpr(p.source), artifact: c.artifact});
}
for (const c of callCases()) {
  const p = projectProgram(encode(c.artifact));
  rows.push({name: c.name, profile: 'call', result_type: p.resultType, rocq: rocqProgram(p.fns), main: String(p.main), artifact: c.artifact});
}
// Inputs: the 33-value I64 boundary set of tools/tc0/check-i64.mjs (also the
// exact-arithmetic batch of the Solo5 lane), plus the unary profile's
// immediate-range boundaries.
const LO = -(1n << 63n), HI = (1n << 63n) - 1n;
const inputs = [...new Set([...VALUES, LO + 4094n, LO + 4095n, -4096n, 4095n, 4096n, HI - 4095n, HI - 4094n].map(String))];
const header = {schema: 'fenrir.aarch64.differential-programs/1', inputs, programs: String(rows.length)};
writeFileSync(process.argv[2], [header, ...rows].map(r => JSON.stringify(r)).join('\n') + '\n');
