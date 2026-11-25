"""Measure repeated, output-checked Fenrir search and checking on macOS ARM64."""
import hashlib
import json
import os
import runpy
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from fenrir_driver import workload
from verify import formula


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rust_literal(term):
    if isinstance(term, str):
        return f"Term::Atom({1 << (ord(term) - ord('a'))})"
    if term[0] == "!":
        return f"Term::Not(Box::new({rust_literal(term[1])}))"
    return (f"Term::Binary('{term[0]}',Box::new({rust_literal(term[1])}),"
            f"Box::new({rust_literal(term[2])}))")


def rust_image(here, out, corpus, rows, lane):
    # Share the actual search routine with the verified row-producing CLI.
    ref = out / "reference.rs"
    ref.write_bytes((here / "reference.rs").read_bytes())
    goals = []
    lines = ['fn round(goals: &[Term]) -> u64 { let mut total = 0;']
    for case, row in zip(corpus.read_text().splitlines(), rows.splitlines()):
        _, _, budget, *tokens = case.split()
        _, kind, nodes, witness = row.split()
        if lane == "check" and kind != "proof":
            continue
        goal = f"&goals[{len(goals)}]"
        goals.append(rust_literal(formula(iter(tokens))))
        if lane == "check":
            lines.append(f'total += u64::from(verify_proof({goal}, b"{witness}"));')
            continue
        valid = {"proof": f'result.is_ok() && proof == "{witness}"',
                 "model": f'matches!(result, Err(Failure::Model({witness})))',
                 "exhausted": 'matches!(result, Err(Failure::Exhausted))'}[kind]
        lines.append(f"""{{ let goal = {goal};
            let mut remaining = {budget};
            let mut proof = String::new();
            let result = search(VecDeque::from([(false, goal)]), 0, 0, &mut remaining, &mut proof);
            total += u64::from(remaining == {int(budget)-int(nodes)} && {valid}); }}""")
    lines = ['#[allow(dead_code)] mod reference { include!("reference.rs");', *lines,
             'total }', 'pub fn run(rounds: u64) -> u64 {',
             'let goals = [' + ','.join(goals) + '];',
             'let mut total = 0; for _ in 0..rounds { total += round(std::hint::black_box(&goals)); }',
             'total } }', 'fn main() {',
             'let rounds = std::env::args().nth(1).unwrap().parse().unwrap();',
             'println!("{}", reference::run(rounds)); }']
    src, binary = out / f"rust-{lane}.rs", out / f"rust-{lane}"
    src.write_text("\n".join(lines))
    started = time.perf_counter_ns()
    subprocess.run(["rustc", "-O", "-C", "overflow-checks=yes", src, "-o", binary], check=True)
    return binary, dict(build_ns=time.perf_counter_ns()-started, source_sha256=sha(src),
                        reference_sha256=sha(ref), image_sha256=sha(binary),
                        compiler=subprocess.check_output(["rustc", "-Vv"], text=True).strip())


def nim_literal(term):
    if isinstance(term, str):
        return f"Formula(op: '{term}')"
    fields = [f"op: '{term[0]}'", f"left: {nim_literal(term[1])}"]
    if len(term) == 3:
        fields.append(f"right: {nim_literal(term[2])}")
    return "Formula(" + ", ".join(fields) + ")"


