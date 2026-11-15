#!/bin/sh
# Negative control of the generated-family row of the proposed TC1 gate: the row's
# check must be FAIL with each injected defect switched on in the JavaScript
# implementation, and PASS with none (harness/tc1-random-control.shen).
# Usage: sh harness/run-tc1-random-control.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-random-control/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-random-control.shen" "$jit/lib" "$root" "$out" "$jit/bin/shen-jit" 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
