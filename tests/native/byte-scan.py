"""Check every byte action, rope fallback and invalid start of a native scan."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "benchmarks/prover"))
from fenrir_driver import compiled

program = """
(define allowed {(Tuple I64 I64 I64) --> Bool}
  c lo hi -> (if (< c lo) false (<= c hi)))
(define scan {(Tuple Bytes I64) --> I64}
  buf i -> (if (= i (bytes-length buf)) -1
    (let c (bytes-index buf i)
      (if (= c 13) i
        (if (if (= c 9) true (allowed c 32 126))
          (scan buf (+ i 1)) -1)))))
"""
# One native invocation checks all byte classifications, including each side
# of the printable range and the delimiter, against explicit expected values.
body = "0"
for start in range(0, 256, 64):
    tape = bytes(x for byte in range(start, start + 64) for x in (byte, 13))
    codes = bytes(1 if byte == 13 else 2 if byte == 9 or 32 <= byte <= 126 else 0
                  for byte in range(start, start + 64))
    body = f"(+ {body} (count #x{tape.hex()} #x{codes.hex()} 0 0))"
program += """(define count {(Tuple Bytes Bytes I64 I64) --> I64}
  input codes i acc -> (if (= i (bytes-length codes)) acc
    (let pos (* i 2) code (bytes-index codes i)
         expected (if (= code 0) -1 (if (= code 1) pos (+ pos 1)))
      (count input codes (+ i 1) (+ acc (if (= (scan input pos) expected) 1 0))))))"""
cases = [(0, "256"), (1, "2"), (2, "-1"), (-1, "trap: Bounds"), (3, "trap: Bounds")]
extra = "(scan #x41 n)"
for length in (15, 16, 17, 31, 32, 33):
    for last, expected in [(13, length), (127, -1), (9, length + 1)]:
        handle = len(cases) + 5
        cases.append((handle, str(expected)))
        tape = b"A" * length + bytes([last, 13])
        extra = f"(if (= n {handle}) (scan #x{tape.hex()} 0) {extra})"
program += f"""(define main {{I64 --> I64}}
 n -> (if (= n 0) {body}
      (if (= n 1) (scan (bytes-concat #x4109 #x0d) 0)
      (if (= n 2) (scan #x41 1) {extra}))))"""
# The frontend runs main at input zero. A caller with a literal input keeps
# the scan source and its trap positions identical across both executions.
with tempfile.TemporaryDirectory() as tmp, compiled(root, sys.argv[1], program) as command:
    model_source = Path(tmp) / "prover.fen"
    for value, expected in cases:
        proc = subprocess.run([*command, str(value)], capture_output=True, text=True, timeout=30)
        lines = (proc.stdout + proc.stderr).splitlines()
        model_source.write_text(program.replace("(define main ", "(define run-case ") +
                                f"\n(define main {{I64 --> I64}} unused -> (run-case {value}))\n")
        model = subprocess.check_output(["sh", root / "frontend/fenrir.sh", "run", model_source.name],
                                       cwd=tmp, env=dict(os.environ, FENRIR_FUEL="500000", FENRIR_NATIVE_BUILD="1"), text=True, timeout=60)
        observations = [s for s in model.splitlines() if s.startswith(("outcome:", "trap at:"))]
        trap = expected.startswith("trap:")
        if not observations or observations[0] != ("outcome: Trap " + expected[6:] if trap else "outcome: Ok " + expected):
            raise ValueError((value, expected, model))
        if trap and len(observations) != 2:
            raise ValueError(("missing model trap location", value, model))
        if proc.returncode != int(trap) or lines != [expected, *observations[1:]]:
            raise ValueError((value, proc.returncode, lines))
print(sys.argv[1], "256 byte actions, 18 vector boundary cases, rope, end and bounds passed")
