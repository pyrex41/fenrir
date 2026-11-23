"""Validate the finite native worker packet contract with independently built values."""
from itertools import product
import json
from pathlib import Path
import struct
import subprocess
import sys


def integer(x):
    return ["int", str(x)]


def data(typ, name, *fields):
    return ["data", typ, name, *fields]


def cases(wide=False):
    keys = [2, 256, 2**32 + 17, 2**63 - 1] if wide else range(2)
    for t, k, d in product(range(2), keys, range(2)):
        def command(op):
            if wide:
                return bytes([3 + op, t]) + struct.pack(">q", k) + bytes([d])
            return bytes([op, t, k, d])
        cap = data("Cap", "Tenant", integer(t))
        for opcode, guard, ops in [
                (0, "Once", [data("Write", "StageJob"), data("Write", "PutReport", integer(d), ["bytes", f"{d:02x}"]),
                             data("Write", "RecordKey", integer(k), integer(d))]),
                (1, "Pending", [data("Write", "Finish", integer(k), ["bool", bool(d)])])]:
            writes = data("Writes", "Done")
            for op in reversed(ops):
                writes = data("Writes", "Then", op, writes)
            yield command(opcode), data("Tx", "Tx", cap, data("Guard", guard, integer(k)), writes)
        for kind, old in [(0,0), (1,d), (1,1-d)]:
            fields = [t, k, old if kind else d, 1, 0]
            receipt = data("Receipt", "Receipt", *map(integer, fields))
            response = (data("Response", "Conflict", integer(t), integer(k)) if kind and old != d
                        else data("Response", "Accepted", receipt))
            yield bytes([2])+command(0)+bytes([kind,old])+struct.pack(">5q", *fields), response
        for kind in [2,3]:
            for opcode, name in [(0,"Refused"), (1,"Delivered")]:
                yield bytes([2])+command(opcode)+bytes([kind]), data("Response", name)


def check(binary):
    rows = [*cases(), *cases(wide=True)]
    wire = b"".join(struct.pack(">H", len(pkt))+pkt for pkt, _ in rows)
    run = subprocess.run([binary], input=wire, capture_output=True, check=True, timeout=5)
    buf = memoryview(run.stdout)
    for packet, expected in rows:
        size, = struct.unpack(">H", buf[:2])
        actual = json.loads(bytes(buf[2:2+size]))
        if actual != expected:
            raise ValueError((packet, expected, actual))
        buf = buf[2+size:]
    if buf:
        raise ValueError("extra output")
    print(binary, len(rows), "verified replies")


if __name__ == "__main__":
    for path in sys.argv[1:]:
        check(Path(path).resolve())
