#!/bin/sh
# What does "proved in Shen" establish? Three loads, with the expected answers.
# Usage: sh verification/shen-proving/check.sh path/to/shen-scheme
set -eu
shen=${1:?path to shen-scheme}
cd "$(dirname "$0")"
# shen-scheme loops on "empty stream" at end of input: bound it in time and size.
out=$(printf '(load "sound-rules.shen")\n(load "false-claim.shen")\n(load "unsound-rule.shen")\n' | timeout 20 "$shen" 2>&1 | head -c 65536 | grep -v 'empty stream' || true)
echo "$out"
echo "$out" | grep -q '(fn anything)'                 || { echo 'FAIL: expected the looping A --> B to typecheck' >&2; exit 1; }
echo "$out" | grep -q '(fn ok1)'                      || { echo 'FAIL: expected 2+1=3 to be derivable' >&2; exit 1; }
echo "$out" | grep -q 'type error in rule 1 of wrong' || { echo 'FAIL: expected 1+1=1 to be rejected under the sound rules' >&2; exit 1; }
echo "$out" | grep -q '(fn wrong2)'                   || { echo 'FAIL: expected 1+1=1 to be accepted after the unsound rule' >&2; exit 1; }
echo 'shen-proving: all four expected behaviours observed'
