"""Combine verified Solo5 durable-worker blocks across offered commit rates."""
import argparse
import json
from pathlib import Path
from runpy import run_path

here = Path(__file__).resolve().parent
paired = run_path(str(here / "paired-paced-spt.py"))
capacity = run_path(str(here.parent / "http/capacity.py"))


def replay_block(folder, index, recorded):
    directories = []
    for worker in paired["workers"]:
        with (folder / f"{index}-{worker}.log").open() as log:
            origin = log.readline().rstrip("\n")
        if not origin.startswith("Recovery evidence: "):
            raise ValueError("missing worker run location")
        directories.append(Path(origin.removeprefix("Recovery evidence: ")))
    actual = paired["compare"](*directories)
    if actual["shared"] != recorded["shared"] or len(recorded["samples"]) != 2:
        raise ValueError("block conditions differ from independently replayed evidence")
    for sample, verified in zip(recorded["samples"], actual["samples"]):
        paired["verify_original_sample"](sample, verified)
    actual["order"] = recorded["order"]
    return actual


def summarize(folders, replay=False):
    measurements = {}
    identity = None
    seen = set()
    for folder in folders:
        files = sorted((f for f in folder.glob("*.json") if f.stem.isdecimal()),
                       key=lambda f: int(f.stem))
        if not files or [f.stem for f in files] != [str(i) for i in range(len(files))]:
            raise ValueError(f"{folder}: expected consecutive verified blocks starting at zero")
        pairs = [json.loads(f.read_bytes()) for f in files]
        if replay:
            pairs = [replay_block(folder, index, record) for index, record in enumerate(pairs)]
        result = paired["summarize"](pairs)
        shared = pairs[0]["shared"]
        if result["profile_vfs_time"]:
            raise ValueError("capacity comparisons require unprofiled runs")
        rate, seconds = shared["rate"], shared["seconds"]
        if rate in measurements:
            raise ValueError("duplicate offered rate")
        conditions = dict(shared)
        del conditions["rate"]
        history = dict(conditions["history"])
        store = dict(conditions["store"])
        count = rate * seconds
        if (history.pop("event_count") != count + 1 or store.pop("commits") != count
                or store.pop("tenant_counts") != [(count + 1) // 2, count // 2]):
            raise ValueError("recorded history or database size differs from schedule")
        del history["events_sha256"]
        conditions.update(history=history, store=store,
                          guests=[s["guest_sha256"] for s in pairs[0]["samples"]])
        if identity is not None and conditions != identity:
            raise ValueError("deployments or durations differ across offered rates")
        identity = conditions
        for pair in pairs:
            for sample in pair["samples"]:
                path = Path(sample["directory"]).resolve()
                if path in seen:
                    raise ValueError("worker run appears at multiple rates")
                seen.add(path)
        measurements[rate] = result
    estimates = {}
    for name, worker in zip(("fenrir", "c"), paired["workers"]):
        observations = {}
        for rate, result in measurements.items():
            clear = result["replicated_sustained_lower_bound"][worker] == rate
            growing = result["replicated_failed_upper_bound"][worker] == rate
            if clear and growing:
                raise ValueError("contradictory backlog evidence")
            observations[rate] = ["sustained-at-offered-rate" if clear else
                                  "growing-backlog" if growing else "undetermined"]
        estimates[name] = capacity["bounds"](observations)
    rate = None
    if all(v is not None for estimate in estimates.values() for v in estimate.values()):
        rate = 7 * min(estimate["sustained"] for estimate in estimates.values()) // 10
    latency = measurements.get(rate, {}).get("p99_comparison_at_offered_rate", "undetermined")
    return dict(target="solo5-arm64-spt", evidence="replayed" if replay else "recorded", reference="c", capacity_bounds=estimates,
                two_thirds_capacity_comparison=capacity["throughput_comparison"](estimates),
                paired_latency_rate=rate, p99_at_paired_latency_rate=latency,
                observations=measurements, conditions=identity)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", type=Path, nargs="+")
    parser.add_argument("--replay", action="store_true",
                        help="rerun the history checker and verify binary digests, pacing and SQLite contents")
    args = parser.parse_args()
    print(json.dumps(summarize(args.folders, args.replay), indent=2))
