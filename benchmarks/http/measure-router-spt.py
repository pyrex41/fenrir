"""Time the shared HTTP corpus inside Fenrir and C Solo5 guests."""
import hashlib
import json
import os
from pathlib import Path
import random
import re
import runpy
import statistics
import subprocess
import sys

sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent


def fields(decision):
    if decision in ("Bad", "Oversized"):
        return [400 if decision == "Bad" else 431, 1, 0, 0]
    match = re.fullmatch(r"\(Serve (Home|Status|Missing|\(Item (\d+) (\d+)\)) (true|false)\)", decision)
    if not match:
        raise ValueError(decision)
    route, start, size, close = match.groups()
    return [404 if route == "Missing" else 200, int(close == "true"),
            -1 if route == "Status" else int(start or 0), int(size or 0)]


def corpus_header(cases):
    heads, rows = [], []
    for i, (head, expected) in enumerate(cases):
        encoded = ",".join(map(str, head))
        heads.append(f"static struct {{ fen_object leaf; unsigned char bytes[{len(head)}]; }} head{i} = "
                     f"{{ {{.fields={{{len(head)}}}, .tag=UINT32_MAX, .live=FEN_IMAGE_OBJECT}}, {{{encoded}}} }};")
        rows.append(f'{{ &head{i}.leaf, {{{",".join(map(str, fields(expected)))}}} }}')
    return "\n".join(heads) + "\nstatic const struct test_case cases[] = {\n" + ",\n".join(rows) + "\n};\n"


def write_corpus(out, cases):
    (out / "corpus.h").write_text(corpus_header(cases))


def main(out):
    root = here.parents[1]
    helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "solo5-build-inputs.py"))
    identify = helpers["shared_inputs"]
    cpu = helpers["benchmark_cpu"]()
    inputs = identify()
    out.mkdir(parents=True, exist_ok=False)
    cases = runpy.run_path(str(here / "check-router.py"))["corpus"]()
    write_corpus(out, cases)
    (out / "router-loop.h").write_bytes((here / "router-loop.h").read_bytes())
    (out / "main.c").write_text('''
#include "/src/runtime/native/heap.h"
#define fenrir_entry http_benchmark_entry
#include "/src/benchmarks/prover/timed-spt.c"
#include "router-loop.h"
''')
    def command(*args, **kwargs):
        return subprocess.check_output(args, timeout=180, text=True, **kwargs).strip()
    image = command("docker", "image", "inspect", "--format", "{{.Id}}",
                    os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64"))
    docker = ["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64", "--cpuset-cpus", cpu,
              "--user", f"{os.getuid()}:{os.getgid()}", "-v", f"{root}:/src:ro",
              "-v", f"{out}:/work", "-w", "/work", "--entrypoint", "sh", image, "-ec"]
    command("sh", root / "frontend/fenrir.sh", "emit", "service.fen", out / "artifact", cwd=here,
            env=dict(os.environ, FENRIR_NATIVE_BUILD="1"))
    command("node", here / "build-service.mjs", out / "artifact", out / "router.s", "solo5-arm64-spt")
    (out / "reference.c").write_bytes((here / "reference.c").read_bytes())
    command(*docker, '''export PATH=/opt/solo5-install/bin:$PATH FENRIR_SOLO5_MAIN=/work/main.c
        sh /src/tools/aarch64/link-spt.sh /work/router.s fenrir.spt
        sh /src/tools/aarch64/link-spt.sh /work/reference.c c.spt''')
    rounds = 1000
    orders = [["fenrir", "c"] if i % 2 == 0 else ["c", "fenrir"] for i in range(13)]
    console = command(*docker, 'rounds=$1; shift; for guest do /usr/bin/time -f %M -o /tmp/rss /opt/solo5-install/bin/solo5-spt "$guest.spt" --solo5:quiet "$rounds"; cat /tmp/rss; done',
                      "sh", str(rounds), *(name for order in orders for name in order))
    (out / "console.txt").write_text(console + "\n")
    lines = iter(console.splitlines())
    samples = []
    for order in orders:
        times = {}
        rss = {}
        for name in order:
            valid, elapsed = map(int, next(lines).split())
            if valid != len(cases) * rounds or elapsed <= 0:
                raise ValueError((name, valid, elapsed))
            times[name] = elapsed
            peak_kib = int(next(lines))
            if peak_kib <= 0:
                raise ValueError(f"invalid peak RSS for {name}")
            rss[name] = 1024 * peak_kib
        samples.append(dict(order=order, ns=times, peak_rss_bytes=rss))
    if next(lines, None) is not None:
        raise ValueError("extra guest output")
    ratios = [s["ns"]["fenrir"] / s["ns"]["c"] for s in samples[1:]]
    rng = random.Random(1147)
    boot = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
    report = dict(target="solo5-arm64-spt", container=image, guest_cpu=cpu, host=command("uname", "-a"), hardware=command("sysctl", "-n", "hw.model"),
                  rounds=rounds, heads_per_round=len(cases), bytes_per_round=sum(len(h) for h, _ in cases),
                  warmup=samples[0], samples=samples[1:], paired_median=statistics.median(ratios),
                  bootstrap95=[boot[249], boot[9749]], scope="guest monotonic time around routing and four result-field checks",
                  sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()})
    if inputs != identify():
        raise ValueError("shared compiler or runtime sources changed during measurement")
    report["memory_scope"] = "Linux maximum resident set size of the Solo5 tender process including the guest"
    report["shared_build_inputs"] = inputs
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(out / "report.json", report["paired_median"], report["bootstrap95"])


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
