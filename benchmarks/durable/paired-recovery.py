"""Measure the shared Mac recovery scenario in rotated worker order."""
import argparse
import json
from pathlib import Path
import random
from runpy import run_path
import statistics

from_repeat = run_path(str(Path(__file__).with_name("repeat-recovery.py")))
checked = run_path(str(Path(__file__).with_name("compare-recovery.py")))["checked"]


sustained_growth = run_path(str(Path(__file__).with_name("assess-paced.py")))["sustained_growth"]


def shared_components(sample):
    build = Path(sample["build"])
    hashes = sample["build_sha256"]
    components = {name: hashes[str(build / name)] for name in ("sqlite-port", "otp.txt")}
    # These OTP modules implement the supervisor, transport and persistent service.
    # The application worker and its image intentionally vary across implementations.
    service = Path(__file__).resolve().parents[2] / "host/service/src"
    for source in sorted(service.glob("*.erl")):
        name = source.with_suffix(".beam").name
        components[name] = hashes[str(build / "ebin" / name)]
    adapter = "fenrir_port_reference.beam"
    components[adapter] = hashes[str(build / "ebin" / adapter)]
    components["scenario"] = sample["scenario_sha256"]
    return components


def service_resources(case):
    snapshots = json.loads((case / "resources.json").read_bytes())
    before, after = snapshots["before_load"], snapshots["after_load"]
    for sample in (before, after):
        for field in ("beam_pid", "sqlite_pid", "beam_rss_bytes", "sqlite_rss_bytes", "db_file_bytes"):
            if type(sample.get(field)) is not int or sample[field] <= 0:
                raise ValueError(f"{case}: invalid resource sample {field}")
        for field in ("wal_file_bytes", "shm_file_bytes"):
            value = sample[field]
            if value is not None and (type(value) is not int or value < 0):
                raise ValueError(f"{case}: invalid file size {field}")
        if sample["beam_pid"] == sample["sqlite_pid"]:
            raise ValueError(f"{case}: BEAM and SQLite must be distinct processes")
        location = sample.get("worker_location")
        if location == "external_process":
            if any(type(sample.get(key)) is not int or sample[key] <= 0
                   for key in ("worker_pid", "worker_rss_bytes")):
                raise ValueError(f"{case}: invalid external worker measurement")
            if sample["worker_pid"] in (sample["beam_pid"], sample["sqlite_pid"]):
                raise ValueError(f"{case}: worker PID overlaps another measured process")
        elif (location not in (None, "beam", "per_request_guest")
              or "worker_pid" in sample or "worker_rss_bytes" in sample):
            raise ValueError(f"{case}: inconsistent worker memory accounting")
    if any(before.get(key) != after.get(key) for key in ("worker_location", "worker_pid")):
        raise ValueError(f"{case}: worker changed during the measured commits")
    if any(before[key] != after[key] for key in ("beam_pid", "sqlite_pid")):
        raise ValueError(f"{case}: process changed during the measured commits")
    return snapshots


