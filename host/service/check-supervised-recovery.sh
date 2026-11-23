#!/bin/sh
# From the Apple Silicon host, build and check one bounded SPT service history.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
worker=${1:-fenrir}
workload=${2:-recovery}
case "$workload" in recovery|timeout-after-commit|rollback|backlog|wide-backlog|fresh-commits|paced-commits) ;; *) exit 2 ;; esac
case "$worker" in fenrir|fenrir-native-spt|c-native-spt|erlang|elixir|rust|nim) ;; *) exit 2 ;; esac
mkdir -p build/host/service
out=$(mktemp -d build/host/service/supervised-XXXXXXXX)
echo "Recovery evidence: $root/$out" >&2
if [ "$worker" = elixir ]; then
    pkg="$out/elixir.zip"
    curl -fsSL --max-time 60 https://builds.hex.pm/builds/elixir/v1.19.5-otp-28.zip -o "$pkg"
    echo "ca481510feb6dabc875bba43e44b25c7abafa53bd7a103639851b7aeace8a022  $pkg" | shasum -a 256 -c -
    unzip -q "$pkg" -d "$out/elixir"
fi
sh frontend/fenrir.sh emit examples/service/accepted-job.fen "$out/accepted-job.json"
cmp "$out/accepted-job.json" host/service/artifacts/accepted-job.json
if [ "$worker" = fenrir-native-spt ] || [ "$worker" = c-native-spt ]; then
    handler=fenrir
    if [ "$worker" = c-native-spt ]; then handler=c; fi
    sh benchmarks/durable/native/build-spt.sh "$out/native.spt" "$handler"
    shasum -a 256 "$out/native.spt" "$out/accepted-job.json" > "$out/native.sha256"
fi
if [ -n "${FENRIR_RECOVERY_IMAGE:-}" ]; then
    docker image inspect --format '{{.Id}}' "$FENRIR_RECOVERY_IMAGE" > "$out/container.id"
else
    # BuildKit parses a bare sha256 ID in FROM as a repository and tag.
    # Give the selected local image a build-stage name derived from its identity.
    base_image=${FENRIR_SOLO5_IMAGE:-fenrir-track1-solo5:38e0c348be23-arm64}
    case "$base_image" in
        sha256:*)
            base_id=$(docker image inspect --format '{{.Id}}' "$base_image")
            base_image=fenrir-solo5-input:${base_id#sha256:}
            docker image tag "$base_id" "$base_image"
            ;;
    esac
    reference_tools=none
    case "$worker" in rust|nim) reference_tools=$worker ;; esac
    docker build --platform linux/arm64 --iidfile "$out/container.id" \
        --build-arg "REFERENCE_TOOLS=$reference_tools" \
        --build-arg "SOLO5_IMAGE=$base_image" \
        - < host/service/Dockerfile.recovery
