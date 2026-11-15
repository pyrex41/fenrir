#!/bin/sh
# Build a guest batch (JavaScript, for now) and hand it to the Shen harness.
# Usage: sh harness/run-solo5-pure-call.sh [EXHAUSTIVE_NODES=5 | exact | tc1 | tc1-exhaustive [MAX_NODES=7]]
#   a number  hand cases, generated cases and the exhaustive grammar to that bound
#   exact     the exact-arithmetic family: C guest arithmetic against the model's
#   tc1       the TC1 handler fixtures (both slices) with the TC0-A hand cases
#   tc1-exhaustive  every program of the TC1 handler grammar H to the node bound
#             (tools/tc1/handler-enumerate.mjs), with the TC0-A hand cases
# Needs build/vendor/solo5 built at the pinned commit. Shen/JIT: see harness/jit.sh.
set -eu
. "$(dirname "$0")/jit.sh"
if [ "${1:-5}" = exact ]; then
  batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --exact-arithmetic --build-only)
elif [ "${1:-5}" = tc1 ]; then
  batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --tc1 --build-only)
elif [ "${1:-5}" = tc1-exhaustive ]; then
  batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --tc1-exhaustive-nodes "${2:-7}" --build-only)
else
  batch=$(node "$root/tools/solo5/freerun-pure-call.mjs" --exhaustive-nodes "${1:-5}" --build-only)
fi
status=0
out=$("$jit/bin/shen-jit" script "$root/harness/solo5-pure-call.shen" "$jit/lib" "$root" "$batch" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$out" | tail -n 1
exit "$status"
