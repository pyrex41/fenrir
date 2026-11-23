"""Compare the Nim service parser's reply to each expected Fenrir decision."""
from pathlib import Path
import json
import re
import runpy
import subprocess
import tempfile

here = Path(__file__).resolve().parent


def expected_reply(head, decision):
    if decision == "Bad":
        return ["400 Bad Request", "text/plain", "", True]
    if decision == "Oversized":
        return ["431 Request Header Fields Too Large", "text/plain", "", True]
    match = re.fullmatch(r"\(Serve (Home|Status|Missing|\(Item (\d+) (\d+)\)) (true|false)\)", decision)
    if not match:
        raise ValueError(decision)
    route, start, size, close = match.groups()
    status, kind = "200 OK", "text/plain"
    if route == "Home":
        body = "fenrir\n"
    elif route == "Missing":
        status, body = "404 Not Found", ""
    elif route == "Status":
        kind, body = "application/json", '{"ok":true}\n'
    else:
        body = head[int(start):int(start) + int(size)].decode("ascii")
    return [status, kind, body, close == "true"]


def main():
    cases = runpy.run_path(str(here / "check-router.py"))["corpus"]()
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "reference.nim").write_bytes((here / "reference.nim").read_bytes())
        (work / "check.nim").write_text('''include reference
import std/json
for path in commandLineParams():
  let reply = route(readFile(path))
  echo $(%*[reply.status, reply.kind, reply.body, reply.close])
''')
        paths = []
        for i, (head, _) in enumerate(cases):
            path = work / f"head-{i}"
            path.write_bytes(head)
            paths.append(path)
        subprocess.run(["nim", "c", "--hints:off", "-d:release", "--mm:orc", "--overflowChecks:on",
                        "-d:routerBenchmark", "--nimcache:cache", "check.nim"], cwd=work, check=True)
        lines = subprocess.check_output([work / "check", *paths], text=True).splitlines()
        actual = [json.loads(line) for line in lines]
        expected = [expected_reply(head, decision) for head, decision in cases]
        if actual != expected:
            raise ValueError(list(zip(expected, actual)))
    print(f"Nim passed {len(cases)} shared HTTP parser cases")


if __name__ == "__main__":
    main()
