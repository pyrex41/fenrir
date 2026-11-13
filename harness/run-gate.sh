#!/bin/sh
# Run the TC0-A gate. Usage: sh harness/run-gate.sh
# Exit status: 0 verdict PASS, 1 FAIL, 2 anything else (BLOCKED, UNKNOWN).
# Run by the workflow controller (FENRIR_CHECK_NONCE set), it prints only the
# controller's check record on standard output.
set -eu
. "$(dirname "$0")/jit.sh"
out="$root/build/harness/gate/$(date +%s)-$$"
mkdir -p "$out"
status=0
"$jit/bin/shen-jit" script "$root/harness/gate.shen" "$jit/lib" "$root" "$out" "$jit/bin/shen-jit" \
  ${FENRIR_CHECK_NONCE:+"$FENRIR_CHECK_NONCE" "${FENRIR_CHECK_ID:-}" "${FENRIR_SOURCE_SHA256:-}" "${FENRIR_CONFIG_SHA256:-}"} \
  > "$out/gate.log" 2>&1 || status=$?
if [ -n "${FENRIR_CHECK_NONCE:-}" ]; then
  grep -E '^[a-z0-9-]+: (PASS|FAIL|UNKNOWN|BLOCKED|DEFERRED)$' "$out/gate.log" >&2 || true
  grep '^{"schema":"fenrir.check.v1"' "$out/gate.log" | tail -n 1
else
  # Row lines as they were evaluated, then where the report is.
  grep -E '^[a-z0-9-]+: (PASS|FAIL|UNKNOWN|BLOCKED|DEFERRED)$' "$out/gate.log" || true
  echo "report: $out/gate.json"
fi
exit "$status"
