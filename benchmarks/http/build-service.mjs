import {readFileSync, writeFileSync} from 'node:fs';
import {validatePureCallArtifact} from '../../tools/tc0/pure-call-artifact.mjs';
import {managedImage} from '../../tools/aarch64/managed-image.mjs';

const [input, output, target] = process.argv.slice(2);
const {artifact, codes} = validatePureCallArtifact(readFileSync(input), ['int','0'], {maxNodes:2000});
writeFileSync(output, managedImage(artifact, target === 'solo5-arm64-spt' ? '' : '_', codes, new Map([['response','http_response']])));
