#!/bin/sh
# TC1 slice H1 (tail-resumptive handlers): model against the JavaScript
# implementation and the handwritten expectations, with its injected defects.
# Usage: sh harness/run-tc1-handlers.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-handlers/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-handlers.shen" "$jit/lib" "$root" "$out" sandbox 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
