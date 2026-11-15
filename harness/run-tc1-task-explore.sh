#!/bin/sh
# TC1 slice C1, exhaustive-small: the commuting obligation of spec/tc1/CONCURRENCY.md
# section 9 on every program of grammar G (tools/tc1/task-enumerate.mjs), every reference
# schedule and every production schedule, with two broken variants that must fail it;
# then the sandboxed JavaScript implementation on one witness schedule per reference
# observation class, against the model.
# Usage: sh harness/run-tc1-task-explore.sh [limit N] [states N]   (both for development; they cannot pass)
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-task-explore/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-task-explore.shen" "$jit/lib" "$root" "$out" sandbox "$@" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
