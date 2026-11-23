"""Compare Shen observations with native execution on both ARM64 targets."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="new evidence directory")
parser.add_argument("fixtures", nargs="*", help="fixture filenames (default: handler fixtures)")
parser.add_argument("--all", action="store_true", help="run every frontend round-trip fixture")
parser.add_argument("--native-fixtures", action="store_true", help="check named, annotated programs from tests/native")
parser.add_argument("--cli", type=Path, default=root / "bin/fenrir", help="Fenrir CLI used to build both images")
args = parser.parse_args()
if args.all and args.fixtures:
    parser.error("choose --all or specific fixture names")
if args.native_fixtures and not args.fixtures:
    parser.error("--native-fixtures requires fixture filenames")
fixtures = root / ("tests/native" if args.native_fixtures else "tests/frontend/roundtrip")
cli = args.cli.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
report = []


def run(command, cwd):
    return subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=120)


if args.fixtures:
    sources = [fixtures / name for name in args.fixtures]
else:
    sources = sorted(fixtures.glob("*.fen"))
    if not args.all:
        sources = [p for p in sources if any(
            line.startswith("(effect ") for line in p.read_text().splitlines())]
if not sources:
    sys.exit(f"no round-trip fixtures found in {fixtures}")
if args.native_fixtures:
    profile = run([cli, "profile"], root)
    profile.check_returncode()
    profile_id = json.loads(profile.stdout)["id"]
    model_command = [cli, "model", "--profile", profile_id]
else:
    model_command = ["sh", root / "frontend/fenrir.sh", "run"]
for source in sources:
    case = out / source.stem
    case.mkdir()
    model = run([*model_command, source.name], source.parent)
    (case / "shen.txt").write_text(model.stdout)
    if model.returncode:
        raise ValueError((source, model.returncode, model.stdout))
    expected = []
    expected_code = None
    if args.native_fixtures:
        marker = r"\\ > "
        annotated = [line[len(marker):] for line in source.read_text().splitlines() if line.startswith(marker)]
        observations = [line for line in model.stdout.splitlines() if line.startswith(("emit ", "outcome: "))]
        if not annotated or observations != annotated:
            raise ValueError(f"{source.name}: expected {annotated!r}, Shen reported {observations!r}")
    for line in model.stdout.splitlines():
        if line.startswith(("emit ", "trap at:")):
            expected.append(line)
        elif line.startswith("outcome: deadlock: "):
            expected_code = 1
            expected.append(line[len("outcome: "):])
        elif line.startswith("outcome: Ok "):
            expected_code = 0
            expected.append(line[len("outcome: Ok "):])
        elif line.startswith("outcome: Trap "):
            expected_code = 1
            expected.append("trap: " + line[len("outcome: Trap "):])
    if expected_code is None:
        raise ValueError((source, model.stdout))
    for target in ("macos-arm64", "solo5-arm64-spt"):
        work = case / target
        work.mkdir()
        image = work / "image"
        build = run([cli, "build", "--target", target, source.name, "-o", image], source.parent)
        (work / "build.txt").write_text(build.stdout)
        record = dict(fixture=source.name, target=target, expected=expected,
                      source_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
        if args.native_fixtures:
            record["model_profile"] = profile_id
        if build.returncode:
            record.update(status="build-failed", exit=build.returncode)
        else:
            actual = run(["sh", root / "tools/aarch64/run-image.sh", target, work, "0"], root)
            (work / "actual.txt").write_text(actual.stdout)
            lines = actual.stdout.splitlines()
            if expected_code == 1 and expected[-1].startswith("trap: ") and not any(line.startswith("trap at:") for line in expected):
                # The task oracle reports the trap class without its native source site.
                if lines and re.fullmatch(r"trap at: " + re.escape(source.name) + r":[1-9]\d*:[1-9]\d*", lines[-1]):
                    record["native_trap_site"] = lines.pop()
                else:
                    lines.append("missing native trap location")
            record.update(status="pass" if actual.returncode == expected_code and
                          lines == expected else "mismatch", exit=actual.returncode,
                          image_sha256=hashlib.sha256(image.read_bytes()).hexdigest())
        report.append(record)
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(target, source.name, record["status"], flush=True)
sys.exit(int(any(row["status"] != "pass" for row in report)))
