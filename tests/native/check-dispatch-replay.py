"""Check forced dispatch, FIFO recording, rejection and replay on both ARM64 targets."""
import base64
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=False)


def run(*args, success=True):
    result = subprocess.run([root / "bin/fenrir", *args], capture_output=True, text=True, timeout=120)
    if (result.returncode == 0) != success:
        raise ValueError((args, result.returncode, result.stdout, result.stderr))


first = b'emit "first": 0 (task 1)\n'
second = b'emit "second": 0 (task 2)\n'
reverse = [0, 0, 2, 2, 2, 1, 1, 1, 0, 0]
for target in ("macos-arm64", "solo5-arm64-spt"):
    dest = out / target
    dest.mkdir()
    image = dest / "image"
    run("build", "--target", target, root / "tests/native/dispatch-order.fen", "-o", image)
    for name, ids, expected in [("fifo", None, first + second), ("reversed", reverse, second + first),
                                ("unavailable", [2] + reverse[1:], None),
                                ("short", reverse[:-1], None), ("trailing", reverse + [0], None)]:
        receipt = dest / (name + ".json")
        args = []
        if ids is not None:
            path = dest / (name + "-choices.json")
            path.write_text(json.dumps(ids))
            args.append(path)
        run("record-schedule", target, image, "0", receipt, *args, success=expected is not None)
        if expected is None:
            if receipt.exists():
                raise ValueError("rejected schedule published a receipt")
            continue
        record = json.loads(receipt.read_text())
        if (base64.b64decode(record["observations"]) != expected + b"0\n"
                or ids is not None and record["dispatches"] != ids):
            raise ValueError("unexpected dispatches or events")
        run("replay", image, receipt)
    print(target, "passed forced-order and rejection checks", flush=True)
