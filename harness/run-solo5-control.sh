#!/bin/sh
# Host-controlled Solo5 check: build the batch and both guest images (JavaScript, for
# now), then hand them to the Shen controller (harness/solo5-control.shen), which drives
# the stock spt tender step by step, compares with the Shen model, records and replays
# tapes and runs the hostile-peer tests.
# Usage: sh harness/run-solo5-control.sh [STRIDE=25]
#   STRIDE  every STRIDE-th program of the 5-node exhaustive grammar joins the hand cases
#           and the TC1 handler fixtures
# Needs Solo5 at the pinned commit (harness/solo5.sh). Shen/JIT: see harness/jit.sh.
# The report is printed and kept as report.json in the run directory, with the tapes
# (tape-<program>.fgc) and the guest console logs.
set -eu
if [ "$(uname -s)" != Linux ]; then
  echo "Solo5 control requires a Linux spt host (ARM64 primary)" >&2
  exit 2
fi
. "$(dirname "$0")/jit.sh"
. "$(dirname "$0")/solo5.sh"
batch=$(node "$root/tools/solo5/control-pure-call-build.mjs" --stride "${1:-25}")
run="$batch/run"
mkdir -p "$run"
status=0
out=$("$jit/bin/shen-jit" script "$root/harness/solo5-control.shen" "$jit/lib" "$root" "$batch" "$run" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$out" | tail -n 1 > "$run/report.json"
cat "$run/report.json"
exit "$status"
