#!/bin/sh
# Check the service model in a fresh directory so stale objects cannot pass.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
out="$root/build/service/$(date +%s)-$$"
mkdir -p "$out"
cp "$root/verification/service/AcceptedJob.v" "$out/"
cd "$out"
coqc --version | head -n 1
coqc -Q . FenrirService AcceptedJob.v > assumptions.log
closed=$(grep -c '^Closed under the global context$' assumptions.log || true)
audited=$(grep -c '^Print Assumptions ' AcceptedJob.v)
if [ "$closed" -ne "$audited" ] || grep -q -i 'axiom' assumptions.log; then
  cat assumptions.log
  echo "service model: FAIL (assumption audit: $closed of $audited closed)" >&2
  exit 1
fi
if grep -q -E '\b(Admitted|admit|Axiom|Parameter)\b' AcceptedJob.v; then
  echo "service model: FAIL (admitted or axiomatic content)" >&2
  exit 1
fi
coqchk -silent -Q . FenrirService FenrirService.AcceptedJob > coqchk.log 2>&1 || { cat coqchk.log; exit 1; }
echo "service model: development-pass ($closed of $audited audited theorems closed; coqchk replay ok) in $out"
