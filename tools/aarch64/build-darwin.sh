#!/bin/sh
# Compile a .fen program in the checked-call profile to a Darwin arm64 executable.
set -eu
if [ "$#" -ne 2 ]; then
    echo 'usage: build-darwin.sh SOURCE.fen OUTPUT' >&2
    exit 2
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
exec "$root/bin/fenrir" build --target macos-arm64 "$1" -o "$2"
