"""Exercise checked fallbacks and a near-match to the ARM64 byte reduction."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "benchmarks/prover"))
from fenrir_driver import compiled

program = """
(define fold {(Tuple Bytes I64 I64 I64) --> I64}
  bytes i end acc -> (if (= i end) acc
    (fold bytes (+ i 1) end (+ acc (bytes-index bytes i)))))
(define stride {(Tuple Bytes I64 I64 I64) --> I64}
  bytes i end acc -> (if (= i end) acc
    (stride bytes (+ i 2) end (+ acc (bytes-index bytes i)))))
"""
cases = [
    ("(fold #x12ff03 1 3 -4)", "254"),
    ("(fold (bytes-concat #x01 #x0203) 0 3 0)", "6"),
    ("(fold #x00 0 1 9223372036854775807)", "9223372036854775807"),
    ("(fold #xff 0 2 9223372036854775807)", "trap: Overflow"),
    ("(fold #x01 0 2 0)", "trap: Bounds"),
    ("(fold #x01 -1 0 0)", "trap: Bounds"),
    ("(fold #x01 -1 -1 7)", "7"),
    ("(fold #x01 9223372036854775807 0 0)", "trap: Overflow"),
    (f"(fold #x{'fe' * 18} 1 17 -5)", "4059"),
    (f"(fold #x{'fe' * 18} 1 18 -5)", "4313"),
    (f"(fold (bytes-concat #x{'01' * 32} #x{'02' * 32}) 29 33 8)", "13"),
    ("(fold #x010203 0 3 9223372036854775804)", "trap: Overflow"),
    ("(stride #x01020304 0 4 0)", "4"),
]
body = "0"
for index in reversed(range(len(cases))):
    body = f"(if (= n {index}) {cases[index][0]} {body})"
program += f"(define main {{I64 --> I64}} n -> {body})"
with compiled(root, sys.argv[1], program) as command:
    for index, (_, expected) in enumerate(cases):
        run = subprocess.run([*command, str(index)], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, timeout=30)
        lines = run.stdout.splitlines()
        if run.returncode != int(expected.startswith("trap:")) or not lines or lines[0] != expected:
            raise ValueError((index, expected, run.returncode, lines))
print(sys.argv[1], len(cases), "byte reduction checks passed")
