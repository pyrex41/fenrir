import {readFileSync, writeFileSync} from 'node:fs';
import {validateFrontendArtifact} from '../../../tools/tc0/pure-call-artifact.mjs';
import {shenApplication} from '../../../tools/aarch64/application-image.mjs';
import {TRAP_CODES} from '../../../tools/tc0/pure-call-artifact.mjs';

const [source, dir, target] = process.argv.slice(2);
if (!['macos-arm64','solo5-arm64-spt'].includes(target)) throw Error('unknown target');
const {artifact, codes} = validateFrontendArtifact(readFileSync(source), {maxNodes:2000});
const pinned = JSON.parse(readFileSync(new URL('../../../host/service/artifacts/accepted-job.json', import.meta.url)));
for (const key of ['schema_version','effects','datatypes']) {
  if (JSON.stringify(artifact[key]) !== JSON.stringify(pinned[key])) throw Error('unsupported service ABI: ' + key);
}
const entry = artifact.functions.find(f => f.name === artifact.entry);
if (JSON.stringify(entry.result_type) !== '["Data","Response"]') throw Error('unsupported service result');
const tags = [];
const descriptions = [];
const scalar = new Map([['I64','FIELD_INT'],['Bool','FIELD_BOOL'],['Bytes','FIELD_BYTES']]);
// Constructor tags in the native ABI follow the built-in trap variants.
let tag = TRAP_CODES.length;
for (const {name: type, constructors} of artifact.datatypes) {
  for (const {name, fields} of constructors) {
    tags.push('TAG_' + type + '_' + name + ' = ' + ++tag);
    const kinds = fields.map(t => scalar.get(t) ?? 'FIELD_DATA');
    descriptions.push('[' + tag + '] = {"' + type + '","' + name + '",' + fields.length +
      ',{' + (kinds.join(',') || '0') + '}}');
  }
}
const output = dir + '/program.s';
switch (process.env.FENRIR_NATIVE_BACKEND ?? 'shen') {
  case 'shen': {
    const op = artifact.effects.find(e => e.name === 'Store').operations.find(o => o.name === 'commit');
    shenApplication(source, output, target, [], [['Store', 'commit', 'service_commit', op.result_type]]);
    break;
  }
  case 'javascript': {
    const {managedImage} = await import('../../../tools/aarch64/managed-image.mjs');
    writeFileSync(output, managedImage(artifact, target === 'macos-arm64' ? '_' : '', codes, new Map(), {
      entryType: ['Data','Command'], operations: new Map([['Store', new Map([['commit','service_commit']])]])
    }));
    break;
  }
  default: throw Error('unknown native backend ' + process.env.FENRIR_NATIVE_BACKEND);
}
writeFileSync(dir + '/types.h', 'enum {\n' + tags.join(',\n') + '\n};\n' +
  '#ifndef FEN_TAGS_ONLY\nstatic const struct description descriptions[] = {\n' + descriptions.join(',\n') + '\n};\n#endif\n');
