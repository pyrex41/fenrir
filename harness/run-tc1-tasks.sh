#!/bin/sh
# TC1 slice C1 (structured tasks and bounded channels): the Shen model against the
# sandboxed JavaScript implementation on every hand fixture under several recorded
# schedules each, the handwritten expectations, and the implementation's nine injected
# defects. Usage: sh harness/run-tc1-tasks.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-tasks/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-tasks.shen" "$jit/lib" "$root" "$out" sandbox 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
