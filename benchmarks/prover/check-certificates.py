"""Check externally supplied certificates and three mutations per proof."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from fenrir_driver import byte_expression, compiled, literal
from verify import formula, tableau_steps

here = Path(__file__).resolve().parent
proofs = dict(line.split() for line in (here / "certificates-v1.txt").read_text().splitlines())
cases = []
for row in (here / "corpus-v1.txt").read_text().splitlines():
    name, kind, _, *tokens = row.split()
    if kind == "proof":
        goal = literal(formula(iter(tokens)))
        cases.append((goal, proofs.pop(name)))
if proofs:
    raise ValueError("unknown proof names")
# This branching tautology has a witness longer than one source Bytes literal.
long_goal = formula(iter("> > | | c c | a a > > z a & z z > | | c c | a a > > z a & z z".split()))
long_witness = "".join(tableau_steps(long_goal))
assert len(long_witness) == 273
cases.append((literal(long_goal), long_witness))
body = "false"
for i in reversed(range(len(cases))):
    goal, witness = cases[i]
    good, short, extra, corrupt = [byte_expression(t.encode("ascii"))
                                   for t in (witness, witness[:-1], witness+"x", witness[:-1]+"?")]
    tape = f"(if (= mode 0) {good} (if (= mode 1) {short} (if (= mode 2) {extra} {corrupt})))"
    body = f"(if (= row {i}) (verify-proof {goal} {tape}) {body})"
program = (here / "formula.fen").read_text() + (here / "certificate.fen").read_text()
program += f"\n(define main {{I64 --> Bool}} i -> (let row (/ i 4) mode (- i (* row 4)) {body}))\n"
with compiled(here.parents[1], sys.argv[1], program) as command:
    for i in range(4 * len(cases)):
        result = subprocess.check_output([*command, str(i)], text=True, timeout=30)
        if result != ("1\n" if i % 4 == 0 else "0\n"):
            raise ValueError((i, result))
print(f"{len(cases)} certificates accepted, {3 * len(cases)} mutations rejected")
