#!/bin/sh
# One run of the remote-perform system by hand: builds the two images and the
# supervisor, then runs the supervisor on a spec.
# Usage: sh supervisor/run.sh                 free-running mode, declared manifest
#        sh supervisor/run.sh SCHEDULE.json   the "schedule" object of a spec (see README.md)
# Needs FENRIR_SOLO5 (or build/vendor/solo5), node, and Erlang/OTP: FENRIR_ERLANG,
# else the flake's erlang, else erl and erlc on PATH.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${FENRIR_ERLANG:-}" ] && command -v nix >/dev/null 2>&1; then
  FENRIR_ERLANG=$(cd "$root" && nix build --no-link --print-out-paths .#erlang 2>/dev/null) || FENRIR_ERLANG=
fi
if [ -n "${FENRIR_ERLANG:-}" ]; then erl="$FENRIR_ERLANG/bin/erl"; erlc="$FENRIR_ERLANG/bin/erlc"
else erl=$(command -v erl); erlc=$(command -v erlc); fi
out="$root/build/supervisor/run-$(date +%s)-$$"
mkdir -p "$out"
sh "$root/supervisor/build.sh" "$erlc" "$out/ebin" >/dev/null
timeout 600 node "$root/tools/solo5/remote-build.mjs" --out "$out/images" >/dev/null
tender=$(sed -n 's/.*"tender":"\([^"]*\)".*/\1/p' "$out/images/build.json")
schedule='{"mode":"free","timeout_ms":"2000","deadline_ms":"20000"}'
[ $# -ge 1 ] && schedule=$(cat "$1")
# The manifest is the one the build wrote: the system manifest
# (examples/remote/ledger-system.json) with each member's image.
cat > "$out/spec.json" <<EOF
{"dir":"$out/run","tender":"$tender","life_ms":"60000","start_check":true,"defects":[],
 "manifest":"$out/images/manifest.json",
 "schedule":$schedule}
EOF
status=0
timeout 120 "$erl" -noshell -pa "$out/ebin" -run fenrir_main main -extra "$out/spec.json" < /dev/null || status=$?
exit "$status"