def measure(builds, output, blocks, workload="recovery"):
    workers = {}
    expected = None
    for build in builds:
        history = checked(build)
        worker = history["worker_implementation"]
        contract = [history[key] for key in ("schema", "tenants", "scenario", "event_count", "events_sha256")]
        if worker in workers or expected is not None and contract != expected:
            raise ValueError("expected distinct workers with identical accepted histories")
        expected = contract
        workers[worker] = build
    subject = "fenrir-native-mac"
    if subject not in workers or len(workers) < 2:
        raise ValueError("expected Fenrir and at least one reference worker")
    output.mkdir(parents=True, exist_ok=False)
    names = list(workers)
    pairs = []
    resource_blocks = []
    growing = {name: [] for name in names}
    paced_verdicts = {name: [] for name in names}
    runtime = None
    host = None
    sqlite_connection = None
    shared = None
    builds_by_worker = {}
    schedule = None
    measured_contract = None
    for block in range(blocks):
        offset = block % len(names)
        order = names[offset:] + names[:offset]
        row = {}
        resources = {}
        for name in order:
            dest = output / str(block) / name
            from_repeat["run"](workers[name], dest, 1, workload)
            measured = from_repeat["history_summary"](dest / "0/history.json")
            contract = [measured[k] for k in ("schema", "tenants", "scenario", "event_count", "events_sha256")]
            if measured_contract is not None and contract != measured_contract:
                raise ValueError(f"measured history differs at block {block}, worker {name}")
            measured_contract = contract
            sample = json.loads((dest / "summary.json").read_text())
            if sample["worker"] != name or sample["workload"] != workload or sample["samples"] != 1:
                raise ValueError(f"wrong measurement at block {block}, worker {name}")
            components = shared_components(sample)
            if shared is not None and components != shared:
                changed = sorted(k for k in shared.keys() | components.keys() if shared.get(k) != components.get(k))
                raise ValueError(f"block {block}, worker {name}: differing shared components: {', '.join(changed)}")
            shared = components
            identity = sample["build_sha256"]
            if name in builds_by_worker and builds_by_worker[name] != identity:
                raise ValueError(f"worker build changed at block {block}, worker {name}")
            builds_by_worker[name] = identity
            if host is not None and sample["host"] != host:
                raise ValueError("Mac host differs across paired samples")
            host = sample["host"]
            if runtime is not None and sample["runtime"] != runtime:
                raise ValueError(f"OTP runtime differs at block {block}, worker {name}")
            if sqlite_connection is not None and sample["sqlite_connection"] != sqlite_connection:
                raise ValueError(f"SQLite connection settings differ at block {block}, worker {name}")
            sqlite_connection = sample["sqlite_connection"]
            runtime = sample["runtime"]
            if schedule is not None and sample["schedule"] != schedule:
                raise ValueError("offered schedule differs across paired samples")
            schedule = sample["schedule"]
            if workload == "paced-commits":
                paced = json.loads((dest / "0/paced.json").read_text())
                if (paced["rate"], paced["seconds"]) != (schedule["rate"], schedule["seconds"]):
                    raise ValueError("paced assessment differs from offered schedule")
                growing[name].append(sustained_growth(paced["outstanding_by_second"]))
                paced_verdicts[name].append(paced["offered_rate_verdict"])
            if workload in ("fresh-commits", "paced-commits"):
                resources[name] = service_resources(dest / "0")
            row[name] = sample["median_us"]
        pairs.append(row)
        if resources:
            resource_blocks.append(dict(order=order, workers=resources))
    rng = random.Random(1147)
    ratios = {}
    for reference in names:
        if reference == subject:
            continue
        ratios[reference] = {}
        for metric in pairs[0][subject]:
            if any(row[reference][metric] == 0 for row in pairs):
                ratios[reference][metric] = None
                continue
            values = [row[subject][metric] / row[reference][metric] for row in pairs]
            medians = sorted(statistics.median(rng.choices(values, k=blocks)) for _ in range(10000))
            ratios[reference][metric] = dict(median=statistics.median(values),
                                             bootstrap95=[medians[249], medians[9749]])
    report = dict(workload=workload, schedule=schedule, blocks=blocks, runtime=runtime, host=host, sqlite_connection=sqlite_connection, shared_sha256=shared, build_sha256=builds_by_worker,
                  history_event_count=measured["event_count"], history_events_sha256=measured["events_sha256"], samples_us=pairs, fenrir_over_reference=ratios, bootstrap_seed=1147)
    report["matched_single_core_budget"] = (host["logical_cpu_max"] == 1 and
                                          runtime["schedulers_online"] == 1 and
                                          runtime["dirty_cpu_schedulers_online"] == 1)
    if resource_blocks:
        report["resource_blocks"] = resource_blocks
    if workload == "paced-commits":
        profiled = runtime.get("profile_vfs_time", False)
        report["profile_vfs_time"] = profiled
        report["offered_rate_observations"] = paced_verdicts
        report["sustained_backlog_growth"] = growing
        report["replicated_failed_upper_bound"] = {
            name: schedule["rate"] if not profiled and len(flags) >= 10 and all(flags) else None
            for name, flags in growing.items()}
        report["replicated_sustained_lower_bound"] = {
            name: schedule["rate"] if not profiled and len(verdicts) >= 10 and
            all(v == "sustained-at-offered-rate" for v in verdicts) else None
            for name, verdicts in paced_verdicts.items()}
    (output / "paired.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("builds", nargs="+", type=Path)
    parser.add_argument("--blocks", type=int, default=10)
    parser.add_argument("--workload", choices=["recovery", "backlog", "fresh-commits", "paced-commits"], default="recovery")
    args = parser.parse_args()
    if args.blocks < 1:
        parser.error("blocks must be positive")
    measure(args.builds, args.output, args.blocks, args.workload)
