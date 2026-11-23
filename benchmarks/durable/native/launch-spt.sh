#!/bin/sh
set -eu
exec "$FENRIR_SOLO5/bin/solo5-spt" --mem=32 --net:ctlin=@0 --net:ctlout=@2 \
    "$FENRIR_NATIVE_SERVICE_IMAGE" --solo5:quiet 2>&1 1>/dev/null
