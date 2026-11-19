#!/bin/sh
# Stage A3: decide whether recorded histories of the real service are admitted by the A1
# model (harness/service-history.shen; format spec/service/HISTORY_FORMAT.md).
# Evidence: "observed history accepted" for each accepted history, nothing more.
#
# Usage:
#   sh harness/run-service-history.sh LISTFILE [OUTDIR]   one history path per line
#   sh harness/run-service-history.sh FILE.json [OUTDIR]  one history
# Prints one verdict line per history (JSON); writes OUTDIR/verdicts.jsonl.
# Exit 0 when every history was read (compare the verdicts with expectations), 2 if not.
set -eu
. "$(dirname "$0")/jit.sh"
out="${2:-$root/build/harness/service-history/$(date +%s)-$$}"
mkdir -p "$out"
case "$1" in /*) arg=$1 ;; *) arg=$PWD/$1 ;; esac
case "$arg" in
  *.json) list="$out/list.txt"; printf '%s\n' "$arg" > "$list" ;;
  *) list=$arg ;;
esac
status=0
"$jit/bin/shen-jit" script "$root/harness/service-history.shen" "$jit/lib" "$root" "$out" check "$list" > "$out/stdout.txt" 2>&1 < /dev/null || status=$?
# Loading prints one line per definition; the verdicts are the lines that are JSON objects.
grep '^{"history"' "$out/stdout.txt" || true
exit "$status"
