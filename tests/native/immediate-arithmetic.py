"""Exercise native immediate arithmetic at signed and encoding boundaries."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(root / "benchmarks/prover"))
from fenrir_driver import compiled

low, high = -(2**63), 2**63 - 1
cases = []
for divisor in (1, 2, 8, 2**62, 3):
    for n in (low, low + 1, -9, -1, 0, 9, high):
        expected = abs(n) // divisor * (-1 if n < 0 else 1)
        cases.append((f"(/ {n} {divisor})", str(expected)))
for factor in (1, 8, 256, 2**62):
    for n in sorted({max(low, low // factor - 1), low // factor, high // factor,
                     min(high, high // factor + 1)}):
        expected = str(n * factor) if low <= n * factor <= high else "trap: Overflow"
        for operands in (f"{factor} {n}", f"{n} {factor}"):
            cases.append((f"(* {operands})", expected))
for k in (0, 1, 4095, 4096):
    for n in (low, high):
        for op, value in [("+", n + k), ("-", n - k)]:
            cases.append((f"({op} {n} {k})", str(value) if low <= value <= high else "trap: Overflow"))
    for op, pred in [("<", int.__lt__), ("<=", int.__le__), (">", int.__gt__), (">=", int.__ge__), ("=", int.__eq__)]:
        for n in (k - 1, k, k + 1):
            cases.append((f"(if ({op} {n} {k}) 1 0)", str(int(pred(n, k)))))
for divisor in (1, 2, 8, 2**62):
    for n in (low, low + 1, -9, -1, 0, 1, 9, high):
        expected = abs(n) % divisor * (-1 if n < 0 else 1)
        for product in (f"(* {divisor} (/ x {divisor}))", f"(* (/ x {divisor}) {divisor})"):
            cases.append((f"(let x {n} (- x {product}))", str(expected)))
            cases.append((f"(let x {n} {product})", str(n - expected)))
# Similar arithmetic with different bindings or constants retains its own behavior.
cases.extend([("(let x 10 y 8 (- x (* 2 (/ y 2))))", "2"),
              ("(let x 10 (- x (* 4 (/ x 2))))", "-10")])
# Chunk the cases to stay within the validated program's node limit.
target = sys.argv[1]
for start in range(0, len(cases), 12):
    group = cases[start:start + 12]
    body = "0"
    for i in reversed(range(len(group))):
        body = f"(if (= n {i}) {group[i][0]} {body})"
    source = "(datatype Box (B I64))\n(define main {I64 --> I64} n -> " + body + ")"
    with compiled(root, target, source) as command:
        for i, (_, expected) in enumerate(group):
            run = subprocess.run([*command, str(i)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, timeout=30)
            lines = run.stdout.splitlines()
            if not lines or lines[0] != expected or run.returncode != int(expected.startswith("trap:")):
                raise ValueError((group[i], run.returncode, lines))
print(target, len(cases), "immediate arithmetic checks passed")
