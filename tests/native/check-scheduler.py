"""Build and run the native task-runtime fixtures on Darwin and ARM64 SPT."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
runtime = root / "runtime/native"
tests = root / "tests/native"
out = Path(sys.argv[1]).resolve()
if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
    raise SystemExit("run on an ARM64 Mac with the Solo5 SPT build image")
out.mkdir(parents=True, exist_ok=False)
# Each fixture links the runtime it exercises. Tiny heaps deliberately force
# collection while another task still owns the only root to its objects.
managed = ["heap.c", "managed.c"]
scheduler = [*managed, "context.S", "scheduler.c"]
fixtures = {
    "heap": (["heap.c"], None),
    "context": (["context.S"], None),
    "parked-roots": ([*managed, "context.S"], 3),
    "task-handler-state": ([*managed, "context.S"], None),
    "inherited-handlers": (managed, 4),
    "dispatch-selected": (scheduler, None),
    "fifo-tasks": (scheduler, None),
    "scope-abort": (scheduler, None),
    "implicit-join-roots": ([*scheduler, "task-entry.c"], 1),
    "cancel-owned-scopes": (scheduler, None),
    "fifo-spawn": (scheduler, None),
    "fifo-await": (scheduler, None),
    "virtual-time": (scheduler, None),
    "monotonic-timers": (scheduler, None),
    "fifo-cancel": (scheduler, None),
    "fifo-channel": (scheduler, None),
    "channel-cancel": (scheduler, None),
    "channel-roots": (scheduler, 1),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, folder):
    result = subprocess.run(args, cwd=folder, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=90)
    with (folder / "commands.jsonl").open("a") as stream:
        stream.write(json.dumps(dict(argv=list(map(str, args)), exit=result.returncode,
                                     output=result.stdout)) + "\n")
    if result.returncode != 0:
        raise RuntimeError(result.stdout)


image = subprocess.check_output(["docker", "image", "inspect", "--format", "{{.Id}}",
    os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")], text=True).strip()
report = dict(host=platform.platform(), solo5_image=image, sources={}, results=[])
for name, (sources, capacity) in fixtures.items():
    paths = [tests / (name + ".c"), *(runtime / src for src in sources)]
    for path in [*paths, *runtime.glob("*.h")]:
        report["sources"][str(path.relative_to(root))] = sha(path)
    flags = ["-O2", "-Wall", "-Wextra", "-Werror"]
    if capacity:
        flags.append(f"-DFEN_HEAP_SLOTS={capacity}")
    folder = out / name
    folder.mkdir()
    run(["clang", "-arch", "arm64", *flags, *paths, "-o", "mac"], folder)
    run([folder / "mac"], folder)
    (folder / "manifest.json").write_text('{"type":"solo5.manifest","version":1,"devices":[]}\n')
    run(["docker", "run", "--rm", "--network", "none", "--platform", "linux/arm64",
         "--user", f"{os.getuid()}:{os.getgid()}", "-v", f"{root}:/src:ro", "-v", f"{folder}:/work",
         "-w", "/work", "--entrypoint", "sh", image, "-ec",
         """export PATH=/opt/solo5-install/bin:$PATH
solo5-elftool gen-manifest manifest.json manifest.c
aarch64-solo5-none-static-cc -c manifest.c
fixture=$1
shift
aarch64-solo5-none-static-cc -O2 -Wall -Wextra -Werror -DFENRIR_SOLO5_TEST -c "$fixture" -o test.o
aarch64-solo5-none-static-cc "$@" -c
aarch64-solo5-none-static-ld -z solo5-abi=spt ./*.o -o image.spt
solo5-spt image.spt --solo5:quiet""", "sh", "/src/" + str(paths[0].relative_to(root)), *flags,
         *["/src/runtime/native/" + src for src in sources]], folder)
    report["results"].append(dict(fixture=name, heap_slots=capacity, mac_sha256=sha(folder / "mac"),
                                  spt_sha256=sha(folder / "image.spt")))
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(name, "passed on both targets", flush=True)
