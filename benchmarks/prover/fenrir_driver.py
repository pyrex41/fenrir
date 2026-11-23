"""Corpus term encoding and native compiler invocation."""
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


def literal(term):
    if isinstance(term, str):
        return f"(Atom {1 << (ord(term) - ord('a'))})"
    if term[0] == "!":
        return f"(Neg {literal(term[1])})"
    op = {"&": 0, "|": 1, ">": 2}[term[0]]
    return f"(Binary {op} {literal(term[1])} {literal(term[2])})"


def byte_expression(data):
    """Encode a proof tape within the 256-byte source literal limit."""
    if not data:
        return '""'
    parts = ["#x" + data[i:i+256].hex() for i in range(0, len(data), 256)]
    while len(parts) > 1:
        parts = [f"(bytes-concat {parts[i]} {parts[i+1]})" if i+1 < len(parts) else parts[i]
                 for i in range(0, len(parts), 2)]
    return parts[0]


@contextmanager
def compiled(root, target, program):
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "prover.fen"
        source.write_text(program)
        image = Path(tmp) / "prover"
        subprocess.run([root / "bin/fenrir", "build", "--target", target, source.name, "-o", image],
                       cwd=tmp, stdout=sys.stderr, check=True, timeout=120)
        if target == "macos-arm64":
            command = [image]
        elif sys.platform == "darwin":
            command = ["docker", "run", "--rm", "--platform", "linux/arm64", "--network", "none",
                       "-v", f"{tmp}:/guest:ro", "--entrypoint", "/opt/solo5-install/bin/solo5-spt",
                       os.environ.get("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64"),
                       "/guest/prover", "--solo5:quiet"]
        else:
            command = [str(Path(os.environ["FENRIR_SOLO5"]) / "bin/solo5-spt")
                       if "FENRIR_SOLO5" in os.environ else "solo5-spt", image, "--solo5:quiet"]
        yield command


def workload(here, corpus, proofs, rows, lane, mutation_preflight=False):
    from verify import formula
    units = 0
    source = (here / "formula.fen").read_text()
    source += (here / ("search.fen" if lane == "search" else "certificate.fen")).read_text()
    calls = []
    mutations = []
    for line, result in zip(corpus.read_text().splitlines(), rows.splitlines()):
        name, kind, budget, *tokens = line.split()
        goal = literal(formula(iter(tokens)))
        _, _, nodes, witness = result.split()
        if lane == "check":
            if kind != "proof":
                continue
            assert witness == proofs[name]
            expression = f"(verify-proof {goal} {byte_expression(witness.encode())})"
            if mutation_preflight:
                for invalid in (witness[:-1], witness + "x", witness[:-1] + "?"):
                    mutations.append(f"(if (verify-proof {goal} {byte_expression(invalid.encode())}) 0 1)")
            units += 1
        else:
            remaining = int(budget) - int(nodes)
            expected = {"proof": f"(Proof {byte_expression(witness.encode())} {remaining})",
                        "model": f"(Model {witness} {remaining})",
                        "exhausted": "Exhausted"}[kind]
            expression = f"(= (search (More false {goal} Empty) 0 0 {budget}) {expected})"
            units += int(nodes)
        fun = f"case-{len(calls)}"
        source += f"\n(define {fun} {{I64 --> I64}} i -> (if {expression} 1 0))\n"
        calls.append(f"({fun} i)")
    total = "0"
    for call in calls:
        total = f"(+ {total} {call})"
    source += f"\n(define round-ok {{I64 --> I64}} i -> {total})\n"
    source += """(define repeat-round {(Tuple I64 I64) --> I64}
      i acc -> (if (<= i 0) acc (repeat-round (- i 1) (+ acc (round-ok i)))))
    """
    entry = "(repeat-round n 0)"
    if mutations:
        rejected = "0"
        for check in mutations:
            rejected = f"(+ {rejected} {check})"
        entry = f"(if (= n 0) {rejected} {entry})"
    source += f"(define main {{I64 --> I64}} n -> {entry})\n"
    return source, len(calls), units
