#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1
impl=${2:-fenrir}
case "$impl" in fenrir|fenrir-profile|c) ;; *) exit 2 ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ "$impl" != c ]; then
(cd "$root/benchmarks/framed-log" && FENRIR_NATIVE_BUILD=1 sh "$root/frontend/fenrir.sh" emit stream.fen "$work/artifact")
node "$root/benchmarks/framed-log/build-stream.mjs" "$work/artifact" "$work/program.s" solo5-arm64-spt
fi
docker run -e IMPL="$impl" --rm --network none --platform linux/arm64 --user "$(id -u):$(id -g)" \
    -v "$root:/src:ro" -v "$work:/build" -w /build --entrypoint sh \
    "${FENRIR_SOLO5_IMAGE:-fenrir-track1-solo5:38e0c348be23-arm64}" -ec '
    export PATH=/opt/solo5-install/bin:$PATH
    echo "{\"type\":\"solo5.manifest\",\"version\":1,\"devices\":[{\"name\":\"input\",\"type\":\"BLOCK_BASIC\"}]}" > manifest.json
    solo5-elftool gen-manifest manifest.json manifest.c
    set -- /src/benchmarks/framed-log/reference.c
    if [ "$IMPL" != c ]; then
        set -- program.s /src/benchmarks/framed-log/stream-main.c /src/runtime/native/heap.c /src/runtime/native/managed.c
    fi
    profile_flag=
    if [ "$IMPL" = fenrir-profile ]; then profile_flag=-DFEN_PROFILE_HEAP; fi
    for source in manifest.c /src/benchmarks/framed-log/stream-spt.c "$@"; do
        aarch64-solo5-none-static-cc $profile_flag -O2 -Wall -Wextra -Werror -I/src/runtime/native -c "$source"
    done
    aarch64-solo5-none-static-ld -z solo5-abi=spt ./*.o -o stream.spt'
cp "$work/stream.spt" "$out"
