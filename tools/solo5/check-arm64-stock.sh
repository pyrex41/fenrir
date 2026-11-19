#!/bin/sh
# Bounded stock SPT comparison on ARM64 Linux. Run in the locked default dev shell.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
test "$(uname -s)/$(uname -m)" = Linux/aarch64 || {
  echo 'Expected a native ARM64 Linux host.' >&2
  exit 2
}
: "${FENRIR_SOLO5:?run with nix develop --no-update-lock-file}"
: "${FENRIR_SHEN_JIT:?run with nix develop --no-update-lock-file}"
mkdir -p build/arm64-solo5
out=$(mktemp -d "$root/build/arm64-solo5/check.XXXXXXXX")
mkdir "$out/batch"
{
  printf 'source: %s\n' "$(git rev-parse HEAD)"
  printf 'host: %s\n' "$(uname -srm)"
  nix --version
  node --version
  printf 'Solo5 commit: %s\n' "$(cat "$FENRIR_SOLO5/SOLO5_COMMIT")"
  "$FENRIR_SOLO5/bin/aarch64-solo5-none-static-cc" -v
  "$FENRIR_SOLO5/bin/aarch64-solo5-none-static-ld" --version
} > "$out/host.log" 2>&1
cp flake.lock "$out/flake.lock"
nix path-info --json "$FENRIR_SOLO5" "$FENRIR_SHEN_JIT" > "$out/nix-paths.json"
sha256sum "$FENRIR_SOLO5/bin/solo5-spt" "$FENRIR_SHEN_JIT/bin/shen-jit" \
  "$FENRIR_SHEN_JIT/lib/shen-process.so" > "$out/tool-sha256.txt"

# Small mixed corpus: both TC1 handler slices and TC0-A call/data hand cases.
node tools/solo5/freerun-pure-call.mjs --tc1 --abi spt --build-only --out "$out/batch" \
  > "$out/build.log" 2>&1 || { cat "$out/build.log"; exit 1; }
sha256sum "$out/batch/guest.spt" "$out/batch/batch.json" "$out/batch/programs.json" > "$out/batch-sha256.txt"
"$FENRIR_SHEN_JIT/bin/shen-jit" script harness/solo5-pure-call.shen \
  "$FENRIR_SHEN_JIT/lib" "$root" "$out/batch" < /dev/null > "$out/shen.log" 2>&1 ||
  { status=$?; tail -n 30 "$out/shen.log"; exit "$status"; }
tail -n 1 "$out/shen.log" > "$out/report.json"
node --input-type=module - "$out" <<'JS'
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const out = process.argv[2];
const read = path => JSON.parse(readFileSync(`${out}/${path}`, 'utf8'));
const batch = read('batch/batch.json');
const report = read('report.json');
assert.equal(batch.abi, 'spt');
assert.equal(batch.solo5_source, 'installed');
assert.equal(batch.solo5_path, process.env.FENRIR_SOLO5);
assert.equal(batch.tender, `${process.env.FENRIR_SOLO5}/bin/solo5-spt`);
assert(Number(batch.families['tc1-handlers']) > 0 && Number(batch.families.hand) > 0);
assert.equal(report.schema, 'fenrir.harness.solo5-pure-call/1');
assert.equal(report.harness, 'Shen');
assert.equal(report.status, 'development-pass');
assert.equal(report.qualification, 'UNKNOWN');
assert.equal(report.batch_sha256, batch.batch_sha256);
assert.equal(report.programs, batch.count);
assert.equal(report.fuel, batch.fuel);
assert.equal(report.programs_differing, '0');
assert.equal(report.model_completed, batch.count);
assert.equal(report.guest_completed, batch.count);
assert.equal(report.guest_steps, report.model_steps);
assert(Number(report.model_steps) > 0);
assert(Number(report.defects_detected['reverse-operands']) > 0);
assert(Number(report.defects_detected['wrap-overflow']) > 0);
JS
cat "$out/report.json"
