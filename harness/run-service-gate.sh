#!/bin/sh
# Run the proposed service gate (accepted-job contract A1, handler A2). Usage: sh harness/run-service-gate.sh
# Allow about 30 minutes with the optional A3/A4 rows (the A1 exploration, the A2 and A4 refinement checks and the A4 model dominate).
# Exit status: 0 verdict PASS, 1 FAIL, 2 anything else (BLOCKED, UNKNOWN).
# Run by the workflow controller (FENRIR_CHECK_NONCE set), it prints only the
# controller's check record on standard output.
set -eu
. "$(dirname "$0")/jit.sh"
. "$(dirname "$0")/solo5.sh"
out="$root/build/harness/service-gate/$(date +%s)-$$"
mkdir -p "$out"
status=0
"$jit/bin/shen-jit" script "$root/harness/service-gate.shen" "$jit/lib" "$root" "$out" "$jit/bin/shen-jit" \
  ${FENRIR_CHECK_NONCE:+"$FENRIR_CHECK_NONCE" "${FENRIR_CHECK_ID:-}" "${FENRIR_SOURCE_SHA256:-}" "${FENRIR_CONFIG_SHA256:-}"} \
  > "$out/gate.log" 2>&1 < /dev/null || status=$?
if [ -n "${FENRIR_CHECK_NONCE:-}" ]; then
  grep -E '^[a-z0-9-]+: (PASS|FAIL|UNKNOWN|BLOCKED|DEFERRED)$' "$out/gate.log" >&2 || true
  grep '^{"schema":"fenrir.check.v1"' "$out/gate.log" | tail -n 1
else
  # Row lines as they were evaluated, then where the report is.
  grep -E '^[a-z0-9-]+: (PASS|FAIL|UNKNOWN|BLOCKED|DEFERRED)$' "$out/gate.log" || true
  echo "report: $out/gate.json"
fi
exit "$status"
