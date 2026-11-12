#!/bin/sh
# Build a guest batch (JavaScript, for now) and hand it to the Shen harness.
# Usage: sh harness/run-solo5-pure-call.sh [EXHAUSTIVE_NODES=5 | exact]
#   a number  hand cases, generated cases and the exhaustive grammar to that bound
#   exact     the exact-arithmetic family: C guest arithmetic against the model's
# Needs: build/vendor/solo5 built at the pinned commit, and Shen/JIT 0.7 with its
# lib directory and shen-process.so under build/toolchain/shen-jit-0.7.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
jit="${FENRIR_SHEN_JIT:-$root/build/toolchain/shen-jit-0.7}"
if [ "${1:-5}" = exact ]; then
  batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --exact-arithmetic --build-only)
else
  batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --exhaustive-nodes "${1:-5}" --build-only)
fi
status=0
out=$("$jit/bin/shen-jit" script "$root/harness/solo5-pure-call.shen" "$jit/lib" "$root" "$batch" 2>&1) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$out" | tail -n 1
exit "$status"
