#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1
impl=${2:-fenrir}
case "$impl" in fenrir|c) ;; *) exit 2 ;; esac
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ "$impl" = fenrir ]; then
    (cd "$root/benchmarks/http" && FENRIR_NATIVE_BUILD=1 sh "$root/frontend/fenrir.sh" emit service.fen "$work/artifact")
    node "$root/benchmarks/http/build-service.mjs" "$work/artifact" "$work/program.s" solo5-arm64-spt
fi
docker run -e IMPL="$impl" --rm --network none --platform linux/arm64 --user "$(id -u):$(id -g)" \
    -v "$root:/src:ro" -v "$work:/build" -w /build --entrypoint sh \
    "${FENRIR_SOLO5_IMAGE:-fenrir-track1-solo5:38e0c348be23-arm64}" -ec '
    export PATH=/opt/solo5-install/bin:$PATH
    echo "{\"type\":\"solo5.manifest\",\"version\":1,\"devices\":[{\"name\":\"input\",\"type\":\"NET_BASIC\"},{\"name\":\"output\",\"type\":\"NET_BASIC\"}]}" > manifest.json
    solo5-elftool gen-manifest manifest.json manifest.c
    set -- /src/benchmarks/http/reference.c
    if [ "$IMPL" = fenrir ]; then
        set -- program.s /src/runtime/native/heap.c /src/runtime/native/managed.c
    fi
    for source in manifest.c /src/benchmarks/http/guest-spt.c "$@"; do
        aarch64-solo5-none-static-cc -O2 -Wall -Wextra -Werror -I/src/runtime/native -c "$source"
    done
    aarch64-solo5-none-static-ld -z solo5-abi=spt ./*.o -o http.spt'
clang -arch arm64 -O2 -Wall -Wextra -Werror -I"$root/runtime/native" \
    "$root/benchmarks/http/server.c" "$root/benchmarks/http/guest-client.c" -o "$out/ingress"
cp "$work/http.spt" "$out/http.spt"
