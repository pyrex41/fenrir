"""Compare maximal bounded schedules, retaining both observations for replay."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MODES = ("model", "retry-reapplies")


def execute(command, log, stdin=None):
    with log.open("w") as stream:
        subprocess.run(command, cwd=ROOT, input=stdin, text=True, stdout=stream,
                       stderr=subprocess.STDOUT, check=True, timeout=180)
    data = log.read_text()
    if "uncaught error" in data or "Warning:" in data:
        raise RuntimeError(f"interpreter diagnostics in {log}")
    return data


def key(schedule):
    return json.dumps(schedule, separators=(",", ":"))


def add(rows, schedule, state):
    path = key(schedule)
    if path in rows and rows[path] != state:
        raise ValueError(f"nondeterministic observation for {path}")
    rows[path] = state


def gleipnir(mode, out):
    jit = Path(os.environ.get("FENRIR_SHEN_JIT", ROOT / "build/toolchain/shen-jit-0.7"))
    data = execute([jit / "bin/shen-jit", "script", HERE / "terminal-histories.shen",
                    jit / "lib", ROOT, out, mode], out / f"{mode}.shen.log")
    rows = {}
    for line in data.splitlines():
        if line.startswith("HISTORY "):
            add(rows, *json.loads(line[8:]))
    if not rows:
        raise ValueError("empty Gleipnir result")
    return rows


def event(job):
    return ["accepted", [0, 0, 0, job, job]]


def compare(mode, out, replay, maude_mode):
    left = gleipnir(mode, out)
    right = maude(maude_mode, out)
    paths = sorted(left.keys() | right.keys())
    if replay:
        paths = [key(replay["schedule"])]
    differences = 0
    with (out / f"{mode}.differences.jsonl").open("w") as stream:
        for path in paths:
            if left.get(path) != right.get(path):
                differences += 1
                print(json.dumps(dict(machine=mode, maude_machine=maude_mode, schedule=json.loads(path),
                                      gleipnir=left.get(path), maude=right.get(path))), file=stream)
            if replay:
                print(json.dumps(dict(schedule=json.loads(path), gleipnir=left.get(path),
                                      maude=right.get(path))))
                if path not in left and path not in right:
                    raise ValueError("schedule absent on both sides")
                for side, observed in (("gleipnir", left.get(path)), ("maude", right.get(path))):
                    if key(replay[side]) != key(observed):
                        raise ValueError(f"{side} observation differs from retained witness")
    print(f"{mode}: Gleipnir {len(left)}, Maude {len(right)}, differences {differences}")
    return differences


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("--mutation-control", action="store_true", help="compare the correct Shen model against faulty Maude retry")
    parser.add_argument("--replay", type=Path, help="one JSON line from a differences file")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    replay = json.loads(args.replay.read_text()) if args.replay else None
    modes = [replay["machine"]] if replay else MODES
    if args.mutation_control:
        modes = ["model"]
    if any(mode not in MODES for mode in modes):
        parser.error("unknown machine")
    count = 0
    for mode in modes:
        other = replay.get("maude_machine", mode) if replay else mode
        if args.mutation_control:
            other = "retry-reapplies"
        if other not in MODES:
            parser.error("unknown Maude machine")
        count += compare(mode, out, replay, other)
    if not count and not replay and not args.mutation_control:
        check_duplicate_job(out)
    return int(bool(count))


def check_duplicate_job(out):
    binary = os.environ.get("MAUDE") or shutil.which("maude")
    for policy, log, expected in (("correct", "correct-no-duplicate.log", "No solution."),
                                  ("reapply", "duplicate-job.log", "Solution 1 (state ")):
        query = (f"search [1, 3] initial({policy}) =>* st({policy},S:Nat,C:Nat,R:Nat,X:Nat,"
                 "2,pending,pending,U:Bool,V:Bool,submit :: crash :: submit :: nil) .\nquit\n")
        data = execute([binary, "-no-banner", "-batch", HERE / "accepted-job-retry.maude"],
                       out / log, query)
        if not any(line.startswith(expected) for line in data.splitlines()):
            raise ValueError(f"unexpected duplicate-job reachability for {policy}")


def maude(mode, out):
    policy = "correct" if mode == "model" else "reapply"
    binary = os.environ.get("MAUDE") or shutil.which("maude")
    if not binary:
        raise SystemExit("Run under nix shell .#maude or set MAUDE to the executable")
    pattern = f"st({policy},S:Nat,C:Nat,R:Nat,X:Nat,N:Nat,A:Status,B:Status,U:Bool,V:Bool,H:History)"
    query = f"set print mixfix off .\nsearch initial({policy}) =>! {pattern} .\nquit\n"
    data = execute([binary, "-no-banner", "-no-advise", "-batch", HERE / "accepted-job-retry.maude"],
                   out / f"{mode}.maude.log", query)
    if "No more solutions." not in data:
        raise ValueError("incomplete Maude search")
    rows = {}
    for block in re.split(r"\nSolution \d+ \(state \d+\)\n", data)[1:]:
        fields = dict(re.findall(r"^([NABUV]) --> (\w+)$", block, re.M))
        history = re.search(r"^H --> (.*(?:\n +[^\n]*)*)", block, re.M)[1]
        tokens = re.findall(r"submit|crash|ack\(\s*\d+\s*\)|delivery\(\s*\d+,\s*(?:true|false)\s*\)", history)
        if len(tokens) != history.count("_::_"):
            raise ValueError(f"unrecognized Maude history {history}")
        path, trace = [], []
        for token in reversed(tokens):
            if token == "submit":
                path.append(["submit", 0, 0, 0])
            elif token == "crash":
                path.append(["crash"])
            elif token.startswith("ack"):
                receipt = event(int(re.search(r"\d+", token)[0]))
                trace.append(receipt)
                path.append(["respond", receipt])
            else:
                path.append(["complete", 0, int(re.search(r"\d+", token)[0]), "true" in token])
        n = int(fields["N"])
        jobs = [[i, i, fields["AB"[i]]] for i in range(n)]
        store = [[[i, 0] for i in range(n)], jobs,
                 [[0, 0, event(n - 1)[1]]] if n else [], n]
        outbox = [event(i) for i, name in enumerate("UV") if fields[name] == "true"]
        add(rows, path, [[store], outbox, trace])
    if not rows:
        raise ValueError("empty Maude result")
    return rows


if __name__ == "__main__":
    sys.exit(main())
