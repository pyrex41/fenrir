import {readFileSync, writeFileSync} from 'node:fs';
import {validateFrontendArtifact} from '../../../tools/tc0/pure-call-artifact.mjs';
import {managedImage} from '../../../tools/aarch64/managed-image.mjs';

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
const assembly = managedImage(artifact, target === 'macos-arm64' ? '_' : '', codes, new Map(), {
  entryType: ['Data','Command'],
  operations: new Map([['Store', new Map([['commit','service_commit']])]]),
  describeConstructors(types) {
    for (const {name:type, constructors} of artifact.datatypes) {
      for (const {name, fields} of constructors) {
        const {tag} = types.get(type).get(name);
        tags.push('TAG_' + type + '_' + name + ' = ' + tag);
        const kinds = fields.map(t => scalar.get(t) ?? 'FIELD_DATA');
        descriptions.push('[' + tag + '] = {"' + type + '","' + name + '",' + fields.length +
                          ',{' + (kinds.join(',') || '0') + '}}');
      }
    }
  }
});
writeFileSync(dir + '/program.s', assembly);
writeFileSync(dir + '/types.h', 'enum {\n' + tags.join(',\n') + '\n};\n' +
  '#ifndef FEN_TAGS_ONLY\nstatic const struct description descriptions[] = {\n' + descriptions.join(',\n') + '\n};\n#endif\n');
