"""Exercise every single legal-rule substitution and strict prefix of each witness."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from fenrir_driver import byte_expression, compiled, literal
from verify import evaluate, formula, tableau_steps

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("target", choices=("macos-arm64", "solo5-arm64-spt"))
args = parser.parse_args()
proofs = dict(line.split() for line in (here / "certificates-v1.txt").read_text().splitlines())
goals = []
model_goals = []
for line in (here / "corpus-v1.txt").read_text().splitlines():
    name, kind, _, *tokens = line.split()
    if kind == "proof":
        goals.append((name, formula(iter(tokens)), proofs.pop(name)))
    elif kind == "model":
        goal = formula(iter(tokens))
        model = list(tableau_steps(goal))[-1]
        if type(model) is not int or evaluate(goal, model):
            raise ValueError("expected a falsifying assignment")
        model_goals.append((name, goal))
if proofs:
    raise ValueError("certificate without a corpus goal")
long_goal = formula(iter("> > | | c c | a a > > z a & z z > | | c c | a a > > z a & z z".split()))
goals.append(("long-branching", long_goal, "".join(tableau_steps(long_goal))))

# Build each tape from its original rule bytes. The checker receives ordinary
# Bytes and the independently generated expected rule sequence stays in Python.
program = (here / "formula.fen").read_text() + (here / "certificate.fen").read_text() + """
(define rule-byte {I64 --> Bytes}
  n -> (if (= n 98) "b" (if (= n 115) "s" "x")))
(define edit {(Tuple Bytes I64 I64 I64 I64 Bytes) --> Bytes}
  tape i end at replacement acc -> (if (= i end) acc
    (edit tape (+ i 1) end at replacement (bytes-concat acc
      (rule-byte (if (= i at) replacement (bytes-index tape i)))))))
(define examine {(Tuple Formula Bytes I64) --> I64}
  goal tape i -> (if (= i (bytes-length tape)) 0
    (let byte (bytes-index tape i)
      (let other (if (= byte 98) 115 98)
        (let last (if (= byte 120) 115 120)
          (if (verify-proof goal (edit tape 0 i -1 0 "")) 1
            (if (verify-proof goal (edit tape 0 (bytes-length tape) i other "")) 2
              (if (verify-proof goal (edit tape 0 (bytes-length tape) i last "")) 3
                (examine goal tape (+ i 1))))))))))
"""
body = "-1"
for j, (_, goal) in enumerate(model_goals, start=len(goals)):
    checks = "0"
    for _, _, witness in goals:
        checks = f"(if (verify-proof {literal(goal)} {byte_expression(witness.encode())}) 5 {checks})"
    body = f"(if (= i {j}) {checks} {body})"
for i in reversed(range(len(goals))):
    _, goal, witness = goals[i]
    if witness != "".join(tableau_steps(goal)) or not set(witness) <= set("bsx"):
        raise ValueError("witness differs from the independent tableau")
    body = (f"(if (= i {i}) (let goal {literal(goal)} tape {byte_expression(witness.encode())} "
            f"(if (verify-proof goal tape) (examine goal tape 0) 4)) {body})")
program += f"(define main {{I64 --> I64}} i -> {body})\n"
with compiled(here.parents[1], args.target, program) as command:
    for i, (name, _, witness) in enumerate(goals):
        actual = subprocess.check_output([*command, str(i)], text=True, timeout=60)
        if actual != "0\n":
            raise ValueError((name, actual))
        print(json.dumps(dict(target=args.target, formula=name, accepted=1,
                              rejected_substitutions=2 * len(witness), rejected_prefixes=len(witness))))
    for j, (name, _) in enumerate(model_goals, start=len(goals)):
        actual = subprocess.check_output([*command, str(j)], text=True, timeout=60)
        if actual != "0\n":
            raise ValueError((name, actual))
        print(json.dumps(dict(target=args.target, formula=name, rejected_foreign_proofs=len(goals))))
