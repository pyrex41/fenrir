"""Build the macOS HTTP reference services and record the exact inputs and outputs."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

here = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(destination):
    if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
        raise ValueError("requires macOS ARM64")
    destination.mkdir(parents=True, exist_ok=False)
    records = {}
    with tempfile.TemporaryDirectory() as work:
        work = Path(work)
        for language, compiler, source, flags in [
            ("rust", "rustc", "reference.rs", ["--edition=2021", "-O", "-C", "overflow-checks=yes", "-o", "rust"]),
            ("nim", "nim", "reference.nim", ["c", "-d:release", "--overflowChecks:on", "--out:nim"]),
        ]:
            tool = shutil.which(compiler)
            if not tool:
                raise ValueError(f"missing {compiler}")
            shutil.copyfile(here / source, work / source)
            argv = [tool, *flags, source]
            version = subprocess.check_output([tool, "--version"], text=True).strip()
            subprocess.run(argv, cwd=work, check=True, timeout=180)
            shutil.copy2(work / language, destination / language)
            records[language] = dict(argv=argv, version=version, source=source,
                                     source_sha256=sha(work / source), binary_sha256=sha(destination / language))
    (destination / "reference-build.json").write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
