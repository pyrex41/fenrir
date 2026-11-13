#!/bin/sh
# Check the hand cases in Shen: model against the JavaScript implementation and
# against the hand-derived expectations. Usage: sh harness/run-hand-cases.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/hand-cases/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/hand-cases.shen" "$jit/lib" "$root" "$out" 2>&1) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