def nim_image(here, out, corpus, rows, lane):
    ref = out / "reference.nim"
    ref.write_bytes((here / "reference.nim").read_bytes())
    inputs = ["include reference"]
    lines = ["proc oneRound(): int ="]
    for case, row in zip(corpus.read_text().splitlines(), rows.splitlines()):
        _, _, budget, *tokens = case.split()
        _, kind, nodes, witness = row.split()
        if lane == "check" and kind != "proof":
            continue
        name = f"input{len(inputs)}"
        inputs.append(f"let {name} = " + nim_literal(formula(iter(tokens))))
        lines.extend(["  block:", f"    let goal = {name}"])
        if lane == "check":
            lines.append(f'    if verifyProof(goal, "{witness}"): inc result')
        else:
            lines.extend([f"    var fuel = {budget}", '    var tape = ""',
                          "    let status = search(@[(false, goal)], 0, 0, 0, fuel, tape)",
                          f'    if status == {kind} and fuel == {int(budget)-int(nodes)} and tape == "{witness}": inc result'])
    lines.extend(["var total = 0", "for i in 0 ..< parseInt(paramStr(1)): total += oneRound()", "echo total"])
    src, binary = out / f"nim_{lane}.nim", out / f"nim-{lane}"
    src.write_text("\n".join(inputs + lines))
    flags = ["-d:release", "-d:proverBenchmark", "--mm:orc", "--overflowChecks:on"]
    started = time.perf_counter_ns()
    subprocess.run(["nim", "c", *flags, "--nimcache:" + str(out / f"nimcache-{lane}"),
                    "--out:" + str(binary), src], check=True, capture_output=True)
    return binary, dict(build_ns=time.perf_counter_ns()-started, source_sha256=sha(src),
                        reference_sha256=sha(ref), image_sha256=sha(binary), flags=flags,
                        compiler=subprocess.check_output(["nim", "--version"], text=True).strip())


def koka_image(here, out, corpus, rows, lane):
    literal = runpy.run_path(str(here / "run-koka.py"))["literal"]
    ref = here / "reference.kk"
    folder = out / f"koka-{lane}-build"
    folder.mkdir()
    lines = [ref.read_text().replace("module reference", "module reference\nimport std/os/env")]
    calls = []
    for case, row in zip(corpus.read_text().splitlines(), rows.splitlines()):
        _, kind, budget, *tokens = case.split()
        _, _, nodes, witness = row.split()
        if lane == "check" and kind != "proof":
            continue
        name = f"example{len(calls)}"
        goal = literal(formula(iter(tokens)))
        lines.append(f"val goal{len(calls)} = {goal}")
        goal = f"goal{len(calls)}"
        lines.append(f"fun {name}(): div int")
        if lane == "check":
            lines.append(f'  if verify-proof({goal},"{witness}") then 1 else 0')
        else:
            expected = {"proof": f'Proof(w) -> w == "{witness}"',
                        "model": f'Model(bits) -> bits == {witness}',
                        "exhausted": "Exhausted -> True"}[kind]
            lines.extend([f"  val (result,left) = search([(False,{goal})],0,0,{budget})",
                          "  val valid = match result", "    " + expected, "    _ -> False",
                          f"  if valid && left == {int(budget)-int(nodes)} then 1 else 0"])
        calls.append(name + "()")
    lines.extend(["fun one-round(): div int", "  " + " + ".join(calls),
                  "fun repeat-round(n:int, acc:int): div int",
                  "  if n <= 0 then acc else repeat-round(n - 1, acc + one-round())",
                  "fun main()", '  println(repeat-round(get-args().head("").parse-int.default(0),0))'])
    src, binary = folder / "reference.kk", out / f"koka-{lane}"
    src.write_text("\n".join(lines) + "\n")
    compiler = os.environ.get("KOKA", "koka")
    started = time.perf_counter_ns()
    subprocess.run([compiler, "-O2", "-o", binary, src.name], cwd=folder, check=True, timeout=180)
    binary.chmod(0o700)
    return binary, dict(build_ns=time.perf_counter_ns()-started, source_sha256=sha(src),
                        reference_sha256=sha(ref), image_sha256=sha(binary), flags=["-O2"],
                        compiler=subprocess.check_output([compiler, "--version"], text=True).strip())


