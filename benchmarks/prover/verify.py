"""Check corpus outputs independently, without invoking a reference prover."""
from itertools import islice
import sys
from pathlib import Path


def formula(tokens):
    op = next(tokens)
    if op == "!":
        return (op, formula(tokens))
    if op in {"&", "|", ">"}:
        return (op, formula(tokens), formula(tokens))
    if len(op) != 1 or not "a" <= op <= "z":
        raise ValueError(f"unknown formula token {op!r}")
    return op


def evaluate(expr, mask):
    if isinstance(expr, str):
        return bool(mask & (1 << (ord(expr) - ord("a"))))
    left = evaluate(expr[1], mask)
    if expr[0] == "!":
        return not left
    right = evaluate(expr[2], mask)
    return {"&": left and right, "|": left or right, ">": not left or right}[expr[0]]


def tableau_steps(goal):
    # Left branch first, FIFO obligations within a branch. Every yielded item
    # costs one unit of fuel, including discovery of an open, empty branch.
    branches = [([(False, goal)], frozenset())]
    while branches:
        queue, facts = branches.pop()
        while queue:
            (sign, expr), *tail = queue
            if isinstance(expr, str):
                if (not sign, expr) in facts:
                    yield "x"
                    break
                facts = facts | {(sign, expr)}
                queue = tail
            elif expr[0] == "!":
                queue = tail + [(not sign, expr[1])]
            else:
                left = (not sign if expr[0] == ">" else sign, expr[1])
                right = (sign, expr[2])
                if (sign, expr[0]) in {(True, "&"), (False, "|"), (False, ">")}:
                    queue = tail + [left, right]
                else:
                    branches.append((tail + [right], facts))
                    queue = tail + [left]
                    yield "b"
                    continue
            yield "s"
        else:
            yield sum(1 << (ord(atom) - ord("a")) for sign, atom in facts if sign)
            return


def check(corpus, output):
    if not __debug__:
        raise RuntimeError("checker requires assertions")
    rows = list(output)
    assert len(corpus) == len(rows)
    names = set()
    for case, row in zip(corpus, rows):
        assert case.isascii(), "expected ASCII corpus row"
        name, expected, budget, *tokens = case.split()
        assert name not in names, f"duplicate case name {name!r}"
        names.add(name)
        actual, status, count, witness = row.split()
        assert (name, expected) == (actual, status)
        tokens = iter(tokens)
        goal = formula(tokens)
        assert next(tokens, None) is None
        if status == "exhausted":
            assert int(count) == int(budget)
        check_result(goal, int(budget), status, int(count), witness)


def check_result(goal, budget, status, count, witness):
    if not __debug__:
        raise RuntimeError("checker requires assertions")
    assert 0 <= count <= budget
    steps = tableau_steps(goal)
    visited = list(islice(steps, budget))
    assert len(visited) == count
    if visited and isinstance(visited[-1], int):
        assert status == "model" and int(witness) == visited[-1]
        assert not evaluate(goal, int(witness))
    elif next(steps, None) is None:
        assert status == "proof" and witness == "".join(visited)
    else:
        assert status == "exhausted" and count == budget and witness == "-"


if __name__ == "__main__":
    check(Path(sys.argv[1]).read_text().splitlines(), sys.stdin)
