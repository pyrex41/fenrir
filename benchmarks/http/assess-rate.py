"""Assess one offered HTTP rate from the load driver's census and time series."""
import json
import math
import re
from pathlib import Path
import statistics
import sys


def binary_identities(env):
    target = env["target"]
    binaries = {}
    for path, digest in env["binaries"].items():
        file = Path(path)
        role = file.name
        if role != "load":
            if target == "solo5":
                role = str(Path(file.parent.name) / role)
            elif target == "elixir":
                if file.parent.name not in ("ebin", "consolidated") or file.suffix not in (".beam", ".app"):
                    raise ValueError("unexpected Bandit build artifact")
                role = str(Path(file.parent.parent.name) / file.parent.name / role)
        if role in binaries or not isinstance(digest, str) or not re.fullmatch("[0-9a-f]{64}", digest):
            raise ValueError(f"ambiguous or invalid binary identity for {role}")
        binaries[role] = digest
    required = {"mac": {"fenrir", "rust", "nim", "load"},
                "solo5": {"spt/http.spt", "spt/ingress", "spt-c/http.spt", "spt-c/ingress", "load"}}
    if target == "elixir":
        if not {"load", "fenrir_http_reference/ebin/Elixir.FenrirHttp.Router.beam"} <= binaries.keys():
            raise ValueError("incomplete Bandit binary identities")
    elif set(binaries) != required[target]:
        raise ValueError("incomplete benchmark binary identities")
    return binaries


def has_versioned_origin(env):
    version = env.get("sample_origin_version")
    return type(version) is int and version == 1


def darwin_cpu_limit(env):
    if "darwin_logical_cpu_max" not in env:
        return None
    count = env["darwin_logical_cpu_max"]
    if type(count) is not int or count < 1 or not has_versioned_origin(env):
        raise ValueError("expected a positive Darwin CPU count bound to the sample origin")
    return count


def verify_sample_origin(row, env, name, block, rate_index, environment_digest):
    """Validate worker assignment and rotated run order for versioned sweeps."""
    if "sample_origin_version" not in env and "Origin" not in row:
        return
    if env.get("solo5_memory_method") and (env["target"] != "solo5" or "Solo5Memory" not in row or row["Solo5Memory"] is None):
        raise ValueError("missing Solo5 memory observation")
    method = env.get("solo5_memory_method")
    memory_v2 = "proc-status-smaps-rollup-vm-meminfo-cgroup-peak/2"
    memory_v3 = "proc-status-smaps-rollup-vm-meminfo-cgroup-peak/3"
    if method in (memory_v2, memory_v3):
        for endpoint in ("before", "after"):
            sample = row["Solo5Memory"][endpoint]
            if method == memory_v3:
                cpu = env.get("guest_cpuset")
                if (not isinstance(cpu, str) or not re.fullmatch(r"0|[1-9][0-9]*", cpu)
                        or sample.get("tender_allowed_cpus") != cpu):
                    raise ValueError(f"Solo5 tender CPU affinity differs {endpoint} the run")
            rss = sample.get("tender_rollup_rss_bytes")
            if type(rss) is not int or rss <= 0 or "container_lifetime_peak_bytes" not in sample:
                raise ValueError("missing Solo5 rollup or container memory observation")
            peak = sample["container_lifetime_peak_bytes"]
            if peak is not None and (type(peak) is not int or peak <= 0):
                raise ValueError("invalid container memory peak")
    workers = {"mac": ("fenrir", "rust", "nim"), "solo5": ("fenrir", "c"),
               "elixir": ("elixir",)}[env["target"]]
    position = (workers.index(name) - block - rate_index) % len(workers)
    origin = row.get("Origin")
    if not (has_versioned_origin(env) and isinstance(origin, dict) and type(origin.get("position")) is int):
        raise ValueError("invalid sample origin version or worker position")
    if origin != dict(
            worker=name, position=position, environment_sha256=environment_digest):
        raise ValueError(f"sample origin differs for {name}, block {block}, rate index {rate_index}")


