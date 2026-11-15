#!/usr/bin/env node
// SEPARATE AND WEAKER than a proof: a bounded check of the model's checked
// `add` (tc0.arithmetic add) on Shen/JIT, added because tools/tc0/check-i64.mjs
// has no carry or borrow chains across digit-length boundaries (10^k - 1,
// 10^k) and no values of middling length. Expected results are exact BigInt
// sums. Status of what it establishes: bounded exploration passed, on these
// inputs only.
// Usage: node verification/universal/bounded-add.mjs SHEN_JIT_EXECUTABLE
import {spawnSync} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {VALUES, expected} from '../../tools/tc0/check-i64.mjs';

const root = resolve(import.meta.dirname, '../..');
const MIN = -(1n << 63n), MAX = (1n << 63n) - 1n;
const extra = [];
for (let k = 1n; k <= 18n; k++) {
  const p = 10n ** k;
  extra.push(p - 1n, p, p + 1n, -(p - 1n), -p, -(p + 1n));
}
// Fixed-seed linear congruential generator: values of every length 1..19.
let seed = 0x5eed_f00dn;
const rnd = () => (seed = (seed * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n));
for (let i = 0; i < 228; i++) {
  const len = BigInt(1 + (i % 19));
  let v = rnd() % (10n ** len);
  if (rnd() & 1n) v = -v;
  if (v >= MIN && v <= MAX) extra.push(v);
}
const values = [...new Set([...VALUES, ...extra].map(String))].map(BigInt);
const canonical = s => /^(0|-?[1-9][0-9]*)$/.test(s);

const exe = process.argv[2];
if (!exe) throw new Error('Usage: bounded-add.mjs SHEN_JIT_EXECUTABLE');
const dir = resolve(root, 'build/universal/bounded-add', `${Date.now()}-${process.pid}`);
mkdirSync(dir, {recursive: true});
const rows = [];
for (const a of values) for (const b of values) rows.push([a, b]);
const lines = [`(load "${resolve(root, 'models/tc0/i64.shen')}")`, '(output "FU-BEGIN~%")'];
for (const [a, b] of rows) lines.push(`(output "~A~%" (tc0.arithmetic add ["${a}" "${b}"]))`);
lines.push('(output "FU-END~%")');
const script = resolve(dir, 'cases.shen');
writeFileSync(script, lines.join('\n') + '\n');
const r = spawnSync(resolve(exe), ['script', script], {timeout: 1800000, maxBuffer: 256 * 1024 * 1024, env: {}});
if (r.error || r.signal || r.status !== 0) {
  console.error(`Shen run failed: ${r.error?.message || r.signal || r.stderr.toString().slice(-300)}`);
  process.exit(1);
}
const out = r.stdout.toString().split('\n'), begin = out.indexOf('FU-BEGIN'), end = out.indexOf('FU-END');
const got = begin < 0 || end < 0 ? [] : out.slice(begin + 1, end);
if (got.length !== rows.length) { console.error(`${got.length} results for ${rows.length} cases`); process.exit(1); }
const failures = [];
let ok = 0, overflow = 0;
rows.forEach(([a, b], i) => {
  const want = expected('add', a, b), line = got[i];
  const m = /^\[ok (.*)\]$/.exec(line);
  if (line !== want || (m && !canonical(m[1]))) { if (failures.length < 10) failures.push({a: String(a), b: String(b), want, got: line}); return; }
  if (m) ok++; else overflow++;
});
const report = {schema: 'fenrir.universal-bounded-add/1', status: failures.length ? 'fail' : 'bounded-exploration-passed',
  values: values.length, cases: rows.length, ok, overflow, failures};
console.log(JSON.stringify(report, null, 2));
if (failures.length) process.exitCode = 1;
