"""Compare checked histories for the same scenario across worker implementations."""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]


def check_sqlite_settings(settings):
    required = dict(journal_mode="wal", synchronous=2, foreign_keys=1, busy_timeout_ms=50)
    for key, expected in required.items():
        value = settings.get(key)
        if type(value) is not type(expected) or value != expected:
            raise ValueError(f"unexpected SQLite connection setting {key}: {value!r}")
    if not isinstance(settings.get("sqlite_version"), str) or not settings["sqlite_version"].strip():
        raise ValueError("missing SQLite runtime version")
    return settings


def check_recovery_timings(timings, history):
    if history["scenario"] != "supervised-store-and-worker-recovery":
        raise ValueError("expected supervised recovery history")
    fields = ("worker_kill_to_replacement_observed_us", "replacement_observed_to_successful_retry_us",
              "worker_kill_to_successful_retry_us", "runner_start_to_verified_empty_us",
              "fresh_submit_to_accepted_us", "fresh_submit_to_respond_us", "duplicate_submit_to_accepted_us",
              "delivery_attempts", "pending_jobs_at_start")
    for field in fields:
        value = timings.get(field)
        if type(value) is not int or value < 0:
            raise ValueError(f"invalid recovery measurement {field}")
    if (timings["worker_kill_to_replacement_observed_us"] + timings["replacement_observed_to_successful_retry_us"]
            != timings["worker_kill_to_successful_retry_us"]):
        raise ValueError("recovery intervals disagree")
    if timings["fresh_submit_to_accepted_us"] > timings["fresh_submit_to_respond_us"]:
        raise ValueError("fresh response precedes acceptance")
    events = history["events"]
    deliveries = [e for e in events[:events.index(["drained"])] if e[0] == "complete"]
    if (len(deliveries) != timings["delivery_attempts"] or
            len({(e[1], e[2]) for e in deliveries}) != timings["pending_jobs_at_start"]):
        raise ValueError("recovery counts disagree with deliveries before the first drain")


def run_group(command, timeout, **options):
    # The shell checker launches Shen, and escript can launch native ports.
    with subprocess.Popen(command, start_new_session=True, **options) as child:
        try:
            status = child.wait(timeout)
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            raise
        if status:
            raise subprocess.CalledProcessError(status, command)


def history_summary(path, snapshot=None):
    def read(source):
        data = source.read_bytes()
        if snapshot is not None:
            (snapshot / source.name).write_bytes(data)
        return json.loads(data)

    history = read(path)
    count = 0
    digest = hashlib.sha256()

    def consume(events):
        nonlocal count
        if not isinstance(events, list):
            raise ValueError("expected history events")
        for event in events:
            digest.update(json.dumps(event, sort_keys=True, separators=(",", ":")).encode())
            digest.update(b"\n")
        count += len(events)

    if history["schema"] == "fenrir.service.history/1-chunked":
        chunks = history.pop("chunks")
        total = history.pop("event_count")
        if type(chunks) is not int or type(total) is not int or not 0 <= chunks <= total:
            raise ValueError("invalid history chunk counts")
        for index in range(chunks):
            chunk = read(path.with_name(f"{path.name}.events.{index}"))
            if type(chunk["first"]) is not int or chunk["first"] != count or not chunk["events"]:
                raise ValueError("invalid history chunk extent")
            consume(chunk["events"])
        if total != count:
            raise ValueError("history event count differs")
        history["schema"] = "fenrir.service.history/1"
    elif history["schema"] == "fenrir.service.history/1":
        consume(history.pop("events"))
    else:
        raise ValueError(f"unsupported history schema: {history['schema']}")
    return dict(history, event_count=count, events_sha256=digest.hexdigest())


def replay_timeout(scenario, events):
    # Fresh-key replay scans the growing model store at each submit.
    # Scale the deadline for long histories while bounding a stuck run.
    if scenario != "paced-commits":
        return 120
    blocks = (events + 5999) // 6000
    # A 120,001-event replay exceeded 1,764 seconds on the shared ARM64 host.
    return min(3000, max(120, 7 * blocks * blocks))


def require_accepted_history(verdict, path, history):
    if (Path(verdict["history"]) != path or verdict["verdict"] != "accepted"
            or type(verdict["events"]) is not int or verdict["events"] != history["event_count"]
            or verdict["scenario"] != history["scenario"]):
        raise ValueError(f"{path}: missing matching accepted verdict")


def checked(directory):
    history_path = (directory / "history.json").resolve()
    verdict = json.loads((directory / "check/verdicts.jsonl").read_bytes())
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        snapshot = work / "history.json"
        history = history_summary(history_path, work)
        require_accepted_history(verdict, history_path, history)
        timeout = replay_timeout(history["scenario"], history["event_count"])
        run_group(["sh", root / "harness/run-service-history.sh", snapshot, work / "check"],
                  timeout, stdout=subprocess.DEVNULL)
        fresh = json.loads((work / "check/verdicts.jsonl").read_bytes())
        require_accepted_history(fresh, snapshot, history)
    return history


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", nargs="+", type=Path)
    runs = [checked(directory) for directory in parser.parse_args().directories]
    workers = [h["worker_implementation"] for h in runs]
    if len(set(workers)) != len(workers) or len(workers) < 2:
        raise ValueError("expected two or more different workers")
    for field in ("schema", "tenants", "scenario", "event_count", "events_sha256"):
        if any(h[field] != runs[0][field] for h in runs[1:]):
            raise ValueError(f"{field} differs across histories")
    print(f"{runs[0]['event_count']} matching events across {', '.join(workers)}")


if __name__ == "__main__":
    main()
