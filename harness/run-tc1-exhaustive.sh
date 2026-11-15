#!/bin/sh
# TC1 exhaustive-small handler family: the Shen model against the JavaScript
# implementation on every program of grammar H (tools/tc1/handler-enumerate.mjs) up to
# the node bound, with the implementation's six injected defects.
# Usage: sh harness/run-tc1-exhaustive.sh [MAX_NODES=7]
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-exhaustive/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-exhaustive.shen" "$jit/lib" "$root" "${1:-7}" "$out" sandbox 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
