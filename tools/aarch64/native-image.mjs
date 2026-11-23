// Lower a validated call-profile artifact to a platform assembly translation unit.
// Darwin returns the two-word integer result {value,status} in x0 and x1.
import {readFileSync, writeFileSync} from 'node:fs';
import {compileCallArtifact} from './call.mjs';
import {UnsupportedTupleSpecialization} from './tuple-arguments.mjs';

import {resultPrinter} from './result-printer.mjs';
import {managedImage} from './managed-image.mjs';
import {isTaskSchema,validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

const [target, input, output] = process.argv.slice(2);
const bytes = readFileSync(input);
if (!['macos-arm64', 'solo5-arm64-spt'].includes(target)) throw new Error('unsupported target');
const entry = target === 'macos-arm64' ? '_fenrir_entry' : 'fenrir_entry';
const parsed = JSON.parse(bytes);
const hasTupleResult = parsed.functions?.some(f => f.result_type?.[0] === 'Tuple');
function needsManaged(node, parameter) {
  if (!Array.isArray(node)) return false;
  const [tag, , value] = node;
  if (['lambda','bytes','emit','unit','construct','tuple'].includes(tag)) return true;
  // The scalar backend specializes syntactic tuple arguments and projections
  // of the callee parameter. A tuple value elsewhere needs managed lowering.
  if (tag === 'project') return value[0] !== 'var' || value[2] !== parameter;
  if (tag === 'call' && node[3][0] === 'tuple')
    return node[3].slice(2).some(child => needsManaged(child, parameter));
  return node.some(child => needsManaged(child, parameter));
}
function writeManagedImage() {
  const {artifact, codes} = validatePureCallArtifact(bytes, ['int','0'], {maxNodes:2000});
  writeFileSync(output, managedImage(artifact, target === 'macos-arm64' ? '_' : '', codes));
}
if (isTaskSchema(parsed.schema_version) || parsed.effects?.length || hasTupleResult || parsed.datatypes?.length ||
    parsed.functions?.some(f => needsManaged(f.body, f.parameter_id))) {
  writeManagedImage();
  process.exit(0);
}
let scalarImage;
try {
  scalarImage = compileCallArtifact(bytes, true);
} catch (error) {
  if (!(error instanceof UnsupportedTupleSpecialization)) throw error;
  writeManagedImage();
  process.exit(0);
}
const {binary, code, manifest} = scalarImage;
const lines = ['.text', '.p2align 2', '.globl ' + entry];
const positions = new Map(parsed.source_map.map(p => [p.id, p]));
const trapSites = new Map();
for (let offset = 0; offset < binary.length; offset += 4) {
  if (offset === manifest.entry_offset) lines.push(entry + ':');
  const site = code[offset / 4].origin;
  if (site === undefined) lines.push('  .long 0x' + binary.readUInt32LE(offset).toString(16));
  else {
    const position = positions.get(site);
    if (!position) throw Error('Missing trap location for node ' + site);
    trapSites.set(site, position);
    // Replacing one ret with one branch preserves function-table offsets.
    lines.push('b Lreport' + site);
  }
}
for (const [site, pos] of trapSites) {
  const darwin = target === 'macos-arm64';
  const name = 'Lposition' + site;
  lines.push('.p2align 2', 'Lreport' + site + ':', 'stp x1, x30, [sp, #-16]!',
             ...(darwin ? ['adrp x0, ' + name + '@PAGE', 'add x0, x0, ' + name + '@PAGEOFF']
                        : ['adrp x0, ' + name, 'add x0, x0, :lo12:' + name]),
             'bl ' + (darwin ? '_' : '') + 'fen_set_location', 'ldp x1, x30, [sp], #16', 'ret',
             name + ':', '.byte ' + [...Buffer.from(`trap at: ${pos.file}:${pos.line}:${pos.column}\n`), 0].join(','));
}
lines.push('.p2align 2');
writeFileSync(output, lines.join('\n') + '\n' + resultPrinter(manifest.result_type, new Map(), target === 'macos-arm64' ? '_' : ''));
