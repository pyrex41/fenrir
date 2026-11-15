#!/bin/sh
# The AArch64 lane's whole development check, with every tool from the flake:
#   sh verification/aarch64/check.sh
# 1. node --test tests/aarch64            unit tests of the compilers
# 2. tools/aarch64/check.mjs              profile fenrir-aarch64-checked-unary/1 (as published in PR #8)
# 3. tools/aarch64/check-expr.mjs         profile fenrir-aarch64-checked-expr/1
# 4. harness/run-aarch64-differential.sh  lane semantics against the Shen model
# Any failure, missing tool or timeout fails the whole check. The result is
# development evidence (status development-pass), never a qualification receipt.
# FENRIR_AARCH64_TOOLS and FENRIR_SHEN_JIT override the flake outputs.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
if ! command -v nix >/dev/null 2>&1 && [ -x /nix/var/nix/profiles/default/bin/nix ]; then
  PATH="$PATH:/nix/var/nix/profiles/default/bin"
fi
tools=${FENRIR_AARCH64_TOOLS:-$(cd "$root" && nix build --no-link --print-out-paths .#aarch64-verification)}
PATH="$tools/bin:$PATH"
ROCQPATH="$tools/lib/coq/9.3/user-contrib"
FENRIR_SHEN_JIT=${FENRIR_SHEN_JIT:-$(cd "$root" && nix build --no-link --print-out-paths .#shen-jit)}
export PATH ROCQPATH FENRIR_SHEN_JIT
out="$root/build/aarch64/check-$(date +%s)-$$"
mkdir -p "$out"
cd "$root"
echo "tools: $tools"
echo "shen-jit: $FENRIR_SHEN_JIT"
node --test tests/aarch64/*.test.mjs > "$out/unit.log" 2>&1 || { cat "$out/unit.log"; exit 1; }
tail -n 8 "$out/unit.log"
node tools/aarch64/check.mjs > "$out/unary.log" 2>&1 || { tail -n 30 "$out/unary.log"; exit 1; }
tail -n 2 "$out/unary.log"
node tools/aarch64/check-expr.mjs "$out/expr" > "$out/expr.log" 2>&1 || { tail -n 30 "$out/expr.log"; exit 1; }
tail -n 2 "$out/expr.log"
sh harness/run-aarch64-differential.sh "$out/differential" > "$out/differential.log" 2>&1 || { cat "$out/differential.log"; exit 1; }
tail -n 1 "$out/differential.log"
unary=$(tail -n 1 "$out/unary.log")
node -e '
const fs=require("fs"),[out,tools,unary,diff]=process.argv.slice(1);
const read=p=>JSON.parse(fs.readFileSync(p,"utf8"));
const u=read(unary),e=read(out+"/expr/report.json"),d=read(diff+"report.json");
const summary={schema:"fenrir.aarch64.check/1",status:"development-pass",qualification:"UNKNOWN",tools,
 unary:{profile:u.profile,report:unary,proof_instances:u.proofInstances,native_comparisons:u.nativeCases,rejected_mutants:u.rejectedMutations.length},
 expr:{profile:e.profile,report:out+"/expr/report.json",programs:e.programs,native_comparisons:e.native_comparisons,rejected_mutants:e.rejected_mutants.length},
 differential:{report:diff+"report.json",cases:d.cases,status:d.status,negative_control:d.negative_control}};
fs.writeFileSync(out+"/summary.json",JSON.stringify(summary,null,2)+"\n");console.log(JSON.stringify(summary));
' "$out" "$tools" "$unary" "$out/differential/"
echo "PASS: $out/summary.json"
