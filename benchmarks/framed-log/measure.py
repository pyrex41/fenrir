"""Paired macOS end-to-end reference measurements; run with a fresh output directory."""
import argparse
import hashlib
import json
from pathlib import Path
import os
import platform
import random
import runpy
import re
import selectors
import shutil
import statistics
import subprocess
import sys
import time


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def fixture_inputs(source, checker):
    return {name: digest(source / name) for name in (checker, "boundary_cases.py")}


def version(*cmd):
    return subprocess.check_output(cmd, text=True).strip()


def first_output(command, corpus, expected, env, timeout=30):
    with corpus.open("rb") as stream, selectors.DefaultSelector() as selector:
        start = time.monotonic_ns()
        deadline = start + int(timeout * 1e9)
        with subprocess.Popen(command, env=env, stdin=stream, stdout=subprocess.PIPE) as process:
            try:
                selector.register(process.stdout, selectors.EVENT_READ)
                if not selector.select(max(0, (deadline - time.monotonic_ns()) / 1e9)):
                    raise subprocess.TimeoutExpired(command, timeout)
                first = os.read(process.stdout.fileno(), 1)
                observed = time.monotonic_ns()
                remaining, _ = process.communicate(timeout=max(0, (deadline - observed) / 1e9))
            except BaseException:
                process.kill()
                raise
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command)
        if not first or first + remaining != expected:
            raise ValueError("first-output measurement has missing or incorrect summary")
        return observed - start


def workload_blocks(profile):
    if profile == "long":
        block = b"\xff\xff\x07" + b"\xff" * 65534
        repeats = 1024
        expected = b"7 1024 67106816 17112238080\n"
    elif profile in ("mixed", "single-key", "adjacent-eight", "spaced-eight"):
        repeats = 2048
        frames = []
        groups = {}
        for index in range(64):
            payload_key = (37 * index) % 64
            key = payload_key
            if profile == "single-key":
                key = 0
            elif profile == "adjacent-eight":
                key = payload_key % 8
            elif profile == "spaced-eight":
                key = 8 * (payload_key % 8)
            frames.append(bytes([0, 6, key, payload_key, 1, 2, 3, 255]))
            count, total = groups.get(key, (0, 0))
            groups[key] = count + 1, total + payload_key + 261
        block = b"".join(frames)
        expected = "".join(f"{k} {n*repeats} {5*n*repeats} {total*repeats}\n"
                           for k, (n, total) in sorted(groups.items())).encode()
    else:
        raise ValueError("unknown stream workload profile: " + profile)
    return block, repeats, expected


