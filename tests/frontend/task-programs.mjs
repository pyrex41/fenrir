#!/usr/bin/env node
// Test support for frontend/test.sh: the TC1-C1 artifacts the frontend produced, as the
// programs file tools/solo5/control-task-build.mjs takes (--programs), so that
// harness/solo5-tasks.shen runs them in the v3 guest against the Shen task model under
// the default schedules (lowest, highest, fifo, random:1) and under the guest's own
// FIFO scheduler. Only assembles; nothing is compared here.
//
//   node tests/frontend/task-programs.mjs OUT.json ARTIFACT.json...
import {readFileSync,writeFileSync} from 'node:fs';
import {basename} from 'node:path';

const [out,...files]=process.argv.slice(2);
if(!out||!files.length){console.error('usage: node tests/frontend/task-programs.mjs OUT.json ARTIFACT.json...');process.exit(2);}
const programs=files.map(f=>({name:basename(f,'.json'),program:JSON.parse(readFileSync(f,'utf8'))}));
writeFileSync(out,JSON.stringify({family:'frontend-examples',programs})+'\n');
console.log(String(programs.length));
