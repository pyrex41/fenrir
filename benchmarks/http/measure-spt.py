"""Paired end-to-end latency for one persistent HTTP client and two SPT guests."""
import argparse
from contextlib import ExitStack
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import time

sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wire", here / "check-service.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("fenrir", "c", "output"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    dirs = {"fenrir": args.fenrir, "c": args.c}
    tag = os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
    image = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", tag],
                                    text=True, timeout=15).strip()
    binaries = {name: {file: digest(directory / file) for file in ("http.spt", "ingress")}
                for name, directory in dirs.items()}
    if binaries["fenrir"]["ingress"] != binaries["c"]["ingress"]:
        raise ValueError("comparison requires identical host ingress binaries")
    cases = [("/", b"fenrir\n", 200), ("/items/00012", b"00012", 200),
             ("/status", b'{"ok":true}\n', 200), ("/missing", b"", 404)]
    memory_mib = 32
    samples = []
    with ExitStack() as stack:
        clients = {}
        for name, directory in dirs.items():
            address = stack.enter_context(wire.server([sys.executable, here / "run-spt.py", directory, "0", "--memory-mib", str(memory_mib)],
                                                     env=dict(os.environ, FENRIR_SOLO5_IMAGE=image)))
            wire.check(address)
            clients[name] = http.client.HTTPConnection(*address, timeout=5)
            clients[name].connect()
            stack.callback(clients[name].close)
        for pair in range(13):
            for name in (("c", "fenrir") if pair % 2 else ("fenrir", "c")):
                client = clients[name]
                durations = []
                for i in range(256):
                    path, body, status = cases[i % len(cases)]
                    start = time.monotonic_ns()
                    client.request("GET", path)
                    response = client.getresponse()
                    data = response.read()
                    durations.append(time.monotonic_ns() - start)
                    if (response.status, data) != (status, body) or response.will_close:
                        raise ValueError((path, response.status, data))
                samples.append(dict(pair=pair, guest=name, latency_ns=durations))
    ratios = []
    for pair in range(1, 13):
        elapsed = {row["guest"]: sum(row["latency_ns"]) for row in samples if row["pair"] == pair}
        ratios.append(elapsed["fenrir"] / elapsed["c"])
    rng = random.Random(1147)
    bootstrap = sorted(statistics.median(rng.choices(ratios, k=12)) for _ in range(10000))
    for name, directory in dirs.items():
        if any(digest(directory / file) != expected for file, expected in binaries[name].items()):
            raise ValueError(f"{name} service binary changed during measurement")
    report = dict(scope="closed loop, one client, persistent connection, one outstanding request",
                  host=platform.platform(), cpu=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                  docker_image=image, binaries=binaries, guest_memory_budget_bytes=memory_mib * 1024**2,
                  warmup_pair=0, samples=samples, paired_elapsed_ratio=statistics.median(ratios),
                  bootstrap95=[bootstrap[249], bootstrap[9749]])
    dest = args.output / "report.json"
    dest.write_text(json.dumps(report) + "\n")
    print(dest, report["paired_elapsed_ratio"], report["bootstrap95"])


if __name__ == "__main__":
    main()
