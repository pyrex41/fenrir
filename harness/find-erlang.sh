#!/bin/sh
# Where Erlang/OTP is, for the supervisor (supervisor/): prints two lines, the
# erl executable and the erlc executable, or prints nothing and exits 1.
# FENRIR_ERLANG (an installation directory) decides when it is set, usable or
# not; otherwise the flake's erlang output when nix can provide it; otherwise
# erl and erlc on PATH. The one lookup harness/run-tc1-remote-run.sh and the TC1
# gate's remote-run row both use. Only the flake output satisfies the gate's
# toolchain row.
# Usage: sh harness/find-erlang.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${FENRIR_ERLANG:-}" ] && command -v nix >/dev/null 2>&1; then
  FENRIR_ERLANG=$(cd "$root" && nix build --no-link --print-out-paths .#erlang 2>/dev/null) || FENRIR_ERLANG=
fi
if [ -n "${FENRIR_ERLANG:-}" ]; then erl="$FENRIR_ERLANG/bin/erl"; erlc="$FENRIR_ERLANG/bin/erlc"
else erl=$(command -v erl || true); erlc=$(command -v erlc || true); fi
[ -n "$erl" ] && [ -n "$erlc" ] && [ -x "$erl" ] && [ -x "$erlc" ] || exit 1
printf '%s\n%s\n' "$erl" "$erlc"
