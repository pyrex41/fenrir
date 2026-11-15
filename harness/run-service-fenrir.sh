#!/bin/sh
# Stage A2: the refinement check of the Fenrir accepted-job handler against the A1
# model (spec/service/HANDLER.md), its handler mutants, and the same handler runs
# through the JavaScript TC1-D1 implementation and the Solo5 guest (control protocol v2).
# Development evidence ("bounded exploration passed"), never a gate verdict.
#
# Usage:
#   sh harness/run-service-fenrir.sh [T K D S C R X CAP]
#       A1's scope (harness/run-service-explore.sh); default 2 2 2 3 2 2 1 2000000
#   sh harness/run-service-fenrir.sh replay FILE
#   sh harness/run-service-fenrir.sh replay-retained   (every file of spec/service/counterexamples-a2)
#       Re-execute a retained counterexample of a handler mutant.
# Prints the Shen report, then the Solo5 report on the sample; exit 0 when both pass.
set -eu
. "$(dirname "$0")/jit.sh"
. "$(dirname "$0")/solo5.sh"
FENRIR_SHEN_JIT=$jit
export FENRIR_SHEN_JIT
out="$root/build/harness/service-fenrir/$(date +%s)-$$"
artifacts="$out/artifacts"
mkdir -p "$artifacts"
# Elaborate the handler and its mutants; a mutant the frontend rejects is recorded with
# its message (a static rejection), anything else that fails stops the run.
elaborate() {
  status=0
  sh "$root/frontend/fenrir.sh" emit "$1" "$artifacts/$2.json" > "$out/$2.emit" 2> "$out/$2.err" || status=$?
  case $status in
    0) ;;
    1) mv "$out/$2.err" "$artifacts/$2.rejected"; rm -f "$artifacts/$2.json" ;;
    *) echo "elaboration of $1 failed with status $status" >&2; cat "$out/$2.err" >&2; exit 2 ;;
  esac
}
elaborate "$root/examples/service/accepted-job.fen" accepted-job
for f in "$root"/examples/service/mutants/*.fen; do elaborate "$f" "$(basename "$f" .fen)"; done
run() {
  "$jit/bin/shen-jit" script "$root/harness/service-fenrir.shen" "$jit/lib" "$root" "$out" "$@" < /dev/null
}
status=0
if [ "${1:-}" = replay-retained ]; then
  for f in "$root"/spec/service/counterexamples-a2/*.json; do
    line=$(run replay "$f" "$artifacts" 2>&1 | tail -n 1) || true
    case "$line" in
      *'"status":"reproduced"'*) echo "reproduced: ${f#$root/}" ;;
      *) echo "NOT reproduced: ${f#$root/}: $line"; status=1 ;;
    esac
  done
  exit "$status"
fi
if [ "${1:-}" = replay ]; then
  case "$2" in /*) file=$2 ;; *) file=$PWD/$2 ;; esac
  report=$(run replay "$file" "$artifacts" 2>&1) || status=$?
  printf '%s\n' "$report" | tail -n 1
  exit "$status"
fi
if [ "$#" -ge 8 ]; then params="$1 $2 $3 $4 $5 $6 $7 $8"; else params="2 2 2 3 2 2 1 2000000"; fi
# shellcheck disable=SC2086
report=$(run check "$artifacts" $params sandbox 2>&1) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
if [ ! -s "$out/service-sample.json" ]; then echo "no sample was written" >&2; exit 1; fi
if [ -z "$FENRIR_SOLO5" ] || [ ! -x "$FENRIR_SOLO5/tenders/spt/solo5-spt" ]; then
  echo '{"solo5":"not run: no Solo5 (harness/solo5.sh); this is not a pass"}'
  exit 1
fi
guest=0
sh "$root/harness/run-solo5-durable.sh" "$out/service-sample.json" quick || guest=$?
echo "output: $out" >&2
[ "$status" -eq 0 ] && [ "$guest" -eq 0 ]
