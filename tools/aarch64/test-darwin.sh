#!/bin/sh
# End-to-end test of frontend elaboration, ARM64 lowering, linking and execution.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sh "$root/tools/aarch64/build-darwin.sh" "$root/examples/recursive-sum.fen" "$work/sum"
[ "$("$work/sum" 10)" = 55 ]
[ "$("$work/sum" 0)" = 0 ]
[ "$("$work/sum" 500)" = 125250 ]
status=0
"$work/sum" 9223372036854775807 > "$work/out" 2> "$work/err" || status=$?
[ "$status" = 1 ]
[ ! -s "$work/out" ]
[ "$(head -n 1 "$work/err")" = 'trap: Overflow' ]

# The left operand traps before the nested call in the right operand.
cat > "$work/order.fen" <<'FEN'
(define inc {I64 --> I64}
  x -> (+ x 1))
(define main {I64 --> I64}
  x -> (if (<= x 0)
           (inc (inc x))
           (+ (/ x 0) (inc x))))
FEN
sh "$root/tools/aarch64/build-darwin.sh" "$work/order.fen" "$work/order"
[ "$("$work/order" 0)" = 2 ]
status=0
"$work/order" 9223372036854775807 > "$work/out" 2> "$work/err" || status=$?
[ "$status" = 1 ]
[ "$(head -n 1 "$work/err")" = 'trap: DivZero' ]

sh "$root/tools/aarch64/build-darwin.sh" "$root/examples/tuple-arguments.fen" "$work/pair"
[ "$("$work/pair" 8)" = 5 ]

# Unused tuple components still evaluate, in left-to-right order.
cat > "$work/strict.fen" <<'FEN'
(define first {(Tuple I64 I64 I64) --> I64}
  a b c -> a)
(define main {I64 --> I64}
  x -> (first x (/ x 0) (+ x 1)))
FEN
sh "$root/tools/aarch64/build-darwin.sh" "$work/strict.fen" "$work/strict"
status=0
"$work/strict" 9223372036854775807 > "$work/out" 2> "$work/err" || status=$?
[ "$status" = 1 ]
[ "$(head -n 1 "$work/err")" = 'trap: DivZero' ]

# Build the same emitted tuple program with a deliberately tiny heap.
sh "$root/frontend/fenrir.sh" emit "$root/examples/heap-tuples.fen" "$work/heap.json"
node "$root/tools/aarch64/native-image.mjs" macos-arm64 "$work/heap.json" "$work/heap.s"
for capacity in 2 3; do
    clang -arch arm64 -DFEN_HEAP_SLOTS="$capacity" "$work/heap.s" \
        "$root/tools/aarch64/darwin-main.c" "$root/runtime/native/heap.c" \
        "$root/runtime/native/managed.c" -o "$work/tuple-$capacity"
done
[ "$("$work/tuple-3" 4)" = 11 ]
status=0
"$work/tuple-2" 4 > "$work/out" 2> "$work/err" || status=$?
[ "$status" = 1 ]
[ "$(head -n 1 "$work/err")" = 'trap: HeapExhausted' ]

sh "$root/tools/aarch64/build-darwin.sh" "$root/examples/checked-pair.fen" "$work/checked-pair"
[ "$("$work/checked-pair" 5)" = 25 ]
[ "$("$work/checked-pair" -7)" = -7 ]
for n in -9223372036854775808 3037000500; do
    status=0
    "$work/checked-pair" "$n" > "$work/out" 2> "$work/err" || status=$?
    [ "$status" = 1 ]
    [ "$(head -n 1 "$work/err")" = 'trap: Overflow' ]
done

cat > "$work/equal.fen" <<'FEN'
(define make {I64 --> (Tuple I64 (Tuple Bool I64))}
  x -> (tuple 0 (tuple true x)))
(define main {I64 --> Bool}
  x -> (= (make x) (make 42)))
FEN
sh "$root/tools/aarch64/build-darwin.sh" "$work/equal.fen" "$work/equal"
[ "$("$work/equal" 42)" = 1 ]
[ "$("$work/equal" 41)" = 0 ]

# Exercise the list constructors and both match arms through the scalar CLI.
sed '/^(define main /,$d' "$root/examples/list-sum.fen" > "$work/list.fen"
cat >> "$work/list.fen" <<'FEN'
(define main {I64 --> I64}
  n -> (if (= (range 1 n) (range 1 10))
           (sum (range 1 n))
           (- 0 (sum (range 1 n)))))
FEN
sh "$root/tools/aarch64/build-darwin.sh" "$work/list.fen" "$work/list"
[ "$("$work/list" 0)" = 0 ]
[ "$("$work/list" 9)" = -45 ]
[ "$("$work/list" 10)" = 55 ]

sh "$root/tools/aarch64/build-darwin.sh" "$root/examples/list-sum.fen" "$work/list-result"
[ "$("$work/list-result" 0)" = '(tuple 55 (Cons 1 (Cons 2 (Cons 3 Nil))))' ]

sh "$root/tools/aarch64/build-darwin.sh" "$root/examples/closures.fen" "$work/closures"
[ "$("$work/closures" 0)" = 129 ]

# A returned closure is the only reference to its captured pair while
# allocations in a separate function force collection.
cat > "$work/capture.fen" <<'FEN'
(define make {I64 --> (I64 --> I64)}
  n -> (let pair (tuple n n)
         (lambda (x : I64) (+ x (project pair 1)))))
