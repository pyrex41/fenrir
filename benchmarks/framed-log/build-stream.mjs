import {readFileSync, writeFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {managedImage} from '../../tools/aarch64/managed-image.mjs';

const [artifactPath, assemblyPath, target = "macos-arm64"] = process.argv.slice(2);
const {artifact, codes} = validatePureCallArtifact(readFileSync(artifactPath), ['int', '0'], {maxNodes: 2000});
const names = ['feed', 'finish', 'invalid-offset', 'final-offset', 'summary-keys',
               'next-line', 'line-bytes', 'remaining-keys', 'rejection-line'];
const exports = new Map(names.map(name => [name, 'stream_' + name.replaceAll('-', '_')]));
writeFileSync(assemblyPath, managedImage(artifact, target === 'solo5-arm64-spt' ? '' : '_', codes, exports));
