#!/bin/sh
# Compare the AArch64 lane's source semantics (Rocq) with the Shen pure-call model
# on the lane's programs over the I64 boundary inputs, in Shen.
# Usage: sh harness/run-aarch64-differential.sh [OUTPUT_DIR]
# Needs Shen/JIT (harness/jit.sh) and Rocq 9.3 with its standard library: taken
# from PATH/ROCQPATH when `rocq` is there, otherwise from the flake's
# aarch64-verification output.
set -eu
. "$(dirname "$0")/jit.sh"
if ! command -v rocq >/dev/null 2>&1; then
  tools=$(cd "$root" && nix build --no-link --print-out-paths .#aarch64-verification)
  PATH="$tools/bin:$PATH"
  export ROCQPATH="${ROCQPATH:-$tools/lib/coq/9.3/user-contrib}"
fi
out="${1:-$root/build/harness/aarch64-differential/$(date +%s)-$$}"
mkdir -p "$out"
status=0
report=$("$jit/bin/shen-jit" script "$root/harness/aarch64-differential.shen" "$jit/lib" "$root" "$out" 2>&1 < /dev/null) || status=$?
printf '%s\n' "$report" | tail -n 1
exit "$status"
