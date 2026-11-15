#!/bin/sh
# The first universal-claim test of 04_DIRECTION_AMENDMENT.md §3: checked `add`
# of models/tc0 through Búri's contract checker. Reruns everything that runs:
#   sh verification/universal/check.sh
# 1. Extract the KLambda of the model's `add` closure with the pinned Shen/JIT
#    and compare it with the committed extracted.kl.
# 2. Run Búri's own checker suite (tests/contracts.shen) at the pinned commit.
# 3. Run certify.shen through Búri's Shen checker on Búri's pinned host
#    (Shen-Scheme v0.52): 16 expected verdicts, including the negative controls.
# 4. Run the same certificates through Búri's Rocq checker ContractCert.check
#    (Coq 8.18.0, Búri's pin for this lane) by compiling the generated FenrirCert.v.
# 5. Show that Búri's Shen checker does not run on Shen/JIT 0.7 (62-bit fixnums).
# 6. A separate, weaker bounded check of `add` (bounded-add.mjs).
# Búri is fetched by git at the pinned commit and its tools are built by nix from
# its own flake at that commit; nothing depends on a local Búri checkout.
# The outcome is recorded in README.md: no model property is proved here.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
if ! command -v nix >/dev/null 2>&1 && [ -x /nix/var/nix/profiles/default/bin/nix ]; then
  PATH="$PATH:/nix/var/nix/profiles/default/bin"
fi
BURI_URL=https://github.com/pyrex41/buri
BURI_REV=47491e21b0747f6d62623aa9fc445c229838aa8c
work="$root/build/universal"
buri="$work/buri-$BURI_REV"
mkdir -p "$work"

