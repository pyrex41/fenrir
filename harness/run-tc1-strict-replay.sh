#!/bin/sh
# TC1 strict replay: tapes of the JavaScript handler machine recorded against the
# model's traces and replayed on a fresh machine, for the hand fixtures and for the
# retained original and minimized failures of the reduction campaigns.
# Usage: sh harness/run-tc1-strict-replay.sh [--trusted-local]
set -eu
case "$#:${1:-}" in
  0:) set -- sandbox ;;
  1:--trusted-local) set -- ;;
  *) echo 'usage: run-tc1-strict-replay.sh [--trusted-local]' >&2; exit 2 ;;
esac
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-strict-replay/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-strict-replay.shen" "$jit/lib" "$root" "$out" "$@" < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
