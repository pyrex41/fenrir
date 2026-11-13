#!/bin/sh
# Compare the Shen model with the JavaScript implementation over the exhaustive
# pure-data grammar, in Shen. Usage: sh harness/run-model-vs-candidate.sh [MAX_NODES=5]
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/model-vs-candidate/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/model-vs-candidate.shen" "$jit/lib" "$root" "${1:-5}" "$out" 2>&1) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
