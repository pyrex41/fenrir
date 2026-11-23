"""Combine one target's prover, HTTP router and framed-log timing reports."""
import argparse
from itertools import islice
import hashlib
import json
import math
from pathlib import Path
import random
import re
from runpy import run_path
import statistics


def threshold_verdict(interval, limit):
    low, high = interval
    if high <= limit:
        return "meets-threshold"
    if low > limit:
        return "above-threshold"
    return "undetermined"


def timings(values, reference, ratios, rss=None):
    if len(values) < 10 or any(not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("expected ten or more valid paired elapsed-time ratios")
    ratios.append(values)
    return dict(reference=reference, pairs=len(values), median=statistics.median(values), rss_ratio=rss)


def timing_blocks(rows, key, names, metric="wall_ns"):
    pairs = {}
    for row in rows:
        name = row[key]
        if name in names:
            block = pairs.setdefault(row["pair"], {})
            if name in block:
                raise ValueError("duplicate timing within pair")
            block[name] = row[metric]
    return list(pairs.values())


def matched_ratios(blocks, subject, references, selected):
    for block in blocks:
        for name in [subject, *references]:
            ns = block.get(name)
            if type(ns) is not int or ns <= 0:
                raise ValueError("missing or invalid elapsed time for " + name)
    fastest_ns = min(statistics.median(b[name] for b in blocks) for name in references)
    if selected not in references or statistics.median(b[selected] for b in blocks) != fastest_ns:
        raise ValueError("reported reference differs from fastest eligible median")
    return [b[subject] / b[selected] for b in blocks]


def elapsed_comparison(values):
    n = len(values)
    if n % 2:
        # For an odd sample the resampled median is an order statistic. At
        # rank r its CDF is P(Binomial(n, r/n) >= (n+1)/2). Count resamples
        # exactly so a marginal percentile cannot move by a whole rank.
        ordered = sorted(values)
        middle = n // 2 + 1
        total = n ** n
        lo, hi = 1, middle
        while lo < hi:
            rank = (lo + hi) // 2
            below = sum(math.comb(n, k) * rank ** k * (n - rank) ** (n - k)
                        for k in range(middle, n + 1))
            if 40 * below >= total:
                hi = rank
            else:
                lo = rank + 1
        interval = [ordered[lo - 1], ordered[n - lo]]
    else:
        rng = random.Random(1147)
        boot = sorted(statistics.median(rng.choices(values, k=n)) for _ in range(10000))
        interval = [boot[249], boot[9749]]
    return dict(pairs=n, median=statistics.median(values), bootstrap95=interval)


def reference_timings(blocks, subject, names):
    return {language: elapsed_comparison([b[subject] / b[key] for b in blocks])
            for language, key in names.items()}


def memory_report(blocks, subject, reference, reported=None):
    if len(blocks) < 10 or any(type(b.get(name)) is not int or b[name] <= 0
                               for b in blocks for name in (subject, reference)):
        raise ValueError("expected ten complete pairs of positive peak RSS measurements")

    def ratio(sample):
        return statistics.median(b[subject] for b in sample) / statistics.median(b[reference] for b in sample)

    estimate = ratio(blocks)
    if reported is not None and not math.isclose(estimate, reported, rel_tol=1e-12):
        raise ValueError("reported memory ratio differs from raw peak RSS")
    rng = random.Random(1147)
    boot = sorted(ratio(rng.choices(blocks, k=len(blocks))) for _ in range(10000))
    low, high = boot[249], boot[9749]
    return dict(pairs=len(blocks), ratio=estimate, bootstrap95=[low, high],
                verdict=threshold_verdict((low, high), 2))


def prover_input_identity(report):
    directory = Path(__file__).with_name("prover")
    complete = True
    for field, name in (("corpus_sha256", "corpus-v1.txt"),
                        ("certificates_sha256", "certificates-v1.txt")):
        digest = report.get(field)
        if digest is None:
            complete = False
        elif digest != hashlib.sha256((directory / name).read_bytes()).hexdigest():
            raise ValueError("different prover input for " + name)
    return "matched" if complete else "unrecorded"


def prover_work(report):
    directory = Path(__file__).with_name("prover")
    cases = (directory / "corpus-v1.txt").read_text().splitlines()
    counts = {"search": len(cases), "check": sum(row.split()[1] == "proof" for row in cases)}
    mac = report["target"] == "macos-arm64"
    rounds = report.get("repetitions" if mac else "rounds")
    if rounds is None:
        return "unrecorded"
    if type(rounds) is not int or rounds != 5000:
        raise ValueError("expected 5,000 prover rounds per timed sample")
    if mac:
        complete = True
        for row in report["samples"]:
            lane = row["lane"].split("-")[-1]
            if "rounds" not in row or "result" not in row:
                complete = False
            elif (row["rounds"] != rounds or type(row["result"]) is not int or
                  row["result"] != rounds * counts[lane]):
                raise ValueError("incorrect completed prover work for " + row["lane"])
        return "matched" if complete else "unrecorded"

    complete = True
    for lane, count in counts.items():
        for row in report["lanes"][lane]["samples"]:
            if "console" not in row or "order" not in row:
                complete = False
                continue
            lines = row["console"].splitlines()
            order = row["order"]
            if sorted(order) != ["program", "reference"]:
                raise ValueError("invalid prover sample order")
            has_rss = "peak_rss_bytes" in row
            if len(lines) != len(order) * (2 if has_rss else 1):
                raise ValueError("incomplete prover guest console")
            for i, name in enumerate(order):
                index = i * (2 if has_rss else 1)
                if list(map(int, lines[index].split())) != [count * rounds, row["ns"][name]]:
                    raise ValueError("incorrect completed prover work or elapsed time for " + name)
                if has_rss and int(lines[index + 1]) * 1024 != row["peak_rss_bytes"][name]:
                    raise ValueError("prover console differs from peak RSS for " + name)
    return "matched" if complete else "unrecorded"


def prover_rates(report):
    directory = Path(__file__).with_name("prover")
    oracle = run_path(str(directory / "verify.py"))
    units = {"search": 0, "check": 0}
    for case in (directory / "corpus-v1.txt").read_text().splitlines():
        _, kind, budget, *tokens = case.split()
        goal = oracle["formula"](iter(tokens))
        units["search"] += sum(1 for _ in islice(oracle["tableau_steps"](goal), int(budget)))
        units["check"] += int(kind == "proof")
    mac = report["target"] == "macos-arm64"
    rounds = report.get("repetitions" if mac else "rounds")
    if rounds is None:
        return "unrecorded"
    complete = True
    for lane, count in units.items():
        label = "tableau node" if lane == "search" else "certificate"
        names = ([lane, *(lang + "-" + lane for lang in ("nim", "rust", "koka", "shen"))]
                 if mac else ["program", "reference"])
        for name in names:
            row = report["images"][name] if mac else report["lanes"][lane]
            rate = row.get("work_units_per_second")
            if not mac and rate is not None:
                rate = rate[name]
            for field, expected in (("units_per_round", count), ("work_unit", label)):
                if field not in row:
                    complete = False
                elif row[field] != expected:
                    raise ValueError(f"incorrect {field} for {name} {lane}")
            if rate is None:
                complete = False
                continue
            times = ([s["wall_ns"] for s in report["samples"] if s["lane"] == name] if mac
                     else [s["ns"][name] for s in row["samples"]])
            expected = count * rounds * 1e9 / statistics.median(times)
            if not math.isclose(rate, expected, rel_tol=1e-12):
                raise ValueError(f"incorrect prover work rate for {name} {lane}")
    return "matched" if complete else "unrecorded"


def service_kernel_inputs(http, stream):
    directory = Path(__file__).parent
    cases = run_path(str(directory / "http/check-router.py"))["corpus"]()
    header = run_path(str(directory / "http/measure-router-spt.py"))["corpus_header"](cases)
    block, repeats, output = run_path(str(directory / "framed-log/measure.py"))["workload_blocks"](stream["profile"])
    digest = hashlib.sha256()
    for _ in range(repeats):
        digest.update(block)
    observed_output = stream.get("expected_output_sha256")
    if "expected_output" in stream:
        text_digest = hashlib.sha256(stream["expected_output"].encode()).hexdigest()
        if observed_output is not None and text_digest != observed_output:
            raise ValueError("inconsistent framed-log expected output")
        observed_output = text_digest
    checks = {
        "router corpus": (http.get("sha256", {}).get("corpus.h"), hashlib.sha256(header.encode()).hexdigest()),
        "router heads": (http.get("heads_per_round", http.get("heads")), len(cases)),
        "router bytes": (http.get("bytes_per_round"), sum(len(head) for head, _ in cases)),
        "stream corpus": (stream.get("input_sha256"), digest.hexdigest()),
        "stream bytes": (stream.get("bytes"), len(block) * repeats),
        "stream expected output": (observed_output, hashlib.sha256(output).hexdigest()),
    }
    for name, (actual, expected) in checks.items():
        if actual is not None and actual != expected:
            raise ValueError("different benchmark input for " + name)
    complete = all(actual is not None for actual, _ in checks.values())
    # Darwin runners retain each invocation's stdout digest. Startup reads
    # an empty file, while warmup, elapsed and RSS runs read the corpus.
    if http.get("target") == "darwin-arm64":
        for group in ("startup", "warmups", "samples", "memory_samples"):
            wanted = hashlib.sha256(b"" if group == "startup" else output).hexdigest()
            samples = stream.get(group, [])
            complete = complete and bool(samples)
            for sample in samples:
                actual = sample.get("output_sha256")
                if actual is None:
                    complete = False
                elif actual != wanted:
                    raise ValueError(f"incorrect framed-log output for {group} sample")
    return "matched" if complete else "unrecorded"


def summarize(prover, http, stream):
    rows, ratios = {}, []
    prover_identity = prover_input_identity(prover)
    completed_work = prover_work(prover)
    work_rates = prover_rates(prover)
    service_inputs = service_kernel_inputs(http, stream)
    reports = (prover, http, stream)
    identity_complete = True
    for values in ([r.get("hardware") for r in reports],
                   [r.get("host") or r.get("system") for r in reports]):
        recorded = {v for v in values if v}
        if len(recorded) > 1:
            raise ValueError("different benchmark hosts")
        identity_complete = identity_complete and all(values)
    manifests = [r.get("shared_build_inputs") for r in reports]
    source_identity = "unrecorded"
    if any(m is not None for m in manifests):
        schema = run_path(str(Path(__file__).with_name("solo5-build-inputs.py")))
        supported = [set(schema[name]) for name in ("SHEN_PATHS", "JS_APPLICATION_PATHS", "SHARED_PATHS", "PRE_PROFILE_PATHS", "ORIGINAL_PATHS")]
        if (not manifests[0] or set(manifests[0]) not in supported
                or any(not isinstance(h, str) or not re.fullmatch("[0-9a-f]{64}", h)
                       for h in manifests[0].values())
                or any(m != manifests[0] for m in manifests)):
            raise ValueError("different or missing shared build inputs")
        if set(manifests[0]) != set(schema["ORIGINAL_PATHS"]):
            source_identity = "matched"
    if prover["target"] == "macos-arm64":
        if http["target"] != "darwin-arm64" or "compilers" not in stream:
            raise ValueError("expected three Mac reports")
        inputs = [prover["fenrir_build_inputs"], http["source_sha256"], stream["compilers"]["fenrir"]["sources"]]
        common = {"runtime/native/heap.c", "runtime/native/heap.h", "runtime/native/managed.c",
                  "tools/aarch64/managed-image.mjs", "tools/aarch64/byte-scan.mjs"}
        if manifests[0] and "backends/arm64/managed.shen" in manifests[0]:
            common = set(schema["SHEN_PATHS"])
        if manifests[0] and "spec/native/standalone-v1.json" in manifests[0]:
            common.update(schema["PROFILE_PATHS"])
            stamp = inputs[0].get("tools/aarch64/native-profile-stamp.mjs")
            if not isinstance(stamp, str) or not re.fullmatch("[0-9a-f]{64}", stamp):
                raise ValueError("missing standalone image stamp source identity")
        seen = dict(manifests[0] or {})
        for manifest in inputs:
            if not common.issubset(manifest):
                raise ValueError("missing compiler or runtime identities")
            for name, digest in manifest.items():
                if name in seen and seen[name] != digest:
                    raise ValueError("different build inputs for " + name)
                seen[name] = digest
        for lane in ("search", "check"):
            record = prover["fastest_reference"][lane]
            ref = record["language"]
            references = [lang + "-" + lane for lang in ("nim", "rust", "koka", "shen")]
            blocks = timing_blocks(prover["samples"], "lane", [lane, *references])
            values = matched_ratios(blocks, lane, references, ref + "-" + lane)
            rows[lane] = timings(values, ref, ratios, record["peak_rss_ratio"])
            rows[lane]["eligible_references"] = reference_timings(
                blocks, lane, {name.removesuffix("-" + lane): name for name in references})
        record = http["fastest_measured_reference"]
        if set(record["eligible_measured"]) != {"koka", "rust", "nim"} or record["required_missing"]:
            raise ValueError("incomplete router references")
        ref = record["language"]
        blocks = [s["ns"] for s in http["samples"]]
        references = ["nim", "rust", "koka"]
        values = matched_ratios(blocks, "fenrir", references, ref)
        rows["router"] = timings(values, ref, ratios, record["peak_rss_ratio"])
        rows["router"]["eligible_references"] = reference_timings(blocks, "fenrir", {n: n for n in references})
        record = stream["fastest_measured_reference"]
        ref = record["language"]
        references = ["nim", "rust", "koka", "shen"]
        blocks = timing_blocks(stream["samples"], "language", ["fenrir", *references])
        rows["stream"] = timings(matched_ratios(blocks, "fenrir", references, ref),
                                 ref, ratios, record["fenrir_rss_ratio"])
        rows["stream"]["eligible_references"] = reference_timings(blocks, "fenrir", {n: n for n in references})
        for lane in ("search", "check", "router", "stream"):
            reference = rows[lane]["reference"]
            subject = "fenrir"
            if lane in ("search", "check"):
                subject, reference = lane, reference + "-" + lane
                blocks = timing_blocks(prover["memory_samples"], "lane", [subject, reference], "peak_rss_bytes")
            elif lane == "router":
                blocks = [s["peak_rss_bytes"] for s in http["samples"]]
            else:
                blocks = timing_blocks(stream["memory_samples"], "language", [subject, reference], "peak_rss_bytes")
            rows[lane]["memory"] = memory_report(blocks, subject, reference, rows[lane]["rss_ratio"])
    elif prover["target"] == http["target"] == "solo5-arm64-spt":
        cpus = [r.get("guest_cpu") for r in (prover, http, stream)]
        if any(cpu is not None for cpu in cpus) and not (
                isinstance(cpus[0], str) and cpus[0].isascii() and cpus[0].isdecimal()
                and all(cpu == cpus[0] for cpu in cpus)):
            raise ValueError("different or incomplete Solo5 benchmark CPU identities")
        if len({r["container"] for r in (prover, http, stream)}) != 1:
            raise ValueError("different Solo5 runtime images")
        for lane in ("search", "check"):
            samples = prover["lanes"][lane]["samples"]
            values = matched_ratios([s["ns"] for s in samples], "program", ["reference"], "reference")
            rows[lane] = timings(values, "c", ratios)
            if any("peak_rss_bytes" in sample for sample in samples):
                memory = memory_report([sample["peak_rss_bytes"] for sample in samples], "program", "reference")
                rows[lane].update(memory=memory, rss_ratio=memory["ratio"], memory_scope=prover["memory_scope"])
        for name, report, key in [("router", http, "ns"), ("stream", stream, "elapsed_ns")]:
            samples = report["samples"]
            values = matched_ratios([s[key] for s in samples], "fenrir", ["c"], "c")
            rows[name] = timings(values, "c", ratios)
            if any("peak_rss_bytes" in sample for sample in samples):
                memory = memory_report([sample["peak_rss_bytes"] for sample in samples], "fenrir", "c")
                rows[name].update(memory=memory, rss_ratio=memory["ratio"], memory_scope=report["memory_scope"])
    else:
        raise ValueError("unrecognized target")
    rng = random.Random(1147)
    means = []
    for _ in range(10000):
        draw = [statistics.median(rng.choices(v, k=len(v))) for v in ratios]
        means.append(statistics.geometric_mean(draw))
    means.sort()
    mean_interval = [means[249], means[9749]]
    verdicts = [threshold_verdict(mean_interval, 1.5)]
    for row, values in zip(rows.values(), ratios):
        reference = row["reference"]
        if "eligible_references" not in row:
            row["eligible_references"] = {reference: elapsed_comparison(values)}
        interval = row["eligible_references"][reference]["bootstrap95"]
        row["elapsed_bootstrap95"] = interval
        row["elapsed_verdict"] = threshold_verdict(interval, 2)
        verdicts.append(row["elapsed_verdict"])
    if "above-threshold" in verdicts:
        elapsed_verdict = "above-threshold"
    elif "undetermined" in verdicts:
        elapsed_verdict = "undetermined"
    else:
        elapsed_verdict = "meets-threshold"
    mean = statistics.geometric_mean(row["median"] for row in rows.values())
    memory_verdicts = [row.get("memory", {}).get("verdict", "undetermined") for row in rows.values()]
    gates = [elapsed_verdict, *memory_verdicts]
    if "above-threshold" in gates:
        kernel_verdict = "above-threshold"
    elif "undetermined" in gates or not identity_complete or "unrecorded" in (source_identity, prover_identity, completed_work, work_rates, service_inputs):
        kernel_verdict = "undetermined"
    else:
        kernel_verdict = "meets-threshold"
    return dict(kernel_verdict=kernel_verdict, host_identity="matched" if identity_complete else "unrecorded",
                prover_input_identity=prover_identity, prover_completed_work=completed_work, prover_work_rates=work_rates, router_and_stream_input_identity=service_inputs,
                shared_source_identity=source_identity, target=prover["target"], stream_profile=stream["profile"], rows=rows,
                elapsed_ratio_geomean=mean, bootstrap95=mean_interval, bootstrap_seed=1147,
                geomean_verdict=verdicts[0], elapsed_verdict=elapsed_verdict,
                elapsed_point_estimates_within_gates=mean <= 1.5 and all(r["median"] <= 2 for r in rows.values()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("prover", "router", "stream"):
        parser.add_argument(name, type=Path, help="path to report.json")
    paths = vars(parser.parse_args())
    sources = {k: p.read_bytes() for k, p in paths.items()}
    score = summarize(*(json.loads(sources[name]) for name in ("prover", "router", "stream")))
    score["reports"] = {name: dict(path=str(paths[name]), sha256=hashlib.sha256(data).hexdigest())
                        for name, data in sources.items()}
    print(json.dumps(score, indent=2))
