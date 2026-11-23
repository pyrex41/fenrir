"""Serve loopback TCP with a persistent Solo5 router connected by two pipes."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def main(directory, port, memory_mib, single_guest_cpu=False, cidfile=None, guest_cpu=None):
    image = os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
    cpu = 0 if single_guest_cpu else guest_cpu
    cpu_options = [f"--cpuset-cpus={cpu}"] if cpu is not None else []
    # Verify the kernel-enforced mask in the container before starting the tender.
    check = (f"grep -Eq '^Cpus_allowed_list:[[:space:]]+{cpu}$' /proc/self/status && "
             if cpu is not None else "")
    identity_options = ["--cidfile", str(cidfile)] if cidfile else []
    command = ["docker", "run", "--rm", "-i", "--platform", "linux/arm64", "--network", "none",
               *cpu_options, *identity_options, "-v", f"{directory.resolve()}:/guest:ro", "--entrypoint", "sh", image, "-ec",
               check + f"exec /opt/solo5-install/bin/solo5-spt --mem={memory_mib} --net:input=@0 --net:output=@2 "
               "/guest/http.spt --solo5:quiet 2>&1 1>/dev/null"]
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as guest:
        try:
            with subprocess.Popen([directory / "ingress", port], stdin=guest.stdout,
                                  stdout=guest.stdin) as ingress:
                guest.stdout.close()
                guest.stdin.close()
                try:
                    while ingress.poll() is None and guest.poll() is None:
                        time.sleep(0.1)
                    return ingress.returncode if ingress.returncode is not None else 2
                finally:
                    if ingress.poll() is None:
                        ingress.terminate()
                    ingress.wait(timeout=5)
        finally:
            try:
                guest.wait(timeout=5)
            except subprocess.TimeoutExpired:
                guest.terminate()
                guest.wait(timeout=5)


if __name__ == "__main__":
    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("port")
    parser.add_argument("--memory-mib", type=int, default=32)
    affinity = parser.add_mutually_exclusive_group()
    affinity.add_argument("--single-guest-cpu", action="store_true")
    affinity.add_argument("--guest-cpu", type=int)
    parser.add_argument("--cidfile", type=Path)
    args = parser.parse_args()
    if args.guest_cpu is not None and args.guest_cpu < 0:
        parser.error("guest CPU must be nonnegative")
    if args.memory_mib < 1:
        parser.error("guest memory must be positive")
    try:
        sys.exit(main(args.directory, args.port, args.memory_mib, args.single_guest_cpu, args.cidfile, args.guest_cpu))
    except KeyboardInterrupt:
        sys.exit(0)
