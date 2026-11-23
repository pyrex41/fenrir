#!/bin/sh
# Exercise all four applications from one editable copy of an installed release.
set -eu
[ "$#" = 2 ] || { echo 'usage: check-package-apps.sh PACKAGE NEW_DIRECTORY' >&2; exit 2; }
package=$(cd "$1" && pwd -P)
tc="$package/bin/fenrir-toolchain"
mkdir "$2"
out=$(cd "$2" && pwd -P)
cp -R "$package/libexec/fenrir" "$out/src"
chmod -R u+w "$out/src"
cd "$out/src"
"$tc" sh harness/run-service-explore.sh replay-retained > "$out/service-counterexamples.log"
for target in macos-arm64 solo5-arm64-spt; do
    for fixture in persistent-counts persistent-decoder shared-counts-child chunk-snapshots; do
        "$package/bin/fenrir" run --target "$target" "benchmarks/framed-log/$fixture.fen" 41 > "$out/$fixture-$target.log"
        printf '%s\n' '(tuple true true true)' | cmp - "$out/$fixture-$target.log"
    done
    "$tc" python3 benchmarks/prover/run-fenrir.py "$target" > "$out/search-$target.log"
    query=$("$tc" python3 benchmarks/prover/run-fenrir.py "$target" --formula '> z z' --budget 3)
    [ "$query" = 'goal proof 3 ssx' ]
    certificate=$("$tc" python3 benchmarks/prover/run-fenrir.py "$target" --formula '> z z' --certificate ssx)
    [ "$certificate" = valid ]
    "$tc" python3 benchmarks/prover/check-prefixes.py "$target" > "$out/prefix-$target.log"
    "$tc" python3 benchmarks/prover/check-certificates.py "$target" > "$out/check-$target.log"
done
cmp "$out/search-macos-arm64.log" "$out/search-solo5-arm64-spt.log"
for target in mac spt; do
    "$tc" sh "benchmarks/framed-log/build-$target.sh" "$out/stream-$target"
    "$tc" sh "benchmarks/http/build-$target.sh" "$out/http-$target"
done
"$tc" python3 benchmarks/framed-log/check.py "$out/stream-mac"
"$tc" python3 benchmarks/framed-log/check-spt.py "$out/stream-spt"
"$tc" python3 - "$out" <<'PY'
import runpy
import sys
from pathlib import Path

out = Path(sys.argv[1])
wire = runpy.run_path("benchmarks/http/check-service.py")
for server in ([out / "http-mac", "0"], [sys.executable, "benchmarks/http/run-spt.py", out / "http-spt", "0"]):
    with wire["server"](server) as address:
        wire["check"](address)
    print(server[-2], "passed HTTP wire and concurrency checks")
PY
# Rename one public route in the writable Fenrir source and rebuild both services.
"$tc" python3 - <<'PY'
from pathlib import Path
router = Path("benchmarks/http/router.fen")
source = router.read_text()
if source.count('"/status"') != 1:
    raise ValueError("expected one /status route in released router")
router.write_text(source.replace('"/status"', '"/health"'))
PY
for target in mac spt; do
    "$tc" sh "benchmarks/http/build-$target.sh" "$out/http-edited-$target"
done
"$tc" python3 - "$out" <<'PY'
from pathlib import Path
import runpy
import sys
out = Path(sys.argv[1])
wire = runpy.run_path("benchmarks/http/check-service.py")
for command in ([out / "http-edited-mac", "0"],
                [sys.executable, "benchmarks/http/run-spt.py", out / "http-edited-spt", "0"]):
    with wire["server"](command) as address:
        for route, expected in [
            (b"/health", wire["response"](b"200 OK", b'{"ok":true}\n', kind=b"application/json")),
            (b"/status", wire["response"](b"404 Not Found")),
        ]:
            wire["verify"](address, [wire["request"](route)], expected)
PY
"$tc" sh host/service/check-supervised-recovery.sh fenrir-native-spt > "$out/recovery-spt.log" 2>&1
prior=$(sed -n 's/^Recovery evidence: //p' "$out/recovery-spt.log")
"$tc" sh benchmarks/durable/native/check-mac-recovery.sh "$prior" > "$out/recovery-mac.log" 2>&1
tail -1 "$out/recovery-mac.log"
"$tc" python3 - "$package" "$out" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

package, out = map(Path, sys.argv[1:])
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

from runpy import run_path
recovery = run_path("benchmarks/durable/compare-recovery.py")

receipts = {}
for target in ("mac", "spt"):
    lines = (out / f"recovery-{target}.log").read_text().splitlines()
    case, = [Path(line.removeprefix("Recovery evidence: ")) for line in lines if line.startswith("Recovery evidence: ")]
    verdict = json.loads((case / "check/verdicts.jsonl").read_text())
    history_path = (case / "history.json").resolve()
    recovery["require_accepted_history"](verdict, history_path, recovery["history_summary"](history_path))
    timings = json.loads((case / "timings.json").read_bytes())
    recovery["check_recovery_timings"](timings, json.loads((case / "history.json").read_bytes()))
    receipts[target] = dict(history_sha256=sha(case / "history.json"), verdict=verdict,
                            timings_sha256=sha(case / "timings.json"), timings=timings)
artifacts = ["src/benchmarks/http/router.fen", "http-edited-mac", "http-edited-spt/http.spt",
             "http-edited-spt/ingress", "http-edited-mac.build.json", "http-mac.build.json",
             "service-counterexamples.log", "stream-mac", "stream-spt", "http-mac", "http-spt/ingress", "http-spt/http.spt",
             "persistent-counts-macos-arm64.log", "persistent-counts-solo5-arm64-spt.log",
             "persistent-decoder-macos-arm64.log", "persistent-decoder-solo5-arm64-spt.log",
             "chunk-snapshots-macos-arm64.log", "chunk-snapshots-solo5-arm64-spt.log",
             "shared-counts-child-macos-arm64.log", "shared-counts-child-solo5-arm64-spt.log",
             "search-macos-arm64.log", "search-solo5-arm64-spt.log",
             "check-macos-arm64.log", "check-solo5-arm64-spt.log",
             "prefix-macos-arm64.log", "prefix-solo5-arm64-spt.log"]
report = dict(package=str(package), files={name: sha(out / name) for name in artifacts}, recovery=receipts)
(out / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
PY
