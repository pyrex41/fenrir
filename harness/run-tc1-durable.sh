#!/bin/sh
# TC1 slice D1 (durable effects discharged by the host): the Shen model against the
# sandboxed JavaScript implementation on every hand fixture under its host replies,
# the handwritten expectations (each kind shown able to fail), and the
# implementation's seven injected defects. Usage: sh harness/run-tc1-durable.sh
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-durable/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-durable.shen" "$jit/lib" "$root" "$out" sandbox 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
