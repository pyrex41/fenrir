import { writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { checkedPath, decode, inspectFile, repoRelative } from './identity.mjs';

export const ARM_GATES = new Map([
  ['arm-development-g1', 'g1'],
  ['arm-development-tc1', 'tc1'],
]);
export const ARM_SPEC = {
  g1: ['spec/tc0/tc0-a-requirements.json', 'tc0-a-gate-run/3', 'harness/gate.shen'],
  tc1: ['spec/tc1/tc1-requirements.json', 'tc1-gate-run/1', 'harness/tc1-gate.shen'],
};
const MARKER = 'FENRIR_ARM_CAPTURE ';
const HASH = /^[0-9a-f]{64}$/;
export const statuses = new Map([['PASS', 0], ['FAIL', 1], ['UNKNOWN', 2], ['BLOCKED', 2]]);
const matches = (object, expected) => object && Object.keys(object).length === Object.keys(expected).length &&
  Object.entries(expected).every(([key, value]) => object[key] === value);

export function captureBinding(role, receipt, profileSha256, manifestSha256, g1ManifestSha256) {
  return { role, nonce: receipt.nonce, source_sha256: receipt.sourceHash,
    profile_sha256: profileSha256, manifest_sha256: manifestSha256, g1_manifest_sha256: g1ManifestSha256 };
}

export function readArmFrame(bytes, binding, exitCode) {
  const frames = bytes && decode(bytes).split('\n').filter(line => line.startsWith(MARKER));
  if (!frames || frames.length !== 1) throw new Error('Expected one bounded ARM development frame');
  const edge = frames[0].slice(MARKER.length);
  if (Buffer.byteLength(edge) > 4096) throw new Error('Oversized ARM development frame');
  const frame = JSON.parse(edge);
  // The wire frame has only its own fields and the flat binding. Count keys
  // to reject duplicates rather than letting JSON.parse take the last value.
  const keyCount = [...edge.matchAll(/"(?:[^"\\]|\\.)*"(\s*:)?/g)].filter(match => match[1]).length;
  if (frame?.schema !== 'fenrir.arm-development-frame/1' || Object.keys(frame).length !== 4 ||
      !matches(frame.binding, binding) || keyCount !== 4 + Object.keys(binding).length ||
      !HASH.test(frame.report_sha256) || !statuses.has(frame.verdict) || statuses.get(frame.verdict) !== exitCode)
    throw new Error('Invalid ARM development frame, binding, digest, or exit');
  return frame;
}

export function validateArmReport(report, { role, receipt, binding, manifest }) {
  const [path, schema, evaluator] = ARM_SPEC[role === 'nested-g1' ? 'g1' : role];
  if (report?.schema !== schema || report.head !== receipt.head || report.manifest !== path ||
      report.evaluator !== evaluator || !matches(report.capture, binding) || !statuses.has(report.verdict) ||
      report.authority !== 'UNREGISTERED' || report.qualification !== 'UNKNOWN' ||
      !Array.isArray(report.claims) || report.claims.length ||
      report.runner?.uname_sm !== 'Linux aarch64\n' || report.runner?.uname_exit !== '0' ||
      report.runner?.legacy_qualification_platform !== false || !Array.isArray(report.waivers) ||
      !Array.isArray(report.rows))
    throw new Error(`Invalid ${role} report identity or non-qualification state`);
  const specs = new Map(manifest.rows.map(row => [row.id, row.required]));
  const seen = new Set();
  for (const row of report.rows) {
    if (seen.has(row?.id) || (row?.id === 'source-drift' ? row.status !== 'UNKNOWN' || row.required !== true
      : !specs.has(row?.id) || row.required !== specs.get(row.id)) ||
      !(statuses.has(row.status) || (!row.required && row.status === 'DEFERRED')))
      throw new Error(`Invalid ${role} row inventory or status`);
    seen.add(row.id);
  }
  if ([...specs.keys()].some(id => !seen.has(id))) throw new Error(`Missing ${role} manifest row`);
  const required = report.rows.filter(row => row.required);
  const verdict = ['FAIL', 'BLOCKED', 'UNKNOWN'].find(status => required.some(row => row.status === status)) ?? 'PASS';
  if (report.verdict !== verdict) throw new Error(`Invalid ${role} row aggregation`);
}

export function validateNestedRow(top, nested, nestedSha256) {
  const row = top.rows.find(row => row.id === 'tc0-a-gate');
  if (row?.detail?.report_sha256 !== nestedSha256 || !HASH.test(nestedSha256) || row.status !== nested.verdict)
    throw new Error('TC1 row does not bind this same-run G1 report digest and verdict');
}

export async function retainArmReports(root, directory, receipt, frame, binding, manifests) {
  const load = async relativePath => {
    const path = repoRelative(root, resolve(directory, relativePath));
    const file = await inspectFile(await checkedPath(root, path), 4 * 1024 * 1024, { capture: true, singleLink: true });
    return { path, ...file, object: JSON.parse(decode(file.bytes)) };
  };
  const top = await load('gate.json');
  if (top.sha256 !== frame.report_sha256 || top.object.verdict !== frame.verdict)
    throw new Error('ARM gate report contradicts the development frame');
  validateArmReport(top.object, { role: binding.role, receipt, binding, manifest: manifests[binding.role] });
  const bundle = [[top, 'evaluator-gate.json']];
  if (binding.role === 'tc1') {
    const nested = await load('tc0-a-gate/gate.json');
    const child = { ...binding, role: 'nested-g1', manifest_sha256: binding.g1_manifest_sha256 };
    validateArmReport(nested.object, { role: child.role, receipt, binding: child, manifest: manifests.g1 });
    validateNestedRow(top.object, nested.object, nested.sha256);
    bundle.push([nested, 'evaluator-nested-g1.json']);
  }
  const evidence = [];
  for (const [file, copy] of bundle) {
    const dest = resolve(directory, copy);
    await writeFile(dest, file.bytes, { flag: 'wx', mode: 0o600 });
    evidence.push({ sourcePath: file.path, retainedPath: repoRelative(root, dest), sha256: file.sha256, bytes: file.size });
  }
  receipt.evidence = evidence;
  receipt.evaluator = { verdict: frame.verdict, reportedWaivers: top.object.waivers, waiverAdmission: 'not-evaluated',
    reportedClaims: [] };
}
