#!/bin/sh
# TC1 generated handler family: the Shen model against the JavaScript implementation
# on the generated family G (tools/tc1/handler-generate.mjs), with the six injected
# defects and the handler behaviours the traces exercise.
# Usage: sh harness/run-tc1-generated.sh [COUNT=2048]
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-generated/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-generated.shen" "$jit/lib" "$root" "${1:-2048}" "$out" sandbox 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
