#!/bin/sh
# TC1 slice C1, closing the loop: the generated family beyond grammar G (model against
# the sandboxed JavaScript implementation), catalog coverage of the C1 transitions over
# hand, exhaustive and generated traces with depth, scheduling-point and queue
# invariants, discovery-and-reduction campaigns for four of the nine JavaScript task
# defects, and strict replay of hand-fixture and retained-failure tapes.
# Usage: sh harness/run-tc1-task-loop.sh [stride N]   (stride over grammar G for coverage; default 1, all of G)
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-task-loop/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-task-loop.shen" "$jit/lib" "$root" "$out" sandbox "$@" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1 > "$out/report.json"
cat "$out/report.json"
exit "$status"
