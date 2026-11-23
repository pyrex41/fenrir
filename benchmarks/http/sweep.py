"""Run identical offered loads on persistent servers, retaining each guest's backlog."""
import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
from runpy import run_path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wire", here / "check-service.py")
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_recorded_driver(source, destination):
    metadata = json.loads((source / "environment.json").read_text())
    if metadata["checkout_sha256"]["load.go"] != sha(here / "load.go"):
        raise ValueError("recorded driver source differs from this sweep")
    digests = [digest for path, digest in metadata["binaries"].items() if Path(path).name == "load"]
    if len(digests) != 1:
        raise ValueError("expected one recorded load driver")
    shutil.copy2(source / "load", destination)
    if sha(destination) != digests[0]:
        destination.unlink()
        raise ValueError("copied driver differs from its recorded binary")
    return metadata["go"]


def verify_service_sources(fenrir_build, references, source):
    if fenrir_build is not None:
        for filename in ("service.fen", "router.fen", "build-mac.sh", "build-service.mjs", "server.c"):
            if fenrir_build["inputs"].get("benchmarks/http/" + filename) != sha(source / filename):
                raise ValueError(f"Fenrir build used a different {filename}")
    if references is not None:
        for name, filename in (("rust", "reference.rs"), ("nim", "reference.nim")):
            build = references[name]
            if build["source"] != filename or build["source_sha256"] != sha(source / filename):
                raise ValueError(f"{name} build source differs from the sweep")


def ingress_pid(launcher, executable):
    children = subprocess.check_output(["pgrep", "-P", str(launcher)], text=True, timeout=5).split()
    matches = []
    for pid in children:
        command = subprocess.check_output(["ps", "-p", pid, "-o", "comm="], text=True, timeout=5).strip()
        if Path(command).resolve() == executable.resolve():
            matches.append(int(pid))
    if len(matches) != 1:
        raise ValueError(f"expected one running ingress child of {launcher} at {executable}")
    return matches[0]


def mac_resources(pid, start):
    raw = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=", "-o", "rss="],
                                  text=True, timeout=5).split()
    cpu, rss = raw
    seconds = 0.0
    for component in cpu.split(":"):
        seconds = seconds * 60 + float(component)
    return dict(elapsed_ns=time.monotonic_ns() - start, cpu_seconds=seconds, rss_bytes=int(rss) * 1024)


def mac_cpu_load(server_pid, client_pid):
    # Darwin ps reports recently averaged CPU percent, with one core equal to 100.
    raw = subprocess.check_output(["ps", "-A", "-o", "pid=,%cpu="], text=True, timeout=5)
    processes = dict((int(pid), float(cpu)) for pid, cpu in
                     (line.split() for line in raw.splitlines()))
    server = processes.pop(server_pid)
    client = processes.pop(client_pid, None)  # The driver may finish during sampling.
    return dict(server_percent=server, driver_percent=client,
                other_processes_percent=round(sum(processes.values()), 1))


def guest_memory(container, cpu):
    # The launcher execs the tender as PID 1. /proc/meminfo is VM-wide.
    command = ["docker", "exec", container, "sh", "-ec",
               "test \"$(readlink /proc/1/exe)\" = /opt/solo5-install/bin/solo5-spt; "
               "cat /proc/1/status /proc/meminfo; "
               "awk '/^Rss:/ {print \"RollupRss:\", $2, $3}' /proc/1/smaps_rollup; "
               "if test -r /sys/fs/cgroup/memory.peak; then "
               "printf 'CgroupPeak: '; cat /sys/fs/cgroup/memory.peak; fi"]
    try:
        output = subprocess.check_output(command, text=True, timeout=10)
    except subprocess.TimeoutExpired:
        # Retry the read-only snapshot against the same tender after a Docker stall.
        output = subprocess.check_output(command, text=True, timeout=30)
    fields = dict(line.split(":", 1) for line in output.splitlines() if ":" in line)
    allowed_cpus = fields["Cpus_allowed_list"].strip()
    if allowed_cpus != str(cpu):
        raise ValueError("tender CPU affinity changed")
    def kib(name):
        value, unit = fields[name].split()
        if unit != "kB" or int(value) <= 0:
            raise ValueError(f"unexpected Linux memory counter {name}")
        return int(value) * 1024
    return dict(tender_allowed_cpus=allowed_cpus, tender_rollup_rss_bytes=kib("RollupRss"),
                container_lifetime_peak_bytes=int(fields["CgroupPeak"]) if "CgroupPeak" in fields else None,
                tender_rss_bytes=kib("VmRSS"), tender_lifetime_hwm_bytes=kib("VmHWM"),
                vm_total_bytes=kib("MemTotal"), vm_available_bytes=kib("MemAvailable"))


