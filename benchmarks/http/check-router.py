"""Run the compiled Fenrir HTTP head parser against the bounded service profile."""
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parent / "prover"))
from fenrir_driver import compiled


def request(path=b"/", fields=b"Host: x"):
    return b"GET " + path + b" HTTP/1.1\r\n" + fields + b"\r\n\r\n"


def corpus():
    cases = [(request(), "(Serve Home false)"), (request(b"/status"), "(Serve Status false)"),
             (request(b"/Status"), "(Serve Missing false)"),
             (request(b"/items/001"), "(Serve (Item 11 3) false)"),
             (request(b"/items/"), "(Serve Missing false)"),
             (request(b"/items/12q"), "(Serve Missing false)"),
             (request(fields=b"hOsT:\tx\r\nConnection: keep-alive, \tClOsE "), "(Serve Home true)"),
             (request(fields=b"Host:x\r\nConnection: closed"), "(Serve Home false)"),
             (request(fields=b"Host:x\r\nConnection:close\r\nConnection:keep-alive"), "(Serve Home true)"),
             (request(fields=b"Host:x\r\nX!#$%&'*+-.^_`|~:\t"), "(Serve Home false)")]
    for fields in [b"", b"host: \t", b"host:x\r\nhost:y", b"Bad field:x",
                   b"host:x\r\nContent-Length:0", b"host:x\r\nTRANSFER-ENCODING:chunked",
                   b"host:\xff", b":x", b"host:x\nY:z", b"host:x\rY:z"]:
        cases.append((request(fields=fields), "Bad"))
    for raw in [b"POST / HTTP/1.1\r\nHost:x\r\n\r\n", request(b"/\x7f"),
                request(b"//a b"), request().replace(b"1.1", b"1.0"), request()[:-1]]:
        cases.append((raw, "Bad"))
    for n in (8192, 8193):
        prefix = b"Host:x\r\nY:"
        fields = prefix + b"a" * (n - len(request(fields=prefix)))
        cases.append((request(fields=fields), "(Serve Home false)" if n == 8192 else "Oversized"))
    return cases


def main(target):
    cases = corpus()
    def literal(raw):
        # Repeated chunks avoid the frontend's literal-size bound on long heads.
        if len(raw) <= 256:
            return "#x" + raw.hex()
        mid = len(raw) // 2
        return f"(bytes-concat {literal(raw[:mid])} {literal(raw[mid:])})"
    for start in range(0, len(cases), 10):
        batch = cases[start:start+10]
        body = "Bad"
        for i in reversed(range(len(batch))):
            body = f"(if (= n {i}) (parse-head {literal(batch[i][0])}) {body})"
        source = (here / "router.fen").read_text() + f"\n(define main {{I64 --> Decision}} n -> {body})"
        with compiled(here.parents[1], target, source) as command:
            for i, (_, expected) in enumerate(batch):
                actual = subprocess.check_output([*command, str(i)], text=True, timeout=30).strip()
                if actual != expected:
                    raise ValueError((start+i, actual, expected))
    print(target, len(cases), "HTTP router checks passed")


if __name__ == "__main__":
    main(sys.argv[1])
