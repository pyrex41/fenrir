import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access, lstat, mkdir, readFile, readdir, readlink, realpath, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import { CLAIMS } from './core.mjs';

export const CONFIG_PATH = '.pi/fenrir-workflow.json';
export const RUN_ROOT = '.pi/fenrir-workflow-runs';
export const sha = value => createHash('sha256').update(value).digest('hex');
const BUILTIN_PROTECTED = [CONFIG_PATH, '.pi/extensions/fenrir-workflow', '01_FULL_VISION.md', '02_TINY_LANGUAGE_CORE.md', '03_PHASED_EXECUTION_PLAN.md'];
const ALWAYS_IGNORED = ['.git', RUN_ROOT];
const nonempty = x => typeof x === 'string' && x.trim().length > 0;
function keys(object, allowed, name) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) throw new Error(`${name} must be an object`);
  for (const key of Object.keys(object)) if (!allowed.includes(key)) throw new Error(`Unknown ${name} field ${key}`);
}
function strings(value, name, max = 128) {
  if (!Array.isArray(value) || value.length > max || value.some(x => !nonempty(x) || x.length > 4096) || new Set(value).size !== value.length) throw new Error(`${name} must be unique bounded nonempty strings`);
  return [...value];
}
export function localPath(value) {
  if (!nonempty(value) || isAbsolute(value) || value.includes('\\') || value.includes('\0') || value.split('/').some(p => p === '..') || value === '.') throw new Error(`Expected a repository-relative path: ${value}`);
  return value.replace(/^\.\//, '').replace(/\/$/, '');
}
export function validateConfig(raw) {
  keys(raw, ['version', 'checks', 'requiredChecks', 'requiredClaims', 'protectedPaths', 'ignoredPaths', 'requireContinuousContext'], 'config');
  if (raw.version !== 1) throw new Error('Unsupported Fenrir workflow config version');
  keys(raw.checks, Object.keys(raw.checks || {}), 'checks');
  if (Object.keys(raw.checks).length > 64) throw new Error('Too many checks');
  const checks = {};
  for (const [id, spec] of Object.entries(raw.checks)) {
    if (!/^[a-z][a-z0-9-]{0,63}$/.test(id)) throw new Error(`Invalid check ID: ${id}`);
    keys(spec, ['kind', 'command', 'timeoutSeconds', 'authorityPaths'], `check ${id}`);
    if (!['development', 'qualification'].includes(spec.kind)) throw new Error(`Invalid check kind: ${id}`);
    if (!Array.isArray(spec.command) || !spec.command.length || spec.command.length > 64 || spec.command.some(x => typeof x !== 'string' || x.includes('\0') || x.length > 4096) || !nonempty(spec.command[0])) throw new Error(`Invalid argv for ${id}`);
    if (!Number.isSafeInteger(spec.timeoutSeconds) || spec.timeoutSeconds < 1 || spec.timeoutSeconds > 3600) throw new Error(`Invalid timeout for ${id}`);
    const authorityPaths = strings(spec.authorityPaths, `${id}.authorityPaths`).map(localPath);
    if (spec.kind === 'qualification' && !authorityPaths.length) throw new Error(`Qualification check ${id} needs declared evaluator authority paths`);
    checks[id] = { ...spec, command: [...spec.command], authorityPaths };
  }
  if (raw.requireContinuousContext !== undefined && typeof raw.requireContinuousContext !== 'boolean') throw new Error('requireContinuousContext must be boolean');
  const protectedPaths = [...new Set([...BUILTIN_PROTECTED, ...strings(raw.protectedPaths || [], 'protectedPaths').map(localPath), ...Object.values(checks).flatMap(c => c.authorityPaths)])].sort();
  const ignoredPaths = strings(raw.ignoredPaths || ['node_modules', 'build'], 'ignoredPaths').map(localPath);
  for (const p of ignoredPaths) if (protectedPaths.some(a => a === p || a.startsWith(p + '/'))) throw new Error(`Cannot ignore evaluator authority: ${p}`);
  const requiredClaims = strings(raw.requiredClaims ?? CLAIMS, 'requiredClaims');
  if (CLAIMS.some(claim => !requiredClaims.includes(claim))) throw new Error('TC0-A completion must retain all six demonstration claims');
  return {
    version: 1, checks, protectedPaths, ignoredPaths,
    requiredChecks: strings(raw.requiredChecks, 'requiredChecks'),
    requiredClaims,
    requireContinuousContext: raw.requireContinuousContext ?? true,
  };
}
export async function loadConfig(cwd) {
  const path = await safeFile(cwd, CONFIG_PATH);
  const bytes = await readFile(path);
  if (bytes.length > 128 * 1024) throw new Error('Workflow config is too large');
  return { config: validateConfig(JSON.parse(bytes.toString('utf8'))), configHash: sha(bytes) };
}
export function under(root, path) {
  const delta = relative(root, path);
  return delta === '' || (!delta.startsWith('..' + sep) && delta !== '..' && !isAbsolute(delta));
}
export async function safeFile(cwd, path) {
  const absolute = resolve(cwd, localPath(path));
  const base = await realpath(cwd);
  const resolved = await realpath(absolute);
  if (!under(base, resolved)) throw new Error(`Path escapes checkout: ${path}`);
  // Reject symlink ancestors too: the checked path must be the path actually read.
  let current = resolve(cwd);
  for (const part of relative(resolve(cwd), absolute).split(sep)) {
    current = resolve(current, part);
    if ((await lstat(current)).isSymbolicLink()) throw new Error(`Symlink evidence/authority is not allowed: ${path}`);
  }
  if (!(await lstat(absolute)).isFile()) throw new Error(`Not a regular file: ${path}`);
  return absolute;
}
export async function hashFile(path, maxBytes = 64 * 1024 * 1024) {
  const before = await lstat(path);
  if (!before.isFile() || before.size > maxBytes) throw new Error(`Invalid/oversized hash input: ${path}`);
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  const after = await lstat(path);
  if (before.ino !== after.ino || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) throw new Error(`File changed while hashing: ${path}`);
  return hash.digest('hex');
}
const ignored = (path, rules) => rules.some(rule => path === rule || path.startsWith(rule + '/'));
async function tree(cwd, roots, ignore = []) {
  const files = [];
  let bytes = 0;
  async function visit(path) {
    if (ignored(path, ignore)) return;
    if (files.length >= 20000) throw new Error('Source snapshot file-count limit reached');
    const absolute = resolve(cwd, path || '.');
    let info;
    try { info = await lstat(absolute); }
    catch (error) { if (error.code === 'ENOENT') { files.push([path, 'missing']); return; } throw error; }
    if (info.isSymbolicLink()) throw new Error(`Source/authority symlinks require an explicit reviewed strategy: ${path} → ${await readlink(absolute)}`);
    if (info.isDirectory()) {
      files.push([path, 'directory']);
      for (const name of (await readdir(absolute)).sort()) await visit(path ? `${path}/${name}` : name);
    } else if (info.isFile()) {
      bytes += info.size;
      if (bytes > 512 * 1024 * 1024) throw new Error('Source snapshot byte limit reached');
      files.push([path, await hashFile(absolute)]);
    } else throw new Error(`Special file is not valid source/authority: ${path}`);
  }
  for (const root of roots) await visit(root);
  return { hash: sha(JSON.stringify(files)), files: files.length, bytes };
}
export const sourceIdentity = (cwd, config) => tree(cwd, [''], [...ALWAYS_IGNORED, ...config.ignoredPaths]);
export const protectedIdentity = (cwd, config) => tree(cwd, config.protectedPaths);
export async function evidenceReferences(cwd, paths) {
  return Promise.all(strings(paths, 'evidence paths', 64).map(async path => {
    const normalized = localPath(path);
    return { path: normalized, sha256: await hashFile(await safeFile(cwd, normalized)) };
  }));
}
export async function referencesValid(cwd, refs) {
  try { return (await evidenceReferences(cwd, refs.map(r => r.path))).every((r, i) => r.sha256 === refs[i].sha256); }
  catch { return false; }
}
export async function privateDirectory(cwd, path) {
  const normalized = localPath(path);
  let current = resolve(cwd);
  for (const part of normalized.split('/')) {
    current = resolve(current, part);
    try { await mkdir(current, { mode: 0o700 }); }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
    const info = await lstat(current);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Workflow storage must not contain symlinks or special files');
  }
  return current;
}
export async function atomicJson(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  try { await rename(temporary, path); }
  finally { await rm(temporary, { force: true }); }
}
export async function acquireLock(cwd, owner) {
  const directory = await privateDirectory(cwd, RUN_ROOT);
  const path = resolve(directory, 'controller.lock');
  const token = randomUUID();
  try { await writeFile(path, JSON.stringify({ version: 1, token, pid: process.pid, ...owner }), { flag: 'wx', mode: 0o600 }); }
  catch (error) { if (error.code === 'EEXIST') throw new Error(`Workflow lock occupied: ${path}. Inspect owner and cleanup; never auto-steal a stale lock.`); throw error; }
  return { path, token };
}
export async function releaseLock(lock) {
  if (!lock) return;
  const record = JSON.parse(await readFile(lock.path, 'utf8'));
  if (record.token !== lock.token) throw new Error('Workflow lock ownership changed; not removing another owner’s lock');
  await rm(lock.path);
}
export async function lockExists(cwd) {
  try { await access(resolve(cwd, RUN_ROOT, 'controller.lock')); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
export async function executableIdentity(command, cwd, path = process.env.PATH || '') {
  const candidates = command.includes('/') ? [resolve(cwd, command)] : path.split(':').map(p => resolve(p || cwd, command));
  for (const file of candidates) {
    try { await access(file, 1); const actual = await realpath(file); return { path: actual, sha256: await hashFile(actual, 256 * 1024 * 1024) }; }
    catch (error) { if (!['ENOENT', 'EACCES', 'ENOTDIR'].includes(error.code)) throw error; }
  }
  throw new Error(`Executable unavailable: ${command}`);
}
