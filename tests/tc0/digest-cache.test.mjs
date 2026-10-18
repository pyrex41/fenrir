// The stat-keyed digest cache must never return a digest for changed content.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { digest } from '../../tools/tc0/digest-cache.mjs';
const sha = p => createHash('sha256').update(readFileSync(p)).digest('hex');
test('large-file digests are cached only while content identity is unchanged', () => {
  const parent = resolve('build/tc0');
  mkdirSync(parent, { recursive: true });
  const dir = mkdtempSync(resolve(parent, 'digest-cache-unit-'));
  try {
    const big = resolve(dir, 'big.bin');
    writeFileSync(big, Buffer.alloc(2 << 20, 1));
    assert.equal(digest(big), sha(big));
    assert.equal(digest(big), sha(big));
    const bytes = Buffer.alloc(2 << 20, 1);
    bytes[123] = 2;
    writeFileSync(big, bytes); // same size, rewritten in place
    assert.equal(digest(big), sha(big));
    const other = resolve(dir, 'other.bin');
    const swap = Buffer.alloc(2 << 20, 1);
    swap[7] = 9;
    writeFileSync(other, swap);
    renameSync(other, big); // replaced by rename
    assert.equal(digest(big), sha(big));
    const small = resolve(dir, 'small.txt');
    writeFileSync(small, 'a');
    assert.equal(digest(small), sha(small));
    writeFileSync(small, 'b');
    assert.equal(digest(small), sha(small));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
