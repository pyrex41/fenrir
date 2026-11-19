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
#   schedules   C1 fixtures use their stated schedule; a non-runnable choice fails
#   stable      elaborating twice gives the same bytes
#   remote      every program under examples/remote/ and tests/frontend/remote/
#               declares a remote effect: it checks, elaborates twice to the same
#               bytes of schema tc1-handler-demo/3, and either runs alone and
#               prints its header's lines, or, when main leaves the remote effect
#               to the system (no "\\ > " lines), run refuses it with status 2.
#               A program that serves an effect (a peer's program, with a
#               (serve ...) form) elaborates to schema tc1-handler-demo/4 and is
#               refused by run in the same way. Files named *.decl.fen hold
#               declarations for other files to include and are not programs.
#   include     every program under tests/frontend/include/ (not its *.decl.fen
#               files) either says "\\ ok" on its first line and runs to the
#               lines of its header, or says "\\ expect FILE:LINE:COLUMN TEXT" and
#               is rejected there, FILE being the file of that directory the
#               problem is in: the program, or a file it includes
#   durable     re-emit the pinned service artifact, and check D1 programs;
#               run I64 entries when the durable model harness is available
#   Solo5       the examples, elaborated, run in the Solo5 guest and agree with
#               the model step for step (harness/solo5-pure-call.shen). Skipped,
#               and said so, when FENRIR_SOLO5 is not set and build/vendor/solo5
#               is not built.
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
  if grep -Fq '"schema_version":"tc1-task-demo/1"' "$work/fixture.json" &&
     ! grep -Fq '"schema_version":"tc1-task-demo/1","slice":"TC1-C1"' "$work/elaborated.json"; then
    fail "$file" "expected C1 artifact identity"; continue
  fi
  if ! difference=$(node tests/frontend/fixture.mjs same "$work/fixture.json" "$work/elaborated.json" 2>&1); then
    fail "$file" "not the fixture's program up to IDs:" "$difference"
  fi
done

schedules=0
for file in tests/frontend/schedules/*.fen; do
  schedules=$((schedules + 1))
  spec=$(sed -n 's/^\\\\ schedule //p' "$file")
  sed -n 's/^\\\\ > //p' "$file" > "$work/expected"
  want=0
  if grep -q ': error:' "$work/expected"; then want=1; fi
  status=0
  sh "$fenrir" run "$file" "$spec" > "$work/out" 2>&1 || status=$?
  observed "$work/out" | grep -v '^schedule: ' > "$work/observed"
  if [ "$status" -ne "$want" ] || [ -z "$spec" ] || [ ! -s "$work/expected" ] ||
     ! cmp -s "$work/expected" "$work/observed"; then
    fail "$file" "status $status (expected $want)" "expected: $(cat "$work/expected")" "got: $(cat "$work/out")"
  fi
done

stable=0
for file in examples/*.fen tests/frontend/programs/task-*.fen; do
  stable=$((stable + 1))
  name=$(basename "$file" .fen)
  sh "$fenrir" emit "$file" "$work/$name.json" > /dev/null 2>&1
  sh "$fenrir" emit "$file" "$work/again.json" > /dev/null 2>&1
  if [ ! -s "$work/$name.json" ] || ! cmp -s "$work/$name.json" "$work/again.json"; then fail "$file" "two elaborations differ"; fi
done

remote=0
for file in examples/remote/*.fen tests/frontend/remote/*.fen; do
  case $file in *.decl.fen) continue ;; esac
  remote=$((remote + 1))
  if grep -q '^(serve ' "$file"; then schema='"schema_version":"tc1-handler-demo/4","serves":'; alone='cannot be run alone: it serves a remote effect'
  else schema='"schema_version":"tc1-handler-demo/3","slice":"TC1-R1"'; alone='cannot be run alone: main performs the remote effect'; fi
  sed -n 's/^\\\\ > //p' "$file" > "$work/expected"
  status=0
  sh "$fenrir" check "$file" > "$work/out" 2> "$work/err" || status=$?
  if [ "$status" -ne 0 ]; then fail "$file" "check: status $status" "$(cat "$work/err")"; continue; fi
  sh "$fenrir" emit "$file" "$work/remote.json" > /dev/null 2>&1
  sh "$fenrir" emit "$file" "$work/again.json" > /dev/null 2>&1
  if [ ! -s "$work/remote.json" ] || ! cmp -s "$work/remote.json" "$work/again.json"; then fail "$file" "two elaborations differ"; fi
  if ! grep -q "$schema" "$work/remote.json"; then fail "$file" "the artifact is not of the expected schema ($schema)"; fi
  status=0
  sh "$fenrir" run "$file" > "$work/out" 2> "$work/err" || status=$?
  if [ -s "$work/expected" ]; then
    observed "$work/out" > "$work/observed"
    if [ "$status" -ne 0 ] || ! cmp -s "$work/expected" "$work/observed"; then
      fail "$file" "status $status; expected:" "$(cat "$work/expected")" "got:" "$(cat "$work/out" "$work/err")"
    fi
  else
    case $(cat "$work/err") in
      *"$alone"*) refused=yes ;;
      *) refused=no ;;
    esac
    if [ "$status" -ne 2 ] || [ "$refused" = no ] || [ -s "$work/out" ]; then
      fail "$file" "run must refuse a program that leaves a remote effect to the system, or serves one, with status 2" "status $status; got:" "$(cat "$work/out" "$work/err")"
    fi
  fi
done
# The example's caller and peer include one declarations file.
for file in examples/remote/ledger-caller.fen examples/remote/ledger-peer.fen; do
  grep -q '^(include "ledger.decl.fen")$' "$file" || fail "$file" "does not include examples/remote/ledger.decl.fen"
done

included=0
for file in tests/frontend/include/*.fen; do
  case $file in *.decl.fen) continue ;; esac
  included=$((included + 1))
  status=0
  if [ "$(sed -n 1p "$file")" = '\\ ok' ]; then
    sed -n 's/^\\\\ > //p' "$file" > "$work/expected"
    sh "$fenrir" run "$file" > "$work/out" 2> "$work/err" || status=$?
    observed "$work/out" > "$work/observed"
    if [ "$status" -ne 0 ] || [ ! -s "$work/expected" ] || ! cmp -s "$work/expected" "$work/observed"; then
      fail "$file" "status $status; expected:" "$(cat "$work/expected")" "got:" "$(cat "$work/out" "$work/err")"
    fi
    continue
  fi
  position=$(sed -n '1s/^\\\\ expect \([^ ]*\) .*/\1/p' "$file")
  text=$(sed -n '1s/^\\\\ expect [^ ]* //p' "$file")
  prefix="tests/frontend/include/$position: error: "
  sh "$fenrir" check "$file" > "$work/out" 2> "$work/err" || status=$?
  message=$(cat "$work/err")
  case $message in
    "$prefix"*"$text"*) matched=yes ;;
    *) matched=no ;;
  esac
  if [ "$status" -ne 1 ] || [ -z "$text" ] || [ -z "$position" ] || [ "$matched" = no ] || [ -s "$work/out" ]; then
    fail "$file" "status $status; expected: $prefix...$text" "got: $message"
  fi
