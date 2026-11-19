#!/bin/sh
# Compiles the supervisor with erlc: plain OTP, no rebar, no hex.
# Usage: sh supervisor/build.sh [ERLC=erlc] [EBIN=build/supervisor/ebin]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
erlc=${1:-erlc}
ebin=${2:-$here/../build/supervisor/ebin}
mkdir -p "$ebin"
"$erlc" -Werror -o "$ebin" "$here"/src/*.erl
cp "$here/src/fenrir_supervisor.app.src" "$ebin/fenrir_supervisor.app"
echo "$ebin"
