"""Run the compiled Fenrir prover on the benchmark corpus or a supplied prefix formula."""
import argparse
from itertools import islice
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from fenrir_driver import byte_expression, compiled, literal
from verify import check, check_result, formula, tableau_steps


def check_certificate(here, target, term, certificate):
    tape = certificate.encode("ascii")
    encoded = byte_expression(tape)
    program = (here / "formula.fen").read_text() + (here / "certificate.fen").read_text()
    program += f"\n(define main {{I64 --> Bool}} i -> (verify-proof {literal(term)} {encoded}))\n"
    with compiled(here.parents[1], target, program) as command:
        actual = subprocess.check_output([*command, "0"], timeout=30)
    # One extra expansion distinguishes a complete tape from a prefix.
    steps = list(islice(tableau_steps(term), len(tape) + 1))
    valid = steps == list(certificate)
    if actual != (b"1\n" if valid else b"0\n"):
        raise ValueError("compiled and independent certificate checks disagree")
    print("valid" if valid else "invalid")
    return 0 if valid else 1


def main():
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("macos-arm64", "solo5-arm64-spt"))
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--corpus", type=Path, help="compile and verify all search cases in a corpus file")
    source.add_argument("--formula", help="one space-separated prefix formula")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--budget", type=int, help="search fuel for the supplied formula (default 100)")
    mode.add_argument("--certificate", help="check the supplied ASCII proof tape")
    args = parser.parse_args()
    target = args.target
    if args.formula is None:
        if args.budget is not None or args.certificate is not None:
            parser.error("--budget and --certificate require --formula")
        path = args.corpus if args.corpus is not None else here / "corpus-v1.txt"
        try:
            corpus = path.read_text(encoding="ascii").splitlines()
        except (OSError, UnicodeError) as exc:
            parser.error(str(exc))
        if not corpus:
            parser.error(f"{path}: empty corpus")
        cases = []
        names = set()
        for line_number, line in enumerate(corpus, 1):
            try:
                name, expected, budget_text, *tokens = line.split()
                if name in names:
                    raise ValueError(f"duplicate case name {name!r}")
                names.add(name)
                budget = int(budget_text)
                if expected not in ("proof", "model", "exhausted") or not 0 <= budget < 2**63:
                    raise ValueError("expected proof, model or exhausted and a nonnegative I64 budget")
                items = iter(tokens)
                goal = literal(formula(items))
                if next(items, None) is not None:
                    raise ValueError("extra tokens after the formula")
            except StopIteration:
                parser.error(f"{path}:{line_number}: incomplete prefix formula")
            except (ValueError, RecursionError) as exc:
                parser.error(f"{path}:{line_number}: invalid corpus case: {exc}")
            cases.append((name, budget, goal))
    else:
        tokens = iter(args.formula.split())
        try:
            term = formula(tokens)
        except (ValueError, StopIteration, RecursionError) as exc:
            parser.error(f"invalid or incomplete prefix formula: {exc}")
        if next(tokens, None) is not None:
            parser.error("extra tokens after the formula")
        if args.certificate is not None:
            if not args.certificate.isascii():
                parser.error("certificate must contain ASCII characters")
            return check_certificate(here, target, term, args.certificate)
        budget = 100 if args.budget is None else args.budget
        if not 0 <= budget < 2**63:
            parser.error("budget must be a nonnegative signed 64-bit integer")
        cases = [("goal", budget, literal(term))]
    body = "Exhausted"
    for index in reversed(range(len(cases))):
        _, budget, goal = cases[index]
        body = f"(if (= i {index}) (search (More false {goal} Empty) 0 0 {budget}) {body})"
    program = (here / "formula.fen").read_text() + (here / "search.fen").read_text()
    program += f"\n(define main {{I64 --> Answer}} i -> {body})\n"
    with compiled(root, target, program) as command:
        rows = []
        for i, (name, budget, _) in enumerate(cases):
            output = subprocess.check_output([*command, str(i)], text=True, timeout=30).strip()
            if output == "Exhausted":
                row = f"{name} exhausted {budget} -"
            else:
                match = re.fullmatch(r"\((Proof|Model) (\S+) (\d+)\)", output)
                if not match:
                    raise ValueError(output)
                kind, value, remaining = match.groups()
                if kind == "Proof":
                    if not value.startswith("#x"):
                        raise ValueError(output)
                    value = bytes.fromhex(value[2:]).decode("ascii")
                row = f"{name} {kind.lower()} {budget-int(remaining)} {value}"
            rows.append(row)
        if args.formula is None:
            check(corpus, rows)
        else:
            _, status, count, witness = rows[0].split()
            check_result(term, budget, status, int(count), witness)
        print("\n".join(rows))


if __name__ == "__main__":
    sys.exit(main())
