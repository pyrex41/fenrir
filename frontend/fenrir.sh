#!/bin/sh
# Fenrir frontend: check, run or emit a program written in the surface syntax
# (spec/tc1/SURFACE.md, a draft).
#
#   sh frontend/fenrir.sh check FILE.fen           elaborate and validate
#   sh frontend/fenrir.sh run FILE.fen [SCHEDULE] [PROFILE]   check, then run on the Shen model
#   sh frontend/fenrir.sh emit FILE.fen OUT.json   check, then write the artifact
#   sh frontend/fenrir.sh run-artifact FILE.json [SCHEDULE] [PROFILE]
#
# The entry point is the function main, run with input 0. FENRIR_FUEL bounds the
# model steps of a run (default 100000). Shen/JIT: see harness/jit.sh.
# Exit status: 0 done (a trap is an outcome, not a failure), 1 the program was
# rejected, 2 usage or a file problem, 3 a defect in the frontend, 4 the step
# budget ran out. A program whose main leaves a remote effect to the system
# (spec/tc1/SURFACE.md) is checked and emitted, but run refuses it with status 2:
# it needs a peer, which only a system of images has. A durable program with a
# typed host request is also refused by run; with I64 input, run uses the durable
# model harness when installed and stops at the first host request, if any.
# FENRIR_REQUIRE_SHEN_TYPING=1 additionally requires the fixed Shen checker.
# An unsupported schema or unknown search in that mode exits with status 2.
# SCHEDULE applies only to C1: fifo (default), lowest, highest, random:N,
# prandom:N, or a JSON file of task IDs.
set -eu
usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
[ $# -ge 2 ] || usage
command=$1 file=$2
# The module name of an artifact is its file name without directory or extension.
module=$(basename "$file" .fen)
fuel=${FENRIR_FUEL:-100000}
case $fuel in ''|*[!0-9]*) echo "FENRIR_FUEL must be a number of steps" >&2; exit 2 ;; esac
case $command in
  check) [ $# -eq 2 ] || usage; set -- check "$file" "$module" ;;
  run)
    case $# in 2) set -- run "$file" "$module" "$fuel" ;; 3) set -- run "$file" "$module" "$fuel" "$3" ;; 4) set -- run "$file" "$module" "$fuel" "$3" "$4" ;; *) usage ;; esac ;;
  emit) [ $# -eq 3 ] || usage; set -- emit "$file" "$module" "$3" ;;
  run-artifact)
    case $# in 2) set -- run-artifact "$file" "$fuel" ;; 3) set -- run-artifact "$file" "$fuel" "$3" ;; 4) set -- run-artifact "$file" "$fuel" "$3" "$4" ;; *) usage ;; esac ;;
  *) usage ;;
esac
case ${FENRIR_REQUIRE_SHEN_TYPING:-0} in
  0) ;;
  1) set -- require-shen-typing "$@" ;;
  *) echo "FENRIR_REQUIRE_SHEN_TYPING must be 0 or 1" >&2; exit 2 ;;
esac
. "$(dirname "$0")/../harness/jit.sh"
if [ ! -x "$jit/bin/shen-jit" ]; then
  echo "Shen/JIT was not found at $jit: see harness/jit.sh" >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
"$jit/bin/shen-jit" script "$root/frontend/main.shen" "$jit/lib" "$root" "$work" "$@" > "$work/log" 2>&1 < /dev/null || status=$?
if [ ! -f "$work/result" ]; then
  # The driver always writes a result; without one, Shen itself stopped.
  echo "internal error in the frontend; the end of the Shen log follows" >&2
  tail -n 5 "$work/log" >&2
  exit 3
fi
if [ "$status" -eq 0 ] || [ "$status" -eq 4 ]; then
  if [ "$command" = emit ] && [ -n "${FENRIR_BUILD_INPUTS_DIR:-}" ] && [ "$status" -eq 0 ]; then
    cp "$work/inputs.json" "$FENRIR_BUILD_INPUTS_DIR/inputs.json"
  fi
  cat "$work/result"
else
  cat "$work/result" >&2
fi
exit "$status"
