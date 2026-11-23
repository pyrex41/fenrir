#!/bin/sh
# Build and compare the implemented CPU references on the frozen corpus.
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
corpus="$dir/corpus-v1.txt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ "$#" -gt 1 ]; then
    echo 'usage: check-references.sh [NEW_EVIDENCE_DIRECTORY]' >&2
    exit 2
fi
evidence=$work
if [ "$#" -eq 1 ]; then
    mkdir "$1"
    evidence=$(cd "$1" && pwd)
fi
rustc -O -C overflow-checks=yes "$dir/reference.rs" -o "$work/rust"
nim c -d:release --overflowChecks:on --nimcache:"$work/cache" \
    --out:"$work/nim" "$dir/reference.nim"
for impl in rust nim; do
    "$work/$impl" "$corpus" > "$evidence/$impl.rows"
    python3 "$dir/verify.py" "$corpus" < "$evidence/$impl.rows"
done
python3 "$dir/run-shen.py" "$corpus" > "$evidence/shen.rows"
python3 "$dir/verify.py" "$corpus" < "$evidence/shen.rows"
python3 "$dir/run-koka.py" "$corpus" > "$evidence/koka.rows"
python3 "$dir/verify.py" "$corpus" < "$evidence/koka.rows"
python3 "$dir/run-koka.py" "$corpus" "$dir/certificates-v1.txt"
python3 "$dir/run-shen.py" "$corpus" "$dir/certificates-v1.txt"
cmp "$evidence/rust.rows" "$evidence/koka.rows"
cmp "$evidence/rust.rows" "$evidence/nim.rows"
cmp "$evidence/rust.rows" "$evidence/shen.rows"
echo 'Rust, Nim, Koka, and Shen/JIT agree on all prover corpus rows.'
