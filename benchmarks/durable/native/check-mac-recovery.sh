#!/bin/sh
# Reuse the admitted service descriptor from a Solo5 recovery build. Startup
# validates the original image before the campaign installs the native worker.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
prior=$(cd "$1" && pwd)
worker=${2:-fenrir-native-mac}
workload=${3:-recovery}
case "$workload" in recovery|timeout-after-commit|rollback|backlog|wide-backlog) ;; *) exit 2 ;; esac
case "$worker" in fenrir-native-mac|rust|nim|erlang|elixir) ;; *) exit 2 ;; esac
cd "$root"
out=$(mktemp -d "$root/build/host/service/native-mac-XXXXXXXX")
echo "Recovery evidence: $out" >&2
mkdir "$out/ebin"
docker run --rm --platform linux/arm64 --network none --entrypoint cat "$(cat "$prior/container.id")" \
    /opt/solo5-install/bin/solo5-spt > "$out/tender"
python3 - "$prior/guest/image.json" "$root" "$out" <<'PY'
import json
from pathlib import Path
import sys
src, root, out = map(Path, sys.argv[1:])
desc = json.loads(src.read_bytes())
for key in ("image", "batch_dir"):
    desc[key] = str(root / Path(desc[key]).relative_to("/src"))
desc["tender"] = str(out / "tender")
(out / "image.json").write_text(json.dumps(desc))
PY
case "$worker" in
    fenrir-native-mac) sh benchmarks/durable/native/build-mac.sh "$out/worker" ;;
    rust)
        rustc --version > "$out/reference-compiler.txt"
        rustc --edition=2021 -O -C overflow-checks=yes benchmarks/durable/reference.rs -o "$out/worker" ;;
    nim)
        nim --version > "$out/reference-compiler.txt"
        nim c -d:release --overflowChecks:on --nimcache:"$out/nimcache" --out:"$out/worker" benchmarks/durable/reference.nim ;;
esac
erlc -Wall -o "$out/ebin" host/service/src/*.erl benchmarks/durable/*.erl
case "$worker" in
    erlang) implementation="$out/ebin/fenrir_erlang_reference.beam" ;;
    elixir)
        elixir --version > "$out/reference-compiler.txt"
        elixirc --warnings-as-errors -pa "$out/ebin" -o "$out/ebin" benchmarks/durable/elixir_reference.ex
        implementation="$out/ebin/Elixir.Fenrir.DurableReference.beam"
        elixir_lib=$(elixir -e 'IO.write(Path.dirname(:code.lib_dir(:elixir)))')
        export ERL_LIBS="$elixir_lib${ERL_LIBS:+:$ERL_LIBS}" ;;
    *)
        implementation="$out/worker"
        case "$worker" in
            fenrir-native-mac) python3 benchmarks/durable/native/check.py "$implementation" ;;
            *) python3 benchmarks/durable/check-ports.py "$implementation" ;;
        esac
        export FENRIR_REFERENCE_PORT="$implementation" ;;
esac
cc -O2 -Wall -Wextra -Werror host/service/c_src/fenrir_sqlite_port.c -lsqlite3 -o "$out/sqlite-port"
export ERL_FLAGS="-pa $out/ebin" FENRIR_SQLITE_PORT="$out/sqlite-port"
erl -noshell -eval 'io:put_chars(erlang:system_info(system_version)),halt().' > "$out/otp.txt"
# Bind the shared supervisor, ledger protocol and worker adapter to the same
# receipt as the measured worker. The replay loads every module from ebin.
shasum -a 256 "$out"/ebin/*.beam "$out/sqlite-port" "$prior/accepted-job.json" \
    "$out/image.json" "$out/otp.txt" > "$out/native.sha256"
if [ -f "$out/worker" ]; then
    shasum -a 256 "$out/worker" >> "$out/native.sha256"
fi
escript host/service/test/supervised-recovery.escript "$out/image.json" "$root/host/service/priv/spt-launch" \
    "$out" "$worker" "$workload" > "$out/run.log" 2>&1 || { tail -40 "$out/run.log" >&2; exit 1; }
sh harness/run-service-history.sh "$out/history.json" "$out/check"
python3 benchmarks/durable/compare-recovery.py "$prior" "$out"
