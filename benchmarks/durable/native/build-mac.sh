#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$root" && sh frontend/fenrir.sh emit examples/service/accepted-job.fen "$work/handler.json")
node "$root/benchmarks/durable/native/build.mjs" "$work/handler.json" "$work" macos-arm64
clang -arch arm64 -O2 -Wall -Wextra -Werror -I"$work" -I"$root/runtime/native" \
    "$work/program.s" "$root/benchmarks/durable/native/mac.c" "$root/benchmarks/durable/native/port.c" \
    "$root/runtime/native/managed.c" "$root/runtime/native/heap.c" -o "$1"
