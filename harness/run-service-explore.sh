#!/bin/sh
# Accepted-job contract (application example A1): Gleipnir's bounded exploration
# of the Shen model, its mutants and the JavaScript implementation.
# Development evidence ("bounded exploration passed"), never a gate verdict.
#
# Usage:
#   sh harness/run-service-explore.sh [T K D S C R X CAP] [sandbox]
#       T tenants, K keys, D digests; budgets S submits, C deliveries,
#       R responses, X crashes; CAP the product-state cap (truncation is a fail).
#       Default: 2 2 2 3 2 2 1 2000000
#   sh harness/run-service-explore.sh replay FILE
#       Re-execute a retained counterexample (e.g. spec/service/counterexamples/*.json);
#       exits 0 exactly when the named check first fails at the recorded step.
#   sh harness/run-service-explore.sh retain OUTDIR
#       Copy the counterexamples of a run into spec/service/counterexamples.
#   sh harness/run-service-explore.sh replay-retained
#       Replay every retained counterexample under spec/service/counterexamples.
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/service-explore/$(date +%s)-$$"
mkdir -p "$out"
run() {
  "$jit/bin/shen-jit" script "$root/harness/service-explore.shen" "$jit/lib" "$root" "$out" "$@" < /dev/null
}
status=0
case "${1:-}" in
  replay)
    case "$2" in /*) file=$2 ;; *) file=$PWD/$2 ;; esac
    report=$(run replay "$file" 2>&1) || status=$?
    printf '%s\n' "$report" | tail -n 1
    exit "$status" ;;
  retain)
    # Copy a run's counterexamples (OUTDIR given) into spec/service/counterexamples,
    # pointing each file's replay command at its retained copy.
    rm -rf "$out"
    mkdir -p "$root/spec/service/counterexamples"
    for f in "$2"/counterexamples/*.json; do
      sed 's#build/harness/service-explore/[^"]*/counterexamples/#spec/service/counterexamples/#' "$f" \
        > "$root/spec/service/counterexamples/$(basename "$f")"
    done
    ls "$root/spec/service/counterexamples"
    exit 0 ;;
  replay-retained)
    for f in "$root"/spec/service/counterexamples/*.json; do
      line=$(run replay "$f" 2>&1 | tail -n 1) || true
      case "$line" in
        *'"status":"reproduced"'*) echo "reproduced: ${f#$root/}" ;;
        *) echo "NOT reproduced: ${f#$root/}: $line"; status=1 ;;
      esac
    done
    exit "$status" ;;
esac
if [ "$#" -ge 8 ]; then params="$1 $2 $3 $4 $5 $6 $7 $8"; shift 8; else params="2 2 2 3 2 2 1 2000000"; fi
# shellcheck disable=SC2086
report=$(run explore $params "$@" 2>&1) || status=$?
# Loading prints one line per definition; the report is the last line. The full
# report and the counterexamples stay in $out.
printf '%s\n' "$report" | tail -n 1
echo "output: $out" >&2
exit "$status"
