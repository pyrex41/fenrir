#!/bin/sh
# Select the standalone backend for the CLI and the directly linked benchmarks.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
case ${FENRIR_NATIVE_BACKEND:-shen} in
    shen) exec sh "$root/harness/emit-arm64.sh" "$1" "$2" "$3" "${4:---application}" ;;
    javascript)
        if [ "$#" = 4 ]; then set -- "$1" "$2" "$3" --standalone "$4"; fi
        exec node "$root/tools/aarch64/native-image.mjs" "$@" ;;
    *) echo "unknown native backend: $FENRIR_NATIVE_BACKEND" >&2; exit 2 ;;
esac
