#!/bin/sh
# Stage A4: the refinement check of the Fenrir handlers (v1 unchanged, v2) and of the
# Fenrir migration program against the A4 model (spec/service/UPGRADE.md section 9), the
# Fenrir mutants of examples/service/mutants-a4, and every distinct run through the
# JavaScript TC1-D1 implementation and the Solo5 guest (control protocol v2).
# Development evidence ("bounded exploration passed"), never a gate verdict.
#
# Usage:
#   sh harness/run-service-upgrade-fenrir.sh [T K D S C R X P G CAP]
#       the A4 scope (harness/run-service-upgrade.sh); default 2 1 2 2 2 1 1 1 4 1500000
#   sh harness/run-service-upgrade-fenrir.sh replay FILE
#   sh harness/run-service-upgrade-fenrir.sh replay-retained   (spec/service/counterexamples-a4-fenrir)
#   sh harness/run-service-upgrade-fenrir.sh retain OUTDIR
# Prints the Shen report, then the Solo5 report on the sample; exit 0 when both pass.
set -eu
. "$(dirname "$0")/jit.sh"
. "$(dirname "$0")/solo5.sh"
FENRIR_SHEN_JIT=$jit
export FENRIR_SHEN_JIT
out="$root/build/harness/service-upgrade-fenrir/$(date +%s)-$$"
artifacts="$out/artifacts"
mkdir -p "$artifacts"
retained="$root/spec/service/counterexamples-a4-fenrir"
if [ "${1:-}" = retain ]; then
  rm -rf "$out"
  mkdir -p "$retained"
  rm -f "$retained"/*.json
  for f in "$2"/counterexamples/*.json; do
    sed 's#replay [^"]*/counterexamples/#replay spec/service/counterexamples-a4-fenrir/#' "$f" > "$retained/$(basename "$f")"
  done
  ls "$retained"
  exit 0
fi
# Elaborate from the repository root with repository-relative names: an artifact's source
# map carries the file as named, so its bytes and hash are the same on every machine.
elaborate() {
  (cd "$root" && sh frontend/fenrir.sh emit "$1" "$artifacts/$2.json") > "$out/$2.emit" 2> "$out/$2.err" || {
    echo "elaboration of $1 failed" >&2; cat "$out/$2.err" >&2; exit 2; }
}
elaborate examples/service/accepted-job.fen accepted-job
elaborate examples/service/accepted-job-v2.fen accepted-job-v2
elaborate examples/service/migrate-v1-v2.fen migrate-v1-v2
for f in "$root"/examples/service/mutants-a4/*.fen; do
  elaborate "examples/service/mutants-a4/$(basename "$f")" "$(basename "$f" .fen)"
done
run() {
  "$jit/bin/shen-jit" script "$root/harness/service-upgrade-fenrir.shen" "$jit/lib" "$root" "$out" "$@" < /dev/null
}
status=0
if [ "${1:-}" = replay-retained ]; then
  for f in "$retained"/*.json; do
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
if [ "$#" -ge 10 ]; then params="$1 $2 $3 $4 $5 $6 $7 $8 $9 ${10}"; else params="2 1 2 2 2 1 1 1 4 1500000"; fi
# shellcheck disable=SC2086
report=$(run check "$artifacts" $params sandbox 2>&1) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
if [ ! -s "$out/service-upgrade-sample.json" ]; then echo "no sample was written" >&2; exit 1; fi
if [ -z "$FENRIR_SOLO5" ] || [ ! -x "$FENRIR_SOLO5/tenders/spt/solo5-spt" ]; then
  echo '{"solo5":"not run: no Solo5 (harness/solo5.sh); this is not a pass"}'
  exit 1
fi
guest=0
sh "$root/harness/run-solo5-durable.sh" "$out/service-upgrade-sample.json" quick || guest=$?
echo "output: $out" >&2
[ "$status" -eq 0 ] && [ "$guest" -eq 0 ]
