"""Identify frontend, code generator and managed runtime sources shared by kernel guests."""
import hashlib
import os
from pathlib import Path


ORIGINAL_PATHS = ["frontend/fenrir.sh", "frontend/main.shen", "frontend/reader.shen",
             "frontend/elaborate.shen", "frontend/validate.mjs", "tools/tc0/pure-call-artifact.mjs",
             "tools/aarch64/managed-image.mjs", "tools/aarch64/byte-scan.mjs",
             "runtime/native/heap.h", "runtime/native/heap.c", "runtime/native/managed.c"]

PRE_PROFILE_PATHS = ORIGINAL_PATHS + [
    "tools/aarch64/result-printer.mjs", "tools/tc0/canonical.mjs", "runtime/native/task-state.h",
    "harness/jit.sh", "harness/common.shen", "models/tc0/i64.shen",
    "models/tc0/pure-call-machine.shen", "models/tc1/handler-machine.shen",
]

PROFILE_PATHS = ["spec/native/standalone-v1.json", "tools/tc1/native-profile.mjs", "tools/aarch64/native-profile.mjs"]
SHARED_PATHS = PRE_PROFILE_PATHS + PROFILE_PATHS


JS_APPLICATION_PATHS = SHARED_PATHS + ["tools/aarch64/application-image.mjs", "tools/aarch64/native-image.sh"]
SHEN_PATHS = [p for p in SHARED_PATHS if p not in {
    "tools/aarch64/managed-image.mjs", "tools/aarch64/byte-scan.mjs", "tools/aarch64/result-printer.mjs"
}] + ["tools/aarch64/native-image.sh", "tools/aarch64/application-image.mjs", "tools/aarch64/shen-profile.mjs", "harness/emit-arm64.sh",
      "backends/arm64/emit.shen", "backends/arm64/scalar.shen", "backends/arm64/managed.shen",
      "backends/arm64/printer.shen", "backends/arm64/handler-context.shen",
      "backends/arm64/handlers.shen", "backends/arm64/tasks.shen", "backends/arm64/arguments.shen", "backends/arm64/constants.shen", "backends/arm64/byte-scan.shen"]


def shared_inputs():
    root = Path(__file__).resolve().parents[1]
    paths = {"javascript": JS_APPLICATION_PATHS, "shen": SHEN_PATHS}[os.getenv("FENRIR_NATIVE_BACKEND", "shen")]
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in paths}


def benchmark_cpu():
    value = os.environ.get("FENRIR_BENCH_CPU", "0")
    if not value.isascii() or not value.isdecimal():
        raise ValueError("FENRIR_BENCH_CPU must identify one nonnegative logical CPU")
    return str(int(value))