done

durable=0
file=examples/service/accepted-job.fen
durable=$((durable + 1))
if ! sh "$fenrir" emit "$file" "$work/accepted-job.json" > "$work/out" 2> "$work/err" ||
   ! cmp -s "$work/accepted-job.json" host/service/artifacts/accepted-job.json ||
   ! grep -Fq "artifact sha256 $(cat host/service/artifacts/accepted-job.sha256)" "$work/out"; then
  fail "$file" "emit must reproduce the pinned artifact and SHA-256" "$(cat "$work/out" "$work/err")"
fi
for mode in run run-artifact; do
  input=$file
  if [ "$mode" = run-artifact ]; then input="$work/accepted-job.json"; fi
  status=0
  sh "$fenrir" "$mode" "$input" > "$work/out" 2> "$work/err" || status=$?
  if [ "$status" -ne 2 ] || ! grep -Fq 'entry takes a request its host supplies' "$work/err"; then
    fail "$file" "$mode must refuse a host-supplied request instead of running the validation probe" "$(cat "$work/out" "$work/err")"
  fi
done
for file in tests/frontend/durable/*.fen; do
  durable=$((durable + 1))
  status=0
  sh "$fenrir" emit "$file" "$work/durable.json" > "$work/out" 2> "$work/err" || status=$?
  if [ "$status" -ne 0 ] || ! grep -Fq '"schema_version":"tc1-durable-demo/1","slice":"TC1-D1"' "$work/durable.json"; then
    fail "$file" "emit: expected TC1-D1" "$(cat "$work/out" "$work/err")"
    continue
  fi
  status=0
  sh "$fenrir" run "$file" > "$work/out" 2> "$work/err" || status=$?
  if [ -f harness/tc1-durable-common.shen ] && [ -f models/tc1/durable-machine.shen ]; then
    sed -n 's/^\\\\ > //p' "$file" > "$work/expected"
    observed "$work/out" > "$work/observed"
    if [ "$status" -ne 0 ] || [ ! -s "$work/expected" ] || ! cmp -s "$work/expected" "$work/observed"; then
      fail "$file" "status $status; expected:" "$(cat "$work/expected")" "got:" "$(cat "$work/out" "$work/err")"
    fi
  elif [ "$status" -ne 2 ] || ! grep -Fq 'cannot run TC1-D1 without the durable model harness' "$work/err"; then
    fail "$file" "run must refuse when the model harness is missing" "$(cat "$work/out" "$work/err")"
  fi
done

# The guest and the harness both stop at 200 steps, so longer programs are
# compared over their first 200 steps only.
if [ -n "${FENRIR_SOLO5:-}" ] || [ -x "$root/build/vendor/solo5/tenders/spt/solo5-spt" ]; then
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
  solo5="skipped (FENRIR_SOLO5 is not set and build/vendor/solo5 is not built)"
fi

printf 'frontend tests: %s accepted programs, %s rejected programs, %s round trips, %s schedule runs, %s stable artifacts, %s remote programs, %s programs with includes, %s durable programs; Solo5: %s; failures: %s\n' \
  "$accepted" "$rejected" "$roundtrips" "$schedules" "$stable" "$remote" "$included" "$durable" "$solo5" "$failures"
[ "$failures" -eq 0 ]
