#!/bin/sh
# Build from the working sources, including files awaiting their first commit.
set -eu
usage() {
    echo 'usage: package-mac.sh [--out-link NEW_PACKAGE_LINK] [NEW_SOURCE_ARCHIVE.tar.gz]' >&2
    exit 2
}
link=
if [ "${1:-}" = --out-link ]; then
    [ "$#" -ge 2 ] && [ -n "$2" ] || usage
    case "$2" in /*) link=$2 ;; *) link=$PWD/$2 ;; esac
    [ ! -e "$link" ] && [ ! -L "$link" ] || { echo 'package link already exists' >&2; exit 2; }
    shift 2
fi
[ "$#" -le 1 ] || usage
archive=
if [ "$#" = 1 ]; then
    case "$1" in /*) archive=$1 ;; *) archive=$PWD/$1 ;; esac
    [ ! -e "$archive" ] && [ ! -L "$archive" ] || { echo 'source archive already exists' >&2; exit 2; }
fi
root=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(mktemp -d)
temporary=
trap 'rm -rf "$stage"; if [ -n "$temporary" ]; then rm -f "$temporary"; fi' EXIT
cd "$root"
cp -R README.md flake.nix flake.lock bin frontend harness models typing tools runtime package.json benchmarks examples fixtures "$stage/"
mkdir -p "$stage/docs/history" "$stage/docs/design"
cp docs/design/SHEN_NATIVE_BACKEND.md "$stage/docs/design/"
cp docs/NATIVE_GUIDE.md docs/PREVIEW.md docs/WORK_FILE.md "$stage/docs/"
cp docs/history/DEVELOPMENT_HISTORY.md "$stage/docs/history/"
mkdir -p "$stage/verification" "$stage/host" "$stage/backends" "$stage/tests/solo5" "$stage/tests/host" "$stage/tests/frontend"
cp -R spec "$stage/"
cp -R verification/aarch64 verification/developer-preview-review.md "$stage/verification/"
cp -R tests/native "$stage/tests/"
cp -R tests/frontend/roundtrip "$stage/tests/frontend/"
cp -R tests/host/histories "$stage/tests/host/"
cp tests/solo5/durable-hand-cases.mjs "$stage/tests/solo5/"
cp -R backends/solo5 backends/arm64 "$stage/backends/"
cp -R host/service "$stage/host/"
# Python bytecode can contain checkout-specific paths and interpreter timestamps.
# Drop generated caches from the private staging copy before hashing the flake.
find "$stage" -type d -name __pycache__ -prune -exec rm -rf {} +
if [ -n "$link" ]; then
    set -- --out-link "$link"
else
    set -- --no-link
fi
package=$(nix build "$@" --print-out-paths "path:$stage#fenrir")
if [ -n "$archive" ]; then
    temporary=$(mktemp "$(dirname "$archive")/.fenrir-source.XXXXXXXX")
    COPYFILE_DISABLE=1 tar -czf "$temporary" -C "$stage" .
    ln "$temporary" "$archive"
    shasum -a 256 "$archive" >&2
fi
printf '%s\n' "$package"
