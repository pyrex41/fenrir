"""Verify unary-rule certificate runs across batching and inline-byte boundaries."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from fenrir_driver import compiled, literal
from verify import formula, tableau_steps

here = Path(__file__).resolve().parent
program = (here / "formula.fen").read_text() + (here / "search.fen").read_text()
branching = formula(iter("> > | | c c | a a > > z a & z z > | | c c | a a > > z a & z z".split()))
program += f"""
(define wrap-neg {{(Tuple I64 Formula) --> Formula}}
  n goal -> (if (= n 0) goal (wrap-neg (- n 1) (Neg (Neg goal)))))
(define main {{I64 --> Answer}}
  input -> (let variant (/ input 4096)
                fuel (- input (* variant 4096))
                pairs (/ variant 2)
                base (if (= variant (* pairs 2)) (Binary 2 (Atom 1) (Atom 1)) {literal(branching)})
                goal (wrap-neg pairs base)
             (search (More false goal Empty) 0 0 fuel)))
"""
target = sys.argv[1]
cases = 0
with compiled(here.parents[1], target, program) as command:
    for kind, base in enumerate(((">", "a", "a"), branching)):
        for pairs in (*range(10), 26, 27, 28, 32, 64):
            goal = base
            for _ in range(pairs):
                goal = ("!", ("!", goal))
            proof = "".join(tableau_steps(goal)).encode()
            for truncated in (0, 1):
                fuel = len(proof) - truncated
                argument = (2 * pairs + kind) * 4096 + fuel
                actual = subprocess.check_output([*command, str(argument)], timeout=30)
                expected = b"Exhausted\n" if truncated else f"(Proof #x{proof.hex()} 0)\n".encode()
                if actual != expected:
                    raise ValueError((kind, pairs, truncated, actual, expected))
                cases += 1
print(target, cases, "exact-fuel and truncated-fuel cases passed")
