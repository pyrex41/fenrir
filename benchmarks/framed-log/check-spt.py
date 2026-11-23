"""Boot the released stream guest with sector-padded input and exact logical EOF."""
from pathlib import Path
from boundary_cases import all_keys, boundary_rejections
import os
import subprocess
import sys
import tempfile


def main(image):
    container = os.getenv("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
    with tempfile.TemporaryDirectory() as tmp:
        disk = Path(tmp) / "input"
        command = ["docker", "run", "--rm", "-i", "--network", "none", "--platform", "linux/arm64",
                   "-v", f"{image.resolve()}:/stream:ro",
                   "--entrypoint", "sh", container, "-ec",
                   'cat > /tmp/input && exec /opt/solo5-install/bin/solo5-spt '
                   '--block:input=/tmp/input /stream --solo5:quiet "$1"', "sh"]

        def check(size, expected, status):
            with disk.open("ab") as output:
                output.write(b"\xa5" * (max(512, (size + 511) // 512 * 512) - size))
            assert disk.stat().st_size % 512 == 0
            with disk.open("rb") as source:
                result = subprocess.run([*command, str(size)], stdin=source, capture_output=True, timeout=60)
            if (result.returncode, result.stdout, result.stderr) != (status, expected, b""):
                raise ValueError((size, result.returncode, result.stdout, result.stderr))

        for size in [0, 1, 511, 512, 513, 8191, 8192, 8193]:
            if size < 2:
                disk.write_bytes(bytes(size))
                check(size, b"" if size == 0 else b"reject 1\n", int(size != 0))
            else:
                disk.write_bytes((size - 2).to_bytes(2, "big") + b"\x07" + b"\xff" * (size - 3))
                check(size, f"7 1 {size-3} {(size-3)*255}\n".encode(), 0)
        mixed = bytes.fromhex("00013f00030000ff00043f616263")
        for payload, expected, status in [
                (mixed, b"0 1 2 255\n63 2 3 294\n", 0),
                (mixed + bytes.fromhex("0000"), b"reject 14\n", 1),
                (mixed + bytes.fromhex("000140"), b"reject 16\n", 1),
                (mixed + bytes.fromhex("00040161"), b"reject 18\n", 1)]:
            disk.write_bytes(payload)
            check(len(payload), expected, status)
        payload, expected = all_keys()
        disk.write_bytes(payload)
        check(len(payload), expected, 0)
        boundary_cases = 0
        for payload, offset in boundary_rejections():
            disk.write_bytes(payload)
            check(len(payload), f"reject {offset}\n".encode(), 1)
            boundary_cases += 1
        block = b"\xff\xff\x07" + b"\xff" * 65534
        with disk.open("wb") as output:
            for _ in range(1024):
                output.write(block)
        check(1024 * len(block), b"7 1024 67106816 17112238080\n", 0)
        print(f"Solo5 block stream passed {14 + boundary_cases} cases")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
