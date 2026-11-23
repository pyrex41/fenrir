"""Run alternating Solo5 durable-service pairs and verify every completed block."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import random
from runpy import run_path
import statistics

here = Path(__file__).resolve().parent
root = here.parents[1]
compare = run_path(str(here / "compare-paced-spt.py"))["compare"]
recovery = run_path(str(here / "compare-recovery.py"))
run_group = recovery["run_group"]
workers = ("fenrir-native-spt", "c-native-spt")


def verify_original_sample(saved, replayed):
    # Older samples can reconstruct added metrics from their retained timestamps.
    later_fields = {"waiting_for_previous_commit_p99_us", "ready_to_dispatch_p99_us", "sustained_backlog_growth"}
    if replayed.keys() - saved.keys() - later_fields:
        raise ValueError("original worker sample is missing required measurements")
    for field, value in saved.items():
        if field not in replayed or type(value) is not type(replayed[field]) or value != replayed[field]:
            raise ValueError(f"original worker sample differs on {field}")


def summarize(pairs):
    if not pairs:
        raise ValueError("expected at least one verified pair")
    shared = pairs[0]["shared"]
    digests = [sample["guest_sha256"] for sample in pairs[0]["samples"]]
    seen = set()
    ratios = []
    cleared = {worker: True for worker in workers}
    growing = {worker: True for worker in workers}
    for block, pair in enumerate(pairs):
        expected_order = workers if block % 2 == 0 else workers[::-1]
        if tuple(pair["order"]) != expected_order:
            raise ValueError("recorded worker order does not alternate across blocks")
        samples = pair["samples"]
        if (pair["shared"] != shared or [s["guest_sha256"] for s in samples] != digests
                or tuple(s["worker"] for s in samples) != workers):
            raise ValueError("pair conditions or guest images changed between blocks")
        for sample in samples:
            location = Path(sample["directory"]).resolve()
            if location in seen:
                raise ValueError("reused run directory")
            seen.add(location)
            growing[sample["worker"]] &= sample.get("sustained_backlog_growth") is True
            cleared[sample["worker"]] &= sample["offered_rate_verdict"] == "sustained-at-offered-rate"
        if samples[1]["acknowledgement_p99_us"] <= 0:
            raise ValueError("reference p99 must be positive")
        ratios.append(samples[0]["acknowledgement_p99_us"] / samples[1]["acknowledgement_p99_us"])
    interval = None
    if len(pairs) >= 10:
        rng = random.Random(1147)
        bootstrap = sorted(statistics.median(rng.choices(ratios, k=len(pairs))) for _ in range(10000))
        interval = [bootstrap[249], bootstrap[9749]]
    profiled = shared.get("profile_vfs_time", False)
    replicated = shared["seconds"] >= 600 and len(pairs) >= 10 and not profiled
    latency = "undetermined"
    if replicated and all(cleared.values()):
        if interval[1] <= 1.5:
            latency = "meets-threshold"
        elif interval[0] > 1.5:
            latency = "above-threshold"
    return dict(profile_vfs_time=profiled, blocks=len(pairs), rate=shared["rate"], seconds=shared["seconds"],
                p99_comparison_at_offered_rate=latency,
                replicated_sustained_lower_bound={w: shared["rate"] if cleared[w] and replicated else None
                                                  for w in workers},
                replicated_failed_upper_bound={w: shared["rate"] if growing[w] and replicated else None
                                               for w in workers},
                fenrir_over_c_p99_ratios=ratios, paired_median=statistics.median(ratios),
                bootstrap95=interval, bootstrap_seed=1147)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rate", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--blocks", type=int, default=10)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--resume", action="store_true",
                      help="revalidate recorded trials and continue the interrupted campaign")
    mode.add_argument("--recheck", action="store_true",
                        help="replay the workers recorded in the existing campaign logs")
    args = parser.parse_args()
    if min(args.rate, args.seconds, args.blocks) < 1:
        parser.error("rate, duration and blocks must be positive")
    if args.recheck or args.resume:
        if not args.output.is_dir():
            parser.error("resume or recheck requires an existing campaign directory")
    else:
        args.output.mkdir(parents=True, exist_ok=False)
    with (args.output / ".campaign.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another runner is using this campaign directory")
        run_campaign(args)


def run_campaign(args):
    env = dict(os.environ, FENRIR_COMMIT_RATE=str(args.rate), FENRIR_COMMIT_SECONDS=str(args.seconds))
    replay_seconds = recovery["replay_timeout"]("paced-commits", args.rate * args.seconds + 1)
    worker_timeout = max(args.seconds * 4 + 300, args.seconds + replay_seconds + 300)
    pairs = []
    for block in range(args.blocks):
        order = workers if block % 2 == 0 else workers[::-1]
        record = args.output / f"{block}.json"
        has_record = args.recheck or (args.resume and record.exists())
        if has_record:
            original = json.loads(record.read_text())
            if tuple(original["order"]) != order:
                raise ValueError("recorded worker order does not alternate across blocks")
        directories = {}
        for worker in order:
            log = args.output / f"{block}-{worker}.log"
            if not has_record and not (args.resume and log.exists()):
                with log.open("x") as output:
                    run_group(["sh", root / "host/service/check-supervised-recovery.sh", worker, "paced-commits"],
                              worker_timeout, cwd=root, env=env,
                              stdout=output, stderr=output)
            with log.open() as output:
                line = output.readline().rstrip("\n")
            if not line.startswith("Recovery evidence: "):
                raise ValueError(f"missing run directory in {log}")
            directory = Path(line[len("Recovery evidence: "):])
            directories[worker] = directory
            if not args.recheck:
                env["FENRIR_RECOVERY_IMAGE"] = (directory / "container.id").read_text().strip()
        pair = compare(*(directories[w] for w in workers))
        if has_record:
            if original["shared"] != pair["shared"]:
                raise ValueError("replayed conditions differ from the original block")
            if len(original["samples"]) != len(pair["samples"]):
                raise ValueError("worker count differs from the original block")
            for saved, replayed in zip(original["samples"], pair["samples"]):
                verify_original_sample(saved, replayed)
            pair["order"] = original["order"]
        else:
            pair["order"] = order
        if (pair["shared"]["rate"], pair["shared"]["seconds"]) != (args.rate, args.seconds):
            raise ValueError("recorded workload differs from requested rate or duration")
        pairs.append(pair)
        result = summarize(pairs)
        prefix = "rechecked-" if args.recheck else ""
        if not (args.resume and has_record):
            block_path = args.output / f"{prefix}{block}.json"
            pending = block_path.with_suffix(".pending")
            pending.write_text(json.dumps(pair, indent=2) + "\n")
            pending.replace(block_path)
        summary_name = prefix + "summary"
        pending = args.output / (summary_name + ".pending")
        pending.write_text(json.dumps(result, indent=2) + "\n")
        pending.replace(args.output / (summary_name + ".json"))
        print(f"verified {block + 1}/{args.blocks} pairs at {args.rate} commits/s", flush=True)


if __name__ == "__main__":
    main()
