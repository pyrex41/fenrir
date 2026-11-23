"""Score matched Mac durable-worker campaigns at distinct offered rates."""
import argparse
import json
from pathlib import Path
import random
from runpy import run_path
import statistics

capacity = run_path(str(Path(__file__).resolve().parents[1] / "http/capacity.py"))
subject = "fenrir-native-mac"
references = {"rust", "nim", "erlang", "elixir"}


def load_report(path, replay):
    read = lambda p: json.loads(p.read_bytes())
    report = read(path)
    if not replay:
        return report
    here = Path(__file__).resolve().parent
    paired = run_path(str(here / "paired-recovery.py"))
    assessor = run_path(str(here / "assess-paced.py"))
    check_store = run_path(str(here / "check-fresh-store.py"))["check"]
    rate, seconds = (report["schedule"][k] for k in ("rate", "seconds"))
    count = rate * seconds
    for block, row in enumerate(report["samples_us"]):
        for name, metrics in row.items():
            case = path.parent / str(block) / name / "0"
            sample = read(case.parent / "summary.json")
            history = paired["checked"](case)
            if (history["events_sha256"] != report["history_events_sha256"]
                    or history["event_count"] != report["history_event_count"]
                    or history["worker_implementation"] != name or history["scenario"] != "paced-commits"):
                raise ValueError(f"{case}: history differs from paired report")
            timing = read(case / "timings.json")
            assessment = assessor["check_workload"](timing, history["event_count"], count, rate)
            if ("vfs_time_ns" in timing or assessment != read(case / "paced.json")
                    or assessment["offered_rate_verdict"] != report["offered_rate_observations"][name][block]
                    or any(timing[k] != value for k, value in metrics.items())):
                raise ValueError(f"{case}: raw pacing differs from paired report")
            growth = assessor["sustained_growth"](assessment["outstanding_by_second"])
            if growth != report["sustained_backlog_growth"][name][block]:
                raise ValueError(f"{case}: backlog growth differs from paired report")
            if check_store(case / "jobs.db", count) != read(case / "store-check.json"):
                raise ValueError(f"{case}: replayed database differs")
            identity = paired["from_repeat"]["build_identity"](Path(sample["build"]), name)
            if (sample["worker"] != name or identity != report["build_sha256"][name]
                    or sample["build_sha256"] != identity or paired["shared_components"](sample) != report["shared_sha256"]
                    or any(sample[k] != report[k] for k in ("host", "runtime", "sqlite_connection", "schedule"))
                    or paired["from_repeat"]["comparison"]["check_sqlite_settings"](timing["sqlite_connection"])
                    != report["sqlite_connection"]):
                raise ValueError(f"{case}: worker build or environment differs from paired report")
    return report


def summarize(reports):
    identity = None
    observations = {}
    samples = {}
    for report in reports:
        rate, seconds = (report["schedule"][k] for k in ("rate", "seconds"))
        if (report["workload"] != "paced-commits" or rate in samples
                or report["history_event_count"] != rate * seconds + 1
                or report["runtime"].get("profile_vfs_time") or report.get("profile_vfs_time")):
            raise ValueError("expected distinct unprofiled paced campaigns with complete histories")
        shared = {key: report.get(key) for key in ("runtime", "host", "sqlite_connection", "shared_sha256", "build_sha256")}
        if not all(shared[k] for k in ("runtime", "sqlite_connection", "shared_sha256", "build_sha256")):
            raise ValueError("missing benchmark deployment identity")
        shared["seconds"] = seconds
        if identity is not None and identity != shared:
            raise ValueError("worker builds, host, runtime, SQLite or duration differ across campaigns")
        identity = shared
        rows = report["samples_us"]
        blocks = report["blocks"]
        if not rows or len(rows) != blocks:
            raise ValueError("missing paired sample")
        order = report.get("resource_blocks", [])
        workers = order[0]["order"] if order else list(rows[0])
        if subject not in workers or not set(workers) <= references | {subject} or len(set(workers)) != len(workers) or len(workers) < 2:
            raise ValueError("expected Fenrir and recognized reference workers")
        if set(workers) != set(shared["build_sha256"]):
            raise ValueError("worker set differs from build identities")
        rotated = len(order) == blocks and all(
            b["order"] == workers[i % len(workers):] + workers[:i % len(workers)] for i, b in enumerate(order))
        eligible = blocks >= 10 and seconds >= 600 and rotated
        samples[rate] = rows
        for worker in workers:
            if any(set(row) != set(workers) or type(row[worker]["acknowledgement_p99_us"]) is not int
                   or row[worker]["acknowledgement_p99_us"] <= 0 for row in rows):
                raise ValueError("incomplete paired latency samples")
            outcomes = report["offered_rate_observations"][worker]
            growth = report.get("sustained_backlog_growth", {}).get(worker, [False] * blocks)
            if len(outcomes) != blocks or len(growth) != blocks:
                raise ValueError("missing backlog observations")
            verdicts = []
            for g, v in zip(growth, outcomes):
                if type(g) is not bool or v not in ("short-run", "sustained-at-offered-rate", "backlog-clearance-unconfirmed"):
                    raise ValueError("invalid backlog observation")
                if g and v == "sustained-at-offered-rate":
                    raise ValueError("contradictory backlog evidence")
                verdicts.append("growing-backlog" if g else v)
            observations.setdefault(worker, {})[rate] = verdicts if eligible else ["undetermined"]
    bounds = {("fenrir" if w == subject else w): capacity["bounds"](v) for w, v in observations.items()}
    host = identity["host"] or {}
    budget = (host.get("logical_cpu_max") == 1 and identity["runtime"]["schedulers_online"] == 1
              and identity["runtime"]["dirty_cpu_schedulers_online"] == 1)
    complete = set(bounds) == references | {"fenrir"}
    reference = capacity["select"](bounds) if complete and budget else None
    rate = interval = None
    latency = "undetermined"
    if reference and all(bounds[n][k] is not None for n in ("fenrir", reference) for k in ("sustained", "failed")):
        rate = 7 * min(bounds[n]["sustained"] for n in ("fenrir", reference)) // 10
        if rate in samples and all(all(v == "sustained-at-offered-rate" for v in observations[n][rate])
                                   for n in (subject, reference)):
            ratios = [row[subject]["acknowledgement_p99_us"] / row[reference]["acknowledgement_p99_us"]
                      for row in samples[rate]]
            rng = random.Random(1147)
            draws = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            interval = [draws[249], draws[9749]]
            if interval[1] <= 1.5:
                latency = "meets-threshold"
            elif interval[0] > 1.5:
                latency = "above-threshold"
    return dict(target="macos-arm64", matched_single_core_budget=budget, complete_reference_set=complete,
                capacity_bounds=bounds, reference=reference, paired_latency_rate=rate, p99_bootstrap95=interval,
                two_thirds_capacity_comparison=capacity["throughput_comparison"](bounds) if complete and budget else "undetermined",
                p99_at_paired_latency_rate=latency)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reports", type=Path, nargs="+", help="paired.json reports at distinct rates")
    parser.add_argument("--replay", action="store_true", help="verify recorded runs against retained raw evidence")
    args = parser.parse_args()
    result = summarize([load_report(p, args.replay) for p in args.reports])
    result["evidence"] = "replayed" if args.replay else "recorded"
    print(json.dumps(result, indent=2))
