#!/bin/sh
# The AArch64 lane's whole development check, with every tool from the flake:
#   sh verification/aarch64/check.sh
# 1. node --test tests/aarch64            unit tests of the compilers
# 2. tools/aarch64/check.mjs              profile fenrir-aarch64-checked-unary/1 (as published in PR #8)
# 3. tools/aarch64/check-expr.mjs         profile fenrir-aarch64-checked-expr/1
# 4. tools/aarch64/check-call.mjs         profile fenrir-aarch64-checked-call/1
# 5. harness/run-aarch64-differential.sh  lane semantics against the Shen model
# Any failure, missing tool or timeout fails the whole check. The result is
# development evidence (status development-pass), never a qualification receipt.
# FENRIR_AARCH64_TOOLS and FENRIR_SHEN_JIT override the flake outputs.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
fail() { printf '%s\n' "aarch64 check: $*" >&2; exit 1; }
build_output() {
  if ! command -v nix >/dev/null 2>&1 && [ -x /nix/var/nix/profiles/default/bin/nix ]; then
    PATH="$PATH:/nix/var/nix/profiles/default/bin"
  fi
  command -v nix >/dev/null 2>&1 || fail "Nix is required to resolve .#$1"
  nix build --no-update-lock-file --no-link --print-out-paths ".#$1" ||
    fail "could not build .#$1 for this host; see verification/aarch64/README.md"
}
tools=${FENRIR_AARCH64_TOOLS:-$(build_output aarch64-verification)}
for exe in node rocq rocqchk qemu-aarch64; do
  [ -x "$tools/bin/$exe" ] || fail "missing $tools/bin/$exe"
done
for exe in as ld objcopy; do
  [ -x "$tools/bin/aarch64-unknown-linux-gnu-$exe" ] ||
    [ -x "$tools/bin/aarch64-linux-gnu-$exe" ] ||
    fail "missing AArch64 GNU $exe in $tools/bin (requires an AArch64-prefixed executable name)"
done
PATH="$tools/bin:$PATH"
ROCQPATH="$tools/lib/coq/9.3/user-contrib"
[ -d "$ROCQPATH/Stdlib" ] || fail "missing Rocq standard library in $ROCQPATH"
FENRIR_SHEN_JIT=${FENRIR_SHEN_JIT:-$(build_output shen-jit)}
[ -x "$FENRIR_SHEN_JIT/bin/shen-jit" ] && [ -f "$FENRIR_SHEN_JIT/lib/shen-process.so" ] ||
  fail "expected bin/shen-jit and lib/shen-process.so in $FENRIR_SHEN_JIT"
export PATH ROCQPATH FENRIR_SHEN_JIT
out="$root/build/aarch64/check-$(date +%s)-$$"
mkdir -p "$out"
echo "tools: $tools"
echo "shen-jit: $FENRIR_SHEN_JIT"
node --test tests/aarch64/*.test.mjs > "$out/unit.log" 2>&1 || { cat "$out/unit.log"; exit 1; }
tail -n 8 "$out/unit.log"
node tools/aarch64/check.mjs > "$out/unary.log" 2>&1 || { tail -n 30 "$out/unary.log"; exit 1; }
tail -n 2 "$out/unary.log"
node tools/aarch64/check-expr.mjs "$out/expr" > "$out/expr.log" 2>&1 || { tail -n 30 "$out/expr.log"; exit 1; }
tail -n 2 "$out/expr.log"
node --max-old-space-size=6000 tools/aarch64/check-call.mjs "$out/call" > "$out/call.log" 2>&1 || { tail -n 30 "$out/call.log"; exit 1; }
tail -n 2 "$out/call.log"
sh harness/run-aarch64-differential.sh "$out/differential" > "$out/differential.log" 2>&1 || { cat "$out/differential.log"; exit 1; }
tail -n 1 "$out/differential.log"
unary=$(tail -n 1 "$out/unary.log")
node -e '
const fs=require("fs"),assert=require("node:assert/strict"),[out,tools,unary,diff]=process.argv.slice(1);
const read=p=>JSON.parse(fs.readFileSync(p,"utf8"));
const u=read(unary),e=read(out+"/expr/report.json"),c=read(out+"/call/report.json"),d=read(diff+"report.json");
for(const [name,report] of Object.entries({unary:u,expr:e,call:c,differential:d})) {
  assert.equal(report.status,"development-pass",name+" report did not pass");
}
const summary={schema:"fenrir.aarch64.check/1",status:"development-pass",qualification:"UNKNOWN",tools,
 unary:{profile:u.profile,report:unary,proof_instances:u.proofInstances,native_comparisons:u.nativeCases,rejected_mutants:u.rejectedMutations.length},
 expr:{profile:e.profile,report:out+"/expr/report.json",programs:e.programs,native_comparisons:e.native_comparisons,rejected_mutants:e.rejected_mutants.length},
 call:{profile:c.profile,report:out+"/call/report.json",programs:c.programs,tail_constant_stack_instances:c.tail_constant_stack_instances,native_comparisons:c.native_comparisons,rejected_mutants:c.rejected_mutants.length},
 differential:{report:diff+"report.json",cases:d.cases,status:d.status,negative_control:d.negative_control}};
fs.writeFileSync(out+"/summary.json",JSON.stringify(summary,null,2)+"\n");console.log(JSON.stringify(summary));
' "$out" "$tools" "$unary" "$out/differential/"
echo "PASS: $out/summary.json"
