import {buildApplication} from '../../tools/aarch64/application-image.mjs';

const [input, output, target = 'macos-arm64'] = process.argv.slice(2);
await buildApplication(input, output, target, new Map([['response', 'http_response']]));