(define churn-pair {I64 --> (Tuple I64 I64)}
  n -> (tuple n n))
(define churn {I64 --> I64}
  n -> (project (churn-pair n) 0))
(define main {I64 --> I64}
  n -> (let f (make n)
            a (churn 1)
            b (churn 2)
         (f (+ a b))))
FEN
sh "$root/frontend/fenrir.sh" emit "$work/capture.fen" "$work/capture.json"
node "$root/tools/aarch64/native-image.mjs" macos-arm64 "$work/capture.json" "$work/capture.s"
clang -arch arm64 -DFEN_HEAP_SLOTS=3 "$work/capture.s" "$root/tools/aarch64/darwin-main.c" \
    "$root/runtime/native/heap.c" "$root/runtime/native/managed.c" -o "$work/capture"
[ "$("$work/capture" 40)" = 43 ]

cat > "$work/bytes.fen" <<'FEN'
(define main {I64 --> (Tuple Bytes Bool I64)}
  n -> (let b (bytes-concat #x00 #xffff)
         (tuple b (= b #x00ffff) (bytes-index b n))))
FEN
sh "$root/tools/aarch64/build-darwin.sh" "$work/bytes.fen" "$work/bytes"
[ "$("$work/bytes" 0)" = '(tuple #x00ffff true 0)' ]
[ "$("$work/bytes" 2)" = '(tuple #x00ffff true 255)' ]
for n in -1 3; do
    status=0
    "$work/bytes" "$n" > "$work/out" 2> "$work/err" || status=$?
    [ "$status" = 1 ]
    [ "$(head -n 1 "$work/err")" = 'trap: Bounds' ]
done

sh "$root/tools/aarch64/build-darwin.sh" "$root/examples/bytes.fen" "$work/emit-bytes"
status=0
"$work/emit-bytes" 0 > "$work/observations" 2>&1 || status=$?
[ "$status" = 1 ]
printf '%s\n' 'emit "summary": (tuple 6 646 true Bounds)' "trap: Bounds" "trap at: $root/examples/bytes.fen:26:18" > "$work/expected"
cmp "$work/expected" "$work/observations"

# Each iteration allocates a capturing closure and tail-calls through it.
# The named function and lambda alternate on a small native stack.
cat > "$work/tail-apply.fen" <<'FEN'
(define bounce {I64 --> I64}
  n -> (if (<= n 0) 7
           (let step (lambda (k : I64) (bounce (- n k)))
             (step 1))))
(define main {I64 --> I64}
  n -> (bounce n))
FEN
sh "$root/tools/aarch64/build-darwin.sh" "$work/tail-apply.fen" "$work/tail-apply"
[ "$( (ulimit -s 512 && "$work/tail-apply" 1000000) )" = 7 ]

# A trap propagating out of a non-tail callee retains its originating span.
status=0
"$work/checked-pair" -9223372036854775808 > "$work/out" 2> "$work/err" || status=$?
[ "$status" = 1 ]
grep -Fqx "trap at: $root/examples/checked-pair.fen:4:19" "$work/err"

# Each of the sixteen alternatives needs its own chain only while it executes.
python3 "$root/tests/native/wide-match-frame.py" "$work/wide.fen"
sh "$root/tools/aarch64/build-darwin.sh" "$work/wide.fen" "$work/wide"
for n in $(seq 0 15); do
    [ "$("$work/wide" "$n")" = "$((28 + 2 * n))" ]
done

# Matching a fresh constructor must evaluate its unused fields before the arm.
sh "$root/tools/aarch64/build-darwin.sh" "$root/tests/native/immediate-constructor-match.fen" "$work/match-fresh"
[ "$("$work/match-fresh" 1)" = 41 ]
for pair in '0 DivZero' '9223372036854775807 Overflow'; do
    set -- $pair
    status=0
    "$work/match-fresh" "$1" > "$work/out" 2> "$work/err" || status=$?
    [ "$status" = 1 ]
    grep -Fxq "trap: $2" "$work/err"
done

# A projected literal tuple is strict in operands on both sides of the result.
sh "$root/tools/aarch64/build-darwin.sh" "$root/tests/native/immediate-tuple-project.fen" "$work/project-fresh"
[ "$("$work/project-fresh" 1)" = 1 ]
for pair in '0 DivZero' '9223372036854775807 Overflow'; do
    set -- $pair
    status=0
    "$work/project-fresh" "$1" > "$work/out" 2> "$work/err" || status=$?
    [ "$status" = 1 ]
    grep -Fxq "trap: $2" "$work/err"
done

sh "$root/tools/aarch64/build-darwin.sh" "$root/tests/native/local-tuple-projection.fen" "$work/local-pair"
[ "$("$work/local-pair" -7)" = -6 ]
[ "$("$work/local-pair" 5)" = 7 ]

sh "$root/tools/aarch64/build-darwin.sh" "$root/tests/native/recursive-tuple-specialization.fen" "$work/recursive-pair"
[ "$( (ulimit -s 512 && "$work/recursive-pair" 1000000) )" = 2000007 ]

sh "$root/tools/aarch64/build-darwin.sh" "$root/tests/native/fresh-parent-match.fen" "$work/fresh-parent"
[ "$("$work/fresh-parent" 41)" = '(tuple (Cell 41) (tuple (Pair (Cell 41) 1) (Cell 41)))' ]