def write_workload(path, profile):
    block, repeats, expected = workload_blocks(profile)
    with path.open("wb") as stream:
        for _ in range(repeats):
            stream.write(block)
    return expected


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("requires macOS arm64 resource counters")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("profile", nargs="?", default="long",
                        choices=("long", "mixed", "single-key", "adjacent-eight", "spaced-eight"))
    parser.add_argument("--rotation-cycles", type=int, default=2,
                        help="complete forward and reverse rotations over all five implementations")
    args = parser.parse_args()
    if args.rotation_cycles < 1:
        parser.error("rotation cycles must be positive")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().parent
    identify = runpy.run_path(str(Path(__file__).resolve().parents[1] / "solo5-build-inputs.py"))["shared_inputs"]
    build_inputs = identify()
    fixtures = fixture_inputs(source, "check.py")
    corpus = out / "input.bin"
    profile = args.profile
    expected = write_workload(corpus, profile)
    report = dict(profile=profile, scope="fresh process, warm file cache, includes launch, read, parse and output",
                  system=version("uname", "-a"), hardware=version("sysctl", "-n", "hw.model"),
                  chip=version("sysctl", "-n", "machdep.cpu.brand_string"),
                  os=version("sw_vers"), input_sha256=digest(corpus), bytes=corpus.stat().st_size,
                  expected_output=expected.decode(), compilers={}, samples=[])
    for name, ext, flags in [
        ("rust", "rs", ["rustc", "-O", "-C", "overflow-checks=yes"]),
        ("nim", "nim", ["nim", "c", "-d:release", "--overflowChecks:on",
                        "--nimcache:" + str(out / "nimcache")])]:
        src = source / ("reference." + ext)
        binary = out / name
        cmd = (flags + [str(src), "-o", str(binary)] if name == "rust" else
               flags + ["--out:" + str(binary), str(src)])
        started = time.monotonic_ns()
        subprocess.run(cmd, check=True, timeout=180, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        build_ns = time.monotonic_ns() - started
        report["compilers"][name] = dict(version=version(flags[0], "--version"),
            executable=shutil.which(flags[0]), command=cmd, build_ns=build_ns,
            source_sha256=digest(src), binary_sha256=digest(binary))
        subprocess.run([sys.executable, source / "check.py", binary], check=True, timeout=120)

    binary = out / "fenrir"
    cmd = ["sh", str(source / "build-mac.sh"), str(binary)]
    started = time.monotonic_ns()
    subprocess.run(cmd, check=True, timeout=180)
    root = source.parents[1]
    inputs = [source / filename for filename in ("processor.fen", "stream.fen", "stream-main.c", "stream-darwin.c", "stream-io.h",
              "build-stream.mjs", "build-mac.sh")]
    inputs += [root / filename for filename in build_inputs]
    report["compilers"]["fenrir"] = dict(command=cmd, build_ns=time.monotonic_ns() - started,
        clang=version("clang", "--version"), binary_sha256=digest(binary),
        sources={str(path.relative_to(root)): digest(path) for path in inputs})
    subprocess.run([sys.executable, source / "check.py", binary], check=True, timeout=120)

    jit = Path(os.environ.get("FENRIR_SHEN_JIT", root / "build/toolchain/shen-jit-0.7")).resolve()
    env = dict(os.environ, FENRIR_SHEN_JIT=str(jit))
    shen = out / "shen"
    subprocess.run(["sh", source / "build-shen.sh", shen], check=True)
    subprocess.run([sys.executable, source / "check.py", shen], env=env, check=True, timeout=120)
    report["compilers"]["shen"] = dict(version=version(jit / "bin/shen-jit", "--version"),
        runtime_sha256=digest(jit / "bin/shen-jit"), ffi_sha256=digest(jit / "lib/ffi.shen"),
        source_sha256=digest(out / "shen.shen"), launcher_sha256=digest(shen))

    koka = os.environ.get("KOKA", "koka")
    for name in ("reference.kk", "koka-io.c"):
        shutil.copyfile(source / name, out / name)
    cmd = [koka, "-O2", "-o", str(out / "koka"), "reference.kk"]
    started = time.monotonic_ns()
    subprocess.run(cmd, cwd=out, check=True, timeout=180)
    (out / "koka").chmod(0o700)
    report["compilers"]["koka"] = dict(command=cmd, version=version(koka, "--version"),
        build_ns=time.monotonic_ns() - started, source_sha256=digest(out / "reference.kk"),
        adapter_sha256=digest(out / "koka-io.c"), binary_sha256=digest(out / "koka"))
    subprocess.run([sys.executable, source / "check.py", out / "koka"], check=True, timeout=120)

    def sample(name, pair, order, memory=False, startup=False):
        command = [out / name]
        if memory:
            command = ["/usr/bin/time", "-l", *command]
        with (Path(os.devnull) if startup else corpus).open("rb") as stream:
            start = time.monotonic_ns()
            result = subprocess.run(command, env=env, stdin=stream, capture_output=True, timeout=30, check=True)
            elapsed = time.monotonic_ns() - start
        if result.stdout != (b"" if startup else expected):
            raise ValueError("summary mismatch")
        row = dict(language=name, pair=pair, order=order, wall_ns=elapsed,
                   output_sha256=hashlib.sha256(result.stdout).hexdigest())
        if memory:
            counters = result.stderr.decode()
            peak = re.search(r"^\s*(\d+)\s+maximum resident set size", counters, re.M)
            if not peak:
                raise ValueError("missing Darwin peak RSS")
            row.update(peak_rss_bytes=int(peak[1]), raw_counters=counters)
        return row

    languages = ("rust", "nim", "shen", "koka", "fenrir")
    report["startup"] = [sample(name, -1, i, startup=True) for i, name in enumerate(languages)]
    report["warmups"] = [sample(name, -1, i) for i, name in enumerate(languages)]
    pairs = 2 * len(languages) * args.rotation_cycles
    report["rotation_cycles"] = args.rotation_cycles
    for i in range(pairs):
        shift = i % len(languages)
        names = languages[shift:] + languages[:shift]
        if (i // len(languages)) % 2:
            names = names[::-1]
        rows = [sample(name, i, j) for j, name in enumerate(names)]
        report["samples"].extend(rows)
    report["median_mib_per_s"] = {
        name: report["bytes"] / 2**20 * 1e9 / statistics.median(
            row["wall_ns"] for row in report["samples"] if row["language"] == name)
        for name in languages}
    report["memory_samples"] = [sample(row["language"], row["pair"], row["order"], memory=True)
                                for row in report["samples"]]
    report["first_output_samples"] = [
        dict(language=row["language"], pair=row["pair"], order=row["order"],
             first_output_ns=first_output([out / row["language"]], corpus, expected, env))
        for row in report["samples"]]
    report["median_first_output_ns"] = {
        name: statistics.median(row["first_output_ns"] for row in report["first_output_samples"]
                                if row["language"] == name)
        for name in languages}
    profiled = out / "fenrir-profile"
    subprocess.run(["sh", source / "build-mac.sh", profiled, "fenrir-profile"], check=True, timeout=180)
    with corpus.open("rb") as stream:
        profile_run = subprocess.run([profiled], stdin=stream, capture_output=True, check=True, timeout=30)
    heap = json.loads(profile_run.stderr)
    if profile_run.stdout != expected or heap["bytes"] != report["bytes"]:
        raise ValueError("profiled stream input or output differs")
    report["fenrir_heap"] = dict(**heap, binary_sha256=digest(profiled),
                                allocations_per_mib=heap["allocations"] * 2**20 / heap["bytes"])
    fastest = max(("rust", "nim", "shen", "koka"), key=report["median_mib_per_s"].get)
    def elapsed_ratio(name, reference):
        samples = report["samples"]
        times = {(row["pair"], row["language"]): row["wall_ns"] for row in samples}
        values = [times[i, name] / times[i, reference] for i in range(pairs)]
        rng = random.Random(1147)
        bootstrap = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10000))
        return dict(paired_median=statistics.median(values), bootstrap95=[bootstrap[249], bootstrap[9749]], seed=1147)

    for name in ("nim", "fenrir"):
        report[name + "_over_rust"] = elapsed_ratio(name, "rust")
    peaks = {name: statistics.median(row["peak_rss_bytes"] for row in report["memory_samples"]
                                     if row["language"] == name) for name in languages}
    report["fastest_measured_reference"] = dict(language=fastest, elapsed=elapsed_ratio("fenrir", fastest), median_rss_bytes=peaks,
                                                 fenrir_rss_ratio=peaks["fenrir"] / peaks[fastest])
    if identify() != build_inputs:
        raise ValueError("shared compiler or runtime sources changed during measurement")
    if fixture_inputs(source, "check.py") != fixtures:
        raise ValueError("stream correctness fixtures changed during measurement")
    report["correctness_fixture_sha256"] = fixtures
    report["shared_build_inputs"] = build_inputs
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(out / "report.json", report["median_mib_per_s"], report["nim_over_rust"])


if __name__ == "__main__":
    main()
