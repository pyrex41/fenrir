"""Measure paired guest execution over one warm block image in an ARM64 VM."""
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
from measure import digest, fixture_inputs, version, write_workload


def profile_medians(samples):
    medians = {}
    for name in ("fenrir", "c"):
        outside_io = [row["elapsed_ns"][name] - row["read_ns"][name] - row["write_ns"][name]
                      for row in samples]
        if any(duration < 0 for duration in outside_io):
            raise ValueError("measured reads and writes exceed guest elapsed time")
        medians[name] = {field: statistics.median(row[field][name] for row in samples)
                         for field in ("elapsed_ns", "read_ns", "write_ns")}
        medians[name]["outside_read_write_ns"] = statistics.median(outside_io)
    return medians


def main(out):
    helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "solo5-build-inputs.py"))
    identify = helpers["shared_inputs"]
    cpu = helpers["benchmark_cpu"]()
    inputs = identify()
    out.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().parent
    fixtures = fixture_inputs(source, "check-spt.py")
    container = os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
    image_id = version("docker", "image", "inspect", "--format", "{{.Id}}", container)
    env = dict(os.environ, FENRIR_SOLO5_IMAGE=image_id)
    guests = {}
    for name in ("fenrir", "c"):
        image = out / (name + ".spt")
        subprocess.run(["sh", source / "build-spt.sh", image, name], env=env, check=True, timeout=180)
        subprocess.run([sys.executable, source / "check-spt.py", image], env=env, check=True, timeout=180)
        guests[name] = digest(image)
    profile = sys.argv[2] if len(sys.argv) > 2 else "long"
    disk = out / "corpus"
    expected = write_workload(disk, profile)
    expected_lines = expected.decode().splitlines()
    size = disk.stat().st_size
    pairs = [("fenrir", "c") if i % 2 == 0 else ("c", "fenrir") for i in range(13)]
    command = ["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64", "--cpuset-cpus", cpu,
               "-v", f"{out}:/bench:ro", "--entrypoint", "sh", image_id, "-ec",
               'cp /bench/corpus /tmp/input; size=$1; mode=$2; shift 2; for name do '
               '/usr/bin/time -f %M -o /tmp/rss /opt/solo5-install/bin/solo5-spt --block:input=/tmp/input "/bench/$name.spt" '
               '--solo5:quiet "$mode$size"; cat /tmp/rss; done', "sh", str(size)]
    def collect(mode, orders, console, fields):
        run = subprocess.run(command + [mode, *(n for pair in orders for n in pair)], text=True,
                             capture_output=True, check=True, timeout=180)
        (out / console).write_text(run.stdout)
        lines = iter(run.stdout.splitlines())
        samples = []
        for pair in orders:
            sample = {"order": pair, "peak_rss_bytes": {}, **{field: {} for field in fields}}
            for name in pair:
                if [next(lines) for _ in expected_lines] != expected_lines:
                    raise ValueError("incorrect guest output")
                for field in fields:
                    match = re.fullmatch(field + r" (0|[1-9][0-9]*)", next(lines))
                    if not match:
                        raise ValueError(f"missing guest {field}")
                    sample[field][name] = int(match[1])
                elapsed = sample["elapsed_ns"][name]
                if elapsed <= 0 or (mode == "p" and
                        (sample["first_output_ns"][name] > elapsed or
                         sample["read_ns"][name] + sample["write_ns"][name] > elapsed)):
                    raise ValueError(f"inconsistent guest clock intervals for {name}")
                peak_kib = int(next(lines))
                if peak_kib <= 0:
                    raise ValueError(f"invalid peak RSS for {name}")
                sample["peak_rss_bytes"][name] = 1024 * peak_kib
            samples.append(sample)
        if next(lines, None) is not None:
            raise ValueError("unexpected guest output")
        return samples

    samples = collect("t", pairs, "console.txt", ("elapsed_ns",))
    io_fields = ("read_ns", "write_ns", "first_output_ns", "elapsed_ns")
    profile_samples = collect("p", pairs, "profile-console.txt", io_fields)
    instrumented = out / "fenrir-profile.spt"
    subprocess.run(["sh", source / "build-spt.sh", instrumented, "fenrir-profile"],
                   env=env, check=True, timeout=180)
    heap_fields = ("allocations", "collections", "collection_ns")
    heap_run, = collect("p", [("fenrir-profile",)], "heap-console.txt", heap_fields + io_fields)
    heap = {field: heap_run[field]["fenrir-profile"] for field in heap_fields + io_fields}
    if heap["collection_ns"] + heap["read_ns"] + heap["write_ns"] > heap["elapsed_ns"]:
        raise ValueError("guest heap and I/O durations exceed total")
    heap.update(binary_sha256=digest(instrumented), bytes=size,
                allocations_per_mib=heap["allocations"] * 2**20 / size)
    ratios = [s["elapsed_ns"]["fenrir"] / s["elapsed_ns"]["c"] for s in samples[1:]]
    rng = random.Random(1147)
    boot = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
    report = dict(profile=profile, hardware=version("sysctl", "-n", "hw.model"), host=version("uname", "-a"),
                  container=image_id, guest_cpu=cpu, guest_sha256=guests, bytes=size, input_sha256=digest(disk),
                  scope="guest monotonic clock around stream_process including sector reads and summary writes",
                  expected_output_sha256=hashlib.sha256(expected).hexdigest(),
                  fenrir_heap=heap, profile_warmup=profile_samples[0], profile_samples=profile_samples[1:],
                  profile_medians_ns=profile_medians(profile_samples[1:]),
                  median_first_output_ns={name: statistics.median(s["first_output_ns"][name]
                      for s in profile_samples[1:]) for name in ("fenrir", "c")},
                  warmup=samples[0], samples=samples[1:], median_fenrir_over_c=statistics.median(ratios),
                  paired_bootstrap95=[boot[249], boot[9749]])
    if inputs != identify():
        raise ValueError("shared compiler or runtime sources changed during measurement")
    report["memory_scope"] = "Linux maximum resident set size of the Solo5 tender process including the guest"
    if fixture_inputs(source, "check-spt.py") != fixtures:
        raise ValueError("stream correctness fixtures changed during measurement")
    report["correctness_fixture_sha256"] = fixtures
    report["shared_build_inputs"] = inputs
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(out / "report.json", report["median_fenrir_over_c"], report["paired_bootstrap95"])


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
