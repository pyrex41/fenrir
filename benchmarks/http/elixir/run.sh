#!/bin/sh
set -eu
cd "$(dirname "$0")"
root=$(cd ../../.. && pwd)
mix_root=${FENRIR_HTTP_MIX_ROOT:-$root/build/http/elixir}
export MIX_BUILD_PATH="$mix_root/build" MIX_DEPS_PATH="$mix_root/deps"
if [ "${1:-}" = build ]; then
    mix deps.get --check-locked
    exec mix compile
fi
exec mix run --no-compile serve.exs "$@"