def run_load(command, seconds, pid):
    start = time.monotonic_ns()
    samples = [mac_resources(pid, start)] if pid else []
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as client:
        try:
            while True:
                remaining = seconds + 30 - (time.monotonic_ns() - start) / 1e9
                if remaining <= 0:
                    raise TimeoutError("HTTP load client exceeded its deadline")
                try:
                    stdout, stderr = client.communicate(timeout=min(5, remaining) if pid else remaining)
                    break
                except subprocess.TimeoutExpired:
                    if pid:
                        try:
                            sample = mac_resources(pid, start)
                        except subprocess.TimeoutExpired:
                            continue
                        try:
                            sample["host_cpu"] = mac_cpu_load(pid, client.pid)
                        except subprocess.TimeoutExpired:
                            pass  # Host-wide CPU is an optional observation.
                        samples.append(sample)
            if pid:
                samples.append(mac_resources(pid, start))
        finally:
            if client.poll() is None:
                client.kill()
                client.communicate()
        if client.returncode not in (0, 1) or not stdout:
            raise RuntimeError((client.returncode, stderr))
    return stdout, samples


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("build", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--target", choices=["solo5", "mac", "elixir"], required=True)
    p.add_argument("--seconds", type=int, required=True)
    p.add_argument("--rates", type=int, nargs="+", required=True)
    p.add_argument("--blocks", type=int, default=1, help="paired repetitions of every offered rate")
    p.add_argument("--guest-cpu", type=int, help="Solo5 VM CPU index (default 0)")
    p.add_argument("--connections", type=int, default=16)
    restart = p.add_mutually_exclusive_group()
    restart.add_argument("--driver-from", type=Path, help="reuse a previous sweep’s verified load binary")
    restart.add_argument("--resume", action="store_true",
                   help="continue an interrupted sweep with the recorded driver and matching environment")
    args = p.parse_args()
    if args.guest_cpu is not None and (args.target != "solo5" or args.guest_cpu < 0):
        p.error("--guest-cpu requires Solo5 and a nonnegative CPU index")
    if args.guest_cpu is None:
        args.guest_cpu = 0
    if len(set(args.rates)) != len(args.rates):
        p.error("each offered rate must occur once per block")
    if args.blocks < 1:
        p.error("blocks must be positive")
    if not 1 <= args.connections <= 64 or not 1 <= args.seconds <= 3600:
        p.error("connections must be 1..64 and duration 1..3600 seconds")
    if any(not 1 <= rate <= 1_000_000 or rate * args.seconds > 128_000_000 for rate in args.rates):
        p.error("rate outside load driver limits")
    if not args.resume:
        args.output.mkdir(parents=True, exist_ok=False)
    with (args.output / ".sweep.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            p.error("another sweep is using this output directory")
        run_sweep(args)


def run_sweep(args):
    root = args.build.resolve()
    driver = args.output.resolve() / "load"
    if args.driver_from:
        go_version = copy_recorded_driver(args.driver_from, driver)
    elif not args.resume:
        subprocess.run(["go", "build", "-o", driver, here / "load.go"], check=True)
    if not args.driver_from:
        go_version = subprocess.check_output(["go", "version"], text=True).strip()
    if args.target == "solo5":
        memory_mib = 32
        commands = {k: [sys.executable, here / "run-spt.py", root / d, "0", "--memory-mib", str(memory_mib), "--guest-cpu", str(args.guest_cpu)]
                    for k, d in [("fenrir", "spt"), ("c", "spt-c")]}
        images = [root / d / f for d in ("spt", "spt-c") for f in ("http.spt", "ingress")]
    elif args.target == "elixir":
        commands = {"elixir": [here / "elixir/run.sh", "0"]}
        os.environ["FENRIR_HTTP_MIX_ROOT"] = str(root)
        lib = root / "build/lib"
        if not (lib / "fenrir_http_reference/ebin/Elixir.FenrirHttp.Router.beam").is_file():
            raise ValueError("build the Elixir HTTP reference before running the sweep")
        images = sorted(p for p in lib.rglob("*") if p.suffix in (".beam", ".app") and p.is_file())
    else:
        commands = {k: [root / k, "127.0.0.1:0" if k == "rust" else "0"]
                    for k in ("fenrir", "rust", "nim")}
        images = [root / k for k in commands]
    metadata = dict(host=platform.platform(), binaries={str(p): sha(p) for p in [*images, driver]},
                    go=go_version,
                    cpu=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip())
    metadata["darwin_logical_cpu_max"] = int(subprocess.check_output(
        ["sysctl", "-n", "hw.logicalcpu_max"], text=True))
    sources = ["sweep.py", "assess-rate.py", "load.go", "check-service.py", "service.fen", "router.fen", "server.c",
               "build-service.mjs"]
    if args.target == "solo5":
        sources.extend(["build-spt.sh", "guest-spt.c", "guest-client.c", "reference.c", "run-spt.py"])
        if sha(root / "spt/ingress") != sha(root / "spt-c/ingress"):
            raise ValueError("matched Solo5 runs require identical host ingress binaries")
        tag = os.environ.get("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
        image = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}", tag],
                                        text=True).strip()
        os.environ["FENRIR_SOLO5_IMAGE"] = image
        metadata["solo5_container"] = image
        metadata["guest_cpuset"] = str(args.guest_cpu)
        metadata["solo5_memory_method"] = "proc-status-smaps-rollup-vm-meminfo-cgroup-peak/3"
        metadata["guest_memory_budget_bytes"] = memory_mib * 1024**2
    elif args.target == "elixir":
        sources = ["sweep.py", "assess-rate.py", "load.go", "elixir/run.sh", "elixir/serve.exs", "elixir/lib/router.ex",
                   "elixir/mix.exs", "elixir/mix.lock", "elixir/check.py"]
        metadata["beam"] = subprocess.check_output(["elixir", "--version"], text=True).strip()
        metadata["erl_flags"] = os.environ.get("ERL_FLAGS", "")
        metadata["comparison"] = "idiomatic Bandit deployment"
    else:
        sources.extend(["build-mac.sh", "reference.rs", "reference.nim"])
        fenrir_receipt = root / "fenrir.build.json"
        if fenrir_receipt.exists():
            record = json.loads(fenrir_receipt.read_text())
            if record["binary_sha256"] != sha(root / "fenrir"):
                raise ValueError("Fenrir binary differs from its build receipt")
            if record.get("profile_lock"):
                raise ValueError("capacity runs require a Fenrir server built without lock profiling")
            metadata["fenrir_build"] = record
        build_receipt = root / "reference-build.json"
        if build_receipt.exists():
            records = json.loads(build_receipt.read_text())
            for name in ("rust", "nim"):
                if records[name]["binary_sha256"] != sha(root / name):
                    raise ValueError(f"{name} binary differs from its build receipt")
            metadata["reference_build"] = records
        verify_service_sources(metadata.get("fenrir_build"), metadata.get("reference_build"), here)
    metadata.update(sample_origin_version=1, target=args.target, seconds=args.seconds, connections=args.connections,
                    rates=args.rates, blocks=args.blocks, checkout_sha256={name: sha(here / name) for name in sources})
    environment = args.output / "environment.json"
    if args.resume:
        if json.loads(environment.read_text()) != metadata:
            raise ValueError("resume requires identical environment, workload, sources and binaries")
    else:
        environment.write_text(json.dumps(metadata, indent=2))
    assess = run_path(str(here / "assess-rate.py"))["assess"]
    verify_origin = run_path(str(here / "assess-rate.py"))["verify_sample_origin"]
    environment_digest = sha(environment)
    with ExitStack() as stack:
        containers = {}
        if args.target == "solo5":
            ids = Path(stack.enter_context(tempfile.TemporaryDirectory()))
            for name, command in commands.items():
                command.extend(["--cidfile", ids / name])
        pids = {}
        addresses = {k: stack.enter_context(wire.server(cmd, on_start=lambda pid, k=k: pids.update({k: pid})))
                     for k, cmd in commands.items()}
        if args.target == "solo5":
            for name, command in commands.items():
                pids[name] = ingress_pid(pids[name], command[2] / "ingress")
        for address in addresses.values():
            if args.target == "elixir":
                run_path(str(here / "elixir/check.py"))["check"](address[1])
            else:
                wire.check(address)
        if args.target == "solo5":
            # Successful wire checks require both tenders to have started.
            containers = {name: (ids / name).read_text().strip() for name in commands}
        for index, rate in enumerate(args.rates * args.blocks):
            names = list(commands)
            block, rate_index = divmod(index, len(args.rates))
            offset = (block + rate_index) % len(names)
            for position, name in enumerate(names[offset:] + names[:offset]):
                output = args.output / f"{index}-{name}-{rate}.json"
                if args.resume and output.exists():
                    prior = json.loads(output.read_text())
                    verify_origin(prior, metadata, name, block, rate_index, environment_digest)
                    assess(prior)
                    if (prior["Rate"], prior["Seconds"], prior["Connections"], prior["Block"],
                        prior["RateIndex"]) != (rate, args.seconds, args.connections, block, rate_index):
                        raise ValueError(f"workload differs for {output}")
                    continue
                addr = "%s:%s" % addresses[name]
                command = [driver, "-addr", addr, "-rate", str(rate), "-seconds", str(args.seconds),
                           "-connections", str(args.connections)]
                before = guest_memory(containers[name], args.guest_cpu) if containers else None
                data, samples = run_load(command, args.seconds, pids[name])
                row = json.loads(data)
                if containers:
                    row["Solo5Memory"] = dict(container_id=containers[name], before=before,
                                              after=guest_memory(containers[name], args.guest_cpu))
                row["Origin"] = dict(worker=name, position=position, environment_sha256=environment_digest)
                row["Block"] = block
                row["RateIndex"] = rate_index
                if row["Scheduled"] != args.seconds * rate or row["Scheduled"] != sum(
                        row[key] for key in ("Valid", "Errors", "Invalid", "Missed")):
                    raise ValueError("inconsistent request census")
                if samples:
                    completed = row["Valid"] + row["Invalid"] + row["Errors"]
                    cpu = samples[-1]["cpu_seconds"] - samples[0]["cpu_seconds"]
                    scope = "Darwin TCP ingress process" if args.target == "solo5" else "Darwin server process"
                    row["ServerResources"] = dict(scope=scope, pid=pids[name], samples=samples, cpu_seconds=cpu,
                        cpu_us_per_completed=cpu * 1e6 / completed if completed else None,
                        max_sampled_rss_bytes=max(s["rss_bytes"] for s in samples))
                row["RestartedServerSession"] = args.resume
                pending = output.with_suffix(".pending")
                pending.write_text(json.dumps(row) + "\n")
                assess(row)
                pending.replace(output)
                print(name, rate, row["Valid"], "valid;", row["Timeline"][-1]["Backlog"],
                      "outstanding at end;", row["P99ns"] / 1e6, "ms p99", flush=True)


if __name__ == "__main__":
    main()