def shen_image(here, out, corpus, rows, lane):
    literal = runpy.run_path(str(here / "run-shen.py"))["literal"]
    ref = here / "reference.shen"
    program = [ref.read_text()]
    total = "0"
    for case, row in zip(corpus.read_text().splitlines(), rows.splitlines()):
        _, kind, budget, *tokens = case.split()
        _, _, nodes, witness = row.split()
        if lane == "check" and kind != "proof":
            continue
        symbol = f"*pv-input-{len(program)}*"
        program.append(f"(set {symbol} {literal(formula(iter(tokens)))})")
        goal = f"(value {symbol})"
        if lane == "check":
            condition = f'(pv.verify {goal} "{witness}")'
        else:
            expected = f'[{kind} "{witness}" {int(budget) - int(nodes)}]'
            condition = f'(= (pv.search [[false {goal}]] [] [] {budget}) {expected})'
        total = f"(+ {total} (if {condition} 1 0))"
    program.extend([f"(define pv.round Unit -> {total})",
                    "(define pv.repeat 0 Acc -> Acc N Acc -> (pv.repeat (- N 1) (+ Acc (pv.round 0))))",
                    '(output "~A~%" (pv.repeat (hd (read-from-string (hd (tl (value *argv*))))) 0))'])
    src = out / f"shen-{lane}.shen"
    src.write_text("\n".join(program))
    default = here.parents[1] / "build/toolchain/shen-jit-0.12"
    jit = Path(os.environ.get("FENRIR_SHEN_JIT", default)).resolve() / "bin/shen-jit"
    return [jit, "script", src], dict(source_sha256=sha(src), reference_sha256=sha(ref),
                                      jit_sha256=sha(jit), jit=str(jit),
                                      compilation="script loading and JIT occur in each process")


