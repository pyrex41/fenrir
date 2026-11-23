"""Run any profile-1 executable against independently constructed byte streams."""
from boundary_cases import all_keys, boundary_rejections
import hashlib
import subprocess
import sys
import tempfile


def frame(key, payload):
    return (1 + len(payload)).to_bytes(2, "big") + bytes([key]) + payload


def check(stream, expected, rejected=None):
    for chunk in (1, 2, 7, 8192, 65536):
        run = subprocess.run([sys.argv[1], str(chunk)], input=stream,
                             capture_output=True, timeout=20)
        result = (run.returncode, run.stdout, run.stderr)
        want = (0, expected, b"") if rejected is None else (1, b"", f"reject {rejected}\n".encode())
        if result != want:
            raise ValueError((chunk, result, want))


check(b"", b"")
check(*all_keys())
small = frame(63, b"") + frame(0, b"\x00\xff") + frame(63, b"abc")
check(small, b"0 1 2 255\n63 2 3 294\n")
for suffix, relative in [(b"\x00", 1), (b"\x00\x00", 0), (b"\x00\x01", 2),
                         (b"\x00\x01\x40", 2), (b"\x00\x04\x01ab", 5)]:
    check(small + suffix, b"", len(small) + relative)

for payload, offset in boundary_rejections():
    check(payload, b"", offset)

# Feed 64 MiB through the OS file interface. Generate the expected summary
# algebraically so the oracle does not share the parser's state machine.
with tempfile.TemporaryFile() as stream:
    block = frame(7, b"\xff" * 65534)
    for _ in range(1024):
        stream.write(block)
    stream.seek(0)
    run = subprocess.run([sys.argv[1]], stdin=stream, capture_output=True, timeout=30)
    wanted = f"7 1024 {65534 * 1024} {65534 * 1024 * 255}\n".encode()
    if (run.returncode, run.stdout, run.stderr) != (0, wanted, b""):
        raise ValueError("large stream mismatch")
    print("large summary SHA-256", hashlib.sha256(run.stdout).hexdigest())
