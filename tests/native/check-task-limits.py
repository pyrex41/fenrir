"""Compare portable and native-profile task quotas with both installed ARM64 targets."""
import base64
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def checked(args, case, log):
    result = subprocess.run(args, cwd=case, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=120)
    (case / log).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"{log}: {result.stdout}")
    return result.stdout


def main(cli, out):
    fixtures = Path(__file__).resolve().parent
    frontend = fixtures.parents[1] / "frontend/fenrir.sh"
    out.mkdir(parents=True, exist_ok=False)
    profile = json.loads(checked([cli, "profile"], out, "profile.json"))
    limits = profile["limits"]
    children = limits["max_live_nonroot_children"]
    handlers = limits["max_inherited_handlers"]
    cases = [("quota-children", children, "42"), ("quota-children", children + 1, "TaskLimit"),
             ("quota-handlers", handlers, "42"), ("quota-handlers", handlers + 1, "TaskLimit"),
             ("retained-task-handle", None, "#x6162")]
    for name, count, native in cases:
        case = out / (f"{name}-{count}" if count is not None else name)
        case.mkdir()
        source = name + ".fen"
        shutil.copyfile(fixtures / source, case / source)
        if count is not None:
            (case / "main.fen").write_text(f'(library "{source}")\n(define main {{I64 --> I64}} n -> (exercise {count}))\n')
            source = "main.fen"
        portable = "#x6162" if count is None else "42"
        for policy in ("fifo", "highest", "prandom:7"):
            for mode, value in (("portable", portable), ("native", native)):
                args = (["sh", frontend, "run", source, policy] if mode == "portable" else
                        [cli, "model", "--profile", profile["id"], source, policy])
                trace = checked(args, case, f"{mode}-{policy.replace(':', '-')}.log")
                observations = [line for line in trace.splitlines() if line.startswith(("emit ", "outcome: "))]
                expected = "outcome: Trap TaskLimit" if value == "TaskLimit" else f"outcome: Ok {value}"
                if observations != [expected]:
                    raise ValueError((case, policy, mode, observations, expected))
        for target in profile["targets"]:
            image = case / target
            receipt = case / (target + ".json")
            checked([cli, "build", "--target", target, source, "-o", image], case, target + "-build.log")
            checked([cli, "record", target, image, "0", receipt], case, target + "-record.log")
            recorded = json.loads(receipt.read_bytes())
            output = base64.b64decode(recorded["observations"]).decode()
            if native == "TaskLimit":
                site = re.escape(name + ".fen")
                valid = recorded["exit_status"] == 1 and re.fullmatch(
                    rf"trap: TaskLimit\ntrap at: {site}:[1-9]\d*:[1-9]\d*\n", output)
            else:
                valid = recorded["exit_status"] == 0 and output == native + "\n"
            if not valid:
                raise ValueError((case, target, recorded["exit_status"], output))
        print(case.name, "passed portable and native-profile Shen and both ARM64 targets", flush=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
