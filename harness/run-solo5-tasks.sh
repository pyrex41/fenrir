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
if [ "$(uname -s)" != Linux ]; then
  echo "Solo5 task control requires a Linux spt host (ARM64 primary)" >&2
  exit 2
fi
. "$(dirname "$0")/jit.sh"
. "$(dirname "$0")/solo5.sh"
batch=$(node "$root/tools/solo5/control-task-build.mjs" "$@")
run="$batch/run"
mkdir -p "$run"
status=0
"$jit/bin/shen-jit" script "$root/harness/solo5-tasks.shen" "$jit/lib" "$root" "$batch" "$run" < /dev/null > "$run/shen.log" 2>&1 || status=$?
# Preserve diagnostics; don't publish an exception's last line as a report.
tail -n 1 "$run/shen.log" > "$run/result.txt"
if ! node -e 'const r=JSON.parse(require("node:fs").readFileSync(process.argv[1]));if(r.schema!=="fenrir.harness.solo5-tasks/1"||r.qualification!=="UNKNOWN"||r.status!==(process.argv[2]==="0"?"development-pass":"development-fail"))process.exit(1)' "$run/result.txt" "$status"; then
  tail -n 25 "$run/shen.log" >&2
  exit 2
fi
mv "$run/result.txt" "$run/report.json"
cat "$run/report.json"
exit "$status"
