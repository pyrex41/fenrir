#!/bin/sh
# TC1 remote perform (spec/tc1/EFFECTS.md §12.12): one request served by a peer's
# program, on three machines. Elaborates the peer programs, runs the cases on the
# JavaScript machine and builds the Solo5 guest that runs them on the C machine
# (tools/tc1/peer-requests.mjs), then compares both with the Shen model, step for
# step (harness/tc1-peer-requests.shen). See that file for what is checked.
# Needs Solo5 at the pinned commit (FENRIR_SOLO5 or build/vendor/solo5), node, and
# Shen/JIT (harness/jit.sh). No KVM: the spt tender only.
# The TC1 gate's remote-peer row (harness/tc1-remote-rows.shen) does the same steps.
# Usage: sh harness/run-tc1-peer-requests.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-peer-requests/$(date +%s)-$$"
mkdir -p "$out"
timeout 600 node "$root/tools/tc1/peer-requests.mjs" --out "$out" >/dev/null
status=0
report=$(timeout 900 "$jit/bin/shen-jit" script "$root/harness/tc1-peer-requests.shen" "$jit/lib" "$root" "$out" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
