"""Compile the decoder and check typed summaries with split frames on both targets."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parent / "prover"))
from fenrir_driver import compiled


def frame(key, payload):
    return (1 + len(payload)).to_bytes(2, "big") + bytes([key]) + payload


def chunk(part):
    return "#x" + part.hex() if part else '""'


def saved_state_checks():
    # Each suffix starts from the same saved decoder. Keep one sibling live
    # across construction of the other so either direction of aliasing is visible.
    prefix = [(0, b""), (3, b"x"), (16, b"y"), (32, b""), (63, b"z")]
    common = b"".join(frame(k, payload) for k, payload in prefix)
    pending = frame(3, b"abc")

    def totals(records):
        counts = {}
        for key, payload in records:
            n, size, total = counts.get(key, (0, 0, 0))
            counts[key] = n + 1, size + len(payload), total + sum(payload)
        term = "NoKeys"
        for key, (n, size, total) in sorted(counts.items(), reverse=True):
            term = f"(Key {key} {n} {size} {total} {term})"
        return f"(Accepted {term})"

    checks = []
    for cut in range(len(pending) + 1):
        head = common + pending[:cut]
        suffix = pending[cut:]
        left = suffix + frame(3, b"d")
        right = suffix + frame(62, b"ef")
        records = prefix + [(3, b"abc")]
        original = (totals(prefix) if cut == 0 else totals(records) if not suffix
                    else f"(Rejected {len(head)})")
        checks.append(
            f"(let saved (feed (LengthHi 0 Vacant) {chunk(head)}) "
            f"left (feed saved {chunk(left)}) right (feed saved {chunk(right)}) "
            f"(if (= (finish left) {totals(records + [(3, b'd')])}) "
            f"(if (= (finish right) {totals(records + [(62, b'ef')])}) "
            f"(= (finish saved) {original}) false) false))")
    return checks


def main(target):
    data = frame(63, b"") + frame(0, bytes([0, 255])) + frame(63, b"abc")
    totals = "(Accepted (Key 0 1 2 255 (Key 63 2 3 294 NoKeys)))"
    cases = [(b"", "(Accepted NoKeys)"), (data, totals)]
    for suffix, offset in [(b"\x00", 1), (b"\x00\x00", 0), (b"\x00\x01", 2),
                           (b"\x00\x01\x40", 2), (b"\x00\x04\x01ab", 5)]:
        cases.append((data + suffix, f"(Rejected {len(data) + offset})"))
    source = (here / "processor.fen").read_text()
    checks = []
    for stream, expected in cases:
        for split in range(len(stream) + 1):
            expr = f"(feed (feed (LengthHi 0 Vacant) {chunk(stream[:split])}) {chunk(stream[split:])})"
            checks.append(f"(= (finish {expr}) {expected})")
    source += """
(define repeat-chunk {(Tuple I64 Decoder) --> Decoder}
  n state -> (if (= n 0) state (repeat-chunk (- n 1) (feed state #x00030701ff))))
"""
    checks.append("(= (finish (repeat-chunk 100000 (LengthHi 0 Vacant))) (Accepted (Key 7 100000 200000 25600000 NoKeys)))")
    for values in [(0, 1, 0, 0), (63, 100000, 200000, 25600000),
                   (47, 389, 1099511627776, 280375465082880)]:
        fields = " ".join(map(str, values))
        expected = (fields + "\n").encode().hex()
        checks.append(f"(= (summary-line {fields}) #x{expected})")
    for offset in (0, 9, 10, 1099511627776):
        expected = f"reject {offset}\n".encode().hex()
        checks.append(f"(= (rejection-line {offset}) #x{expected})")
    source += """
(define collect-lines {Totals --> Bytes}
  totals -> (match (next-line totals)
    (End -> "")
    ((Line bytes rest) -> (bytes-concat bytes (collect-lines rest)))))

(define render {Summary --> Bytes}
  result -> (match result
    ((Accepted totals) -> (collect-lines totals))
    ((Rejected offset) -> (rejection-line offset))))
"""
    for stream, wanted in [(b"", b""), (data, b"0 1 2 255\n63 2 3 294\n"),
                           (data + b"\x00", f"reject {len(data)+1}\n".encode())]:
        checks.append(f"(= (render (finish (feed (LengthHi 0 Vacant) {chunk(stream)}))) {chunk(wanted)})")
    batch_size = min(16, 32 - source.count("(define ") - 1)
    if batch_size < 1:
        raise ValueError("decoder fixtures exceed the frontend function limit")
    saved = saved_state_checks()
    batches = [checks[i:i + batch_size] for i in range(0, len(checks), batch_size)]
    # The retained-state fixtures embed three full summaries per case.
    batches.extend(saved[i:i + 2] for i in range(0, len(saved), 2))
    for batch in batches:
        program = source
        # Each check has its own root frame so completed test inputs can be collected.
        for index, expr in enumerate(batch):
            program += f"(define check-{index} {{I64 --> I64}} n -> (if {expr} 1 0))\n"
        terms = [f"(check-{index} n)" for index in range(len(batch))]
        while len(terms) > 1:
            terms = [f"(+ {terms[i]} {terms[i+1]})" if i+1 < len(terms) else terms[i]
                     for i in range(0, len(terms), 2)]
        program += f"(define main {{I64 --> I64}} n -> {terms[0]})\n"
        with compiled(here.parents[1], target, program) as command:
            output = subprocess.check_output([*command, "0"], text=True, timeout=120).strip()
            if output != str(len(batch)):
                raise ValueError((target, output, len(batch)))
    print(f"{target}: {len(checks) + len(saved)} checks passed")


if __name__ == "__main__":
    main(sys.argv[1])
