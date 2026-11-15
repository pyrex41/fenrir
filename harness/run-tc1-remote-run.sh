#!/bin/sh
# TC1 remote perform (spec/tc1/EFFECTS.md §12): the real system against the model.
# Builds the caller and peer images for the Solo5 spt tender
# (tools/solo5/remote-build.mjs), compiles the Erlang/OTP supervisor
# (supervisor/), and hands both to harness/tc1-remote-run.shen, which runs the
# system under a set of schedules and judges every recorded run with the model
# models/tc1/remote-system.shen. See that file for what is checked.
# The negative control runs first: with the non-idempotent peer in place of the
# peer, the same checker must report a failure and exit with status 1.
# Needs: Solo5 at the pinned commit (FENRIR_SOLO5 or build/vendor/solo5),
# Erlang/OTP (FENRIR_ERLANG, else the flake's erlang, else erl and erlc on PATH),
# node, and Shen/JIT (harness/jit.sh). No KVM: the spt tender only.
# Usage: sh harness/run-tc1-remote-run.sh
set -eu
. "$(dirname "$0")/jit.sh"
if [ -z "${FENRIR_ERLANG:-}" ] && command -v nix >/dev/null 2>&1; then
  FENRIR_ERLANG=$(cd "$root" && nix build --no-link --print-out-paths .#erlang 2>/dev/null) || FENRIR_ERLANG=
fi
if [ -n "${FENRIR_ERLANG:-}" ]; then erl="$FENRIR_ERLANG/bin/erl"; erlc="$FENRIR_ERLANG/bin/erlc"
else erl=$(command -v erl); erlc=$(command -v erlc); fi
out="$root/build/remote-run/$(date +%s)-$$"
mkdir -p "$out/ebin" "$out/control" "$out/check"
sh "$root/supervisor/build.sh" "$erlc" "$out/ebin" >&2
timeout 600 node "$root/tools/solo5/remote-build.mjs" --out "$out/images" >/dev/null
run() {
  timeout "$1" "$jit/bin/shen-jit" script "$root/harness/tc1-remote-run.shen" "$jit/lib" "$root" \
    "$out/images" "$out/ebin" "$erl" "$out/$2" "$3" ${4:+"$4"} 2>&1 < /dev/null
}
control_status=0
control_report=$(run 300 control negative-control) || control_status=$?
control=not-failed
case "$control_status:$(printf '%s\n' "$control_report" | tail -n 1)" in
  1:*'"status":"development-fail"'*) control=failed-as-required ;;
esac
status=0
report=$(run 1500 check check "$control") || status=$?
# Loading prints one line per definition; the report is the last line.
printf '%s\n' "$report" | tail -n 1
exit "$status"
