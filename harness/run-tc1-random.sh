#!/bin/sh
# TC1 generated handler family: programs generated in Shen from fixed seeds
# (harness/tc1-generate.shen), accepted by the validator, and agreed step for step by
# the Shen model, the JavaScript implementation and the Solo5 guest.
# Usage: sh harness/run-tc1-random.sh [SEEDS=20] [PER_SEED=1000] [noguest | defect=NAME]
#   noguest       leave the Solo5 guest out (model against the implementation only)
#   defect=NAME   negative control: switch an injected defect on; the check must fail
# The guest needs build/vendor/solo5 built at the pinned commit. Shen/JIT: see harness/jit.sh.
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/tc1-random/$(date +%s)-$$"
mkdir -p "$out"
case "${3:-}" in
  noguest) set -- "${1:-20}" "${2:-1000}" ;;
  defect=*) set -- "${1:-20}" "${2:-1000}" "$3" ;;
  "") set -- "${1:-20}" "${2:-1000}" "guest=$jit/bin/shen-jit" ;;
  *) echo "Usage: sh harness/run-tc1-random.sh [SEEDS=20] [PER_SEED=1000] [noguest | defect=NAME]" >&2; exit 2 ;;
esac
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/tc1-random.shen" "$jit/lib" "$root" "$out" "$1" "$2" sandbox ${3:+"$3"} 2>&1 < /dev/null) || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
