#!/bin/sh
# Fenrir frontend: check, run or emit a program written in the surface syntax
# (spec/tc1/SURFACE.md, a draft).
#
#   sh frontend/fenrir.sh check FILE.fen           elaborate and validate
#   sh frontend/fenrir.sh run FILE.fen             check, then run on the Shen model
#   sh frontend/fenrir.sh emit FILE.fen OUT.json   check, then write the artifact
#   sh frontend/fenrir.sh run-artifact FILE.json   validate and run an existing artifact
#
# The entry point is the function main, run with input 0. FENRIR_FUEL bounds the
# model steps of a run (default 100000). Shen/JIT: see harness/jit.sh.
# Exit status: 0 done (a trap is an outcome, not a failure), 1 the program was
# rejected, 2 usage or a file problem, 3 a defect in the frontend, 4 the step
# budget ran out.
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
  run) [ $# -eq 2 ] || usage; set -- run "$file" "$module" "$fuel" ;;
  emit) [ $# -eq 3 ] || usage; set -- emit "$file" "$module" "$3" ;;
  run-artifact) [ $# -eq 2 ] || usage; set -- run-artifact "$file" "$fuel" ;;
  *) usage ;;
esac
. "$(dirname "$0")/../harness/jit.sh"
if [ ! -x "$jit/bin/shen-jit" ]; then
  echo "Shen/JIT was not found at $jit: see harness/jit.sh" >&2
  exit 2
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The Shen typing checker (typing/): its files are compiled once into a heap image
# per Shen/JIT build and version of those files, under build/typing/, so that a run
# does not recompile the search's sequent rules (about 0.3 s). The image holds only
# what those files define; without it, main.shen loads them from source.
image=
if key=$( { echo "$jit"; cat "$root/typing/checker.shen" "$root/typing/structure.shen" "$root/typing/search.shen"; } 2>/dev/null |
          sha256sum 2>/dev/null | cut -c1-16) && [ ${#key} -eq 16 ]; then
  image="$root/build/typing/image-$key.img"
  if [ ! -f "$image" ]; then
    partial="$image.$$"
    if mkdir -p "$root/build/typing" 2>/dev/null &&
       "$jit/bin/shen-jit" --save "$partial" eval -q -l "$root/typing/checker.shen" -l "$root/typing/structure.shen" \
         -l "$root/typing/search.shen" > /dev/null 2>&1 < /dev/null &&
       mv "$partial" "$image" 2>/dev/null; then :; else rm -f "$partial"; image=; fi
  fi
fi
status=0
if [ -n "$image" ]; then
  SHEN_JIT_IMAGE=$image "$jit/bin/shen-jit" script "$root/frontend/main.shen" "$jit/lib" "$root" "$work" "$@" > "$work/log" 2>&1 < /dev/null || status=$?
else
  "$jit/bin/shen-jit" script "$root/frontend/main.shen" "$jit/lib" "$root" "$work" "$@" > "$work/log" 2>&1 < /dev/null || status=$?
fi
if [ ! -f "$work/result" ]; then
  # The driver always writes a result; without one, Shen itself stopped.
  echo "internal error in the frontend; the end of the Shen log follows" >&2
  tail -n 5 "$work/log" >&2
  exit 3
fi
if [ "$status" -eq 0 ] || [ "$status" -eq 4 ]; then
  cat "$work/result"
else
  cat "$work/result" >&2
fi
exit "$status"
