#!/bin/sh
# TC1 discovery-and-reduction campaign for one injected handler defect: discover the
# first generated program showing the defect's discrepancy class, reduce it by typed
# proposals, and replay the original and minimized failures strictly.
# Usage: sh harness/run-tc1-reduction.sh DEFECT
#   DEFECT forgotten_resume | double_resume | outermost_handler | shallow_resume
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-reduction/$(date +%s)-$$-${1:?DEFECT}"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-reduction.shen" "$jit/lib" "$root" "$out" "$1" sandbox 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