FENRIR_SHEN_JIT=${FENRIR_SHEN_JIT:-$(cd "$root" && nix build --no-link --print-out-paths .#shen-jit)}
jit="$FENRIR_SHEN_JIT/bin/shen-jit"
tools=${BURI_TOOLS:-$(nix build --no-link --print-out-paths "git+$BURI_URL?rev=$BURI_REV#dotTools")}
echo "shen-jit: $FENRIR_SHEN_JIT"
echo "buri: $BURI_URL $BURI_REV, tools $tools"

if [ ! -d "$buri/.git" ] || [ "$(git -C "$buri" rev-parse HEAD)" != "$BURI_REV" ]; then
  rm -rf "$buri"
  git init -q "$buri"
  git -C "$buri" fetch -q --depth 1 "$BURI_URL" "$BURI_REV"
  git -C "$buri" checkout -q FETCH_HEAD
fi
[ "$(git -C "$buri" rev-parse HEAD)" = "$BURI_REV" ] || { echo "FAIL: Búri checkout is not at $BURI_REV" >&2; exit 1; }
ln -sfn "$tools" "$buri/.tools"

# 1. Extraction.
cd "$root"
timeout 300 "$jit" script verification/universal/extract-run.shen > "$work/extract.log" 2>&1 \
  || { tail -n 20 "$work/extract.log"; exit 1; }
grep '^fu-' "$work/extract.log" > "$work/extracted.kl"
diff -u verification/universal/extracted.kl "$work/extracted.kl" \
  || { echo 'FAIL: the model compiles to different KLambda than extracted.kl records' >&2; exit 1; }
echo "1. extracted.kl reproduced ($(grep -c '^fu-def' "$work/extracted.kl") definitions over the add, arithmetic and step closures)"

# 2. Búri's own suite for its Shen checker.
(cd "$buri" && timeout 300 scripts/check-shen tests/contracts.shen) > "$work/buri-contracts.log" 2>&1 \
  || { cat "$work/buri-contracts.log"; exit 1; }
grep -qx 'BURI_SUITE_OK contracts 19' "$work/buri-contracts.log" || { cat "$work/buri-contracts.log"; exit 1; }
echo "2. $(tail -n 1 "$work/buri-contracts.log")"

# 3. Certificates through the Shen checker.
(cd "$buri" && timeout 900 scripts/shen -l shen/base.shen -l shen/contract-cert.shen \
   -e "(set fu.extracted \"$work/extracted.kl\")" -e "(set fu.rocq-out \"$work/FenrirCert.v\")" \
   -e "(set fu.cert-out \"$work/fragment.cert\")" \
   -l "$here/certify.shen") > "$work/certify.log" 2>&1 || true
grep '^FU-' "$work/certify.log" | cut -c1-220
grep -qx 'FU-CERT-OK 16' "$work/certify.log" || { echo 'FAIL: certify.shen verdicts differ from the expected ones' >&2; exit 1; }
diff -u "$here/FenrirCert.v" "$work/FenrirCert.v" || { echo 'FAIL: FenrirCert.v is stale' >&2; exit 1; }
diff -u "$here/fragment.cert" "$work/fragment.cert" || { echo 'FAIL: fragment.cert is stale' >&2; exit 1; }
echo "3. Shen checker: all 16 expected verdicts"

# 4. The same certificates through the Rocq checker.
(cd "$buri/rocq" && for m in Observation KLSyntax KLValue KLSemantics ContractCert KLMetatheory ContractLogic ContractPrims; do
   ../scripts/rocq coqc -Q . Buri "$m.v" || exit 1; done) > "$work/rocq-buri.log" 2>&1 \
  || { tail -n 30 "$work/rocq-buri.log"; exit 1; }
coqc() { "$buri/scripts/rocq" coqc -Q "$buri/rocq" Buri -Q . Fenrir "$@"; }
cd "$work"
coqc FenrirCert.v > "$work/rocq-fenrir.log" 2>&1 || { tail -n 30 "$work/rocq-fenrir.log"; exit 1; }
echo "4. Rocq checker (coqc $("$buri/scripts/rocq" coqc --version | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -n 1)): all $(grep -c '^Example' FenrirCert.v) examples in FenrirCert.v hold"

# 4b. Separate result: two helper lemmas derived in Búri's calculus (HelperLemmas.v),
#     their assumptions, and three false variants that Rocq must reject.
cp "$here/HelperLemmas.v" "$work/HelperLemmas.v"
coqc HelperLemmas.v > "$work/rocq-lemmas.log" 2>&1 || { tail -n 30 "$work/rocq-lemmas.log"; exit 1; }
printf 'From Fenrir Require Import HelperLemmas.\nPrint Assumptions HelperLemmas.digit_correct.\nPrint Assumptions HelperLemmas.checked_correct.\n' > "$work/Assumptions.v"
coqc Assumptions.v > "$work/assumptions.log" 2>&1 || { cat "$work/assumptions.log"; exit 1; }
[ "$(grep -c '^Closed under the global context$' "$work/assumptions.log")" = 2 ] || { cat "$work/assumptions.log"; exit 1; }
mutant() { # name, sed expression: the mutated file must NOT compile
  mkdir -p "$work/mutant-$1"
  cp "$work/FenrirCert.v" "$work/FenrirCert.vo" "$work/mutant-$1/"
  sed "$2" "$here/HelperLemmas.v" > "$work/mutant-$1/HelperLemmas.v"
  cmp -s "$here/HelperLemmas.v" "$work/mutant-$1/HelperLemmas.v" && { echo "FAIL: mutant $1 changed nothing" >&2; exit 1; }
  if (cd "$work/mutant-$1" && coqc HelperLemmas.v) > "$work/mutant-$1/log" 2>&1; then
    echo "FAIL: false variant $1 was accepted by Rocq" >&2; exit 1; fi
}
mutant digit-range-8 's/(0 <= d <= 9)%Z/(0 <= d <= 8)%Z/'
mutant digit-domain-58 's/(48 <= c <= 57)%N/(48 <= c <= 58)%N/'
mutant checked-swapped 's/if fitsb V then VCons (VSym okn)/if negb (fitsb V) then VCons (VSym okn)/'
cd "$root"
echo "4b. HelperLemmas.v: digit_correct and checked_correct closed under the global context; 3 false variants rejected"

# 5. Búri's Shen checker on Shen/JIT.
cat > "$work/jit-checker.shen" <<EOF
(load "$buri/shen/base.shen")
(load "$buri/shen/contract-cert.shen")
(output "FU-JIT-THEORY ~S~%" (trap-error (buri.cc-theory) (/. E (error-to-string E))))
EOF
timeout 120 "$jit" script "$work/jit-checker.shen" > "$work/jit-checker.log" 2>&1 || true
grep -q '^FU-JIT-THEORY "integer overflow"' "$work/jit-checker.log" \
  || { cat "$work/jit-checker.log"; echo 'FAIL: expected the fingerprint to overflow on Shen/JIT' >&2; exit 1; }
echo '5. Búri Shen checker on Shen/JIT 0.7: fingerprint raises "integer overflow" (as recorded)'

# 6. Separate, weaker: bounded exploration of `add`.
node "$here/bounded-add.mjs" "$jit" > "$work/bounded-add.json" || { cat "$work/bounded-add.json"; exit 1; }
echo "6. bounded add: $(node -e 'const r=require(process.argv[1]);console.log(r.status, r.cases+" cases", r.ok+" ok", r.overflow+" overflow")' "$work/bounded-add.json")"

echo 'universal: checks reproduced; status of the TC0-A add property: OPEN (README.md)'