fi
set --
if [ "$workload" = paced-commits ]; then set -- --cpuset-cpus=0; fi
docker run --rm --platform linux/arm64 --network none "$@" --user "$(id -u):$(id -g)" \
    -v "$root:/src" -w /src -e FENRIR_PROFILE_VFS -e FENRIR_COMMIT_RATE -e FENRIR_COMMIT_SECONDS -e WORKLOAD="$workload" -e WORKER="$worker" -e OUT="/src/$out" --entrypoint sh "$(cat "$out/container.id")" -ec '
    mkdir "$OUT/ebin"
    node host/service/tools/build-image.mjs "$OUT/accepted-job.json" "$OUT/guest" 2 2 2 2
    erlc -Wall -Werror -o "$OUT/ebin" host/service/src/*.erl benchmarks/durable/*.erl
    cc -O2 -Wall -Wextra -Werror host/service/c_src/fenrir_sqlite_port.c -lsqlite3 -o "$OUT/sqlite-port"
    export FENRIR_SQLITE_PORT="$OUT/sqlite-port" ERL_FLAGS="-pa $OUT/ebin"
    if [ "$WORKLOAD" = paced-commits ]; then
        export ERL_FLAGS="$ERL_FLAGS +S 1:1 +SDcpu 1 +SDio 1"
        erl -noshell -eval '\''io:put_chars(json:encode(#{otp => list_to_binary(erlang:system_info(system_version)), schedulers_online => erlang:system_info(schedulers_online), dirty_cpu_schedulers_online => erlang:system_info(dirty_cpu_schedulers_online)})), halt().'\'' > "$OUT/otp.json"
        awk "/^Cpus_allowed_list:/ {print \$2}" /proc/self/status > "$OUT/cpus.txt"
        test "$(cat "$OUT/cpus.txt")" = 0
        (cd "$OUT" && sha256sum ebin/*.beam sqlite-port) > "$OUT/shared.sha256"
    fi
    if [ "$WORKER" = elixir ]; then
        export ERL_LIBS="$OUT/elixir/lib"
        "$OUT/elixir/bin/elixirc" --warnings-as-errors -pa "$OUT/ebin" -o "$OUT/ebin" benchmarks/durable/elixir_reference.ex
    fi
    if [ "$WORKER" = fenrir-native-spt ] || [ "$WORKER" = c-native-spt ]; then
        export FENRIR_NATIVE_SERVICE_IMAGE="$OUT/native.spt"
        export FENRIR_REFERENCE_PORT=/src/benchmarks/durable/native/launch-spt.sh
    fi
    if [ "$WORKER" = rust ]; then
        export FENRIR_REFERENCE_PORT="$OUT/reference"
        rustc --version > "$OUT/reference-compiler.txt"
        rustc --edition=2021 -O -C overflow-checks=yes benchmarks/durable/reference.rs -o "$FENRIR_REFERENCE_PORT"
    fi
    if [ "$WORKER" = nim ]; then
        export FENRIR_REFERENCE_PORT="$OUT/reference"
        nim --version > "$OUT/reference-compiler.txt"
        nim c -d:release --overflowChecks:on --nimcache:"$OUT/nimcache" --out:"$FENRIR_REFERENCE_PORT" benchmarks/durable/reference.nim
    fi
    exec escript host/service/test/supervised-recovery.escript "$OUT/guest/image.json" /src/host/service/priv/spt-launch "$OUT" "$WORKER" "$WORKLOAD"
' > "$out/run.log" 2>&1 || { tail -30 "$out/run.log" >&2; exit 1; }
sh harness/run-service-history.sh "$out/history.json" "$root/$out/check"
python3 - "$out" "$workload" <<'PY'
import json
from pathlib import Path
import sys

out = Path(sys.argv[1]).resolve()
history = json.loads((out / "history.json").read_text())
verdict = json.loads((out / "check/verdicts.jsonl").read_text())
if (verdict["history"] != str(out / "history.json") or verdict["verdict"] != "accepted"
        or verdict["events"] != (history["event_count"] if history["schema"] == "fenrir.service.history/1-chunked"
                                 else len(history["events"]))):
    sys.exit("Recovery history did not pass the model checker")
if sys.argv[2] == "recovery":
    from runpy import run_path
    validate = run_path("benchmarks/durable/compare-recovery.py")["check_recovery_timings"]
    validate(json.loads((out / "timings.json").read_bytes()), history)
PY
case "$workload" in
    fresh-commits|paced-commits)
        count=128
        set --
        if [ "$workload" = paced-commits ]; then
            count=$((FENRIR_COMMIT_SECONDS * FENRIR_COMMIT_RATE))
            set -- --rate "$FENRIR_COMMIT_RATE"
        fi
        python3 benchmarks/durable/assess-paced.py "$out/timings.json" --count "$count" "$@" \
            --verdict "$out/check/verdicts.jsonl" > "$out/commit-check.json"
        python3 benchmarks/durable/check-fresh-store.py "$out/jobs.db" "$count" > "$out/store-check.json"
        ;;
esac
