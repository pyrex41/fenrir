"""Run source-annotated native tests at the frontend's default I64 input."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def expected(source):
    marker = chr(92) * 2 + " > "
    lines = [s[len(marker):] for s in source.read_text().splitlines() if s.startswith(marker)]
    if not lines or any(not s.startswith('emit ') for s in lines[:-1]):
        raise ValueError("expected event lines followed by one outcome annotation")
    outcome = re.fullmatch(r"outcome: (Ok|Trap) (.+)", lines[-1])
    if not outcome:
        raise ValueError("missing final outcome annotation")
    kind, value = outcome.groups()
    if kind == "Trap":
        lines[-1] = "trap: " + value
        return 1, lines
    lines[-1] = {"true": "1", "false": "0"}.get(value, value)
    return 0, lines


def run(source, target):
    status, lines = expected(source)
    with tempfile.TemporaryDirectory() as work:
        subprocess.run([ROOT / "bin/fenrir", "build", "--target", target, source,
                        "-o", Path(work) / "image"], check=True, timeout=120)
        proc = subprocess.run(["sh", ROOT / "tools/aarch64/run-image.sh", target, work, "0"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    output = proc.stdout.decode().splitlines()
    if status == 1:
        marker = chr(92) * 2 + " native trap-site: "
        sites = [s[len(marker):] for s in source.read_text().splitlines() if s.startswith(marker)]
        if sites:
            if len(sites) != 1 or not re.fullmatch(r"[1-9]\d*:[1-9]\d*", sites[0]):
                raise ValueError("expected one positive line:column trap-site annotation")
            lines.append(f"trap at: {source}:{sites[0]}")
        elif output and re.fullmatch(r"trap at: .+:[1-9]\d*:[1-9]\d*", output[-1]):
            output.pop()
        else:
            raise ValueError(f"missing source location for native trap: {output!r}")
    if proc.returncode != status or output != lines:
        raise ValueError(f"expected exit {status} and {lines!r}, got {proc.returncode} and {output!r}")


def main():
    target, *files = sys.argv[1:]
    failed = 0
    for name in files:
        try:
            run(Path(name), target)
            print("PASS", name, flush=True)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            failed += 1
            print(f"FAIL {name}: {exc}", file=sys.stderr)
    print(f"{target}: {len(files) - failed} passed, {failed} failed")
    return int(failed != 0)


if __name__ == "__main__":
    sys.exit(main())
