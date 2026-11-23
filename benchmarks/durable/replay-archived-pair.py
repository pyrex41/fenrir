"""Replay one extracted checker variant and compare its verdict with the recorded one."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive_directory", type=Path)
parser.add_argument("variant", choices=("canonical", "cached"))
parser.add_argument("shen_jit_prefix", type=Path)
args = parser.parse_args()
root = args.archive_directory.resolve()
jit = args.shen_jit_prefix.resolve()
source = root / args.variant
history = root / "input/history.json"
header = json.loads(history.read_bytes())
files = [history, *(history.with_name(f"history.json.events.{i}") for i in range(header["chunks"]))]
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
if hashes != json.loads((root / "input-hashes.json").read_bytes()):
    raise ValueError("archived input differs from recorded hashes")
expected = json.loads((root / "canonical-verdict.jsonl").read_bytes())
expected["history"] = str(history)
with TemporaryDirectory() as tmp:
    work = Path(tmp)
    listing = work / "list"
    listing.write_text(str(history) + "\n")
    subprocess.run([jit / "bin/shen-jit", "script", source / "harness/service-history.shen",
                    jit / "lib", source, work, "check", listing],
                   stdin=subprocess.DEVNULL, check=True, timeout=2400)
    observed = json.loads((work / "verdicts.jsonl").read_bytes())
    if observed != expected:
        raise ValueError(f"replayed verdict differs: {observed}")
