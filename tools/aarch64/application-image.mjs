import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {readFileSync, writeFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../tc0/pure-call-artifact.mjs';

export function shenApplication(input, output, target, exports, operations = []) {
  execFileSync('sh', [fileURLToPath(new URL('../../harness/emit-arm64.sh', import.meta.url)),
    target, input, output, '--application', JSON.stringify([...exports]), JSON.stringify(operations)], {stdio: 'inherit'});
}

export async function buildApplication(input, output, target, exports) {
  const {artifact, codes} = validatePureCallArtifact(readFileSync(input), ['int', '0'], {maxNodes: 2000});
  for (const [name, symbol] of exports) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(symbol) || !artifact.functions.some(f => f.name === name))
      throw Error('invalid native export ' + name);
  }
  switch (process.env.FENRIR_NATIVE_BACKEND ?? 'shen') {
    case 'shen':
      shenApplication(input, output, target, exports);
      break;
    case 'javascript': {
      const {managedImage} = await import('./managed-image.mjs');
      writeFileSync(output, managedImage(artifact, target === 'solo5-arm64-spt' ? '' : '_', codes, exports));
      break;
    }
    default: throw Error('unknown native backend ' + process.env.FENRIR_NATIVE_BACKEND);
  }
}
