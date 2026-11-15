#!/bin/sh
# Host-controlled Solo5 check of TC1-C1 tasks over control protocol v3
# (spec/solo5/pure-call-control-v3.md): build the batch and the v3 guest image, then hand
# them to the Shen host (harness/solo5-tasks.shen), which drives the stock spt tender
# step by step under recorded reference schedules (the host names every task) and under
# the guest's own FIFO policy, compares with the Shen task model, runs the injected guest
# defects, records and replays tapes and runs the v3 negative tests.
# Usage: sh harness/run-solo5-tasks.sh [--stride N] [--programs FILE.json]...
#   (arguments go to tools/solo5/control-task-build.mjs)
# Needs Solo5 at the pinned commit (harness/solo5.sh). Shen/JIT: see harness/jit.sh.
set -eu
. "$(dirname "$0")/jit.sh"
. "$(dirname "$0")/solo5.sh"
batch=$(node "$root/tools/solo5/control-task-build.mjs" "$@")
run="$batch/run"
mkdir -p "$run"
status=0
out=$("$jit/bin/shen-jit" script "$root/harness/solo5-tasks.shen" "$jit/lib" "$root" "$batch" "$run" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$out" | tail -n 1 > "$run/report.json"
cat "$run/report.json"
exit "$status"
