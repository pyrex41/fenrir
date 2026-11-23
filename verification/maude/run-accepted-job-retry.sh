#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out=${1:-$(mktemp -d build/maude-history-XXXXXXXX)}
if [ -z "${MAUDE:-}" ] && ! command -v maude >/dev/null; then
  exec nix --extra-experimental-features 'nix-command flakes' shell .#maude -c sh verification/maude/run-accepted-job-retry.sh "$out"
fi
mkdir -p "$out"
python3 verification/maude/compare.py "$out"
sh harness/run-service-explore.sh replay verification/maude/retry-after-crash.json
echo "History and witness logs: $out"
