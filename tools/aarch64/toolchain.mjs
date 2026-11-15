// Tool resolution for the AArch64 lane. Rocq 9 ships `rocq compile` and
// `rocqchk` in place of coqc/coqchk; nixpkgs' cross binutils use the
// aarch64-unknown-linux-gnu- prefix, Debian/Ubuntu's aarch64-linux-gnu-.
// The first candidate found on PATH is used; none found fails the check.
import {spawnSync} from 'node:child_process';

const CANDIDATES = {
  coqc: [['rocq', ['compile']], ['coqc', []]],
  coqchk: [['rocqchk', []], ['coqchk', []]],
  as: [['aarch64-unknown-linux-gnu-as', []], ['aarch64-linux-gnu-as', []]],
  ld: [['aarch64-unknown-linux-gnu-ld', []], ['aarch64-linux-gnu-ld', []]],
  objcopy: [['aarch64-unknown-linux-gnu-objcopy', []], ['aarch64-linux-gnu-objcopy', []]],
  qemu: [['qemu-aarch64', []]],
};
const found = new Map();
export function tool(name) {
  if (found.has(name)) return found.get(name);
  for (const [exe, pre] of CANDIDATES[name]) {
    const r = spawnSync(exe, [...pre, '--version'], {timeout: 60000});
    if (!r.error && r.status === 0) { const t = {exe, pre, version: r.stdout.toString().split('\n')[0]}; found.set(name, t); return t; }
  }
  throw new Error(`Missing tool for ${name}: tried ${CANDIDATES[name].map(c => c[0]).join(', ')}`);
}
export function run(name, args, {cwd, ok = true, timeout = 300000} = {}) {
  const t = tool(name);
  const r = spawnSync(t.exe, [...t.pre, ...args], {cwd, timeout, maxBuffer: 64 * 1024 * 1024});
  if (r.error || r.signal) throw new Error(`${t.exe}: ${r.error || r.signal}`);
  if (ok && r.status !== 0) throw new Error(`${t.exe} ${args.join(' ')}: ${r.stderr}\n${r.stdout}`);
  return r;
}
export const versions = () => Object.fromEntries(Object.keys(CANDIDATES).map(k => [k, `${tool(k).exe}: ${tool(k).version}`]));
