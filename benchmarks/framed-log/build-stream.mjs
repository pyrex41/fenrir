import {buildApplication} from '../../tools/aarch64/application-image.mjs';

const [artifactPath, assemblyPath, target = "macos-arm64"] = process.argv.slice(2);
const names = ['feed', 'finish', 'invalid-offset', 'final-offset', 'summary-keys',
               'next-line', 'line-bytes', 'remaining-keys', 'rejection-line'];
const exports = new Map(names.map(name => [name, 'stream_' + name.replaceAll('-', '_')]));
await buildApplication(artifactPath, assemblyPath, target, exports);
