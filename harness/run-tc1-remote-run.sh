#!/bin/sh
# TC1 remote perform (spec/tc1/EFFECTS.md §12): the real system against the model.
# Builds the caller and peer images for the Solo5 spt tender
# (tools/solo5/remote-build.mjs; the caller's program is the source file
# examples/remote/ledger-caller.fen and the peer's examples/remote/ledger-peer.fen,
# both elaborated by frontend/fenrir.sh; and the same for the rates system,
# examples/remote/rates-system.json, whose peer has no durable store), compiles
# the Erlang/OTP supervisor
# (supervisor/), and hands both to harness/tc1-remote-run.shen, which runs the
# system under a set of schedules and judges every recorded run with the model
# models/tc1/remote-system.shen. See that file for what is checked.
# The negative control runs first: with the non-idempotent peer in place of the
# peer, the same checker must report a failure and exit with status 1.
# Needs: Solo5 at the pinned commit (FENRIR_SOLO5 or build/vendor/solo5),
# Erlang/OTP (harness/find-erlang.sh: FENRIR_ERLANG, else the flake's erlang, else
# erl and erlc on PATH),
# node, and Shen/JIT (harness/jit.sh). No KVM: the spt tender only.
# The TC1 gate's remote-run row (harness/tc1-remote-rows.shen) does the same steps.
# Usage: sh harness/run-tc1-remote-run.sh
set -eu
. "$(dirname "$0")/jit.sh"
erlang=$(sh "$root/harness/find-erlang.sh") || { echo "Erlang/OTP not found (FENRIR_ERLANG, the flake's erlang, or erl and erlc on PATH)" >&2; exit 2; }
erl=$(printf '%s\n' "$erlang" | sed -n 1p); erlc=$(printf '%s\n' "$erlang" | sed -n 2p)
out="$root/build/remote-run/$(date +%s)-$$"
mkdir -p "$out/ebin" "$out/control" "$out/check"
sh "$root/supervisor/build.sh" "$erlc" "$out/ebin" >&2
timeout 600 node "$root/tools/solo5/remote-build.mjs" --out "$out/images" >/dev/null
# The second system: a caller that only reads and a peer with no durable store.
timeout 600 node "$root/tools/solo5/remote-build.mjs" --manifest examples/remote/rates-system.json --out "$out/images-rates" >/dev/null
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
