"""Repeat a built Mac worker's recovery scenario with fresh OTP and SQLite state."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
from runpy import run_path
import statistics
import subprocess

root = Path(__file__).resolve().parents[2]
scenario = root / "host/service/test/supervised-recovery.escript"


comparison = run_path(str(Path(__file__).with_name("compare-recovery.py")))
history_summary = comparison["history_summary"]
run_group = comparison["run_group"]


def build_identity(build, worker):
    module = {"erlang": "fenrir_erlang_reference.beam", "elixir": "Elixir.Fenrir.DurableReference.beam"}.get(worker)
    implementation = build / "ebin" / module if module else build / "worker"
    recorded = {}
    for entry in (build / "native.sha256").read_text().splitlines():
        digest, name = entry.split("  ", 1)
        path = Path(name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"build digest differs for {path}")
        recorded[path] = digest
    required = {implementation, build / "sqlite-port", build / "otp.txt", build / "image.json"}
    required.update((build / "ebin").glob("*.beam"))
    missing = required.difference(recorded)
    if missing:
        raise ValueError("rebuild worker to record missing inputs: " + ", ".join(sorted(map(str, missing))))
    return {str(p): digest for p, digest in recorded.items()}


def run(build, output, samples, workload="recovery"):
    build = build.resolve()
    expected = history_summary(build / "history.json")
    worker = expected["worker_implementation"]
    if workload != "recovery":
        expected = None
    identity = build_identity(build, worker)
    env = dict(os.environ, ERL_FLAGS=os.environ.get("ERL_FLAGS", "") + ' -pa "' + str(build / "ebin") + '"',
               FENRIR_REFERENCE_PORT=str(build / "worker"), FENRIR_SQLITE_PORT=str(build / "sqlite-port"))
    schedule = None
    if workload == "paced-commits":
        rate = int(env.get("FENRIR_COMMIT_RATE", "0"))
        seconds = int(env.get("FENRIR_COMMIT_SECONDS", "0"))
        if min(rate, seconds) < 1:
            raise ValueError("paced commits require positive FENRIR_COMMIT_RATE and FENRIR_COMMIT_SECONDS")
        schedule = dict(rate=rate, seconds=seconds)
    if worker == "elixir":
        lib = subprocess.check_output(["elixir", "-e", "IO.write(Path.dirname(:code.lib_dir(:elixir)))"], text=True)
        env["ERL_LIBS"] = os.pathsep.join(filter(None, [lib, env.get("ERL_LIBS")]))
    probe = ("io:put_chars(json:encode(#{otp => list_to_binary(erlang:system_info(system_version)),"
             "schedulers_online => erlang:system_info(schedulers_online),"
             "dirty_cpu_schedulers_online => erlang:system_info(dirty_cpu_schedulers_online)})), halt().")
    runtime = json.loads(subprocess.check_output(["erl", "-noshell", "-eval", probe], env=env, timeout=30))
    host = dict(system=platform.system(), machine=platform.machine(), release=platform.release(),
                model=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True, timeout=5).strip(),
                logical_cpu_max=int(subprocess.check_output(["sysctl", "-n", "hw.logicalcpu_max"], timeout=5)))
    if host["system"] != "Darwin" or host["machine"] != "arm64" or host["logical_cpu_max"] < 1:
        raise ValueError("expected an Apple Silicon host")
    if workload in ("fresh-commits", "paced-commits") and env.get("FENRIR_PROFILE_VFS") == "1":
        runtime["profile_vfs_time"] = True
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    measurements = []
    for index in range(samples):
        case = output / str(index)
        case.mkdir()
        with (case / "run.log").open("wb") as log:
            run_group(["escript", scenario, build / "image.json", root / "host/service/priv/spt-launch",
                       case, worker, workload], stdout=log, stderr=subprocess.STDOUT, env=env,
                      timeout=60 + (seconds if schedule else 0))
        history = case / "history.json"
        run_group(["sh", root / "harness/run-service-history.sh", history, case / "check"],
                  stdout=subprocess.DEVNULL, timeout=comparison["replay_timeout"](workload, rate * seconds + 1 if schedule else 0))
        verdict = json.loads((case / "check/verdicts.jsonl").read_bytes())
        actual = history_summary(history)
        comparison["require_accepted_history"](verdict, history, actual)
        scenario_name = "full-domain-backlog" if workload == "backlog" else workload
        if expected is None and actual["scenario"] == scenario_name and actual["worker_implementation"] == worker:
            expected = actual
        if actual != expected:
            raise ValueError(f"recovery history differs at sample {index}")
        timing = json.loads((case / "timings.json").read_bytes())
        if workload == "recovery":
            comparison["check_recovery_timings"](timing, json.loads(history.read_bytes()))
        if workload in ("fresh-commits", "paced-commits"):
            if ("vfs_time_ns" in timing) != runtime.get("profile_vfs_time", False):
                raise ValueError("SQLite VFS timing mode differs from run configuration")
            check_store = run_path(str(Path(__file__).with_name("check-fresh-store.py")))["check"]
            count = rate * seconds if schedule else 128
            check_workload = run_path(str(Path(__file__).with_name("assess-paced.py")))["check_workload"]
            assessment = check_workload(timing, verdict["events"], count, rate if schedule else None)
            evidence = check_store(case / "jobs.db", count)
            (case / "store-check.json").write_text(json.dumps(evidence) + "\n")
            if schedule:
                (case / "paced.json").write_text(json.dumps(assessment) + "\n")
        measurements.append(timing)
    settings_key = "sqlite_connection_before_and_after_restart" if workload == "recovery" else "sqlite_connection"
    settings_by_run = [comparison["check_sqlite_settings"](row[settings_key]) for row in measurements]
    settings = settings_by_run[0]
    if any(other != settings for other in settings_by_run):
        raise ValueError("SQLite connection settings differ across samples")
    keys = [k for k, value in measurements[0].items() if k.endswith("_us") and type(value) is int]
    report = dict(workload=workload, worker=worker, build=str(build), build_sha256=identity, samples=samples, runtime=runtime, host=host,
                  schedule=schedule, sqlite_connection=settings, scenario_sha256=hashlib.sha256(scenario.read_bytes()).hexdigest(),
                  median_us={k: statistics.median(row[k] for row in measurements) for k in keys})
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output / "summary.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--workload", choices=["recovery", "backlog", "fresh-commits", "paced-commits"], default="recovery")
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("samples must be positive")
    run(args.build, args.output, args.samples, args.workload)
