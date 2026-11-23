// Cross-check the assembler's actual .text bytes against the two Rocq-backed
// compiler profiles. Each case retains both images and its source artifact.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, writeFileSync} from 'node:fs';
import {resolve, join} from 'node:path';
import {cases} from './expr-fixtures.mjs';
import {callCases, deepCases} from './call-fixtures.mjs';
import {compileExprArtifact, sha256} from './expr.mjs';
import {compileCallArtifact} from './call.mjs';

const root = resolve(import.meta.dirname, '../..');
const out = resolve(process.argv[2]);
mkdirSync(out);
const rows = [];
for (const [kind, fixtures, compile] of [
  ['expr', cases(), compileExprArtifact],
  ['call', [...callCases(), ...deepCases()], compileCallArtifact],
]) {
  for (const {name, artifact} of fixtures) {
    const cwd = join(out, kind + '-' + name);
    mkdirSync(cwd);
    const source = Buffer.from(JSON.stringify(artifact));
    writeFileSync(join(cwd, 'artifact.json'), source);
    const reference = compile(source).binary;
    const exec = (command, args) => execFileSync(command, args, {cwd, encoding: 'utf8', timeout: 60000});
    exec('sh', [join(root, 'harness/emit-arm64.sh'), 'solo5-arm64-spt', 'artifact.json', 'program.s', '--proof-' + kind]);
    exec('clang', ['--target=aarch64-none-elf', '-c', 'program.s', '-o', 'program.o']);
    const dump = exec(process.env.LLVM_OBJDUMP || 'llvm-objdump', ['-s', '-j', '.text', 'program.o']);
    const words = dump.split('\n').flatMap(line => line.match(/^\s*[\da-f]+ ((?:[\da-f]{8} ?){1,4})/i)?.[1].trim().split(/ +/) ?? []);
    const binary = Buffer.from(words.join(''), 'hex');
    writeFileSync(join(cwd, 'shen.bin'), binary);
    writeFileSync(join(cwd, 'reference.bin'), reference);
    assert.equal(sha256(binary), sha256(reference), kind + '/' + name);
    rows.push({kind, name, bytes: binary.length, sha256: sha256(binary)});
  }
}
writeFileSync(join(out, 'report.json'), JSON.stringify(rows, null, 2) + '\n');
console.log(rows.length + ' exact function tables matched');
