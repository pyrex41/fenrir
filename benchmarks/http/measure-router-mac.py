"""Time matched parser calls on native Apple Silicon."""
import hashlib
import json
import os
from pathlib import Path
import random
import re
import runpy
import shutil
import statistics
import subprocess
import sys

here = Path(__file__).resolve().parent
root = here.parents[1]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=False)


def command(*args, **kwargs):
    return subprocess.check_output(args, cwd=kwargs.pop("cwd", out), text=True,
                                   timeout=180, **kwargs).strip()


identify = runpy.run_path(str(Path(__file__).resolve().parents[1] / "solo5-build-inputs.py"))["shared_inputs"]
build_inputs = identify()
cases = runpy.run_path(str(here / "check-router.py"))["corpus"]()
runpy.run_path(str(here / "measure-router-spt.py"))["write_corpus"](out, cases)
expected_reply = runpy.run_path(str(here / "check-nim-router.py"))["expected_reply"]
rust_cases, rows = [], []
for index, (head, decision) in enumerate(cases):
    name = f"head-{index}"
    (out / name).write_bytes(head)
    reply = expected_reply(head, decision)
    rows.append([name, *reply])
    values = ", ".join(json.dumps(v) for v in reply)
    rust_cases.append(f'(include_bytes!("{name}").as_slice(), ({values}))')
(out / "cases.json").write_text(json.dumps(rows))
(out / "cases.rs").write_text("{ let cases = [" + ",\n".join(rust_cases) + r'''];
    let rounds: usize = std::env::args().nth(1).unwrap().parse().unwrap();
    let start = std::time::Instant::now();
    let mut count = 0;
    for _ in 0..rounds {
        for (head, expected) in &cases {
            assert_eq!(route(std::hint::black_box(head)), *expected);
            count += 1;
        }
    }
    println!("{} {}", count, start.elapsed().as_nanos());
}''')
for name in ("reference.rs", "reference.nim", "router-time.rs", "router-time.nim"):
    shutil.copyfile(here / name, out / name.replace("router-time", "router_time"))
command("sh", root / "frontend/fenrir.sh", "emit", "service.fen", out / "artifact", cwd=here,
        env=dict(os.environ, FENRIR_NATIVE_BUILD="1"))
command("node", here / "build-service.mjs", "artifact", "router.s")
native = root / "runtime/native"
builds = {
    "rust": ["rustc", "--edition=2021", "-O", "-C", "overflow-checks=yes", "router_time.rs", "-o", "rust"],
    "nim": ["nim", "c", "--hints:off", "-d:release", "--mm:orc", "--overflowChecks:on",
            "-d:routerBenchmark", "-o:nim", "router_time.nim"],
}
for name, source in [("fenrir", "router.s"), ("c", str(here / "reference.c"))]:
    builds[name] = ["clang", "-arch", "arm64", "-O2", "-I", str(native), "-I", str(out),
                    source, str(here / "router-mac.c"), str(native / "heap.c"),
                    str(native / "managed.c"), "-o", name]
koka = os.environ.get("KOKA", "koka")
fields = runpy.run_path(str(here / "measure-router-spt.py"))["fields"]
kk_cases = [f'(decode("{head.hex()}".list,[]),({",".join(map(str, fields(decision)))}))'
            for head, decision in cases]
driver = ("\nfun main()\n  val cases = [" + ",\n    ".join(kk_cases) + "]\n"
          '  val rounds = get-args().head("").parse-int.default(0)\n'
          '  val (duration,count) = elapsed(fn() repeat-cases(rounds,cases,0))\n'
          '  println(count.show ++ " " ++ duration.nano-seconds.show)\n')
(out / "reference.kk").write_text((here / "reference.kk").read_text() + driver)
builds["koka"] = [koka, "-O2", "-o", str(out / "koka"), "reference.kk"]
for args in builds.values():
    command(*args)
(out / "koka").chmod(0o700)
samples = []
names = list(builds)
rounds = 200
for i in range(1 + 3 * len(names)):
    order = names[i % len(names):] + names[:i % len(names)]
    ns, rss = {}, {}
    for name in order:
        args = [out / name, str(rounds)]
        if name == "nim":
            args.append("cases.json")
        raw = command("/usr/bin/time", "-l", *args, stderr=subprocess.STDOUT)
        (out / f"{i}-{name}.txt").write_text(raw + "\n")
        count, ns[name] = map(int, raw.splitlines()[0].split())
        if count != rounds * len(cases) or ns[name] <= 0:
            raise ValueError((name, count, ns[name]))
        rss[name] = int(re.search(r"(\d+)\s+maximum resident set size", raw)[1])
    samples.append(dict(order=order, ns=ns, peak_rss_bytes=rss))
ratios = {}
rng = random.Random(1147)
for name in names:
    pairs = [s["ns"]["fenrir"] / s["ns"][name] for s in samples[1:]]
    boot = sorted(statistics.median(rng.choices(pairs, k=len(pairs))) for _ in range(10000))
    ratios[name] = [statistics.median(pairs), boot[249], boot[9749]]
eligible = ("rust", "nim", "koka")
median_ns = {name: statistics.median(row["ns"][name] for row in samples[1:]) for name in names}
median_rss = {name: statistics.median(row["peak_rss_bytes"][name] for row in samples[1:]) for name in names}
fastest = min(eligible, key=median_ns.get)
comparison = dict(language=fastest, eligible_measured=eligible, required_missing=[],
                  paired_median=ratios[fastest][0], bootstrap95=ratios[fastest][1:],
                  peak_rss_ratio=median_rss["fenrir"] / median_rss[fastest])
sources = [here / name for name in ("router.fen", "service.fen", "router-loop.h", "router-mac.c",
           "build-service.mjs", "reference.c", "reference.kk", "reference.rs", "reference.nim", "router-time.rs",
           "router-time.nim", "check-router.py", "check-nim-router.py", "measure-router-mac.py",
           "measure-router-spt.py")]
sources += [native / name for name in ("heap.h", "heap.c", "managed.c")]
sources += [root / name for name in build_inputs]
report = dict(target="darwin-arm64", host=command("uname", "-a"), hardware=command("sysctl", "-n", "hw.model"), os=command("sw_vers"),
              rounds=rounds, heads=len(cases), bytes_per_round=sum(len(h) for h, _ in cases),
              median_ns=median_ns, median_rss_bytes=median_rss, fastest_measured_reference=comparison,
              source_sha256={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              builds=builds, versions={k: command(k, "--version") for k in ["rustc", "nim", "clang", "node", koka]},
              warmup=samples[0], samples=samples[1:], paired_median_and_bootstrap95=ratios,
              sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()})
if identify() != build_inputs:
    raise ValueError("shared compiler or runtime sources changed during measurement")
report["shared_build_inputs"] = build_inputs
(out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(out / "report.json", ratios)
