"""Build and measure the four alpha kernels on one target, then score the raw reports."""
import argparse
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys

here = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("macos-arm64", "solo5-arm64-spt"))
    parser.add_argument("output", type=Path, help="new campaign directory")
    args = parser.parse_args()
    out = args.output.resolve()
    env = os.environ.copy()
    if args.target == "macos-arm64":
        bundled = here.parent / "build/toolchain/koka-3.2.3/bin/koka"
        compiler = env.get("KOKA") or (str(bundled) if bundled.is_file() else "koka")
        executable = shutil.which(compiler)
        if executable is None:
            parser.error("macOS kernel comparisons require Koka; set KOKA to its executable")
        # The suites compile in temporary directories, so preserve an absolute path.
        env["KOKA"] = str(Path(executable).resolve())
        suites = ("prover/measure-fenrir.py", "http/measure-router-mac.py", "framed-log/measure.py")
        stream_args = ["mixed", "--rotation-cycles", "8"]
    else:
        suites = ("prover/measure-spt.py", "http/measure-router-spt.py", "framed-log/measure-spt.py")
        image = env.get("FENRIR_SOLO5_IMAGE", "fenrir-track1-solo5:38e0c348be23-arm64")
        env["FENRIR_SOLO5_IMAGE"] = subprocess.check_output(
            ["docker", "image", "inspect", "--format", "{{.Id}}", image], text=True, timeout=30).strip()
        stream_args = ["mixed"]
    out.mkdir(parents=True, exist_ok=False)
    reports = []
    for name, suite in zip(("prover", "router", "stream"), suites):
        print(f"{args.target} {name}: {out / (name + '.log')}", flush=True)
        command = [sys.executable, here / suite, out / name]
        if name == "stream":
            command.extend(stream_args)
        with (out / (name + ".log")).open("x") as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        reports.append(Path(name) / "report.json")
    result = subprocess.check_output([sys.executable, here / "kernel-scorecard.py", *reports],
                                     cwd=out, text=True, timeout=60)
    (out / "score.json").write_text(result)
    score = json.loads(result)
    print(f"{score['target']} {score['kernel_verdict']}, elapsed ratio {score['elapsed_ratio_geomean']:.3f}")


if __name__ == "__main__":
    main()
