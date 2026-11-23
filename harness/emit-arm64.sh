#!/bin/sh
set -eu
. "$(dirname "$0")/jit.sh"
target=$1 artifact=$2 output=$3 profile=$4
exports=${5:-[]}
case "$target" in
    macos-arm64) entry=_fenrir_entry ;;
    solo5-arm64-spt) entry=fenrir_entry ;;
    *) exit 2 ;;
esac
case "$profile" in
    --proof-call) kind=proof-call ;;
    --proof-expr) kind=proof-expr ;;
    *) kind=standalone ;;
esac
if [ "$kind" = standalone ] && [ "$profile" != --application ]; then
    node "$root/tools/aarch64/shen-profile.mjs" "$target" "$artifact" "$output.stamp" "$profile"
fi
"$jit/bin/shen-jit" script "$root/backends/arm64/emit.shen" "$jit/lib/" \
    "$root/backends/arm64" "$artifact" "$output" "$entry" "$exports" "${6:-[]}" "$root/spec/native/standalone-v1.json" "$kind" > "$output.log" 2>&1 || {
    if [ -s "$output.error" ]; then cat "$output.error" >&2; else tail -8 "$output.log" >&2; fi
    exit 1
}
[ "$kind" = standalone ] && [ "$profile" != --application ] || exit 0
cat "$output.stamp" >> "$output"
