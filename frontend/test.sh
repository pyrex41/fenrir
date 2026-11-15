#!/bin/sh
# Tests of the Fenrir frontend. Usage: sh frontend/test.sh
#
#   accepted    every program under examples/ and tests/frontend/programs/
#               elaborates, validates, runs on the model, and prints exactly the
#               lines its header gives after "\\ > " (emissions, then outcome)
#   rejected    every program under tests/frontend/bad/ is rejected with status 1,
#               at the position and with the message its first line states
#               ("\\ expect LINE:COLUMN TEXT", or "\\ expect - TEXT" for a
#               rejection that has no position)
#   round trip  every program under tests/frontend/roundtrip/ is a hand fixture
#               of the same name rewritten in surface syntax: the model run of
#               the elaborated artifact has the fixture's outcome and emissions,
#               and the artifact is the fixture's program up to a renaming of IDs
#   stable      elaborating twice gives the same bytes
#   Solo5       the examples, elaborated, run in the Solo5 guest and agree with
#               the model step for step (harness/solo5-pure-call.shen). Skipped,
#               and said so, when build/vendor/solo5 is not built.
#
# Development evidence only. Exit status 0 when nothing failed.
set -u
. "$(dirname "$0")/../harness/jit.sh"
# Resolve Shen/JIT once for every fenrir.sh below.
FENRIR_SHEN_JIT=$jit
export FENRIR_SHEN_JIT
fenrir="$root/frontend/fenrir.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"
failures=0
fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
  shift
  for line in "$@"; do printf '     %s\n' "$line"; done
}
# What a run says, without what differs between a program and its fixture.
observed() { grep -v -e '^steps: ' -e '^trap at: ' "$1"; }

accepted=0
for file in examples/*.fen tests/frontend/programs/*.fen; do
  accepted=$((accepted + 1))
  sed -n 's/^\\\\ > //p' "$file" > "$work/expected"
  status=0
  sh "$fenrir" run "$file" > "$work/out" 2> "$work/err" || status=$?
  observed "$work/out" > "$work/observed"
  if [ "$status" -ne 0 ] || [ ! -s "$work/expected" ] || ! cmp -s "$work/expected" "$work/observed"; then
    fail "$file" "status $status; expected:" "$(cat "$work/expected")" "got:" "$(cat "$work/out" "$work/err")"
  fi
done

rejected=0
for file in tests/frontend/bad/*.fen; do
  rejected=$((rejected + 1))
  position=$(sed -n '1s/^\\\\ expect \([^ ]*\) .*/\1/p' "$file")
  text=$(sed -n '1s/^\\\\ expect [^ ]* //p' "$file")
  if [ "$position" = - ]; then prefix="$file: error: "; else prefix="$file:$position: error: "; fi
  status=0
  sh "$fenrir" check "$file" > "$work/out" 2> "$work/err" || status=$?
  message=$(cat "$work/err")
  case $message in
    "$prefix"*"$text"*) matched=yes ;;
    *) matched=no ;;
  esac
  if [ "$status" -ne 1 ] || [ -z "$text" ] || [ "$matched" = no ] || [ -s "$work/out" ]; then
    fail "$file" "status $status; expected: $prefix...$text" "got: $message"
  fi
done

roundtrips=0
for file in tests/frontend/roundtrip/*.fen; do
  roundtrips=$((roundtrips + 1))
  name=$(basename "$file" .fen)
  if ! node tests/frontend/fixture.mjs write "$name" "$work/fixture.json"; then fail "$file" "no such fixture"; continue; fi
  sh "$fenrir" run-artifact "$work/fixture.json" > "$work/fixture.out" 2>&1 || true
  sh "$fenrir" run "$file" > "$work/out" 2>&1 || true
  observed "$work/fixture.out" > "$work/expected"
  observed "$work/out" > "$work/observed"
  if ! grep -q '^outcome: ' "$work/expected" || ! cmp -s "$work/expected" "$work/observed"; then
    fail "$file" "the fixture's artifact gives:" "$(cat "$work/fixture.out")" "the surface program gives:" "$(cat "$work/out")"
    continue
  fi
  sh "$fenrir" emit "$file" "$work/elaborated.json" > /dev/null 2>&1
  if ! difference=$(node tests/frontend/fixture.mjs same "$work/fixture.json" "$work/elaborated.json" 2>&1); then
    fail "$file" "not the fixture's program up to IDs:" "$difference"
  fi
done

stable=0
for file in examples/*.fen; do
  stable=$((stable + 1))
  name=$(basename "$file" .fen)
  sh "$fenrir" emit "$file" "$work/$name.json" > /dev/null 2>&1
  sh "$fenrir" emit "$file" "$work/again.json" > /dev/null 2>&1
  if [ ! -s "$work/$name.json" ] || ! cmp -s "$work/$name.json" "$work/again.json"; then fail "$file" "two elaborations differ"; fi
done

# The guest and the harness both stop at 200 steps, so longer programs are
# compared over their first 200 steps only.
if [ -x "$root/build/vendor/solo5/tenders/spt/solo5-spt" ]; then
  set --
  for file in examples/*.fen; do set -- "$@" "$work/$(basename "$file" .fen).json"; done
  guest=$#
  if batch=$(node tests/frontend/solo5-batch.mjs "$@" 2> "$work/err"); then
    report=$("$jit/bin/shen-jit" script "$root/harness/solo5-pure-call.shen" "$jit/lib" "$root" "$batch" 2>&1 < /dev/null | tail -n 1)
    case $report in
      *'"status":"development-pass"'*'"programs_differing":"0"'*) solo5="$guest programs agree with the model in the guest" ;;
      *) solo5="FAILED"; fail "Solo5 guest against the model" "$report" ;;
    esac
  else
    solo5="FAILED"; fail "Solo5 guest build" "$(cat "$work/err")"
  fi
else
  solo5="skipped (build/vendor/solo5 is not built)"
fi

printf 'frontend tests: %s accepted programs, %s rejected programs, %s round trips, %s stable artifacts; Solo5: %s; failures: %s\n' \
  "$accepted" "$rejected" "$roundtrips" "$stable" "$solo5" "$failures"
[ "$failures" -eq 0 ]
