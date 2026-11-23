"""Paired Shen/JavaScript ARM64 application measurements on one Apple Silicon host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import signal
import statistics
import struct
import subprocess
import sys
import time


def run(args, **options):
    result = subprocess.run(args, capture_output=True, timeout=180, **options)
    if result.returncode:
        raise RuntimeError((args, result.returncode, result.stdout[-1024:], result.stderr[-2048:]))
    return result


def drive_worker(argv, packets):
    # NET_BASIC is a request/reply transport. A host must drain each response
    # before submitting the next message to avoid filling the guest TX queue.
    observed = []
    def timed_out(*_):
        raise TimeoutError("durable worker timed out")
    prior = signal.signal(signal.SIGALRM, timed_out)
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    signal.alarm(120)
    try:
        for packet in packets:
            proc.stdin.write(struct.pack(">H", len(packet)) + packet)
            proc.stdin.flush()
            header = proc.stdout.read(2)
            if len(header) != 2:
                raise ValueError("worker exited before a response")
            size = int.from_bytes(header, "big")
            observed.append(proc.stdout.read(size))
        proc.stdin.close()
        if proc.stdout.read() or proc.wait() != 0:
            raise ValueError("worker returned a trailing response or failed")
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, prior)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    return observed


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="pre-migration checkout")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    original = args.baseline.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    image = run(["docker", "image", "inspect", "--format", "{{.Id}}",
                 os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")]).stdout.decode().strip()
    docker = ["docker", "run", "--rm", "-i", "--network", "none", "--platform", "linux/arm64", "--cpuset-cpus=0",
              "-v", f"{out}:/work", "-v", f"{root}:/src:ro", "-w", "/work", "--entrypoint", "sh", image, "-ec"]
    http = root / "benchmarks/http"
    corpus = runpy.run_path(str(http / "check-router.py"))["corpus"]()
    runpy.run_path(str(http / "measure-router-spt.py"))["write_corpus"](out, corpus)
    (out / "router-loop.h").write_bytes((http / "router-loop.h").read_bytes())
    (out / "router-main.c").write_text('#include "/src/runtime/native/heap.h"\n#define fenrir_entry http_benchmark_entry\n'
                                       '#include "/src/benchmarks/prover/timed-spt.c"\n#include "router-loop.h"\n')
    run(["sh", root / "frontend/fenrir.sh", "emit", "service.fen", out / "router.json"], cwd=http, env={**os.environ, "FENRIR_NATIVE_BUILD": "1"})
    framed = root / "benchmarks/framed-log"
    sys.path.insert(0, str(framed))
    expected = runpy.run_path(str(framed / "measure.py"))["write_workload"](out / "stream.bin", "mixed")
    stream = (out / "stream.bin").read_bytes()
    durable = root / "benchmarks/durable"
    cases = runpy.run_path(str(durable / "check-ports.py"))["cases"]
    pairs = {**dict(cases()), **dict(cases(wide=True))}
    packets = []
    for packet in pairs:
        if packet[0] == 2:
            packets.extend([packet[1:12] if packet[1] in (3, 4) else packet[1:5], packet])
    packets *= 8
    wire = b"".join(struct.pack(">H", len(p)) + p for p in packets)
    report = dict(solo5_image=image, wire_sha256=digest(wire), stream_sha256=digest(stream), lanes={})
    for target in ("mac", "spt"):
        platform = "macos-arm64" if target == "mac" else "solo5-arm64-spt"
        for app in ("http", "framed-log", "durable"):
            key = app + "/" + platform
            builds = {}
            for name, tree in (("javascript", original), ("shen", root)):
                binary = out / f"{app}-{target}-{name}"
                env = {**os.environ, "FENRIR_NATIVE_BACKEND": name, "FENRIR_SOLO5_IMAGE": image}
                start = time.monotonic_ns()
                if app == "http":
                    assembly = str(binary) + ".s"
                    run(["node", tree / "benchmarks/http/build-service.mjs", out / "router.json", assembly, platform], env=env)
                    if target == "mac":
                        run(["clang", "-O2", "-arch", "arm64", "-I", out, "-I", root / "runtime/native", assembly,
                             http / "router-mac.c", root / "runtime/native/managed.c", root / "runtime/native/heap.c", "-o", binary])
                    else:
                        run([*docker, 'export PATH=/opt/solo5-install/bin:$PATH FENRIR_SOLO5_MAIN=/work/router-main.c; '
                             'sh /src/tools/aarch64/link-spt.sh "$1.s" "$1"', "sh", binary.name])
                else:
                    subdir = "durable/native" if app == "durable" else app
                    run(["sh", tree / f"benchmarks/{subdir}/build-{target}.sh", binary], cwd=out, env=env)
                builds[name] = dict(build_ns=time.monotonic_ns() - start, sha256=digest(binary.read_bytes()))
            samples = []
            for iteration in range(6):
                pair = {}
                for name in (("shen", "javascript") if iteration % 2 else ("javascript", "shen")):
                    binary = out / f"{app}-{target}-{name}"
                    start = time.monotonic_ns()
                    if app == "http":
                        argv = [binary, "100"] if target == "mac" else [*docker, 'exec /opt/solo5-install/bin/solo5-spt "$1" --solo5:quiet 100', "sh", binary.name]
                        result, ns = map(int, run(argv).stdout.split())
                        assert result == len(corpus) * 100
                    elif app == "framed-log":
                        if target == "mac":
                            reply = run([binary], input=stream).stdout
                            ns = time.monotonic_ns() - start
                            assert reply == expected
                        else:
                            reply = run([*docker, 'cp stream.bin /tmp/input; exec /opt/solo5-install/bin/solo5-spt --block:input=/tmp/input "$1" --solo5:quiet "t$2"',
                                         "sh", binary.name, str(len(stream))]).stdout
                            prefix = expected + b"elapsed_ns "
                            assert reply.startswith(prefix)
                            ns = int(reply[len(prefix):])
                    else:
                        argv = [binary] if target == "mac" else [*docker, 'export FENRIR_SOLO5=/opt/solo5-install FENRIR_NATIVE_SERVICE_IMAGE="/work/$1"; '
                                                                  'exec sh /src/benchmarks/durable/native/launch-spt.sh', 'sh', binary.name]
                        observed = drive_worker(argv, packets)
                        ns = time.monotonic_ns() - start
                        if any(json.loads(reply) != pairs[packet] for packet, reply in zip(packets, observed)):
                            raise ValueError("durable response differs from independent oracle")
                    pair[name] = ns
                samples.append(pair)
            ratio = statistics.median(p["shen"] / p["javascript"] for p in samples[1:])
            clock = ("in-process monotonic around checked kernel" if app == "http" or (app == "framed-log" and target == "spt")
                     else "host process start through exit including Solo5 container launch" if target == "spt"
                     else "host process start through exit")
            report["lanes"][key] = dict(builds=builds, clock=clock, samples_ns=samples[1:], warmup=samples[0], median_paired_ratio=ratio)
            (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(key, ratio, flush=True)


if __name__ == "__main__":
    main()
