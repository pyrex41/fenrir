#!/bin/sh
# Run the PROPOSED Shen gate evaluator. It is not the registered gate and always
# reports qualification UNKNOWN. Usage: sh harness/run-gate.sh
# Exit status: 0 verdict PASS, 1 FAIL, 2 anything else.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
jit="${FENRIR_SHEN_JIT:-$root/build/toolchain/shen-jit-0.7}"
out="$root/build/harness/gate/$(date +%s)-$$"
mkdir -p "$out"
status=0
"$jit/bin/shen-jit" script "$root/harness/gate.shen" "$jit/lib" "$root" "$out" "$jit/bin/shen-jit" > "$out/gate.log" 2>&1 || status=$?
# Row lines as they were evaluated, then the report.
grep -E '^[a-z0-9-]+: (PASS|FAIL|UNKNOWN|BLOCKED|DEFERRED)$' "$out/gate.log" || true
echo "report: $out/gate.json"
exit "$status"
