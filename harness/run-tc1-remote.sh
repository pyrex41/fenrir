#!/bin/sh
# TC1 remote perform (spec/tc1/EFFECTS.md §12): bounded exhaustive exploration of
# the Shen model models/tc1/remote-system.shen, its mutants, and a negative
# control. The model only: the implementation is checked by run-tc1-remote-run.sh.
# The negative control runs first: the same checker with the non-idempotent
# mutant in place of the model must report a failure and exit with status 1.
# Usage: sh harness/run-tc1-remote.sh
set -eu
. "$(dirname "$0")/jit.sh"
control_status=0
control_report=$(timeout 600 "$jit/bin/shen-jit" script "$root/harness/tc1-remote.shen" "$jit/lib" "$root" negative-control 2>&1 < /dev/null) || control_status=$?
control=not-failed
case "$control_status:$(printf '%s\n' "$control_report" | tail -n 1)" in
  1:*'"status":"development-fail"'*) control=failed-as-required ;;
esac
status=0
report=$(timeout 1200 "$jit/bin/shen-jit" script "$root/harness/tc1-remote.shen" "$jit/lib" "$root" check "$control" 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