def main():
    if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
        raise SystemExit("requires macOS ARM64")
    here = Path(__file__).resolve().parent
    root = here.parents[1]
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=False)
    identify = runpy.run_path(str(Path(__file__).resolve().parents[1] / "solo5-build-inputs.py"))["shared_inputs"]
    build_inputs = identify()
    corpus = here / "corpus-v1.txt"
    certs = here / "certificates-v1.txt"
    proofs = dict(row.split() for row in certs.read_text().splitlines())
    evidence = out / "reference-checks"
    preflight = subprocess.run(["sh", here / "check-references.sh", evidence],
                               text=True, stdout=subprocess.PIPE, check=True, timeout=360)
    (evidence / "checks.txt").write_text(preflight.stdout)
    rows = (evidence / "rust.rows").read_text()
    (out / "expected.rows").write_text(rows)
    report = dict(target="macos-arm64", machine=platform.platform(), corpus_sha256=sha(corpus),
                  host=subprocess.check_output(["uname", "-a"], text=True).strip(),
                  hardware=subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip(),
                  chip=subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                  certificates_sha256=sha(certs), repetitions=5000, samples=[], images={},
                  scope="fresh process per sample; repeated kernel and output validation inside process")
    report["reference_checks"] = dict(
        verifier_sha256=sha(here / "verify.py"),
        runner_sha256=sha(here / "check-references.sh"),
        evidence_sha256={p.name: sha(p) for p in sorted(evidence.iterdir())})
    emitter = [] if "backends/arm64/managed.shen" in build_inputs else ["tools/aarch64/native-image.mjs"]
    report["fenrir_build_inputs"] = {**build_inputs, **{
        name: sha(root / name) for name in ["bin/fenrir", "tools/aarch64/darwin-main.c",
                                             "tools/aarch64/native-profile-stamp.mjs", *emitter]
    }}
    commands = {}
    work = {"search": 0, "check": 0}
    for lane in work:
        source, cases, work[lane] = workload(here, corpus, proofs, rows, lane)
        path = out / f"{lane}.fen"
        path.write_text(source)
        image = out / lane
        start = time.perf_counter_ns()
        subprocess.run([root / "bin/fenrir", "build", "--target", "macos-arm64", path.name,
                        "-o", image], cwd=out, check=True)
        report["images"][lane] = dict(build_ns=time.perf_counter_ns()-start,
                                     source_sha256=sha(path), image_sha256=sha(image))
        commands[lane] = [image], cases

    for lane in ("search", "check"):
        for language, build in (("rust", rust_image), ("nim", nim_image), ("koka", koka_image), ("shen", shen_image)):
            binary, identity = build(here, out, corpus, rows, lane)
            label = f"{language}-{lane}"
            report["images"][label] = identity
            commands[label] = (binary if language == "shen" else [binary]), commands[lane][1]
            work[label] = work[lane]

    def sample(lane, rounds):
        cmd, cases = commands[lane]
        start = time.perf_counter_ns()
        output = subprocess.check_output([*cmd, str(rounds)], text=True, timeout=60)
        elapsed = time.perf_counter_ns() - start
        if output != f"{rounds * cases}\n":
            raise ValueError((lane, rounds, output))
        return dict(lane=lane, rounds=rounds, wall_ns=elapsed, result=int(output))

    report["startup"] = [sample(lane, 0) for lane in commands]
    report["warmup"] = [sample(lane, 10) for lane in commands]
    for pair in range(2 * len(commands)):
        names = list(commands)
        rotation = pair % len(names)
        names = names[rotation:] + names[:rotation]
        for lane in (names if pair < len(names) else reversed(names)):
            report["samples"].append(dict(pair=pair, **sample(lane, report["repetitions"])))
    for lane in commands:
        elapsed = statistics.median(s["wall_ns"] for s in report["samples"] if s["lane"] == lane)
        report["images"][lane]["work_unit"] = "tableau node" if lane.endswith("search") else "certificate"
        report["images"][lane]["units_per_round"] = work[lane]
        report["images"][lane]["work_units_per_second"] = work[lane] * report["repetitions"] * 1e9 / elapsed
    for lane in ("search", "check"):
        for language in ("rust", "nim", "koka", "shen"):
            ratios = []
            for pair in range(2 * len(commands)):
                times = {s["lane"]: s["wall_ns"] for s in report["samples"] if s["pair"] == pair}
                ratios.append(times[lane] / times[f"{language}-{lane}"])
            rng = random.Random(1147)
            boot = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            report[f"fenrir_over_{language}_{lane}"] = dict(paired_median=statistics.median(ratios),
                                                      bootstrap95=[boot[249], boot[9749]], seed=1147)
    # Collect memory independently so the Darwin time wrapper cannot change wall timings.
    memory = []
    for pair in range(2 * len(commands)):
        order = list(commands) if pair % 2 == 0 else list(reversed(commands))
        for lane in order:
            cmd, cases = commands[lane]
            rounds = report["repetitions"]
            result = subprocess.run(["/usr/bin/time", "-l", *cmd, str(rounds)],
                                    capture_output=True, text=True, timeout=60, check=True)
            peak = re.search(r"^\s*(\d+)\s+maximum resident set size", result.stderr, re.M)
            if not peak or result.stdout != f"{rounds * cases}\n":
                raise ValueError(f"invalid memory sample for {lane}")
            memory.append(dict(pair=pair, lane=lane, peak_rss_bytes=int(peak[1]), counters=result.stderr))
    report["memory_samples"] = memory
    for lane in work:
        report["images"][lane]["median_peak_rss_bytes"] = statistics.median(
            row["peak_rss_bytes"] for row in memory if row["lane"] == lane)
    report["fastest_reference"] = {}
    for lane in ("search", "check"):
        fastest = max(("rust", "nim", "koka", "shen"),
                      key=lambda lang: report["images"][f"{lang}-{lane}"]["work_units_per_second"])
        reference = report["images"][f"{fastest}-{lane}"]
        report["fastest_reference"][lane] = dict(
            language=fastest, elapsed=report[f"fenrir_over_{fastest}_{lane}"],
            peak_rss_ratio=report["images"][lane]["median_peak_rss_bytes"] / reference["median_peak_rss_bytes"])
    if identify() != build_inputs:
        raise ValueError("shared compiler or runtime sources changed during measurement")
    for name, digest in report["fenrir_build_inputs"].items():
        if sha(root / name) != digest:
            raise ValueError("prover build input changed during measurement: " + name)
    report["shared_build_inputs"] = build_inputs
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(out / "report.json", {k:v["work_units_per_second"] for k,v in report["images"].items()})


if __name__ == "__main__":
    main()
