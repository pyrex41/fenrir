#!/bin/sh
set -eu
target=$1
run_dir=$2
input=$3
solo5_image=${FENRIR_SOLO5_IMAGE:-fenrir-track1-solo5:38e0c348be23-arm64}
case "$target" in
    macos-arm64) "$run_dir/image" "$input" ;;
    solo5-arm64-spt)
        if [ "$(uname -sm)" = 'Linux aarch64' ]; then
            "${FENRIR_SOLO5:+$FENRIR_SOLO5/bin/}solo5-spt" "$run_dir/image" --solo5:quiet "$input"
        else
            docker run --rm --platform linux/arm64 --network none \
              --user "$(id -u):$(id -g)" -v "$run_dir:/guest:ro" \
              --entrypoint /opt/solo5-install/bin/solo5-spt "$solo5_image" \
              /guest/image --solo5:quiet "$input"
        fi ;;
    *) exit 2 ;;
esac
