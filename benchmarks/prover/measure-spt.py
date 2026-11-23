"""Paired Solo5 ARM64 proof search and certificate verification."""
import hashlib
import json
import os
from pathlib import Path
import random
import runpy
import statistics
import subprocess
import sys

sys.dont_write_bytecode = True
from fenrir_driver import workload
from verify import check, formula


def command(*args, **kwargs):
    return subprocess.check_output(args, timeout=180, text=True, **kwargs).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def c_table(corpus, rows, lane):
    entries = []
    formula_capacity, proof_capacity = 64, 256
    lines = corpus.read_text().splitlines()
    if len(lines) != len(rows.splitlines()):
        raise ValueError("corpus row count mismatch")
    for line, row in zip(lines, rows.splitlines()):
        _, kind, budget, *tokens = line.split()
        if lane == "check" and kind != "proof":
            continue
        _, _, nodes, witness = row.split()
        ops, right = [], []

        def flatten(expr):
            index = len(ops)
            ops.append(expr[0])
            right.append(0)
            if isinstance(expr, tuple):
                flatten(expr[1])
                if len(expr) == 3:
                    right[index] = len(ops)
                    flatten(expr[2])

        flatten(formula(iter(tokens)))
        if len(ops) > 32767:
            raise ValueError("formula exceeds signed 16-bit queue indices")
        formula_capacity = max(formula_capacity, len(ops) + 1)
        # Search emits at most one rule per visited node. The checker
        # preflight also appends one byte to each supplied certificate.
        proof_capacity = max(proof_capacity, int(nodes) + 1, len(witness) + 1)
        model = witness if kind == "model" else "0"
        proof = witness if kind == "proof" else ""
        status = {"model": "COUNTERMODEL", "exhausted": "EXHAUSTED", "proof": "PROOF"}[kind]
        offsets = ", ".join(map(str, right))
        entries.append(f'  {{{{"{"".join(ops)}", {{{offsets}}}}}, "{proof}", {budget}, {nodes}, {model}, {status}}}')
    return (f"#define MAX_FORMULA {formula_capacity}\n#define MAX_PROOF {proof_capacity}\n#ifndef CORPUS_LIMITS_ONLY\n"
            + "static const bool checking = " + str(lane == "check").lower() + ";\n"
            + "static const test_case cases[] = {\n" + ",\n".join(entries) + "\n};\n#endif\n")


def main(out):
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "solo5-build-inputs.py"))
    identify = helpers["shared_inputs"]
    cpu = helpers["benchmark_cpu"]()
    inputs = identify()
    out.mkdir(parents=True, exist_ok=False)
    corpus = here / "corpus-v1.txt"
    certificates = here / "certificates-v1.txt"
    proofs = dict(line.split() for line in certificates.read_text().splitlines())
    command("rustc", "-O", "-C", "overflow-checks=yes", here / "reference.rs", "-o", out / "oracle")
    rows = command(out / "oracle", corpus) + "\n"
    check(corpus.read_text().splitlines(), rows.splitlines())
    (out / "expected.rows").write_text(rows)
    tag = os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
    image = command("docker", "image", "inspect", "--format", "{{.Id}}", tag)
    docker = ["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64", "--cpuset-cpus", cpu,
              "--user", f"{os.getuid()}:{os.getgid()}", "-v", f"{root}:/src:ro",
              "-v", f"{out}:/work", "-w", "/work", "--entrypoint", "sh", image, "-ec"]
    report = dict(target="solo5-arm64-spt", container=image, guest_cpu=cpu, rounds=5000, lanes={},
                  memory_scope="Linux maximum resident set size of the Solo5 tender process including the guest",
                  clock="in-guest monotonic around the repeated kernel and result checks",
                  host=command("uname", "-a"), hardware=command("sysctl", "-n", "hw.model"),
                  corpus_sha256=digest(corpus), certificates_sha256=digest(certificates),
                  verifier_sha256=digest(here / "verify.py"), expected_rows_sha256=digest(out / "expected.rows"))
    for lane in ("search", "check"):
        folder = out / lane
        folder.mkdir()
        source, cases, units = workload(here, corpus, proofs, rows, lane, mutation_preflight=True)
        (folder / "benchmark.fen").write_text(source)
        command("sh", root / "frontend/fenrir.sh", "emit", "benchmark.fen", "artifact",
                cwd=folder, env=dict(os.environ, FENRIR_NATIVE_BUILD="1"))
        command("node", root / "tools/aarch64/native-image.mjs", "solo5-arm64-spt",
                "artifact", "program.s", cwd=folder)
        (folder / "corpus.h").write_text(c_table(corpus, rows, lane))
        (folder / "reference.c").write_bytes((here / "reference.c").read_bytes())
        command(*docker, '''cd "$1"; export PATH=/opt/solo5-install/bin:$PATH
export FENRIR_SOLO5_MAIN=/src/benchmarks/prover/timed-spt.c
for src in program.s reference.c; do
    sh /src/tools/aarch64/link-spt.sh "$src" "${src%.*}.spt"
done''', "sh", lane)
        preflight = None
        if lane == "check":
            preflight = {}
            for guest in ("program", "reference"):
                line = command(*docker, 'cd "$1"; /opt/solo5-install/bin/solo5-spt "$2.spt" --solo5:quiet 0',
                               "sh", lane, guest)
                rejected, elapsed = map(int, line.split())
                if rejected != cases * 3 or elapsed <= 0:
                    raise ValueError((guest, "checker mutation preflight", line))
                preflight[guest] = line
        samples = []
        for pair in range(13):
            order = ["program", "reference"] if pair % 2 == 0 else ["reference", "program"]
            console = command(*docker, '''cd "$1"; shift; for guest do
                /usr/bin/time -o /tmp/rss -f %M /opt/solo5-install/bin/solo5-spt "$guest.spt" --solo5:quiet 5000
                cat /tmp/rss
            done''', "sh", lane, *order)
            times = {}
            rss = {}
            lines = console.splitlines()
            if len(lines) != 2 * len(order):
                raise ValueError(console)
            for i, name in enumerate(order):
                line = lines[2 * i]
                peak_kib = int(lines[2 * i + 1])
                count, elapsed = map(int, line.split())
                if count != 5000 * cases or elapsed <= 0 or peak_kib <= 0:
                    raise ValueError((lane, name, line))
                times[name] = elapsed
                rss[name] = peak_kib * 1024
            samples.append(dict(order=order, ns=times, peak_rss_bytes=rss, console=console))
        ratios = [row["ns"]["program"] / row["ns"]["reference"] for row in samples[1:]]
        rng = random.Random(1147)
        boot = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
        report["lanes"][lane] = dict(mutation_preflight=preflight, warmup=samples[0], samples=samples[1:], units_per_round=units,
            work_unit="tableau node" if lane == "search" else "certificate",
            work_units_per_second={name: units * report["rounds"] * 1e9 /
                                   statistics.median(row["ns"][name] for row in samples[1:])
                                   for name in ("program", "reference")},
            median_fenrir_over_c=statistics.median(ratios), paired_bootstrap95=[boot[249], boot[9749]],
            sha256={p.name: digest(p) for p in folder.iterdir() if p.is_file()})
    if inputs != identify():
        raise ValueError("shared compiler or runtime sources changed during measurement")
    report["shared_build_inputs"] = inputs
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(out / "report.json", {k: v["median_fenrir_over_c"] for k, v in report["lanes"].items()})


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
