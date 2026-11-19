import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

test('QEMU fault allowance does not count host errors as a killed mutant', t => {
  const bin = mkdtempSync(join(tmpdir(), 'fenrir-qemu-'));
  t.after(() => rmSync(bin, {recursive: true, force: true}));
  writeFileSync(join(bin, 'qemu-aarch64'), `#!/bin/sh
ulimit -c 0
case "$1" in
  --version) echo sentinel ;;
  guest-fault) kill -ILL $$ ;;
  host-kill) kill -KILL $$ ;;
  timeout) while :; do :; done ;;
esac
`, {mode: 0o755});
  const toolchain = new URL('../../tools/aarch64/toolchain.mjs', import.meta.url);
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {run} from ${JSON.stringify(toolchain.href)};
    const opts = {ok: false, allowSignals: ['SIGILL']};
    assert.equal(run('qemu', ['guest-fault'], opts).signal, 'SIGILL');
    assert.throws(() => run('qemu', ['guest-fault'], {ok: false}), /SIGILL/);
    assert.throws(() => run('qemu', ['host-kill'], opts), /SIGKILL/);
    assert.throws(() => run('qemu', ['timeout'], {...opts, timeout: 30}), /ETIMEDOUT/);
  `], {encoding: 'utf8', env: {...process.env, PATH: `${bin}:${process.env.PATH}`}, timeout: 5000});
  assert.equal(result.status, 0, result.stderr || String(result.error));
});
