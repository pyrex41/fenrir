// SHA-256 with a stat-keyed cache for large files (toolchain binaries), shared
// with tools/check-tc0-expression.py through build/cache/sha256-stat.json.
// A cached digest is reused only while (dev, ino, size, mtime, ctime) are all
// unchanged: any write bumps ctime and a replacement changes the inode, and ctime
// cannot be set back without privileges. Files under 1 MiB are always rehashed.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const cachePath = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../../build/cache/sha256-stat.json'
);
const LARGE = 1 << 20;
let cache;
const load = () => {
  try {
    cache ??= JSON.parse(readFileSync(cachePath, 'utf8'));
  } catch {
    cache = {};
  }
  return cache;
};
const signature = s => [s.dev, s.ino, s.size, s.mtimeNs, s.ctimeNs].map(String);

export function digest(path) {
  const real = resolve(path),
    st = statSync(real, { bigint: true });
  if (st.size < LARGE) return createHash('sha256').update(readFileSync(real)).digest('hex');
  const sig = signature(st),
    hit = load()[real];
  if (hit && JSON.stringify(hit.stat) === JSON.stringify(sig)) return hit.sha256;
  const sha256 = createHash('sha256').update(readFileSync(real)).digest('hex');
  // Only record when the file did not change while it was being read.
  if (JSON.stringify(signature(statSync(real, { bigint: true }))) === JSON.stringify(sig)) {
    load()[real] = { stat: sig, sha256 };
    mkdirSync(dirname(cachePath), { recursive: true });
    const tmp = `${cachePath}.${process.pid}`;
    writeFileSync(tmp, JSON.stringify(cache));
    renameSync(tmp, cachePath);
  }
  return sha256;
}
