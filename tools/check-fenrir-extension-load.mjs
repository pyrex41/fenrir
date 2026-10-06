import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

// Loading trusted extension factories only: no session, credentials or model requests.
const sdkRoot = process.argv[2] || process.env.PI_SDK_ROOT;
if (!sdkRoot) {
  console.error('Usage: node tools/check-fenrir-extension-load.mjs <path-to-@earendil-works/pi-coding-agent>');
  process.exitCode = 2;
} else {
  const root = resolve(sdkRoot);
  const { loadExtensions } = await import(pathToFileURL(resolve(root, 'dist/core/extensions/loader.js')).href);
  const extensionPath = resolve('.pi/extensions/fenrir-workflow/index.ts');
  const loaded = await loadExtensions([extensionPath], process.cwd());
  assert.deepEqual(loaded.errors, [], 'Actual Pi loader must accept the extension');
  assert.equal(loaded.extensions.length, 1);
  const extension = loaded.extensions[0];
  assert.deepEqual([...extension.tools.keys()], ['fenrir_status', 'fenrir_progress', 'fenrir_check', 'fenrir_checkpoint']);
  assert.deepEqual([...extension.commands.keys()], ['fenrir-workflow']);
  assert.equal(extension.handlers.has('context'), false, 'Must not compete with pi-clm projection');
  assert.equal(extension.handlers.has('context_with_system'), false);
  const version = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8')).version;
  console.log(JSON.stringify({ result: 'PASS', scope: 'actual Pi extension loading/registration only', piVersion: version,
    tools: [...extension.tools.keys()], commands: [...extension.commands.keys()], modelRequests: 0 }, null, 2));
}
