#!/bin/sh
# Local adapter/codec checks only. No guest image, model, or gate verdict.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
for tool in "${CC:-cc}" erl erlc; do
    command -v "$tool" >/dev/null || { echo "Missing local tool: $tool" >&2; exit 2; }
done
erl -noshell -noinput -eval 'case erlang:system_info(otp_release) of "28" -> halt(0); _ -> halt(2) end.' ||
    { echo 'Put Erlang/OTP 28 on PATH (the upstream test sources are warning-clean on OTP 28, not OTP 29).' >&2; exit 2; }
out="$root/build/host/service/host-only-$(date +%s)-$$"
ebin="$out/ebin"
mkdir -p "$ebin" "$out/bin"
artifact="$here/artifacts/accepted-job.json"
if command -v sha256sum >/dev/null; then
    actual=$(sha256sum "$artifact")
else
    actual=$(shasum -a 256 "$artifact")
fi
[ "${actual%% *}" = "$(cat "$here/artifacts/accepted-job.sha256")" ] ||
    { echo 'Committed A3 artifact does not match its pin.' >&2; exit 1; }
if [ -n "${SQLITE_PREFIX:-}" ]; then
    set -- "-I$SQLITE_PREFIX/include" "-L$SQLITE_PREFIX/lib" "-Wl,-rpath,$SQLITE_PREFIX/lib"
else
    set --
fi
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L \
    "$@" "$here/c_src/fenrir_sqlite_port.c" -lsqlite3 -o "$out/bin/fenrir_sqlite_port"
erlc -Wall -Werror -o "$ebin" "$here"/src/*.erl "$here"/test/*.erl
cp "$here/src/fenrir_service.app.src" "$ebin/fenrir_service.app"
export FENRIR_SQLITE_PORT="$out/bin/fenrir_sqlite_port"
cat > "$out/config.term" <<EOF
#{out => "$out", root => "$root", artifact => "$artifact"}.
EOF
printf '%s\n' "A3 host-only tests (committed artifact; no guest or history checker): $out/unit.json" >&2
status=0
erl -noshell -noinput -pa "$ebin" -run fenrir_unit main "$out/config.term" host-only > "$out/check.log" 2>&1 || status=$?
if [ "$status" -ne 0 ]; then
    cat "$out/check.log" >&2
else
    tail -n 1 "$out/check.log"
fi
exit "$status"
