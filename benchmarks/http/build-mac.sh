#!/bin/sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$1
shift
case "$#" in
    0) ;;
    1) [ "$1" = --profile-lock ] || exit 2; set -- -DFENRIR_HTTP_PROFILE_LOCK ;;
    *) exit 2 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
source_manifest() {
    python3 - "$root" <<'MANIFEST'
import hashlib
import json
from pathlib import Path
from runpy import run_path
import sys

root = Path(sys.argv[1])
inputs = run_path(str(root / "benchmarks/solo5-build-inputs.py"))["shared_inputs"]()
for name in ("benchmarks/http/service.fen", "benchmarks/http/router.fen",
             "benchmarks/http/build-mac.sh", "benchmarks/http/build-service.mjs",
             "benchmarks/http/server.c", "runtime/native/task-state.h",
             "tools/tc0/canonical.mjs", "harness/jit.sh"):
    inputs[name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
print(json.dumps(inputs, sort_keys=True))
MANIFEST
}
source_manifest > "$work/before.json"
(cd "$root/benchmarks/http" && FENRIR_NATIVE_BUILD=1 sh "$root/frontend/fenrir.sh" emit service.fen "$work/artifact")
node "$root/benchmarks/http/build-service.mjs" "$work/artifact" "$work/program.s"
clang "$@" -O2 -Wall -Wextra -Werror -arch arm64 -I"$root/runtime/native" "$work/program.s" \
    "$root/benchmarks/http/server.c" "$root/runtime/native/heap.c" "$root/runtime/native/managed.c" -o "$out"
source_manifest > "$work/after.json"
cmp "$work/before.json" "$work/after.json" || { echo 'HTTP service sources changed during build' >&2; exit 1; }
python3 - "$work" "$out" "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

work, out = map(Path, sys.argv[1:3])


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


record = dict(binary_sha256=digest(out), artifact_sha256=digest(work / "artifact"),
              assembly_sha256=digest(work / "program.s"),
              inputs=json.loads((work / "before.json").read_text()),
              clang=subprocess.check_output(["clang", "--version"], text=True).strip(),
              node=subprocess.check_output(["node", "--version"], text=True).strip())
if "-DFENRIR_HTTP_PROFILE_LOCK" in sys.argv[3:]:
    record["profile_lock"] = True
out.with_name(out.name + ".build.json").write_text(json.dumps(record, indent=2) + "\n")
PY
