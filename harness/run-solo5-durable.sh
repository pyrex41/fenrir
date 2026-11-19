#!/bin/sh
# Host-controlled Solo5 check of TC1-D1 durable effects over control protocol v2
# (spec/solo5/pure-call-control-v2.md): build the batch and the v2 guest image, then hand
# them to the Shen host (harness/solo5-durable.shen), which drives the stock spt tender
# step by step, answers every host request with the batch's replies, compares with the
# Shen durable model, records and replays tapes and runs the v2 hostile-host tests.
# Usage: sh harness/run-solo5-durable.sh [PROGRAMS.json [quick]]
#   PROGRAMS.json  programs with inputs and replies (default: the TC1-D1 hand fixtures),
#                  as tools/solo5/control-durable-build.mjs reads them
#   quick          controlled runs and one replay per tape only
# Needs Solo5 at the pinned commit (harness/solo5.sh). Shen/JIT: see harness/jit.sh.
set -eu
if [ "$(uname -s)" != Linux ]; then
  echo "Solo5 durable control requires a Linux spt host (ARM64 primary)" >&2
  exit 2
fi
. "$(dirname "$0")/jit.sh"
if [ ! -f "$root/models/tc1/durable-machine.shen" ]; then
  echo "Solo5 durable comparison blocked: missing models/tc1/durable-machine.shen" >&2
  exit 2
fi
. "$(dirname "$0")/solo5.sh"
if [ "$#" -ge 1 ]; then
  batch=$(node "$root/tools/solo5/control-durable-build.mjs" --programs "$1")
else
  batch=$(node "$root/tools/solo5/control-durable-build.mjs")
fi
run="$batch/run"
mkdir -p "$run"
status=0
out=$("$jit/bin/shen-jit" script "$root/harness/solo5-durable.shen" "$jit/lib" "$root" "$batch" "$run" ${2:-} 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$out" | tail -n 1 > "$run/report.json"
cat "$run/report.json"
exit "$status"
