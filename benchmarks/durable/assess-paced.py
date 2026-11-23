"""Recover the offered queue at second boundaries from sequential completion times."""
import argparse
import json
import math
from pathlib import Path
from runpy import run_path


def check_commit_totals(timings, expected_count):
    count = timings["fresh_commits"]
    elapsed = timings["fresh_commits_elapsed_us"]
    latency = timings["acknowledgement_samples_us"]
    service = timings["service_samples_us"]
    if (type(count) is not int or count != expected_count or count < 1
            or type(elapsed) is not int or elapsed <= 0
            or len(latency) != count or len(service) != count):
        raise ValueError("commit timing count or batch duration differs from workload")
    if any(type(a) is not int or type(s) is not int or not 0 <= s <= a <= elapsed
           for a, s in zip(latency, service)) or sum(service) > elapsed:
        raise ValueError("invalid sequential commit durations")
    if "vfs_time_ns" in timings:
        vfs = timings["vfs_time_ns"]
        if not isinstance(vfs, dict) or set(vfs) != {"write", "sync"} or any(
                type(value) is not int or value < 0 for value in vfs.values()):
            raise ValueError("invalid SQLite VFS durations")
        # Each sequential dispatch interval is rounded to microseconds.
        if sum(vfs.values()) > 1000 * (sum(service) + count):
            raise ValueError("SQLite write and sync durations exceed sequential service time")
    if "store_transaction_ns" in timings:
        transaction = timings["store_transaction_ns"]
        if ("vfs_time_ns" not in timings or type(transaction) is not int
                or not sum(timings["vfs_time_ns"].values()) <= transaction
                <= 1000 * (sum(service) + count)):
            raise ValueError("invalid store transaction duration")
    if timings["offered_rate"] == "none" and latency != service:
        raise ValueError("closed-loop latency differs from dispatch-to-acknowledgement time")
    if timings["acknowledgement_p99_us"] != sorted(latency)[(99 * count + 99) // 100 - 1]:
        raise ValueError("reported p99 differs from raw acknowledgement samples")
    if not math.isclose(timings["commits_per_second"], count * 1_000_000 / elapsed, rel_tol=1e-12):
        raise ValueError("reported throughput differs from count and batch duration")


def assess(timings):
    rate = timings["offered_rate"]
    elapsed = timings["fresh_commits_elapsed_us"]
    latency = timings["acknowledgement_samples_us"]
    service = timings["service_samples_us"]
    count = timings["fresh_commits"]
    if (type(rate) is not int or rate < 1 or type(count) is not int or count < 1 or count % rate
            or type(elapsed) is not int or elapsed < 0 or len(latency) != count or len(service) != count):
        raise ValueError("inconsistent paced workload")
    seconds = count // rate
    completions = [0] * seconds
    previous_end = 0
    for index, (total, active) in enumerate(zip(latency, service)):
        if type(active) is not int or type(total) is not int or not 0 <= active <= total:
            raise ValueError("inconsistent acknowledgement latency")
        end = index * 1_000_000 // rate + total
        if end - active < previous_end or end > elapsed:
            raise ValueError("inconsistent sequential commit timestamps")
        previous_end = end
        # Count at the first boundary that includes both arrival and completion.
        # A zero-duration arrival exactly at a boundary belongs to the next second.
        boundary = max(index // rate + 1, (end + 999_999) // 1_000_000)
        if boundary <= seconds:
            completions[boundary - 1] += 1
    completed = 0
    queue = []
    for second, events in enumerate(completions, 1):
        completed += events
        queue.append(second * rate - completed)
    return dict(rate=rate, seconds=seconds, accepted=count, outstanding_by_second=queue,
                drain_past_cutoff_us=max(0, previous_end - seconds * 1_000_000),
                acknowledgement_p99_us=sorted(latency)[(99 * count + 99) // 100 - 1])


def latency_components(timings):
    """Decompose the same requests at or above the acknowledgement p99."""
    count = timings["fresh_commits"]
    check_commit_totals(timings, count)
    rate = timings["offered_rate"]
    if type(rate) is not int or rate < 1:
        raise ValueError("latency decomposition requires a paced workload")
    service = timings["service_samples_us"]
    latency = timings["acknowledgement_samples_us"]
    previous_end = 0
    tail = []
    threshold = timings["acknowledgement_p99_us"]
    for index, (total, active) in enumerate(zip(latency, service)):
        due = index * 1_000_000 // rate
        queued = max(0, previous_end - due)
        ready = total - active - queued
        if ready < 0:
            raise ValueError("dispatch precedes previous completion")
        if total >= threshold:
            tail.append((total, active, queued, ready))
        previous_end = due + total
    names = ("acknowledgement", "service", "waiting_for_previous", "ready_to_dispatch")
    means = {name: sum(values) / len(tail) for name, values in zip(names, zip(*tail))}
    return dict(acknowledgement_p99_us=threshold, tail_count=len(tail), tail_mean_us=means)


def sustained_growth(queue):
    # One in-flight request is normal. Successively higher minute
    # ranges witness accumulation throughout a complete ten-minute experiment.
    if len(queue) < 600:
        return False
    windows = [queue[i:i + 60] for i in range(0, len(queue), 60)]
    ranges = [(min(window), max(window)) for window in windows]
    # A slowly growing queue can have the same depth on both sides of a
    # minute boundary. Require both extrema to advance when ranges touch.
    return ranges[-1][0] > 1 and all(
        previous_min < current_min and previous_max <= current_min and previous_max < current_max
        for (previous_min, previous_max), (current_min, current_max) in zip(ranges, ranges[1:]))


def check_workload(timings, history_events, count, rate):
    check_commit_totals(timings, count)
    if timings["offered_rate"] != (rate if rate is not None else "none") or history_events != count + 1:
        raise ValueError("commit timing and checked history differ")
    if rate is not None:
        result = assess(timings)
        queue = result["outstanding_by_second"]
        # The client has one active request. A sample of at most one means
        # all earlier scheduled work has cleared at that boundary.
        clears = queue[-1] <= 1 and all(min(queue[i:i+60]) <= 1 for i in range(0, len(queue), 60))
        if result["seconds"] < 600:
            verdict = "short-run"
        elif clears:
            verdict = "sustained-at-offered-rate"
        else:
            verdict = "backlog-clearance-unconfirmed"
        return dict(result, observed_clearance=clears, offered_rate_verdict=verdict)
    return dict(accepted=count, commits_per_second=timings["commits_per_second"],
                acknowledgement_p99_us=timings["acknowledgement_p99_us"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("timings", type=Path, nargs="+")
    parser.add_argument("--count", type=int)
    parser.add_argument("--rate", type=int)
    parser.add_argument("--verdict", type=Path)
    parser.add_argument("--latency-components", action="store_true", help="include mean latency components for the p99 tail")
    args = parser.parse_args()
    if (args.count is None) != (args.verdict is None) or args.rate is not None and args.count is None:
        parser.error("supply --count and --verdict together for workload validation")
    for path in args.timings:
        timings = json.loads(path.read_bytes())
        if args.verdict is None:
            result = assess(timings)
        else:
            verdict = json.loads(args.verdict.read_bytes())
            require_accepted = run_path(str(Path(__file__).with_name("compare-recovery.py")))["require_accepted_history"]
            expected = dict(scenario="paced-commits" if args.rate is not None else "fresh-commits",
                            event_count=args.count + 1)
            require_accepted(verdict, path.resolve().with_name("history.json"), expected)
            result = check_workload(timings, verdict["events"], args.count, args.rate)
        if args.latency_components:
            result["latency_components"] = latency_components(timings)
        print(json.dumps(dict(source=str(path), **result)))
