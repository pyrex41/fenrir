"""Check a pair of paced durable runs from the native Fenrir and C Solo5 guests."""
import argparse
import hashlib
import json
from pathlib import Path
from runpy import run_path

here = Path(__file__).resolve().parent
comparison = run_path(str(here / "compare-recovery.py"))
checked = comparison["checked"]
pace = run_path(str(here / "assess-paced.py"))
check_workload = pace["check_workload"]
check_store = run_path(str(here / "check-fresh-store.py"))["check"]


def digests(directory):
    actual = {}
    for line in (directory / "shared.sha256").read_text().splitlines():
        digest, name = line.split("  ", 1)
        if name in actual or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"invalid shared binary digest for {name}")
        actual[name] = digest
    required = {"sqlite-port", *(f"ebin/{p.name}" for p in (directory / "ebin").glob("*.beam"))}
    if actual.keys() != required or "ebin/fenrir_port_reference.beam" not in actual:
        raise ValueError("incomplete shared binary list")
    return actual


def sample(directory):
    history = checked(directory)
    timing = json.loads((directory / "timings.json").read_bytes())
    rate = timing["offered_rate"]
    count = timing["fresh_commits"]
    paced = check_workload(timing, history["event_count"], count, rate)
    store = check_store(directory / "jobs.db", count)
    if store != json.loads((directory / "store-check.json").read_bytes()):
        raise ValueError("stored database check differs from replay")
    receipt = json.loads((directory / "commit-check.json").read_bytes())
    if {key: receipt.get(key) for key in paced} != paced:
        raise ValueError("stored pacing check differs from replay")
    runtime = json.loads((directory / "otp.json").read_bytes())
    cpu = (directory / "cpus.txt").read_text().strip()
    if cpu != "0" or runtime["schedulers_online"] != 1 or runtime["dirty_cpu_schedulers_online"] != 1:
        raise ValueError("expected a single CPU and matched BEAM scheduler budget")
    shared = dict(container=(directory / "container.id").read_text().strip(), cpu=cpu,
                  runtime=runtime, binaries=digests(directory), sqlite=comparison["check_sqlite_settings"](timing["sqlite_connection"]),
                  store=store, rate=rate, seconds=paced["seconds"],
                  history={k: history[k] for k in ("schema", "scenario", "tenants", "event_count", "events_sha256")})
    if history["scenario"] != "paced-commits":
        raise ValueError("expected a paced commits history")
    pinned = {}
    for line in (directory / "native.sha256").read_text().splitlines():
        digest, path = line.split("  ", 1)
        name = Path(path).name
        if name in pinned or hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"native build digest differs for {name}")
        pinned[name] = digest
    if pinned.keys() != {"native.spt", "accepted-job.json"}:
        raise ValueError("expected pinned guest and service artifact")
    if "vfs_time_ns" in timing:
        shared["profile_vfs_time"] = True
    profile = {}
    if "store_transaction_ns" in timing:
        shared["profile_store_transaction"] = True
        profile = dict(store_transaction_ns=timing["store_transaction_ns"],
                       vfs_time_ns=timing["vfs_time_ns"],
                       dispatch_to_acknowledgement_ns=1000 * sum(timing["service_samples_us"]))
    shared["service_artifact_sha256"] = pinned["accepted-job.json"]
    # Requests run sequentially. Split each dispatch delay at the instant
    # both the scheduled arrival and the preceding completion have occurred.
    dispatch_delay = []
    waiting_for_previous = []
    ready_to_dispatch = []
    previous_end = 0
    for index, (latency, service) in enumerate(zip(timing["acknowledgement_samples_us"],
                                                   timing["service_samples_us"])):
        due = index * 1_000_000 // rate
        delay = latency - service
        queued = max(0, previous_end - due)
        dispatch_delay.append(delay)
        waiting_for_previous.append(queued)
        ready_to_dispatch.append(delay - queued)
        previous_end = due + latency
    rank = (99 * count + 99) // 100 - 1
    return shared, dict(worker=history["worker_implementation"], directory=str(directory.resolve()),
                        guest_sha256=pinned["native.spt"], **profile,
                        offered_rate_verdict=paced["offered_rate_verdict"],
                        max_outstanding=max(paced["outstanding_by_second"]),
                        outstanding_at_cutoff=paced["outstanding_by_second"][-1],
                        observed_clearance=paced["observed_clearance"],
                        sustained_backlog_growth=pace["sustained_growth"](paced["outstanding_by_second"]),
                        drain_past_cutoff_us=paced["drain_past_cutoff_us"],
                        scheduled_to_dispatch_p99_us=sorted(dispatch_delay)[rank],
                        waiting_for_previous_commit_p99_us=sorted(waiting_for_previous)[rank],
                        ready_to_dispatch_p99_us=sorted(ready_to_dispatch)[rank],
                        dispatch_to_acknowledgement_p99_us=sorted(timing["service_samples_us"])[rank],
                        acknowledgement_p99_us=paced["acknowledgement_p99_us"])


def compare(first, second):
    shared, fenrir = sample(first)
    matched, c = sample(second)
    if [fenrir["worker"], c["worker"]] != ["fenrir-native-spt", "c-native-spt"]:
        raise ValueError("expected native Fenrir then native C guests")
    if shared != matched:
        different = sorted(k for k in shared.keys() | matched.keys() if shared.get(k) != matched.get(k))
        raise ValueError("differing run conditions: " + ", ".join(different))
    return dict(shared=shared, samples=[fenrir, c])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fenrir", type=Path)
    parser.add_argument("c", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.fenrir, args.c), indent=2))
