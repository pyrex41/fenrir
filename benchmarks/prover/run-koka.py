"""Compile the frozen input as Koka literals and emit the prover's rows."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from verify import formula


def literal(term):
    if isinstance(term, str):
        return f"Atom({1 << (ord(term) - ord('a'))})"
    if term[0] == "!":
        return f"Neg({literal(term[1])})"
    return f"Binary({json.dumps(term[0])},{literal(term[1])},{literal(term[2])})"


def main():
    checking = len(sys.argv) == 3
    proofs = dict(line.split() for line in Path(sys.argv[2]).read_text().splitlines()) if checking else {}
    expected = []
    program = Path(__file__).with_name("reference.kk").read_text() + "\nfun main()\n"
    for line in Path(sys.argv[1]).read_text().splitlines():
        name, kind, budget, *tokens = line.split()
        tokens = iter(tokens)
        term = formula(tokens)
        if next(tokens, None) is not None or int(budget) < 0:
            raise ValueError(line)
        if checking:
            if kind != "proof":
                continue
            tape = proofs.pop(name)
            for witness, accepted in [(tape, True), (tape[:-1], False), (tape + "x", False), (tape[:-1] + "?", False)]:
                program += f'  println(if verify-proof({literal(term)},{json.dumps(witness)}) then "yes" else "no")\n'
                expected.append("yes" if accepted else "no")
            continue
        program += f"  row({json.dumps(name)},{int(budget)},{literal(term)})\n"
    if proofs:
        raise ValueError("unknown certificate names")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "reference.kk").write_text(program)
        subprocess.run([os.environ.get("KOKA", "koka"), "-O2", "-o", str(root / "prover"),
                        "reference.kk"], cwd=root, stdout=sys.stderr, check=True)
        (root / "prover").chmod(0o700)
        if checking:
            actual = subprocess.check_output([root / "prover"], text=True).splitlines()
            if actual != expected or not actual:
                raise ValueError((actual, expected))
            print(f"Koka accepted {expected.count('yes')} proofs and rejected {expected.count('no')} mutations")
        else:
            subprocess.run([root / "prover"], check=True)


if __name__ == "__main__":
    main()