def solo5_memory(record):
    if record is None:
        return None
    if not re.fullmatch(r"[0-9a-f]{64}", record["container_id"]):
        raise ValueError("invalid measured container identity")
    for sample in (record["before"], record["after"]):
        rss, peak, total, available = (sample[key] for key in (
            "tender_rss_bytes", "tender_lifetime_hwm_bytes", "vm_total_bytes", "vm_available_bytes"))
        if any(type(n) is not int or n <= 0 for n in (rss, peak, total, available)):
            raise ValueError("invalid Solo5 memory counter")
        if peak < rss or available > total:
            raise ValueError("inconsistent Solo5 memory counters")
    monotonic = record["before"]["tender_lifetime_hwm_bytes"] <= record["after"]["tender_lifetime_hwm_bytes"]
    return dict(record, tender_hwm_status="observed" if monotonic else "inconsistent",
                tender_lifetime_peak_bytes=record["after"]["tender_lifetime_hwm_bytes"] if monotonic else None)


def driver_resources(record, elapsed_ns, completed, peak_bytes=None):
    if peak_bytes is not None and (type(peak_bytes) is not int or peak_bytes <= 0 or record is None):
        raise ValueError("invalid load generator peak RSS")
    if record is None:
        return None
    user, system = record["UserNs"], record["SystemNs"]
    if any(type(v) is not int or v < 0 for v in (user, system)) or elapsed_ns <= 0:
        raise ValueError("invalid load generator CPU counters")
    cpu_ns = user + system
    result = dict(user_ns=user, system_ns=system, average_cpu_cores=cpu_ns / elapsed_ns,
                cpu_us_per_completed=cpu_ns / (1000 * completed) if completed else None)
    if peak_bytes is not None:
        result["peak_rss_bytes_through_drain"] = peak_bytes
    return result


def host_cpu_summary(samples):
    observations = [s["host_cpu"] for s in samples if "host_cpu" in s]
    if not observations:
        return None
    summary = {}
    for field in ("server_percent", "driver_percent", "other_processes_percent"):
        values = []
        for observation in observations:
            value = observation[field]
            if field == "driver_percent" and value is None:
                continue
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError("invalid host CPU observation")
            values.append(value)
        summary[field] = dict(samples=len(values), median=statistics.median(values) if values else None,
                              peak=max(values, default=None))
    return summary


def process_resources(record, completed):
    if record is None:
        return None
    samples = record["samples"]
    if len(samples) < 2:
        raise ValueError("process measurements need start and end samples")
    previous_time = previous_cpu = -1
    for sample in samples:
        time_ns, cpu, rss = (sample[k] for k in ("elapsed_ns", "cpu_seconds", "rss_bytes"))
        if (type(time_ns) is not int or time_ns <= previous_time or
                type(cpu) not in (float, int) or not math.isfinite(cpu) or cpu < max(0, previous_cpu) or
                type(rss) is not int or rss < 0):
            raise ValueError("invalid process resource sample")
        previous_time, previous_cpu = time_ns, cpu
    elapsed = (samples[-1]["elapsed_ns"] - samples[0]["elapsed_ns"]) / 1e9
    cpu = samples[-1]["cpu_seconds"] - samples[0]["cpu_seconds"]
    peak = max(s["rss_bytes"] for s in samples)
    cost = cpu * 1e6 / completed if completed else None
    reported_cost = record["cpu_us_per_completed"]
    cost_matches = reported_cost is None if cost is None else (
        type(reported_cost) in (float, int) and math.isclose(reported_cost, cost))
    if (not math.isclose(record["cpu_seconds"], cpu) or record["max_sampled_rss_bytes"] != peak
            or not cost_matches):
        raise ValueError("resource summary differs from process samples or request census")
    return dict(scope=record.get("scope"), sampled_seconds=elapsed, average_cpu_cores=cpu / elapsed,
                cpu_us_per_completed=cost, max_sampled_rss_bytes=peak,
                host_cpu=host_cpu_summary(samples))


