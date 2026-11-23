"""Identify frontend, code generator and managed runtime sources shared by kernel guests."""
import hashlib
import os
from pathlib import Path


ORIGINAL_PATHS = ["frontend/fenrir.sh", "frontend/main.shen", "frontend/reader.shen",
             "frontend/elaborate.shen", "frontend/validate.mjs", "tools/tc0/pure-call-artifact.mjs",
             "tools/aarch64/managed-image.mjs", "tools/aarch64/byte-scan.mjs",
             "runtime/native/heap.h", "runtime/native/heap.c", "runtime/native/managed.c"]

SHARED_PATHS = ORIGINAL_PATHS + [
    "tools/aarch64/result-printer.mjs", "tools/tc0/canonical.mjs", "runtime/native/task-state.h",
    "harness/jit.sh", "harness/common.shen", "models/tc0/i64.shen",
    "models/tc0/pure-call-machine.shen", "models/tc1/handler-machine.shen",
]


def shared_inputs():
    root = Path(__file__).resolve().parents[1]
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in SHARED_PATHS}


def benchmark_cpu():
    value = os.environ.get("FENRIR_BENCH_CPU", "0")
    if not value.isascii() or not value.isdecimal():
        raise ValueError("FENRIR_BENCH_CPU must identify one nonnegative logical CPU")
    return str(int(value))
