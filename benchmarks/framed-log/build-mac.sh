#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1
case ${2:-fenrir} in
    fenrir) set -- ;;
    fenrir-profile) set -- -DFEN_PROFILE_HEAP ;;
    *) exit 2 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$root/benchmarks/framed-log" && FENRIR_NATIVE_BUILD=1 sh "$root/frontend/fenrir.sh" emit stream.fen "$work/artifact")
node "$root/benchmarks/framed-log/build-stream.mjs" "$work/artifact" "$work/program.s"
clang "$@" -Wall -Wextra -Werror -O2 -arch arm64 -I"$root/runtime/native" \
    "$work/program.s" "$root/benchmarks/framed-log/stream-main.c" "$root/benchmarks/framed-log/stream-darwin.c" \
    "$root/runtime/native/heap.c" "$root/runtime/native/managed.c" -o "$out"
