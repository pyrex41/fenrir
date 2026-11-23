"""Compare the immutable and heap observations for each bounded alias shape."""
from pathlib import Path
from itertools import product
import argparse
import base64
import hashlib
import json
import re
import subprocess
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("maude", nargs="?", default="maude")
parser.add_argument("--receipts", type=Path, help="directory with both native images and their 24 input receipts")
args = parser.parse_args()
images = {}
if args.receipts is not None:
    for target in ("macos-arm64", "solo5-arm64-spt"):
        images[target] = hashlib.sha256((args.receipts / target).read_bytes()).hexdigest()
shapes = [("p0", "branches(c0,c1,cf)"), ("p1", "branches(c0,c0,cf)"), ("p1", "branches(c0,c1,cf)")]

model = Path(__file__).with_name("constructor-reuse.maude")
for policy, first, second in product(("checked", "parentOnly"), ("false", "true"), ("false", "true")):
    query = (f"search start({policy},{first},{second}) =>! result(Q:Parent,H:Parents,K:Children,"
             "S:Observation,T:Observation) .\nquit\n")
    run = subprocess.run([args.maude,
                          "-no-banner", "-no-advise", str(model)],
                         input=query, text=True, capture_output=True, check=True, timeout=30)
    if run.stderr.strip() or "No more solutions." not in run.stdout:
        raise RuntimeError(run.stderr + run.stdout)
    blocks = re.split(r"Solution \d+ \(state \d+\)", run.stdout)[1:]
    seen = {}
    for block in blocks:
        fields = dict(re.findall(r"^([QHKST])(?::\w+)? --> (.+)$", block, re.MULTILINE))
        key = (fields["Q"], fields["H"].replace(" ", ""))
        observed = tuple(fields[k].replace(" ", "") for k in ("S", "T"))
        if key in seen or fields["K"].replace(" ", "") != f"pairs({first},{second},false)":
            raise ValueError(block)
        seen[key] = observed
    if set(seen) != set(shapes):
        raise ValueError(seen)
    for key, (source, lowered) in seen.items():
        corrupts = policy == "parentOnly" and key == ("p1", "branches(c0,c0,cf)")
        flipped = "false" if first == "true" else "true"
        survivor = second if key == ("p1", "branches(c0,c1,cf)") else first
        if source != f"observed({flipped},{survivor})" or lowered != (
                f"observed({flipped},{flipped})" if corrupts else source):
            raise ValueError((policy, key, source, lowered))
        if policy == "checked":
            index = 4 * shapes.index(key) + 2 * (first == "true") + (second == "true")
            for target, digest in images.items():
                path = args.receipts / f"{target}-{index}.json"
                receipt = json.loads(path.read_bytes())
                if (receipt["schema"] not in ("fenrir-native-observations/2", "fenrir-native-observations/3") or receipt["target"] != target
                        or receipt["input"] != str(index) or receipt["image_sha256"] != digest
                        or type(receipt["exit_status"]) is not int or receipt["exit_status"] != 0
                        or base64.b64decode(receipt["observations"], validate=True)
                        != f"(tuple {flipped} {survivor})\n".encode()):
                    raise ValueError(f"{path}: native observation differs from the checked model or image")
        print(policy, first, second, *key, source, lowered)
