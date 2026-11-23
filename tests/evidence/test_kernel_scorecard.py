"""Regression checks for the elapsed-time intervals in the published scorecards."""
import json
from pathlib import Path
from runpy import run_path
import tarfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCORE = run_path(str(ROOT / "benchmarks/kernel-scorecard.py"))
ARCHIVES = ROOT / "verification/performance/2026-11-22-arm64"


class KernelIntervals(unittest.TestCase):
    def test_profile_aware_shared_sources_and_prover_stamp(self):
        helper = run_path(str(ROOT / "benchmarks/solo5-build-inputs.py"))
        with tarfile.open(ARCHIVES / "validated-package-mac-kernels.tar.gz") as archive:
            reports = [json.load(archive.extractfile(f"{lane}/report.json")) for lane in ("prover", "router", "stream")]
        prover, router, stream = reports
        shared = helper["shared_inputs"]()
        profile = {name: shared[name] for name in helper["PROFILE_PATHS"]}
        for report in reports:
            report["shared_build_inputs"].update(profile)
        for manifest in (prover["fenrir_build_inputs"], router["source_sha256"], stream["compilers"]["fenrir"]["sources"]):
            manifest.update(profile)
        with self.assertRaisesRegex(ValueError, "missing standalone image stamp"):
            SCORE["summarize"](*reports)
        prover["fenrir_build_inputs"]["tools/aarch64/native-profile-stamp.mjs"] = "e" * 64
        self.assertEqual(SCORE["summarize"](*reports)["shared_source_identity"], "matched")
        stream["compilers"]["fenrir"]["sources"]["spec/native/standalone-v1.json"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "different build inputs"):
            SCORE["summarize"](*reports)

    def test_odd_sample_bootstrap_median_ranks(self):
        # Of 15^15 equally likely resamples, at least 2.5% have a median
        # at or below the fourth observation. By symmetry the upper rank is 12.
        self.assertEqual(SCORE["elapsed_comparison"](list(range(1, 16)))["bootstrap95"], [4, 12])

    def test_selected_reference_and_gate_share_interval(self):
        for target, prefix in [("mac", ""), ("solo5", "results/")]:
            with self.subTest(target=target):
                with tarfile.open(ARCHIVES / f"validated-package-{target}-kernels.tar.gz") as archive:
                    reports = [json.load(archive.extractfile(f"{prefix}{lane}/report.json"))
                               for lane in ("prover", "router", "stream")]
                score = SCORE["summarize"](*reports)
                for row in score["rows"].values():
                    interval = row["eligible_references"][row["reference"]]["bootstrap95"]
                    self.assertEqual(row["elapsed_bootstrap95"], interval)
                    self.assertEqual(row["elapsed_verdict"], SCORE["threshold_verdict"](interval, 2))
                if target == "mac":
                    self.assertEqual(score["rows"]["router"]["elapsed_bootstrap95"],
                                     [0.7063337579617834, 1.6970562764658952])


if __name__ == "__main__":
    unittest.main()
