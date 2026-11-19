#!/bin/sh
# Bounded A4 worker integration and crash campaign; not a qualification run.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
: "${FENRIR_A3_TOOLS:?explicit Linux tool prefix required}"
: "${FENRIR_SHEN_JIT:?explicit Shen/JIT prefix required}"
: "${FENRIR_SOLO5:?explicit Solo5 prefix required}"
tools=$FENRIR_A3_TOOLS
export PATH="$tools/bin:$PATH"
out="$repo/build/host/service/a4-workers-$(date +%s)-$$"
mkdir -p "$out/ebin" "$out/launch"
chmod 700 "$out/launch"
cd "$repo"
gcc -std=c11 -O2 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L \
    -I"$tools/include" "$here/c_src/fenrir_sqlite_port.c" -L"$tools/lib" \
    -Wl,-rpath,"$tools/lib" -lsqlite3 -o "$out/fenrir_sqlite_port"
erlc -Wall -Werror -o "$out/ebin" "$here"/src/*.erl \
    "$here"/test/fenrir_a4_workers.erl "$here"/test/fenrir_a4_campaign.erl "$here"/test/fenrir_drive.erl
export FENRIR_SQLITE_PORT="$out/fenrir_sqlite_port"
for artifact in accepted-job accepted-job-v2 migrate-v1-v2; do
    sh frontend/fenrir.sh emit "examples/service/$artifact.fen" "$out/$artifact.json" >&2
done
v1=$(node "$here/tools/build-image.mjs" "$out/accepted-job.json" "$out/v1" 2 3 2 4)
v2=$(node "$here/tools/build-image.mjs" "$out/accepted-job-v2.json" "$out/v2" 2 3 2 4 --v2)
migration=$(node "$here/tools/build-image.mjs" "$out/migrate-v1-v2.json" "$out/migration" --migration)
echo "output: $out" >&2
erl -noshell -noinput -pa "$out/ebin" -run fenrir_a4_workers main \
    "$out" "$here/priv/spt-launch" "$v1" "$v2" "$migration" >&2
node "$here/tools/a4-history-controls.mjs" fixtures "$out"
sh harness/run-service-history.sh "$out/history-list.txt" "$out/verifier" >"$out/verdicts.stdout"
node "$here/tools/a4-history-controls.mjs" verify "$out" >"$out/pilot-report.stdout"
export ERL_FLAGS="${ERL_FLAGS:-+S 2:2 +SDcpu 1 +SDio 1}"
erl -noshell -noinput -pa "$out/ebin" -run fenrir_a4_campaign main \
    "$out" "$tools/bin/erl" "$out/ebin" "$here/priv/node-launch" "$here/priv/spt-launch" "$v1" "$v2" "$migration" >&2
node "$here/tools/a4-crash-evidence.mjs" fixtures "$out"
verifier=0
sh harness/run-service-history.sh "$out/crash-list.txt" "$out/crash-verifier" >"$out/crash-verdicts.stdout" || verifier=$?
node "$here/tools/a4-crash-evidence.mjs" verify "$out" "$verifier"
