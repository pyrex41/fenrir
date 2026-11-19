#!/bin/sh
# Accepted-job upgrade contract (application example A4): Gleipnir's bounded exploration
# of the Shen model of the upgrade, its mutants and the A1 sub-scope agreement.
# Development evidence ("bounded exploration passed"), never a gate verdict.
#
# Usage:
#   sh harness/run-service-upgrade.sh [T K D S C R X P G CAP]
#       T tenants, K keys, D digests; budgets S submits, C deliveries, R responses,
#       X crashes, P dispatches, G upgrade steps; CAP the product-state cap
#       (truncation is a fail). Default: 2 1 2 2 2 1 1 1 4 1500000
#   sh harness/run-service-upgrade.sh replay FILE
#       Re-execute a retained counterexample (spec/service/counterexamples-a4/*.json);
#       exits 0 exactly when the named check first fails at the recorded step.
#   sh harness/run-service-upgrade.sh retain OUTDIR
#       Copy the counterexamples of a run into spec/service/counterexamples-a4.
#   sh harness/run-service-upgrade.sh replay-retained
#       Replay every retained counterexample under spec/service/counterexamples-a4.
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/service-upgrade/$(date +%s)-$$"
mkdir -p "$out"
run() {
  "$jit/bin/shen-jit" script "$root/harness/service-upgrade.shen" "$jit/lib" "$root" "$out" "$@" < /dev/null
}
status=0
case "${1:-}" in
  replay)
    case "$2" in /*) file=$2 ;; *) file=$PWD/$2 ;; esac
    report=$(run replay "$file" 2>&1) || status=$?
    printf '%s\n' "$report" | tail -n 1
    exit "$status" ;;
  retain)
    rm -rf "$out"
    mkdir -p "$root/spec/service/counterexamples-a4"
    rm -f "$root"/spec/service/counterexamples-a4/*.json
    for f in "$2"/counterexamples/*.json; do
      sed 's#replay [^"]*/counterexamples/#replay spec/service/counterexamples-a4/#' "$f" \
        > "$root/spec/service/counterexamples-a4/$(basename "$f")"
    done
    ls "$root/spec/service/counterexamples-a4"
    exit 0 ;;
  replay-retained)
    . "$root/harness/service-retained-replay.sh"
    service_replay_retained "" "$root"/spec/service/counterexamples-a4/*.json || status=$?
    exit "$status" ;;
esac
case $# in
  0) set -- 2 1 2 2 2 1 1 1 4 1500000 ;;
  10) ;;
  *) echo "expected ten scope arguments or none" >&2; exit 2 ;;
esac
report=$(run explore "$@" 2>&1) || status=$?
# Loading prints one line per definition; the report is the last line. The full
# report and the counterexamples stay in $out.
printf '%s\n' "$report" | tail -n 1
echo "output: $out" >&2
exit "$status"