def assess(r):
    # JSON booleans and fractional counts can otherwise pass integer comparisons
    # and even balance the final census while inventing partial requests.
    for key in ("Seconds", "Rate", "Connections", "Scheduled", "Valid", "Invalid",
                "Errors", "Missed", "ElapsedNs", "P50ns", "P99ns", "MaxNs"):
        if type(r[key]) is not int:
            raise ValueError("expected integer measurement for " + key)
    seconds, rate, lanes = (r[k] for k in ("Seconds", "Rate", "Connections"))
    if min(seconds, rate, lanes) < 1:
        raise ValueError("invalid workload")
    total = seconds * rate
    counts = [r[k] for k in ("Valid", "Invalid", "Errors", "Missed")]
    if min(counts) < 0 or sum(counts) != total or r["Scheduled"] != total:
        raise ValueError("inconsistent final request census")
    error_kinds = r.get("ErrorKinds")
    if error_kinds is not None and (any(type(n) is not int or n < 0 for n in error_kinds.values())
                                    or sum(error_kinds.values()) != r["Errors"]):
        raise ValueError("inconsistent transport error counts")
    phase_p99 = {}
    if "ValidRequestPhases" in r:
        phases = r["ValidRequestPhases"]
        if set(phases) != {"PreviousRequest", "Dispatch", "Fetch"}:
            raise ValueError("missing request timing phase")
        for phase, bins in phases.items():
            if len(bins) != 64 or any(type(n) is not int or n < 0 for n in bins) or sum(bins) != r["Valid"]:
                raise ValueError("inconsistent timing histogram for " + phase)
            rank = (99 * r["Valid"] + 99) // 100
            if rank:
                for index, count in enumerate(bins):
                    rank -= count
                    if rank <= 0:
                        phase_p99[phase] = (2**index - 1) / 1e6
                        break
    if r["ElapsedNs"] < seconds * 10**9:
        raise ValueError("run ended before the offered interval")
    latency = (r["P50ns"], r["P99ns"], r["MaxNs"])
    if not r["Valid"] and any(latency):
        raise ValueError("latency reported without a valid response")
    if r["Valid"] and not 0 < r["P50ns"] <= r["P99ns"] <= r["MaxNs"] <= r["ElapsedNs"]:
        raise ValueError("inconsistent latency distribution")
    if "SlowestValid" in r:
        worst = r["SlowestValid"]
        fields = ("Index", "Lane", "ElapsedNs", "PreviousRequestNs", "DispatchNs", "FetchNs")
        if (not isinstance(worst, dict) or any(type(worst.get(k)) is not int or worst[k] < 0 for k in fields)
                or not r["Valid"] or worst["Index"] >= total or worst["Lane"] != worst["Index"] % lanes
                or worst["ElapsedNs"] != r["MaxNs"] or sum(worst[k] for k in fields[3:]) != r["MaxNs"]):
            raise ValueError("inconsistent slowest valid request")
        due_ns = worst["Index"] * 10**9 // rate
        if due_ns + worst["ElapsedNs"] > r["ElapsedNs"]:
            raise ValueError("slowest request finished after the run")
    if "SlowestLaneOrigin" in r:
        origin = r["SlowestLaneOrigin"]
        worst = r.get("SlowestValid")
        fields = ("Index", "Lane", "ElapsedNs", "PreviousRequestNs", "DispatchNs", "FetchNs")
        if (not isinstance(origin, dict) or worst is None or type(origin.get("Valid")) is not bool
                or any(type(origin.get(k)) is not int or origin[k] < 0 for k in fields)
                or origin["Lane"] != worst["Lane"] or origin["Index"] % lanes != origin["Lane"]
                or origin["Index"] > worst["Index"] or origin["PreviousRequestNs"] != 0
                or origin["ElapsedNs"] != origin["DispatchNs"] + origin["FetchNs"]):
            raise ValueError("inconsistent lane backlog origin")
        due = origin["Index"] * 10**9 // rate
        finish = due + origin["ElapsedNs"]
        if (finish > r["ElapsedNs"] or (origin["Valid"] and origin["ElapsedNs"] > r["MaxNs"])
                or (not origin["Valid"] and not (r["Invalid"] or r["Errors"]))):
            raise ValueError("lane origin contradicts the request census")
        if origin["Index"] == worst["Index"]:
            if not origin["Valid"] or any(origin[k] != worst[k] for k in fields):
                raise ValueError("slowest request differs from its own lane origin")
        else:
            next_index = origin["Index"] + lanes
            next_due = next_index * 10**9 // rate
            previous_finish = worst["Index"] * 10**9 // rate + worst["PreviousRequestNs"]
            if (finish <= next_due or worst["PreviousRequestNs"] == 0 or finish > previous_finish
                    or (next_index == worst["Index"] and finish != previous_finish)):
                raise ValueError("disconnected lane backlog origin")
        if "RunFetchNs" in origin:
            fetch = origin["RunFetchNs"]
            duration = worst["Index"] * 10**9 // rate + worst["ElapsedNs"] - due
            endpoints = [origin] if origin["Index"] == worst["Index"] else [origin, worst]
            known_fetch = sum(point["FetchNs"] for point in endpoints)
            known_dispatch = sum(point["DispatchNs"] for point in endpoints)
            if (type(fetch) is not int or not known_fetch <= fetch <= duration - known_dispatch
                    or (worst["Index"] - origin["Index"] <= lanes and fetch != known_fetch)):
                raise ValueError("inconsistent cumulative fetch time in lane backlog")
    timeline = r["Timeline"]
    if len(timeline) != seconds:
        raise ValueError("missing timeline entries")
    previous = completed = 0
    previous_errors = 0
    late_seconds = []
    max_delay_ns = None
    previous_time = 0
    for second, row in enumerate(timeline, 1):
        if any(type(row[k]) is not int for k in ("Second", "Scheduled", "Completed", "Backlog")):
            raise ValueError("noninteger timeline at second " + str(second))
        scheduled, done = row["Scheduled"], row["Completed"]
        if (row["Second"] != second or not previous <= scheduled <= total
                or not completed <= done <= scheduled or row["Backlog"] != scheduled - done):
            raise ValueError("inconsistent timeline at second " + str(second))
        if scheduled < second * rate:
            raise ValueError("fewer requests scheduled than required by sample time")
        if error_kinds is not None:
            errors = row.get("Errors")
            if type(errors) is not int or not previous_errors <= errors <= r["Errors"]:
                raise ValueError("inconsistent sampled transport errors")
            previous_errors = errors
        if "ObservedNs" in row:
            when = row["ObservedNs"]
            if type(when) is not int or when < previous_time or not second * 10**9 <= when <= r["ElapsedNs"] or scheduled != min(
                    total, when * rate // 10**9 + 1):
                raise ValueError("inconsistent sampling clock")
            previous_time = when
            max_delay_ns = max(max_delay_ns or 0, when - second * 10**9)
            on_time = when < (second + 1) * 10**9
        elif second < seconds:
            on_time = scheduled < (second + 1) * rate
        else:
            # The offered count saturates. Only the end time can bound this
            # legacy sample once every request has been scheduled.
            on_time = r["ElapsedNs"] < (second + 1) * 10**9
        if not on_time:
            late_seconds.append(second)
        previous, completed = scheduled, done
    if previous != total or completed > total - r["Missed"]:
        raise ValueError("inconsistent terminal sample")
    backlog = [row["Backlog"] for row in timeline]
    windows = [backlog[i:i+60] for i in range(0, seconds, 60)]
    summaries = [dict(min=min(w), median=statistics.median(w), max=max(w), last=w[-1]) for w in windows]
    # Counts include all finished attempts, including errors. Use observed
    # sample clocks so delayed or partial minutes retain their actual duration.
    start_ns = 0
    start_count = 0
    for minute, summary in enumerate(summaries, 1):
        last = timeline[min(minute * 60, seconds) - 1]
        end_ns = last.get("ObservedNs")
        count = last["Completed"]
        summary["completed"] = count - start_count
        summary["completed_per_second"] = (
            (count - start_count) * 1e9 / (end_ns - start_ns)
            if start_ns is not None and end_ns is not None and end_ns > start_ns else None)
        start_ns, start_count = end_ns, count
    clears = all(min(w) <= lanes for w in windows) and backlog[-1] <= lanes
    # A sufficient witness of continuing accumulation: even the least backlog
    # observed in each later minute exceeds the preceding minute's maximum.
    # A single burst, persistent plateau or late sample leaves growth undecided.
    growing = (seconds >= 600 and not late_seconds and summaries[-1]["min"] > lanes
               and all(current["min"] > prior["max"]
                       for prior, current in zip(summaries, summaries[1:])))
    error_fraction = (r["Errors"] + r["Missed"]) / total
    if r["Invalid"]:
        verdict = "invalid-response"
    elif error_fraction >= 0.001:
        verdict = "failed-response-criteria"
    elif seconds < 600:
        verdict = "short-run"
    elif late_seconds:
        verdict = "sampling-cadence-unconfirmed"
    elif growing:
        verdict = "growing-backlog"
    elif not clears:
        verdict = "backlog-clearance-unconfirmed"
    else:
        verdict = "sustained-at-offered-rate"
    last_observed = r["Timeline"][-1].get("ObservedNs")
    completion_window = dict(completed_by_last_sample=completed,
                             completed_after_last_sample=total - r["Missed"] - completed,
                             last_sample_ns=last_observed,
                             remaining_wall_ns=r["ElapsedNs"] - last_observed if last_observed is not None else None)
    if "LastValidCompletionNs" in r:
        finish = r["LastValidCompletionNs"]
        earliest = (r["Valid"] - 1) * 10**9 // rate if r["Valid"] else 0
        latest = r["ElapsedNs"]
        if last_observed is not None and completed == total - r["Missed"]:
            latest = last_observed
        if (type(finish) is not int or not max(earliest, r["MaxNs"]) <= finish <= latest
                or (finish > 0) != (r["Valid"] > 0)):
            raise ValueError("invalid last valid response completion time")
        completion_window["last_valid_completion_ns"] = finish if r["Valid"] else None
        completion_window["last_valid_past_cutoff_ns"] = max(0, finish - seconds * 10**9) if r["Valid"] else None
    return dict(rate=rate, seconds=seconds, valid=r["Valid"], invalid=r["Invalid"],
                errors=r["Errors"], missed=r["Missed"], error_kinds=error_kinds,
                completion_window=completion_window,
                error_fraction=error_fraction, outstanding_at_cutoff=backlog[-1],
                late_sample_seconds=late_seconds, max_observed_sample_delay_ns=max_delay_ns,
                observed_clearance=clears, observed_growth=growing, backlog_by_minute=summaries,
                p99_ms=r["P99ns"]/1e6, phase_p99_upper_ms=phase_p99, verdict=verdict,
                solo5_memory=solo5_memory(r.get("Solo5Memory")),
                driver_resources=driver_resources(r.get("DriverCPU"), r["ElapsedNs"], total - r["Missed"], r.get("DriverPeakRSSBytes")),
                process_resources=process_resources(r.get("ServerResources"), total - r["Missed"]))


if __name__ == "__main__":
    for name in sys.argv[1:]:
        print(json.dumps(dict(source=name, **assess(json.loads(Path(name).read_text())))))
