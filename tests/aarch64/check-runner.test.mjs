import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {copyFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

// Exercise only shell orchestration in an isolated checkout, without Nix or
// proof tools. These shims do not produce proof evidence.
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'fenrir-aarch64-check-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const tools = join(root, 'tool prefix');
  const jit = join(root, 'jit prefix');
  for (const dir of ['verification/aarch64', 'harness', 'tests/aarch64',
    'tool prefix/bin', 'tool prefix/lib/coq/9.3/user-contrib/Stdlib', 'jit prefix/bin', 'jit prefix/lib']) {
    mkdirSync(join(root, dir), {recursive: true});
  }
  copyFileSync(new URL('../../verification/aarch64/check.sh', import.meta.url),
    join(root, 'verification/aarch64/check.sh'));
  function exe(file, body) {
    writeFileSync(join(root, file), `#!/bin/sh\n${body}\n`, {mode: 0o755});
  }
  for (const name of ['rocq', 'rocqchk', 'qemu-aarch64', 'as', 'ld', 'objcopy']) {
    exe(`tool prefix/bin/${name}`, 'exit 0');
  }
  exe('jit prefix/bin/shen-jit', 'exit 0');
  writeFileSync(join(jit, 'lib/shen-process.so'), '');
  exe('tool prefix/bin/node', 'echo "checks must not be reached" >&2; exit 70');
  function run() {
    return spawnSync('sh', ['verification/aarch64/check.sh'], {
      cwd: root, encoding: 'utf8', env: {...process.env, FENRIR_AARCH64_TOOLS: tools, FENRIR_SHEN_JIT: jit}
    });
  }
  function prefixBinutils(prefix) {
    for (const name of ['as', 'ld', 'objcopy']) {
      symlinkSync(name, join(tools, 'bin', `${prefix}-${name}`));
    }
  }
  return {root, tools, exe, run, prefixBinutils};
}

test('proof check rejects unprefixed binutils, even when present in the prefix', t => {
  const {run} = fixture(t);
  const result = run();
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /missing AArch64 GNU as/);
});

test('proof check requires the Stdlib namespace before invoking any checks', t => {
  const {run, tools, prefixBinutils} = fixture(t);
  prefixBinutils('aarch64-linux-gnu');
  rmSync(join(tools, 'lib/coq/9.3/user-contrib/Stdlib'), {recursive: true});
  const result = run();
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /missing Rocq standard library/);
});

test('a failing check stops the lane, saves its log and does not write a summary', t => {
  const {run, root, exe, prefixBinutils} = fixture(t);
  prefixBinutils('aarch64-unknown-linux-gnu');
  exe('tool prefix/bin/node', `
    test "$#" = 2 && test "$1" = --test || exit 71
    test -d "$ROCQPATH/Stdlib" && test -x "$FENRIR_SHEN_JIT/bin/shen-jit" || exit 72
    echo "intentional test failure"
    exit 1`);
  const result = run();
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stdout, /intentional test failure/);
  const [out] = readdirSync(join(root, 'build/aarch64'));
  assert.deepEqual(readdirSync(join(root, 'build/aarch64', out)), ['unit.log']);
});
