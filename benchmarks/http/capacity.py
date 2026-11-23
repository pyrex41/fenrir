"""Estimate sustainable HTTP capacity bounds from a matched offered-rate sweep."""
import argparse
import hashlib
import json
from pathlib import Path
from runpy import run_path

assessment_module = run_path(str(Path(__file__).with_name("assess-rate.py")))
assess = assessment_module["assess"]
verify_origin = assessment_module["verify_sample_origin"]


def bounds(by_rate):
    lower = upper = None
    for rate, verdicts in sorted(by_rate.items()):
        if all(v == "sustained-at-offered-rate" for v in verdicts):
            lower = rate
        elif all(v in ("failed-response-criteria", "growing-backlog") for v in verdicts) and upper is None:
            upper = rate
    if lower is not None and upper is not None and lower >= upper:
        raise ValueError("non-monotonic capacity evidence, repeat the affected rates")
    return dict(sustained=lower, failed=upper)


def select(estimates):
    references = [name for name in estimates if name != "fenrir"]
    for name in references:
        floor = estimates[name]["sustained"]
        if floor is None:
            continue
        if all(estimates[other]["failed"] is not None and estimates[other]["failed"] <= floor
               for other in references if other != name):
            return name
    return None


def throughput_comparison(estimates):
    fenrir = estimates["fenrir"]
    peers = [value for name, value in estimates.items() if name != "fenrir"]
    # A sustained rate is inclusive. A failing rate is an exclusive upper
    # bound under the same monotonicity assumption used for reference selection.
    if fenrir["sustained"] is not None and all(peer["failed"] is not None for peer in peers):
        if 3 * fenrir["sustained"] >= 2 * max(peer["failed"] for peer in peers):
            return "meets-threshold"
    if fenrir["failed"] is not None and any(
            peer["sustained"] is not None and 3 * fenrir["failed"] <= 2 * peer["sustained"]
            for peer in peers):
        return "below-threshold"
    return "undetermined"


def observations(folder, env):
    rates = env["rates"]
    if type(env["blocks"]) is not int or env["blocks"] < 1:
        raise ValueError("capacity sweep requires positive block count")
    if (not isinstance(rates, list) or not rates or any(type(r) is not int or r < 1 for r in rates)
            or len(set(rates)) != len(rates)):
        raise ValueError("capacity sweep requires distinct positive rates per block")
    names = {"mac": ("fenrir", "rust", "nim"), "solo5": ("fenrir", "c"),
             "elixir": ("elixir",)}[env["target"]]
    environment_digest = hashlib.sha256((folder / "environment.json").read_bytes()).hexdigest()
    excluded = folder / "exclusions.json"
    exclusions = json.loads(excluded.read_text()) if excluded.exists() else {}
    rows = {name: {} for name in names}
    for block in range(env["blocks"]):
        for ri, rate in enumerate(env["rates"]):
            index = block * len(env["rates"]) + ri
            for name in names:
                path = folder / f"{index}-{name}-{rate}.json"
                if path.name in exclusions:
                    verdict = "excluded"
                elif not path.exists():
                    verdict = "missing"
                else:
                    row = json.loads(path.read_text())
                    verify_origin(row, env, name, block, ri, environment_digest)
                    expected = (block, ri, rate, env["seconds"], env["connections"])
                    if tuple(row[k] for k in ("Block", "RateIndex", "Rate", "Seconds", "Connections")) != expected:
                        raise ValueError(f"mismatched workload in {path}")
                    assessment = assess(row)
                    verdict = assessment["verdict"]
                    if env["seconds"] < 600 and verdict != "invalid-response":
                        verdict = "short-run"
                rows[name].setdefault(rate, []).append(verdict)
    return rows


def sweep_identity(env):
    identity = dict(env)
    del identity["rates"]
    identity["binaries"] = assessment_module["binary_identities"](env)
    return identity


def summarize(folder, *additional):
    env = json.loads((folder / "environment.json").read_text())
    identity = sweep_identity(env)
    rows = observations(folder, env)
    rates = set(env["rates"])
    for other in additional:
        extra = json.loads((other / "environment.json").read_text())
        if sweep_identity(extra) != identity:
            raise ValueError("offered-rate sweeps have different environments")
        if rates.intersection(extra["rates"]):
            raise ValueError("combined sweeps must cover distinct rates")
        rates.update(extra["rates"])
        for name, results in observations(other, extra).items():
            rows[name].update(results)
    estimates = {name: bounds(results) for name, results in rows.items()}
    if env["target"] == "elixir":
        return dict(target="elixir", sample_origin_version=env.get("sample_origin_version"),
                    comparison=env["comparison"], darwin_logical_cpu_max=assessment_module["darwin_cpu_limit"](env),
                observations=rows, capacity_bounds=estimates)
    mismatches = sorted(name for name, by_rate in rows.items()
                        if any("invalid-response" in verdicts for verdicts in by_rate.values()))
    reference = None if mismatches else select(estimates)
    latency_rate = None
    if reference and all(estimates[n][k] is not None for n in ("fenrir", reference)
                         for k in ("sustained", "failed")):
        latency_rate = 7 * min(estimates[n]["sustained"] for n in ("fenrir", reference)) // 10
    return dict(target=env["target"], sample_origin_version=env.get("sample_origin_version"),
                darwin_logical_cpu_max=assessment_module["darwin_cpu_limit"](env),
                observations=rows, capacity_bounds=estimates,
                reference=reference, paired_latency_rate=latency_rate,
                capacity_blocks=env["blocks"], invalid_response_workers=mismatches,
                two_thirds_capacity_comparison="undetermined" if mismatches else throughput_comparison(estimates))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", type=Path, nargs="+")
    print(json.dumps(summarize(*parser.parse_args().folders), indent=2))
