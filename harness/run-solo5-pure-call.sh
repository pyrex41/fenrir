#!/bin/sh
# Build the guest batch (JavaScript, for now) and hand it to the Shen harness.
# Usage: sh harness/run-solo5-pure-call.sh [EXHAUSTIVE_NODES=5]
# Needs: build/vendor/solo5 built at the pinned commit, and Shen/JIT 0.7 with its
# lib directory and shen-process.so under build/toolchain/shen-jit-0.7.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
jit="${FENRIR_SHEN_JIT:-$root/build/toolchain/shen-jit-0.7}"
batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --exhaustive-nodes "${1:-5}" --build-only)
status=0
out=$("$jit/bin/shen-jit" script "$root/harness/solo5-pure-call.shen" "$jit/lib" "$root" "$batch" 2>&1) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$out" | tail -n 1
exit "$status"
