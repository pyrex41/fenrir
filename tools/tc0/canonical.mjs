// TC0/0.2 transport only. Unqualified development component, not an AST validator.
import { createHash } from 'node:crypto';

export class EncodingError extends Error {}
export class EncodingLimit extends Error {}
const keyPattern = /^[A-Za-z_][A-Za-z0-9_]*$/;
const defaults = { maxBytes: 1048576, maxDepth: 128, maxValues: 100000 };
function limits(options) {
  for (const key of Object.keys(options)) if (!Object.hasOwn(defaults, key)) throw new TypeError('Unknown limit');
  const result = { ...defaults, ...options };
  for (const value of Object.values(result)) {
    if (!Number.isSafeInteger(value) || value < 1) throw new TypeError('Invalid limit');
  }
  return result;
}
function scalarString(value) {
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new EncodingError('Unpaired surrogate');
    } else if (c >= 0xdc00 && c <= 0xdfff) throw new EncodingError('Unpaired surrogate');
  }
  return value;
}

// Parse before constructing maps: JSON.parse alone silently loses duplicate keys.
export function decode(bytes, options = {}) {
  const bound = limits(options);
  if (!(bytes instanceof Uint8Array)) throw new TypeError('Expected UTF-8 bytes');
  if (bytes.length > bound.maxBytes) throw new EncodingLimit('Byte limit');
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) throw new EncodingError('BOM');
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
  catch { throw new EncodingError('Invalid UTF-8'); }
  let at = 0, count = 0;
  const fail = () => { throw new EncodingError(`Invalid JSON at ${at}`); };
  const ws = () => { while (/[\x20\t\r\n]/.test(text[at] ?? '') && at < text.length) at++; };
  function string() {
    const start = at++;
    while (at < text.length) {
      const c = text[at++];
      if (c === '"') {
        try { return scalarString(JSON.parse(text.slice(start, at))); }
        catch { throw new EncodingError('Invalid string or surrogate'); }
      }
      if (c === '\\') at++; // JSON.parse checks escape grammar and control characters.
    }
    return fail();
  }
  function value(depth) {
    if (depth > bound.maxDepth || ++count > bound.maxValues) throw new EncodingLimit('Work/depth limit');
    ws();
    const c = text[at];
    if (c === '"') return string();
    if (c === '[') {
      at++; ws(); const result = [];
      if (text[at] === ']') { at++; return result; }
      while (true) {
        result.push(value(depth + 1)); ws();
        if (text[at] === ']') { at++; return result; }
        if (text[at++] !== ',') return fail();
      }
    }
    if (c === '{') {
      at++; ws(); const result = Object.create(null), keys = new Set();
      if (text[at] === '}') { at++; return result; }
      while (true) {
        ws(); if (text[at] !== '"') return fail();
        const key = string();
        if (!keyPattern.test(key)) throw new EncodingError('Invalid object key');
        if (keys.has(key)) throw new EncodingError('Duplicate decoded key');
        keys.add(key); ws(); if (text[at++] !== ':') return fail();
        result[key] = value(depth + 1); ws();
        if (text[at] === '}') { at++; return result; }
        if (text[at++] !== ',') return fail();
      }
    }
    for (const [token, result] of [['null', null], ['true', true], ['false', false]]) {
      if (text.startsWith(token, at)) { at += token.length; return result; }
    }
    return fail(); // Numeric tokens are never permitted, including integral tokens.
  }
  const result = value(0); ws(); if (at !== text.length) fail();
  return result;
}

export function encode(value, options = {}) {
  const bound = limits(options), ancestors = new Set();
  let count = 0, size = 0;
  const chunks = [];
  function append(text) {
    size += Buffer.byteLength(text, 'utf8');
    if (size > bound.maxBytes) throw new EncodingLimit('Byte limit');
    chunks.push(text);
  }
  function string(text) {
    scalarString(text); append('"');
    for (const c of text) {
      if (c === '"' || c === '\\') append('\\' + c);
      else if (c.codePointAt(0) < 32) append('\\u' + c.codePointAt(0).toString(16).padStart(4, '0'));
      else append(c);
    }
    append('"');
  }
  function write(v, depth) {
    if (depth > bound.maxDepth || ++count > bound.maxValues) throw new EncodingLimit('Work/depth limit');
    if (v === null) return append('null');
    if (typeof v === 'boolean') return append(v ? 'true' : 'false');
    if (typeof v === 'string') return string(v);
    if (typeof v !== 'object') throw new EncodingError('Non-transport value');
    if (ancestors.has(v)) throw new EncodingError('Cycle');
    ancestors.add(v);
    // Reject accessors, custom prototypes and symbol fields. Callers supply data, not proxies.
    if (!Array.isArray(v) && ![null, Object.prototype].includes(Object.getPrototypeOf(v))) {
      throw new EncodingError('Non-plain object');
    }
    const descriptors = Object.getOwnPropertyDescriptors(v);
    if (Reflect.ownKeys(v).some(k => typeof k !== 'string')) throw new EncodingError('Symbol key');
    for (const d of Object.values(descriptors)) if (!('value' in d)) throw new EncodingError('Accessor');
    if (Array.isArray(v)) {
      if (Object.keys(descriptors).length !== v.length + 1) throw new EncodingError('Sparse/extended array');
      append('[');
      for (let i = 0; i < v.length; i++) {
        if (!Object.hasOwn(descriptors, String(i))) throw new EncodingError('Sparse array');
        if (i) append(','); write(descriptors[i].value, depth + 1);
      }
      append(']');
    } else {
      const keys = Object.keys(descriptors).sort(); // Keys are ASCII, so UTF-8 byte order equals this order.
      append('{');
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (!keyPattern.test(key) || !descriptors[key].enumerable) throw new EncodingError('Invalid object field');
        if (i) append(','); string(key); append(':'); write(descriptors[key].value, depth + 1);
      }
      append('}');
    }
    ancestors.delete(v);
  }
  write(value, 0);
  return Buffer.from(chunks.join(''), 'utf8');
}
export function canonicalize(bytes, options = {}) { return encode(decode(bytes, options), options); }
export function canonicalHash(bytes, options = {}) {
  return createHash('sha256').update(canonicalize(bytes, options)).digest('hex');
}
// Field-level helpers. Decoding transport alone does not validate semantic fields.
export function decimal(value, { unsigned = false } = {}) {
  if (typeof value !== 'string' || !(unsigned ? /^(0|[1-9][0-9]*)$/ : /^(0|-?[1-9][0-9]*)$/).test(value)) {
    throw new EncodingError('Invalid decimal');
  }
  return value;
}
export function hexBytes(value) {
  if (typeof value !== 'string' || !/^(?:[0-9a-f]{2})*$/.test(value)) throw new EncodingError('Invalid hex');
  return value;
}
