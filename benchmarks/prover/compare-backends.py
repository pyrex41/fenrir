"""Compare the same generated program under the pre-migration and Shen compilers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

from fenrir_driver import workload


def command(args, **kwargs):
    return subprocess.check_output(args, text=True, timeout=180, **kwargs).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path, help="checkout of the original JavaScript backend")
    parser.add_argument("rows", type=Path, help="verified prover corpus output")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    rows = args.rows.read_text()
    from verify import check
    corpus = here / "corpus-v1.txt"
    check(corpus.read_text().splitlines(), rows.splitlines())
    proofs = dict(line.split() for line in (here / "certificates-v1.txt").read_text().splitlines())
    rounds = 2000
    image = command(["docker", "image", "inspect", "--format", "{{.Id}}",
                     os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")])
    report = dict(host=platform.platform(), image=image, rounds=rounds, build_ns={}, lanes={},
                  clocks={"macos-arm64": "host process start through checked exit",
                          "solo5-arm64-spt": "guest monotonic around fenrir_entry"},
                  emitter_sources={}, corpus_sha256=digest(corpus))
    for lane in ("search", "check"):
        work = out / lane
        work.mkdir()
        source, cases, _ = workload(here, corpus, proofs, rows, lane)
        (work / "bench.fen").write_text(source)
        command(["sh", root / "frontend/fenrir.sh", "emit", "bench.fen", "artifact.json"], cwd=work,
                env={**os.environ, "FENRIR_NATIVE_BUILD": "1"})
        docker = ["docker", "run", "--rm", "--platform", "linux/arm64", "--network", "none",
                  "--cpuset-cpus=0", "-v", f"{root}:/src:ro", "-v", f"{work}:/work",
                  "-w", "/work", "--entrypoint", "sh", image, "-ec"]
        for target in ("macos-arm64", "solo5-arm64-spt"):
            key = f"{lane}/{target}"
            report["build_ns"][key] = {}
            assemblies = {}
            binaries = {}
            for backend in ("javascript", "shen"):
                name = f"{backend}-{target}"
                assembly = name + ".s"
                before = time.monotonic_ns()
                if backend == "javascript":
                    emitter = args.baseline.resolve() / "tools/aarch64/native-image.mjs"
                    command(["node", emitter, target, "artifact.json", assembly], cwd=work)
                    report["emitter_sources"]["javascript"] = digest(emitter)
                else:
                    command(["sh", root / "tools/aarch64/native-image.sh", target, "artifact.json", assembly],
                            cwd=work, env={**os.environ, "FENRIR_NATIVE_BACKEND": "shen"})
                    report["emitter_sources"]["shen"] = {p.name: digest(p) for p in sorted((root / "backends/arm64").glob("*.shen"))}
                report["build_ns"][key][backend] = time.monotonic_ns() - before
                assemblies[backend] = digest(work / assembly)
                if target == "macos-arm64":
                    command(["clang", "-O2", "-arch", "arm64", assembly, root / "tools/aarch64/darwin-main.c",
                             root / "runtime/native/managed.c", root / "runtime/native/heap.c", "-o", name], cwd=work)
                else:
                    command([*docker, 'export PATH=/opt/solo5-install/bin:$PATH FENRIR_SOLO5_MAIN=/src/benchmarks/prover/timed-spt.c; '
                             'sh /src/tools/aarch64/link-spt.sh "$1.s" "$1"', "sh", name])
                binaries[backend] = digest(work / name)
            samples = []
            for iteration in range(6):
                pair = {}
                for backend in (("javascript", "shen") if iteration % 2 == 0 else ("shen", "javascript")):
                    binary = f"{backend}-{target}"
                    if target == "macos-arm64":
                        start = time.monotonic_ns()
                        result = int(command([work / binary, str(rounds)]))
                        ns = time.monotonic_ns() - start
                    else:
                        result, ns = map(int, command([*docker, 'exec /opt/solo5-install/bin/solo5-spt "$1" --solo5:quiet "$2"',
                                                       "sh", binary, str(rounds)]).split())
                    if result != rounds * cases or ns <= 0:
                        raise ValueError((lane, target, backend, result, ns))
                    pair[backend] = ns
                samples.append(pair)
            report["lanes"][key] = dict(warmup=samples[0], samples_ns=samples[1:], binaries=binaries,
                assemblies=assemblies, artifact=digest(work / "artifact.json"),
                median_paired_ratio=statistics.median(s["shen"] / s["javascript"] for s in samples[1:]))
            (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            print(key, report["lanes"][key]["median_paired_ratio"], flush=True)


if __name__ == "__main__":
    main()
