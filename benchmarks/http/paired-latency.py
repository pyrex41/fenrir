"""Summarize paired HTTP p99 ratios at one rate against a preselected reference."""
import argparse
import hashlib
import json
from pathlib import Path
import random
from runpy import run_path
import statistics

assessment_module = run_path(str(Path(__file__).with_name("assess-rate.py")))
assess = assessment_module["assess"]
verify_origin = assessment_module["verify_sample_origin"]


def summarize(folder, reference, rate):
    env = json.loads((folder / "environment.json").read_text())
    environment_digest = hashlib.sha256((folder / "environment.json").read_bytes()).hexdigest()
    exclusions_file = folder / "exclusions.json"
    exclusions = json.loads(exclusions_file.read_text()) if exclusions_file.exists() else {}
    references = {"mac": {"rust", "nim"}, "solo5": {"c"}}
    if reference not in references[env["target"]]:
        raise ValueError("reference does not match target")
    if env["rates"].count(rate) != 1:
        raise ValueError("expected a single matching rate in each block")
    rate_index = env["rates"].index(rate)
    pairs = []
    for block in range(env["blocks"]):
        index = block * len(env["rates"]) + rate_index
        samples = {}
        host_cpu = {}
        for name in ("fenrir", reference):
            path = folder / f"{index}-{name}-{rate}.json"
            if path.name in exclusions:
                raise ValueError(f"excluded sample {path.name}: {exclusions[path.name]}")
            row = json.loads(path.read_text())
            verify_origin(row, env, name, block, rate_index, environment_digest)
            if (row["Block"], row["RateIndex"], row["Rate"], row["Seconds"], row["Connections"]) != (
                    block, rate_index, rate, env["seconds"], env["connections"]):
                raise ValueError(f"mismatched workload in {path}")
            result = assess(row)
            if result["verdict"] not in ("sustained-at-offered-rate", "short-run") or row["P99ns"] <= 0:
                raise ValueError(f"ineligible latency sample in {path}")
            samples[name] = row["P99ns"]
            resources = result["process_resources"]
            host_cpu[name] = resources["host_cpu"] if resources is not None else None
        pairs.append(dict(block=block, p99_ns=samples, ratio=samples["fenrir"] / samples[reference],
                          host_cpu=host_cpu))
    ratios = [p["ratio"] for p in pairs]
    if not ratios:
        raise ValueError("no paired samples")
    interval = None
    if len(ratios) >= 10:
        rng = random.Random(1147)
        medians = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
        interval = [medians[249], medians[9749]]
    return dict(target=env["target"], sample_origin_version=env.get("sample_origin_version"),
                reference=reference, rate=rate, seconds=env["seconds"],
                pairs=pairs, paired_median=statistics.median(ratios), bootstrap95=interval,
                seed=1147, meets_duration_and_pair_count=env["seconds"] >= 600 and len(pairs) >= 10)


def service_gate(capacity_blocks, throughput, qualified_latency, latency, *, origin_version):
    if type(origin_version) is not int or origin_version != 1:
        return "undetermined"
    # Capacity bounds require agreement across all blocks at each contributing rate.
    if capacity_blocks >= 10 and throughput == "below-threshold":
        return "failed"
    if capacity_blocks < 10 or not qualified_latency:
        return "undetermined"
    if latency == "above-threshold":
        return "failed"
    if throughput == latency == "meets-threshold":
        return "passed"
    return "undetermined"


def latency_environment(env):
    # The chosen load and sample count change between capacity scouting and
    # qualification. Worker identities and measurement conditions must agree.
    required = {"target", "connections", "host", "cpu", "go", "checkout_sha256"}
    if env["target"] == "solo5":
        required.update(("solo5_container", "guest_memory_budget_bytes"))
    if required - env.keys():
        raise ValueError("incomplete capacity or latency environment")
    assessment_module["darwin_cpu_limit"](env)
    identity = dict(env)
    for field in ("rates", "blocks", "seconds"):
        del identity[field]
    identity["binaries"] = assessment_module["binary_identities"](env)
    return identity


def capacity_linked(folder, capacity_folder, *additional):
    capacity = run_path(str(Path(__file__).with_name("capacity.py")))["summarize"](capacity_folder, *additional)
    reference, rate = capacity["reference"], capacity["paired_latency_rate"]
    if reference is None or rate is None:
        raise ValueError("capacity experiment has not resolved the reference and latency rate")
    latency_env = json.loads((folder / "environment.json").read_text())
    capacity_env = json.loads((capacity_folder / "environment.json").read_text())
    if latency_environment(latency_env) != latency_environment(capacity_env):
        raise ValueError("capacity and latency environments differ")
    result = summarize(folder, reference, rate)
    decision = "undetermined"
    if result["meets_duration_and_pair_count"]:
        low, high = result["bootstrap95"]
        if high <= 1.5:
            decision = "meets-threshold"
        elif low > 1.5:
            decision = "above-threshold"
    result.update(capacity_folder=str(capacity_folder), capacity_folders=[str(p) for p in (capacity_folder, *additional)],
                  two_thirds_capacity_comparison=capacity["two_thirds_capacity_comparison"],
                  paired_latency_comparison=decision, capacity_blocks=capacity["capacity_blocks"],
                  throughput_and_latency_gate=service_gate(
                      capacity["capacity_blocks"], capacity["two_thirds_capacity_comparison"],
                      result["meets_duration_and_pair_count"], decision, origin_version=capacity["sample_origin_version"]))
    result["darwin_logical_cpu_max"] = capacity["darwin_logical_cpu_max"]
    if result["target"] == "mac":
        result["single_core_throughput_and_latency_gate"] = (
            result["throughput_and_latency_gate"]
            if result["darwin_logical_cpu_max"] == 1 else "undetermined")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    parser.add_argument("reference", nargs="?")
    parser.add_argument("rate", type=int, nargs="?")
    parser.add_argument("--capacity", type=Path, nargs="+")
    args = parser.parse_args()
    if args.capacity is not None and args.reference is None and args.rate is None:
        report = capacity_linked(args.folder, *args.capacity)
    elif args.capacity is None and args.reference is not None and args.rate is not None:
        report = summarize(args.folder, args.reference, args.rate)
    else:
        parser.error("supply either REFERENCE RATE or --capacity SWEEP_DIR")
    print(json.dumps(report, indent=2))
