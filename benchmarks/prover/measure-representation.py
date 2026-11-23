#!/usr/bin/env python3
"""Build and measure the Fenrir/compact-C/representation-C Solo5 guests."""
import argparse, hashlib, itertools, json, os, random, runpy, statistics
from pathlib import Path
import subprocess, sys

sys.dont_write_bytecode = True

def cmd(*a, cwd=None, env=None, timeout=300):
    return subprocess.run(a, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True, timeout=timeout).stdout.strip()

def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def boot(xs, seed=1147):
    r = random.Random(seed)
    ys = sorted(statistics.median(r.choices(xs, k=len(xs))) for _ in range(10000))
    return [ys[249], ys[9749]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("output", type=Path)
    ap.add_argument("--rounds", type=int, default=5000)
    ap.add_argument("--blocks", type=int, default=12)
    ap.add_argument("--cpuset-cpus", default="1")
    ap.add_argument("--image", default=os.getenv("FENRIR_SOLO5_IMAGE",
        "fenrir-track1-solo5:38e0c348be23-arm64"))
    a = ap.parse_args()
    if not 1 <= a.rounds <= 100000:
        ap.error("rounds must be between 1 and 100000")
    if a.blocks <= 0 or a.blocks % 6:
        ap.error("blocks must be a positive multiple of 6")
    here = Path(__file__).resolve().parent; root = here.parents[1]
    if a.output.exists(): raise SystemExit(f"output already exists: {a.output}")
    out = a.output.resolve(); out.mkdir(parents=True)
    ms = runpy.run_path(str(here / "measure-spt.py"))
    c_table = ms["c_table"]
    workload = runpy.run_path(str(here / "fenrir_driver.py"))["workload"]
    vr = runpy.run_path(str(here / "verify.py")); check = vr["check"]
    corpus = here / "corpus-v1.txt"; certs = here / "certificates-v1.txt"
    cmd("rustc", "-O", "-C", "overflow-checks=yes", str(here / "reference.rs"), "-o", str(out / "oracle"))
    rows = cmd(str(out / "oracle"), str(corpus)) + "\n"; check(corpus.read_text().splitlines(), rows.splitlines())
    (out / "expected.rows").write_text(rows)
    proofs = dict(x.split() for x in certs.read_text().splitlines())
    image = cmd("docker", "image", "inspect", "--format", "{{.Id}}", a.image)
    docker = ["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64",
              "--cpuset-cpus", a.cpuset_cpus, "--user", f"{os.getuid()}:{os.getgid()}",
              "-v", f"{root}:/src:ro", "-v", f"{out}:/work", "-w", "/work", "--entrypoint", "sh", image, "-ec"]
    build = '''cd "$1"; export PATH=/opt/solo5-install/bin:$PATH
cp /src/benchmarks/prover/reference.c compact.c
export FENRIR_SOLO5_MAIN=/src/benchmarks/prover/timed-spt.c
sh /src/tools/aarch64/link-spt.sh compact.c compact.spt
sh /src/tools/aarch64/link-spt.sh program.s program.spt
cp /src/benchmarks/prover/reference-representation.c representation.c
export FENRIR_SOLO5_MAIN=/src/benchmarks/prover/timed-representation.c
sh /src/tools/aarch64/link-spt.sh representation.c representation.spt'''
    lanes = {}; cases = {}
    for lane in ("search", "check"):
        d = out / lane; d.mkdir()
        src, ncase, units = workload(here, corpus, proofs, rows, lane, mutation_preflight=True)
        (d / "benchmark.fen").write_text(src)
        cmd("sh", str(root / "frontend/fenrir.sh"), "emit", "benchmark.fen", "artifact", cwd=d,
            env=dict(os.environ, FENRIR_NATIVE_BUILD="1"))
        cmd("sh", str(root / "tools/aarch64/native-image.sh"), "solo5-arm64-spt", "artifact", "program.s", cwd=d)
        (d / "corpus.h").write_text(c_table(corpus, rows, lane))
        cmd(*docker, build, "sh", lane)
        (d / "fenrir.spt").symlink_to("program.spt")
        cases[lane] = ncase; lanes[lane] = {"cases": ncase, "units": units}

    def invoke(lane, variant, rounds):
        d = out / lane
        raw = cmd(*docker, '''cd "$1"; /usr/bin/time -o /tmp/rss -f %M /opt/solo5-install/bin/solo5-spt "$2.spt" --solo5:quiet "$3"; cat /tmp/rss''',
                  "sh", lane, variant, str(rounds), timeout=180)
        ls = raw.splitlines()
        if len(ls) != 2: raise ValueError((lane, variant, raw))
        value, elapsed = map(int, ls[0].split()); rss = int(ls[1]) * 1024
        wanted = (0 if lane == "search" else cases[lane] * 3) if rounds == 0 else rounds * cases[lane]
        if value != wanted or elapsed <= 0 or rss <= 0: raise ValueError((lane, variant, rounds, raw))
        return {"value": value, "elapsed_ns": elapsed, "peak_rss_bytes": rss, "raw": raw}

    for lane in lanes:
        # Zero-round invocation exercises checker mutation rejection and the
        # no-work path for search for every guest.
        lanes[lane]["zero_round"] = {v: invoke(lane, v, 0) for v in ("fenrir", "compact", "representation")}
        lanes[lane]["warmup"] = {v: invoke(lane, v, a.rounds) for v in ("fenrir", "compact", "representation")}
        perms = list(itertools.permutations(("fenrir", "compact", "representation")))
        blocks = []
        for i in range(a.blocks):
            order = perms[i % 6]; vals = {v: invoke(lane, v, a.rounds) for v in order}
            blocks.append({"block": i, "order": list(order), "variants": vals})
        lanes[lane]["blocks"] = blocks
        lanes[lane]["sha256"] = {name: sha(out / lane / name) for name in
                                 ("artifact", "program.s", "program.spt", "compact.c", "compact.spt",
                                  "representation.c", "representation.spt", "corpus.h")}
        ratios = {v: [b["variants"][v]["elapsed_ns"] / b["variants"]["compact"]["elapsed_ns"]
                         for b in blocks] for v in ("fenrir", "representation")}
        diffs = {v: [b["variants"][v]["elapsed_ns"] - b["variants"]["compact"]["elapsed_ns"]
                       for b in blocks] for v in ("fenrir", "representation")}
        gap = ([x / y for x, y in zip(diffs["representation"], diffs["fenrir"])]
               if all(y > 0 for y in diffs["fenrir"]) else [])
        lanes[lane]["summary"] = {
            "median_ns": {v: statistics.median(b["variants"][v]["elapsed_ns"] for b in blocks) for v in ("fenrir", "compact", "representation")},
            "median_peak_rss_bytes": {v: statistics.median(b["variants"][v]["peak_rss_bytes"] for b in blocks) for v in ("fenrir", "compact", "representation")},
            "median_ratio_over_compact": {v: statistics.median(ratios[v]) for v in ratios},
            "median_difference_ns_vs_compact": {v: statistics.median(diffs[v]) for v in diffs},
            "representation_gap_fraction": statistics.median(gap) if gap else None,
            "paired_bootstrap95": {v: boot(ratios[v]) for v in ratios},
            "difference_bootstrap95_ns": {v: boot(diffs[v]) for v in diffs},
            "representation_gap_fraction_bootstrap95": boot(gap) if gap else None,
        }
    report = {"schema": "fenrir.prover.representation-three-way.v1", "target": "solo5-arm64-spt",
              "image": image, "rounds": a.rounds, "blocks": a.blocks, "cpuset_cpus": a.cpuset_cpus,
              "rotation": {"permutations": [list(x) for x in itertools.permutations(("fenrir", "compact", "representation"))], "repetitions": a.blocks // 6},
              "host": {"uname": cmd("uname", "-a"), "machine": cmd("uname", "-m")},
              "corpus_sha256": sha(corpus), "certificates_sha256": sha(certs),
              "expected_rows_sha256": sha(out / "expected.rows"), "lanes": lanes}
    (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(out / "report.json")

if __name__ == "__main__": main()
