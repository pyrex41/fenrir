#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
case ${2:-fenrir} in
    fenrir) handler=program.s ;;
    c) handler=/src/benchmarks/durable/native/reference.c ;;
    *) exit 2 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
(cd "$root" && sh frontend/fenrir.sh emit examples/service/accepted-job.fen "$work/handler.json")
node "$root/benchmarks/durable/native/build.mjs" "$work/handler.json" "$work" solo5-arm64-spt
docker run --rm --platform linux/arm64 --network none --user "$(id -u):$(id -g)" \
    -e HANDLER="$handler" -v "$root:/src:ro" -v "$work:/work" -w /work --entrypoint sh \
    "${FENRIR_SOLO5_IMAGE:-fenrir-track1-solo5:38e0c348be23-arm64}" -ec '
    export PATH=/opt/solo5-install/bin:$PATH
    echo "{\"type\":\"solo5.manifest\",\"version\":1,\"devices\":[{\"name\":\"ctlin\",\"type\":\"NET_BASIC\"},{\"name\":\"ctlout\",\"type\":\"NET_BASIC\"}]}" > manifest.json
    solo5-elftool gen-manifest manifest.json manifest.c
    for source in manifest.c "$HANDLER" /src/runtime/native/heap.c /src/runtime/native/managed.c \
                  /src/benchmarks/durable/native/port.c /src/benchmarks/durable/native/spt.c; do
        aarch64-solo5-none-static-cc -O2 -Wall -Wextra -Werror -I/work -I/src/runtime/native -c "$source"
    done
    aarch64-solo5-none-static-ld -z solo5-abi=spt ./*.o -o service.spt'
cp "$work/service.spt" "$1"
