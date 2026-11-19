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
"$jit/bin/shen-jit" script "$root/harness/tc1-task-loop.shen" "$jit/lib" "$root" "$out" sandbox "$@" < /dev/null > "$out/shen.log" 2>&1 || status=$?
tail -n 1 "$out/shen.log" > "$out/result.txt"
if ! node -e 'const r=JSON.parse(require("node:fs").readFileSync(process.argv[1]));if(r.schema!=="fenrir.harness.tc1-task-loop/1"||r.qualification!=="UNKNOWN"||r.status!==(process.argv[2]==="0"?"development-pass":"development-fail"))process.exit(1)' "$out/result.txt" "$status"; then
  tail -n 25 "$out/shen.log" >&2
  exit 2
fi
mv "$out/result.txt" "$out/report.json"
cat "$out/report.json"
exit "$status"
