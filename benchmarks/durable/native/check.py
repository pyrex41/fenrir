"""Drive actual Store.commit calls, including abandoning a pending request."""
import json
from pathlib import Path
import runpy
import struct
import subprocess
import sys

helpers = runpy.run_path(str(Path(__file__).resolve().parents[1] / "check-ports.py"))
expected = dict(helpers["cases"]())
expected.update(helpers["cases"](wide=True))
packets = []
for pkt in expected:
    if pkt[0] == 2:
        packets.extend([pkt[1:12] if pkt[1] in (3, 4) else pkt[1:5], pkt])
# An aborted commit receives no reply. The next command is independent.
packets[:0] = [bytes([0, 0, 0, 0]), bytes([1, 1, 0, 1])]
wire = b"".join(struct.pack(">H", len(p)) + p for p in packets)
result = subprocess.run(sys.argv[1:], input=wire, capture_output=True, timeout=45, check=True)
rest = result.stdout
for packet in packets:
    size, = struct.unpack(">H", rest[:2])
    actual = json.loads(rest[2:2+size])
    if actual != expected[packet]:
        raise ValueError((packet, expected[packet], actual))
    rest = rest[2+size:]
if rest:
    raise ValueError("unexpected trailing data")
print(len(packets), "verified native transactions and outcomes")

def frame(payload):
    return struct.pack(">H", len(payload)) + payload


submit = bytes([0, 0, 0, 0])
second = bytes([0, 1, 0, 0])
committed = next(p for p in expected if p[:6] == b"\x02" + submit + b"\x00")
wrong_command = b"\x02" + second + committed[5:]
faults = [
    ("partial header", b"\x00", []),
    ("partial command", b"\x00\x04\x00\x00", []),
    ("oversized packet", b"\x00\x41", []),
    ("empty command", b"\x00\x00", []),
    ("negative extended key", frame(bytes([3, 0, 128]) + bytes(8)), []),
    ("unknown tenant", frame(bytes([0, 2, 0, 0])), []),
    ("unsolicited reply", frame(committed), []),
    ("disconnect during commit", frame(submit), [submit]),
    ("partial reply", frame(submit) + frame(committed)[:-1], [submit]),
    ("wrong command echo", frame(submit) + frame(wrong_command), [submit]),
    ("unknown reply kind", frame(submit) + frame(b"\x02" + submit + b"\xff"), [submit]),
    ("extra receipt byte", frame(submit) + frame(committed + b"\x00"), [submit]),
    ("stale reply after replacement", frame(submit) + frame(second) + frame(committed), [submit, second]),
]
for name, wire, sent in faults:
    proc = subprocess.run(sys.argv[1:], input=wire, capture_output=True, timeout=15)
    if proc.returncode != 2:
        raise ValueError((name, "expected protocol failure", proc.returncode, proc.stderr))
    rest = proc.stdout
    for command in sent:
        size, = struct.unpack(">H", rest[:2])
        if json.loads(rest[2:2+size]) != expected[command]:
            raise ValueError((name, "transaction mismatch"))
        rest = rest[2+size:]
    if rest:
        raise ValueError((name, "unexpected response", rest))
print(len(faults), "protocol failures exited without an application acknowledgement")
