#!/bin/sh
# TC1 generated handler family, reduction: for each injected defect of the JavaScript
# handler machine, find a generated program on which it fails, shrink the program's
# choice list (harness/tc1-reduce.shen), then replay the reduced failures in a fresh
# process (harness/tc1-replay.shen). Prints the two reports, one per line.
# Usage: sh harness/run-tc1-reduce.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-reduce/$(date +%s)-$$"
mkdir -p "$out/reduce" "$out/replay"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-reduce.shen" "$jit/lib" "$root" "$out/reduce" sandbox 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
[ "$status" -eq 0 ] || exit "$status"
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-replay.shen" "$jit/lib" "$root" "$out/replay" "$out/reduce/reduced.jsonl" sandbox 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
