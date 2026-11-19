import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { constants } from 'node:fs';
import { access, lstat, mkdir, open, realpath } from 'node:fs/promises';
import { isAbsolute, relative, resolve, sep } from 'node:path';

export const sha = value => createHash('sha256').update(value).digest('hex');
export const decode = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes);
export const under = (root, path) => path === root || path.startsWith(root + sep);

export function localPath(path) {
  if (typeof path !== 'string' || !path || path.length > 4096 || isAbsolute(path) ||
      /[\\\x00-\x1f]/.test(path) || path.split('/').some(part => !part || part === '.' || part === '..' || part === '.git'))
    throw new Error(`Unsafe repository path: ${JSON.stringify(path)}`);
  return path;
}

export async function checkedPath(root, path, { directory = false, create = false } = {}) {
  let current = root;
  const parts = localPath(path).split('/');
  for (const [index, part] of parts.entries()) {
    current = resolve(current, part);
    if (directory || index < parts.length - 1) {
      if (create) {
        try { await mkdir(current, { mode: 0o700 }); }
        catch (error) { if (error.code !== 'EEXIST') throw error; }
      }
      if (!(await lstat(current)).isDirectory()) throw new Error(`Not a real directory: ${current}`);
    } else if (!(await lstat(current)).isFile()) throw new Error(`Not a regular file: ${current}`);
  }
  return current;
}

const unchanged = (a, b) => ['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs', 'mode', 'nlink'].every(key => a[key] === b[key]);

export async function inspectFile(path, limit, { capture = false, blobFormat, singleLink = false } = {}) {
  // Nonblocking also prevents a concurrent FIFO replacement from hanging open().
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const before = await file.stat({ bigint: true });
    if (!before.isFile() || before.size > BigInt(limit) || (singleLink && before.nlink !== 1n))
      throw new Error(`Invalid or oversized file: ${path}`);
    const hash = createHash('sha256');
    const blob = blobFormat && createHash(blobFormat).update(`blob ${before.size}\0`);
    const chunks = [];
    const buffer = Buffer.allocUnsafe(128 * 1024);
    let size = 0;
    for (;;) {
      const { bytesRead } = await file.read(buffer);
      if (!bytesRead) break;
      size += bytesRead;
      if (size > limit) throw new Error(`File exceeded byte limit: ${path}`);
      const chunk = buffer.subarray(0, bytesRead);
      hash.update(chunk);
      if (blob) blob.update(chunk);
      if (capture) chunks.push(Buffer.from(chunk));
    }
    if (BigInt(size) !== before.size || !unchanged(before, await lstat(path, { bigint: true })))
      throw new Error(`File changed while reading: ${path}`);
    return {
      sha256: hash.digest('hex'), size, executable: Boolean(before.mode & 0o100n),
      ...(blob && { oid: blob.digest('hex') }), ...(capture && { bytes: Buffer.concat(chunks) }),
    };
  } finally { await file.close(); }
}

export async function executableIdentity(command, path) {
  if (!/^[a-zA-Z0-9._+-]+$/.test(command) || command === '.' || command === '..')
    throw new Error('Only a named executable from the supplied PATH is supported');
  for (const dir of path.split(':')) {
    const entry = resolve(dir, command);
    try {
      await access(entry, constants.X_OK);
      const actual = await realpath(entry);
      const { sha256, executable } = await inspectFile(actual, 256 * 1024 * 1024);
      return { entry, path: actual, sha256, executable };
    } catch (error) { if (!['ENOENT', 'EACCES', 'ENOTDIR'].includes(error.code)) throw error; }
  }
  throw new Error(`Executable unavailable: ${command}`);
}

export function sourceReader(root, gitPath, env) {
  const git = (...args) => execFileSync(gitPath, [
    '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false', '-c', 'core.filemode=true',
    '-c', 'core.hooksPath=/dev/null', ...args,
  ], { cwd: root, env, timeout: 10_000, killSignal: 'SIGKILL', maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  const text = (...args) => decode(git(...args)).trimEnd();
  const clean = () => {
    if (git('status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none').length)
      throw new Error('Expected clean source: commit or remove staged, modified and untracked inputs');
  };
  return async expectedHead => {
    if (await realpath(text('rev-parse', '--show-toplevel')) !== root) throw new Error('Run from the checkout root');
    const head = text('rev-parse', '--verify', 'HEAD^{commit}');
    if (head !== expectedHead) throw new Error(`HEAD drift: expected ${expectedHead}, found ${head}`);
    clean();
    const objectFormat = text('rev-parse', '--show-object-format');
    if (!['sha1', 'sha256'].includes(objectFormat)) throw new Error(`Unsupported Git object format: ${objectFormat}`);
    const entries = decode(git('ls-tree', '-rz', '--full-tree', head)).split('\0');
    entries.pop();
    if (!entries.length || entries.length > 20_000) throw new Error('Source snapshot file-count limit');
    let bytes = 0;
    const files = new Map();
    for (const entry of entries) {
      const match = /^(100644|100755) blob ([a-f0-9]+)\t(.+)$/.exec(entry);
      if (!match) throw new Error('Unsupported tracked path: only regular Git blobs are accepted');
      const [, mode, oid, path] = match;
      const file = await inspectFile(await checkedPath(root, path), Math.min(64 * 1024 * 1024, 512 * 1024 * 1024 - bytes), { blobFormat: objectFormat });
      if (file.oid !== oid || file.executable !== (mode === '100755')) throw new Error(`Working file does not match HEAD: ${path}`);
      bytes += file.size;
      files.set(path, [mode, file.sha256]);
    }
    clean();
    if (text('rev-parse', '--verify', 'HEAD^{commit}') !== head) throw new Error('HEAD changed during source snapshot');
    return { head, objectFormat, files, hash: sha(JSON.stringify([head, [...files]])) };
  };
}

export async function committedJson(root, snapshot, path) {
  const expected = snapshot.files.get(path)?.[1];
  if (!expected) throw new Error(`Configuration must be tracked: ${path}`);
  const file = await inspectFile(await checkedPath(root, path), 128 * 1024, { capture: true });
  if (file.sha256 !== expected) throw new Error(`Configuration changed: ${path}`);
  return { value: JSON.parse(decode(file.bytes)), hash: expected };
}

export function authorityHash(snapshot, paths) {
  const unique = new Map();
  for (const base of new Set(paths.map(localPath))) {
    const found = [...snapshot.files].filter(([path]) => base === path || path.startsWith(base + '/'));
    if (!found.length) throw new Error(`Evaluator authority is not tracked: ${base}`);
    for (const [path, value] of found) unique.set(path, value);
  }
  return sha(JSON.stringify([...unique].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)));
}

export async function resolvePath(root, input) {
  const dirs = input.split(':');
  for (const dir of dirs) {
    if (!isAbsolute(dir) || under(root, resolve(dir))) throw new Error('PATH must contain only absolute directories outside the checkout');
    try {
      if (under(root, await realpath(dir))) throw new Error('PATH directory resolves into the checkout');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return dirs.join(':');
}

export const repoRelative = (root, path) => localPath(relative(root, path));
