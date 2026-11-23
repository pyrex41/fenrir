"""Translate corpus syntax to Shen data and run the Shen/JIT reference."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

from verify import formula


def literal(expr):
    if isinstance(expr, str):
        return str(ord(expr) - ord("a"))
    op = {"!": "neg", "&": "conj", "|": "disj", ">": "imp"}[expr[0]]
    return "[" + " ".join([op] + [literal(e) for e in expr[1:]]) + "]"


def main():
    directory = Path(__file__).resolve().parent
    default = directory.parents[1] / "build/toolchain/shen-jit-0.7"
    jit = Path(os.environ.get("FENRIR_SHEN_JIT", default)) / "bin/shen-jit"
    checking = len(sys.argv) == 3
    proofs = dict(line.split() for line in Path(sys.argv[2]).read_text().splitlines()) if checking else {}
    expected = []
    program = (directory / "reference.shen").read_text()
    with tempfile.TemporaryDirectory() as tmp:
        rows = Path(sys.argv[1]).read_text().splitlines()
        for i, line in enumerate(rows):
            name, kind, budget, *tokens = line.split()
            if not re.fullmatch(r"[a-z0-9-]+", name) or not budget.isdecimal():
                raise ValueError(line)
            tokens = iter(tokens)
            goal = literal(formula(tokens))
            if next(tokens, None) is not None:
                raise ValueError(line)
            if checking:
                if kind != "proof":
                    continue
                tape = proofs.pop(name)
                for witness, accepted in [(tape, True), (tape[:-1], False), (tape + "x", False), (tape[:-1] + "?", False)]:
                    program += f'\n(write-to-file "case-{len(expected)}" (str (pv.verify {goal} {json.dumps(witness)})))\n'
                    expected.append("true" if accepted else "false")
                continue
            program += f'\n(write-to-file "row-{i}" (pv.row "{name}" {int(budget)} {goal}))\n'
        script = Path(tmp) / "run.shen"
        script.write_text(program)
        run = subprocess.run([jit.resolve(), "script", script], cwd=tmp, capture_output=True)
        if run.returncode:
            sys.stderr.buffer.write(run.stdout + run.stderr)
            sys.exit(run.returncode)
        if checking:
            actual = [(Path(tmp) / f"case-{i}").read_text() for i in range(len(expected))]
            if actual != expected or not actual or proofs:
                raise ValueError((actual, expected))
            print(f"Shen/JIT accepted {expected.count('true')} proofs and rejected {expected.count('false')} mutations")
            return
        for index in range(len(rows)):
            sys.stdout.write((Path(tmp) / f"row-{index}").read_text())


if __name__ == "__main__":
    main()
