#!/bin/sh
# Fenrir typing: Shen-side validation (structure, derivation search, fixed checker)
# against the JavaScript validator on every program family, with forged-derivation
# and type-safety evidence. Development evidence only; see typing/run.shen.
# Usage: sh typing/run.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/harness/jit.sh"
out="$root/build/typing/$(date +%s)-$$"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/typing/run.shen" "$jit/lib" "$root" "$out" 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
